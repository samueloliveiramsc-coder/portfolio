/* =============================================================================
   SFCS - ETL MongoDB (SPEND / WATCH) -> SQL Server -> Power BI
   03 - Procedures chamadas pelo pacote SSIS

   Fluxo do pacote Carga_Mongo_SPEND_WATCH.dtsx:
     1. etl.usp_IniciarCarga    -> abre a carga, limpa a staging, devolve CargaId e o filtro incremental
     2. Data Flow WATCH / SPEND -> ZappySys MongoDB Source (RAW JSON) -> stg.MongoDocumento
     3. etl.usp_ProcessarCarga  -> achata o JSON, trata contadores e carrega dimensões e fatos
     (OnError) etl.usp_RegistrarFalha
============================================================================= */
USE SFCS_DW;
GO

/* -----------------------------------------------------------------------------
   Abre uma carga e devolve (CargaId, FiltroDesdeUtc) para as variáveis do pacote.
   FiltroDesdeUtc = última leitura carregada - margem, no formato ISO aceito pelo
   placeholder {{User::FiltroDesdeUtc}} da consulta ZappySys.
----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_IniciarCarga
    @MongoDatabase nvarchar(64)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Margem int = ISNULL(TRY_CONVERT(int, (SELECT Valor FROM etl.Configuracao WHERE Chave = 'MARGEM_MINUTOS')), 10);
    DECLARE @Dias   int = ISNULL(TRY_CONVERT(int, (SELECT Valor FROM etl.Configuracao WHERE Chave = 'CARGA_INICIAL_DIAS')), 0);
    DECLARE @Desde  datetime2(3);

    SELECT @Desde = DATEADD(MINUTE, -@Margem, UltimaLeituraUtc)
    FROM etl.ControleCarga
    WHERE MongoDatabase = @MongoDatabase;

    IF @Desde IS NULL
        SET @Desde = CASE WHEN @Dias > 0 THEN DATEADD(DAY, -@Dias, SYSUTCDATETIME()) ELSE '19700101' END;

    BEGIN TRAN;
        -- Cargas que ficaram abertas (pacote abortado) são encerradas como falha
        UPDATE etl.Carga
        SET Status = 'FALHA', Fim = SYSUTCDATETIME(),
            Mensagem = ISNULL(Mensagem, N'Carga interrompida: nova carga iniciada antes do término.')
        WHERE MongoDatabase = @MongoDatabase AND Status = 'EXECUTANDO';

        DELETE stg.MongoDocumento WHERE MongoDatabase = @MongoDatabase;

        INSERT etl.Carga (MongoDatabase, FiltroDesdeUtc) VALUES (@MongoDatabase, @Desde);
        DECLARE @CargaId int = CAST(SCOPE_IDENTITY() AS int);
    COMMIT;

    SELECT @CargaId AS CargaId,
           FORMAT(@Desde, 'yyyy-MM-ddTHH:mm:ss.fff', 'en-US') + 'Z' AS FiltroDesdeUtc;
END
GO

/* -----------------------------------------------------------------------------
   Chamado pelo event handler OnError do pacote.
----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_RegistrarFalha
    @CargaId  int,
    @Mensagem nvarchar(4000)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE etl.Carga
    SET Status = 'FALHA', Fim = SYSUTCDATETIME(),
        Mensagem = LEFT(ISNULL(Mensagem + N' | ', N'') + @Mensagem, 4000)
    WHERE CargaId = @CargaId AND Status <> 'SUCESSO';
END
GO

/* -----------------------------------------------------------------------------
   Diferença entre duas leituras de um contador acumulado.
     primeira leitura da máquina         -> 0 (linha de base, nada a comparar)
     contadores reiniciados / sem valor anterior -> valor atual (contado desde o reinício)
     contador diminuiu sem reinício       -> valor atual (reinício isolado do contador)
----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION etl.fn_Delta (@Atual int, @Anterior int, @Primeira bit, @Reinicio bit)
RETURNS int
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE WHEN @Primeira = 1 THEN 0
                WHEN @Reinicio = 1 OR @Anterior IS NULL THEN ISNULL(@Atual, 0)
                WHEN @Atual >= @Anterior THEN @Atual - @Anterior
                ELSE ISNULL(@Atual, 0) END;
END
GO

/* -----------------------------------------------------------------------------
   Processa os documentos da staging de uma carga e alimenta o modelo dw.
   Tudo em uma transação: em caso de erro nada é gravado e a carga fica como FALHA.
   Reprocessar é seguro: leituras e eventos já carregados são ignorados (MongoId).
----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_ProcessarCarga
    @CargaId int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @MongoDatabase nvarchar(64) = (SELECT MongoDatabase FROM etl.Carga WHERE CargaId = @CargaId);
    IF @MongoDatabase IS NULL
        THROW 50001, N'Carga não encontrada em etl.Carga.', 1;

    DECLARE @Fuso sysname = ISNULL((SELECT Valor FROM etl.Configuracao WHERE Chave = 'FUSO_HORARIO'), N'SA Western Standard Time');
    IF NOT EXISTS (SELECT 1 FROM sys.time_zone_info WHERE name = @Fuso)
        THROW 50002, N'FUSO_HORARIO inválido em etl.Configuracao (consulte sys.time_zone_info).', 1;

    DECLARE @Agora datetime2(3) = SYSUTCDATETIME();
    DECLARE @EpochMinimo bigint = 1577836800;  -- 2020-01-01: abaixo disso TimeStart/TimeStop não é um epoch válido
    DECLARE @LeiturasInseridas int = 0, @LeiturasRepetidas int = 0, @FeedersInseridos int = 0, @EventosInseridos int = 0;

    BEGIN TRY
        /* ===================== 1. Documentos (campos de topo) ===================== */
        CREATE TABLE #Doc (
            StgId        bigint         NOT NULL PRIMARY KEY,
            Colecao      varchar(20)    NOT NULL,
            MongoId      char(24)       NOT NULL,
            Tipo         varchar(50)    NULL,
            Modulo       nvarchar(50)   NULL,
            Sala         nvarchar(50)   NULL,
            DataHoraUtc  datetime2(3)   NULL,
            Sucesso      bit            NULL,
            Status       nvarchar(50)   NULL,
            Texto        nvarchar(1000) NULL,
            Codigo       nvarchar(50)   NULL,
            RowsJson     nvarchar(max)  NULL,
            DataJson     nvarchar(max)  NULL
        );

        INSERT #Doc
        SELECT s.StgId, s.Colecao, j.MongoId, j.Tipo, j.Modulo, j.Sala,
               CAST(TRY_CONVERT(datetimeoffset(3), j.UpdateIso, 127) AS datetime2(3)),
               j.Sucesso, j.Status, LEFT(j.Texto, 1000), j.Codigo, j.RowsJson, j.DataJson
        FROM stg.MongoDocumento s
        CROSS APPLY OPENJSON(s.Documento) WITH (
            MongoId   char(24)       '$._id."$oid"',
            Tipo      varchar(50)    '$.type',
            Modulo    nvarchar(50)   '$.module',
            Sala      nvarchar(50)   '$.room',
            UpdateIso varchar(40)    '$.update."$date"',
            Sucesso   bit            '$.success',
            Status    nvarchar(50)   '$.status',
            Texto     nvarchar(4000) '$.text',
            Codigo    nvarchar(50)   '$.message.code',
            RowsJson  nvarchar(max)  '$.rows' AS JSON,
            DataJson  nvarchar(max)  '$.data' AS JSON
        ) j
        WHERE s.CargaId = @CargaId
          AND j.MongoId IS NOT NULL;

        DECLARE @DocsWatch int = (SELECT COUNT(*) FROM #Doc WHERE Colecao = 'WATCH');
        DECLARE @DocsSpend int = (SELECT COUNT(*) FROM #Doc WHERE Colecao = 'SPEND');

        BEGIN TRAN;

        /* ===================== 2. Linhas e máquinas ===================== */
        INSERT dw.DimLinha (MongoDatabase, Sala, Linha)
        SELECT DISTINCT @MongoDatabase, d.Sala, REPLACE(d.Sala, N'ROOM_', N'')
        FROM #Doc d
        WHERE d.Sala IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dw.DimLinha l WHERE l.MongoDatabase = @MongoDatabase AND l.Sala = d.Sala);

        -- Cadastro das máquinas publicado pelo coletor ao iniciar a agenda (START_AGENDA_*)
        SELECT a.code AS Modulo, a.model AS Modelo, a.node AS NoColetor, a.machine AS Ip, d.Sala,
               ROW_NUMBER() OVER (PARTITION BY d.Sala, a.code ORDER BY d.DataHoraUtc DESC) AS rn
        INTO #Agenda
        FROM #Doc d
        CROSS APPLY OPENJSON(d.RowsJson) WITH (
            code nvarchar(50), model nvarchar(50), node nvarchar(20), machine varchar(45)
        ) a
        WHERE d.Tipo LIKE 'START_AGENDA%' AND a.code IS NOT NULL;

        ;WITH m AS (
            SELECT Sala, Modulo FROM #Doc WHERE Tipo IN ('SPEND', 'AUDIT', 'PICKED') AND Modulo IS NOT NULL AND Sala IS NOT NULL
            UNION
            SELECT Sala, Modulo FROM #Agenda WHERE Sala IS NOT NULL
        )
        INSERT dw.DimMaquina (LinhaKey, Modulo, Familia)
        SELECT l.LinhaKey, m.Modulo, LEFT(m.Modulo, CHARINDEX(N'-', m.Modulo + N'-') - 1)
        FROM m
        JOIN dw.DimLinha l ON l.MongoDatabase = @MongoDatabase AND l.Sala = m.Sala
        WHERE NOT EXISTS (SELECT 1 FROM dw.DimMaquina x WHERE x.LinhaKey = l.LinhaKey AND x.Modulo = m.Modulo);

        UPDATE dm
        SET Modelo = a.Modelo, NoColetor = a.NoColetor, IpModulo = ISNULL(a.Ip, dm.IpModulo)
        FROM dw.DimMaquina dm
        JOIN dw.DimLinha l ON l.LinhaKey = dm.LinhaKey AND l.MongoDatabase = @MongoDatabase
        JOIN #Agenda a ON a.Sala = l.Sala AND a.Modulo = dm.Modulo AND a.rn = 1;

        /* ===================== 3. Leituras SPEND do WATCH ===================== */
        CREATE TABLE #Leitura (
            MongoId          char(24)      NOT NULL PRIMARY KEY,
            MaquinaKey       int           NOT NULL,
            DataHoraUtc      datetime2(3)  NOT NULL,
            Ip               varchar(45)   NULL,
            Arquivo          nvarchar(260) NOT NULL,
            Placa            nvarchar(100) NOT NULL,
            ProgramaKey      int           NULL,
            TimeStart        bigint        NOT NULL,
            TimeStop         bigint        NOT NULL,
            EstadoMaquina    smallint      NULL,
            CodigoErro       int           NULL,
            SinalLuminoso    smallint      NULL,
            PlacasAcum int NOT NULL, TempoRodandoAcum int NOT NULL, TempoPlacaAcum int NOT NULL,
            TempoEsperaEntradaAcum int NOT NULL, TempoEsperaSaidaAcum int NOT NULL, TempoParadaParcialAcum int NOT NULL,
            TempoReparoAcum int NOT NULL, TempoFalhaAcum int NOT NULL, TempoSemComponenteAcum int NOT NULL,
            TempoParadoAcum int NOT NULL, PickAcum int NOT NULL, PlaceAcum int NOT NULL, MissedAcum int NOT NULL,
            SetupFront       int           NULL,
            FeederJson       nvarchar(max) NULL,
            SetupJson        nvarchar(max) NULL
        );

        INSERT #Leitura
        SELECT d.MongoId, dm.MaquinaKey, d.DataHoraUtc, w.Ip,
               ISNULL(NULLIF(w.Arquivo, N''), N'N/D'), ISNULL(NULLIF(w.Placa, N''), N'N/D'), NULL,
               ISNULL(w.TimeStart, 0), ISNULL(w.TimeStop, 0), w.MachineStat, w.ErrorCode, w.SigLight,
               ISNULL(w.ProductNum, 0), ISNULL(w.TimeRun, 0), ISNULL(w.TimePwb, 0),
               ISNULL(w.TimePwbIn, 0), ISNULL(w.TimePwbOut, 0), ISNULL(w.TimeSomeStop, 0),
               ISNULL(w.TimeRepair, 0), ISNULL(w.TimeTrouble, 0), ISNULL(w.TimeNoComp, 0),
               ISNULL(w.TimeDown, 0), ISNULL(sn.Pick, 0), ISNULL(sn.Place, 0), ISNULL(fd.Missed, 0),
               w.SetupFront, w.FeederJson, w.SetupJson
        FROM #Doc d
        JOIN dw.DimLinha l    ON l.MongoDatabase = @MongoDatabase AND l.Sala = d.Sala
        JOIN dw.DimMaquina dm ON dm.LinhaKey = l.LinhaKey AND dm.Modulo = d.Modulo
        CROSS APPLY OPENJSON(d.RowsJson, '$[0]') WITH (
            Ip           varchar(45)   '$.waste.ipmodule',
            ProductNum   int           '$.waste.snapshot.ProductManage.ProductNum',
            TimeStart    bigint        '$.waste.snapshot.ProductManage.TimeStart',
            TimeStop     bigint        '$.waste.snapshot.ProductManage.TimeStop',
            TimeRun      int           '$.waste.snapshot.ProductManage.TimeRun',
            TimePwb      int           '$.waste.snapshot.ProductManage.TimePwb',
            TimePwbIn    int           '$.waste.snapshot.ProductManage.TimePwbIn',
            TimePwbOut   int           '$.waste.snapshot.ProductManage.TimePwbOut',
            TimeSomeStop int           '$.waste.snapshot.ProductManage.TimeSomeStop',
            TimeRepair   int           '$.waste.snapshot.ProductManage.TimeRepair',
            TimeTrouble  int           '$.waste.snapshot.ProductManage.TimeTrouble',
            TimeNoComp   int           '$.waste.snapshot.ProductManage.TimeNoComp',
            TimeDown     int           '$.waste.snapshot.ProductManage.TimeDown',
            Arquivo      nvarchar(260) '$.waste.snapshot.Module.FileName',
            Placa        nvarchar(100) '$.waste.snapshot.Module.PwbId',
            SigLight     smallint      '$.waste.snapshot.Module.SigLight',
            MachineStat  smallint      '$.waste.snapshot.Module.MachineStat',
            ErrorCode    int           '$.waste.snapshot.Module.ErrorCode',
            StoreJson    nvarchar(max) '$.waste.snapshot.StoreNum' AS JSON,
            FeederJson   nvarchar(max) '$.waste.snapshot.Feeder' AS JSON,
            SetupFront   int           '$.setup.snapshot.Front',
            SetupJson    nvarchar(max) '$.setup.snapshot.Feeder' AS JSON
        ) w
        OUTER APPLY (SELECT SUM(Pick) AS Pick, SUM(Place) AS Place
                     FROM OPENJSON(w.StoreJson) WITH (Pick int, Place int)) sn
        OUTER APPLY (SELECT SUM(Missed) AS Missed
                     FROM OPENJSON(w.FeederJson) WITH (Missed int)) fd
        WHERE d.Colecao = 'WATCH' AND d.Tipo = 'SPEND' AND d.Sucesso = 1
          AND w.ProductNum IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dw.FatoMaquinaLeitura f WHERE f.MongoId = d.MongoId);

        INSERT dw.DimPrograma (Arquivo, Placa)
        SELECT DISTINCT Arquivo, Placa FROM #Leitura x
        WHERE NOT EXISTS (SELECT 1 FROM dw.DimPrograma p WHERE p.Arquivo = x.Arquivo AND p.Placa = x.Placa);

        UPDATE x SET ProgramaKey = p.ProgramaKey
        FROM #Leitura x JOIN dw.DimPrograma p ON p.Arquivo = x.Arquivo AND p.Placa = x.Placa;

        -- IP mais recente informado pela própria leitura
        UPDATE dm SET IpModulo = x.Ip
        FROM dw.DimMaquina dm
        JOIN (SELECT MaquinaKey, Ip, ROW_NUMBER() OVER (PARTITION BY MaquinaKey ORDER BY DataHoraUtc DESC) rn
              FROM #Leitura WHERE Ip IS NOT NULL) x ON x.MaquinaKey = dm.MaquinaKey AND x.rn = 1;

        /* ===================== 4. Feeders das leituras novas ===================== */
        -- O array Feeder lista primeiro os "Front" feeders do setup e depois os traseiros (Rear);
        -- o setup segue a mesma ordem. Lado + posição identificam o feeder.
        CREATE TABLE #Feeder (
            MongoId    char(24) NOT NULL,
            Lado       char(1)  NOT NULL,
            FeederPos  smallint NOT NULL,
            ComponenteCodigo nvarchar(100) NULL,
            Picked int NOT NULL, Placed int NOT NULL, Missed int NOT NULL, NoComp int NOT NULL, DiffComp int NOT NULL,
            ErrorVac int NOT NULL, Laser int NOT NULL, Vision int NOT NULL, Copla int NOT NULL, Verify int NOT NULL,
            Height int NOT NULL, LeadBend int NOT NULL, Colin int NOT NULL,
            PRIMARY KEY (MongoId, Lado, FeederPos)
        );

        ;WITH f AS (
            SELECT x.MongoId,
                   CASE WHEN CAST(a.[key] AS int) < ISNULL(x.SetupFront, 32767) THEN 'F' ELSE 'R' END AS Lado,
                   v.*
            FROM #Leitura x
            CROSS APPLY OPENJSON(x.FeederJson) a
            CROSS APPLY OPENJSON(a.value) WITH (
                FeederPos smallint, Picked int, Placed int, Missed int, NoComp int, DiffComp int, ErrorVac int,
                Laser int, Vision int, Copla int, Verify int, Height int, LeadBend int, Colin int
            ) v
            WHERE v.FeederPos IS NOT NULL
        ), s AS (
            SELECT x.MongoId,
                   CASE WHEN CAST(a.[key] AS int) < ISNULL(x.SetupFront, 32767) THEN 'F' ELSE 'R' END AS Lado,
                   v.No, v.CompoName
            FROM #Leitura x
            CROSS APPLY OPENJSON(x.SetupJson) a
            CROSS APPLY OPENJSON(a.value) WITH (No smallint, CompoName nvarchar(100)) v
        )
        INSERT #Feeder
        SELECT f.MongoId, f.Lado, f.FeederPos,
               (SELECT MIN(s.CompoName) FROM s WHERE s.MongoId = f.MongoId AND s.Lado = f.Lado AND s.No = f.FeederPos),
               SUM(ISNULL(Picked, 0)), SUM(ISNULL(Placed, 0)), SUM(ISNULL(Missed, 0)), SUM(ISNULL(NoComp, 0)), SUM(ISNULL(DiffComp, 0)),
               SUM(ISNULL(ErrorVac, 0)), SUM(ISNULL(Laser, 0)), SUM(ISNULL(Vision, 0)), SUM(ISNULL(Copla, 0)), SUM(ISNULL(Verify, 0)),
               SUM(ISNULL(Height, 0)), SUM(ISNULL(LeadBend, 0)), SUM(ISNULL(Colin, 0))
        FROM f
        GROUP BY f.MongoId, f.Lado, f.FeederPos;

        INSERT dw.DimComponente (Codigo)
        SELECT DISTINCT ComponenteCodigo FROM #Feeder x
        WHERE ComponenteCodigo IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dw.DimComponente c WHERE c.Codigo = x.ComponenteCodigo);

        /* ===================== 5. Sequência, repetidas e diferenças ===================== */
        -- Âncora = última leitura já carregada de cada máquina, anterior às leituras novas
        CREATE TABLE #Seq (
            MongoId     char(24)     NOT NULL PRIMARY KEY,
            LeituraId   bigint       NULL,        -- preenchido para âncoras
            Ancora      bit          NOT NULL,
            MaquinaKey  int          NOT NULL,
            DataHoraUtc datetime2(3) NOT NULL,
            ProgramaKey int          NOT NULL,
            TimeStart   bigint       NOT NULL,
            TimeStop    bigint       NOT NULL,
            EstadoMaquina smallint   NULL,
            CodigoErro  int          NULL,
            SinalLuminoso smallint   NULL,
            PlacasAcum int NOT NULL, TempoRodandoAcum int NOT NULL, TempoPlacaAcum int NOT NULL,
            TempoEsperaEntradaAcum int NOT NULL, TempoEsperaSaidaAcum int NOT NULL, TempoParadaParcialAcum int NOT NULL,
            TempoReparoAcum int NOT NULL, TempoFalhaAcum int NOT NULL, TempoSemComponenteAcum int NOT NULL,
            TempoParadoAcum int NOT NULL, PickAcum int NOT NULL, PlaceAcum int NOT NULL, MissedAcum int NOT NULL,
            Repetida    bit          NULL
        );

        INSERT #Seq
        SELECT MongoId, NULL, 0, MaquinaKey, DataHoraUtc, ProgramaKey, TimeStart, TimeStop, EstadoMaquina, CodigoErro, SinalLuminoso,
               PlacasAcum, TempoRodandoAcum, TempoPlacaAcum, TempoEsperaEntradaAcum, TempoEsperaSaidaAcum, TempoParadaParcialAcum,
               TempoReparoAcum, TempoFalhaAcum, TempoSemComponenteAcum, TempoParadoAcum, PickAcum, PlaceAcum, MissedAcum, NULL
        FROM #Leitura;

        INSERT #Seq
        SELECT f.MongoId, f.LeituraId, 1, f.MaquinaKey, f.DataHoraUtc, f.ProgramaKey,
               f.TimeStartBruto, ISNULL(f.TimeStopBruto, 0),
               f.EstadoMaquina, f.CodigoErro, f.SinalLuminoso,
               f.PlacasAcum, f.TempoRodandoAcum, f.TempoPlacaAcum, f.TempoEsperaEntradaAcum, f.TempoEsperaSaidaAcum, f.TempoParadaParcialAcum,
               f.TempoReparoAcum, f.TempoFalhaAcum, f.TempoSemComponenteAcum, f.TempoParadoAcum, f.PickAcum, f.PlaceAcum, f.MissedAcum, 0
        FROM (SELECT MaquinaKey, MIN(DataHoraUtc) AS Inicio FROM #Leitura GROUP BY MaquinaKey) n
        CROSS APPLY (SELECT TOP (1) * FROM dw.FatoMaquinaLeitura f
                     WHERE f.MaquinaKey = n.MaquinaKey AND f.DataHoraUtc <= n.Inicio
                     ORDER BY f.DataHoraUtc DESC, f.LeituraId DESC) f;

        -- Repetida = mesma assinatura da leitura imediatamente anterior (máquina parada)
        ;WITH a AS (
            SELECT MongoId, Ancora,
                   CONCAT_WS('|', ProgramaKey, TimeStart, TimeStop, EstadoMaquina, CodigoErro, PlacasAcum, TempoRodandoAcum,
                             TempoPlacaAcum, TempoEsperaEntradaAcum, TempoEsperaSaidaAcum, TempoParadaParcialAcum, TempoReparoAcum,
                             TempoFalhaAcum, TempoSemComponenteAcum, TempoParadoAcum, PickAcum, PlaceAcum, MissedAcum) AS Assinatura,
                   MaquinaKey, DataHoraUtc
            FROM #Seq
        ), b AS (
            SELECT MongoId, Ancora, Assinatura,
                   LAG(Assinatura) OVER (PARTITION BY MaquinaKey ORDER BY DataHoraUtc, MongoId) AS AssinaturaAnterior
            FROM a
        )
        UPDATE s SET Repetida = CASE WHEN b.Ancora = 0 AND b.Assinatura = b.AssinaturaAnterior THEN 1 ELSE 0 END
        FROM #Seq s JOIN b ON b.MongoId = s.MongoId;

        SET @LeiturasRepetidas = (SELECT COUNT(*) FROM #Seq WHERE Repetida = 1);

        -- Comparação com a leitura anterior mantida (âncora ou nova não repetida)
        SELECT s.*,
               p.MongoId     AS PrevMongoId,
               p.DataHoraUtc AS PrevDataHoraUtc,
               CASE WHEN p.MongoId IS NULL THEN 1 ELSE 0 END AS PrimeiraLeitura,
               CASE WHEN p.MongoId IS NOT NULL AND (
                         (s.TimeStart <> p.TimeStart AND s.TimeStart > 0)
                      OR s.PlacasAcum < p.PlacasAcum OR s.PickAcum < p.PickAcum
                      OR s.PlaceAcum < p.PlaceAcum   OR s.TempoRodandoAcum < p.TempoRodandoAcum)
                    THEN 1 ELSE 0 END AS NovaProducao,
               CASE WHEN p.MongoId IS NOT NULL AND s.ProgramaKey <> p.ProgramaKey THEN 1 ELSE 0 END AS TrocaPrograma,
               p.TimeStart AS pTimeStart,
               -- parâmetros efetivos do cálculo das diferenças (ajustados abaixo para contadores retomados)
               CAST(CASE WHEN p.MongoId IS NULL THEN 1 ELSE 0 END AS bit) AS CalcPrimeira,
               CAST(NULL AS bit) AS CalcReinicio,
               p.MongoId AS BaseMongoId,
               CAST(0 AS bit) AS ContadorRetomado,
               p.PlacasAcum AS pPlacas, p.TempoRodandoAcum AS pRodando, p.TempoPlacaAcum AS pPlaca,
               p.TempoEsperaEntradaAcum AS pEspEntrada, p.TempoEsperaSaidaAcum AS pEspSaida, p.TempoParadaParcialAcum AS pParcial,
               p.TempoReparoAcum AS pReparo, p.TempoFalhaAcum AS pFalha, p.TempoSemComponenteAcum AS pSemComp,
               p.TempoParadoAcum AS pParado, p.PickAcum AS pPick, p.PlaceAcum AS pPlace, p.MissedAcum AS pMissed
        INTO #Calc
        FROM (SELECT *, LAG(MongoId) OVER (PARTITION BY MaquinaKey ORDER BY DataHoraUtc, MongoId) AS PrevId
              FROM #Seq WHERE Repetida = 0) s
        LEFT JOIN #Seq p ON p.MongoId = s.PrevId
        WHERE s.Ancora = 0;

        UPDATE #Calc SET CalcReinicio = NovaProducao;

        -- Contador retomado: as KE voltam a registros de produção anteriores (TimeStart antigo) e os
        -- contadores reaparecem com o valor daquele registro. Se o registro já foi visto, a base passa
        -- a ser a última leitura dele (evita contar de novo o que já foi contado).
        SELECT MongoId, MaquinaKey, DataHoraUtc, TimeStart, PlacasAcum, TempoRodandoAcum, TempoPlacaAcum,
               TempoEsperaEntradaAcum, TempoEsperaSaidaAcum, TempoParadaParcialAcum, TempoReparoAcum, TempoFalhaAcum,
               TempoSemComponenteAcum, TempoParadoAcum, PickAcum, PlaceAcum, MissedAcum
        INTO #Hist
        FROM #Seq
        UNION ALL
        SELECT f.MongoId, f.MaquinaKey, f.DataHoraUtc, f.TimeStartBruto, f.PlacasAcum, f.TempoRodandoAcum, f.TempoPlacaAcum,
               f.TempoEsperaEntradaAcum, f.TempoEsperaSaidaAcum, f.TempoParadaParcialAcum, f.TempoReparoAcum, f.TempoFalhaAcum,
               f.TempoSemComponenteAcum, f.TempoParadoAcum, f.PickAcum, f.PlaceAcum, f.MissedAcum
        FROM dw.FatoMaquinaLeitura f
        WHERE f.MaquinaKey IN (SELECT MaquinaKey FROM #Calc WHERE NovaProducao = 1)
          AND NOT EXISTS (SELECT 1 FROM #Seq s WHERE s.MongoId = f.MongoId);

        CREATE INDEX IX_Hist ON #Hist (MaquinaKey, TimeStart, DataHoraUtc);

        UPDATE c
        SET pPlacas = h.PlacasAcum, pRodando = h.TempoRodandoAcum, pPlaca = h.TempoPlacaAcum,
            pEspEntrada = h.TempoEsperaEntradaAcum, pEspSaida = h.TempoEsperaSaidaAcum, pParcial = h.TempoParadaParcialAcum,
            pReparo = h.TempoReparoAcum, pFalha = h.TempoFalhaAcum, pSemComp = h.TempoSemComponenteAcum,
            pParado = h.TempoParadoAcum, pPick = h.PickAcum, pPlace = h.PlaceAcum, pMissed = h.MissedAcum,
            BaseMongoId = h.MongoId, CalcReinicio = 0, ContadorRetomado = 1
        FROM #Calc c
        CROSS APPLY (SELECT TOP (1) * FROM #Hist h
                     WHERE h.MaquinaKey = c.MaquinaKey AND h.TimeStart = c.TimeStart AND h.DataHoraUtc < c.DataHoraUtc
                     ORDER BY h.DataHoraUtc DESC) h
        WHERE c.NovaProducao = 1 AND c.TimeStart <> 0 AND c.TimeStart <> c.pTimeStart;

        -- Registro nunca visto cujo tempo rodando acumulado não cabe no intervalo desde a leitura
        -- anterior: a produção é anterior à janela observada -> linha de base (diferença 0).
        UPDATE #Calc
        SET CalcPrimeira = 1, ContadorRetomado = 1
        WHERE NovaProducao = 1 AND ContadorRetomado = 0 AND TempoRodandoAcum > 0
          AND TempoRodandoAcum > DATEDIFF(SECOND, PrevDataHoraUtc, DataHoraUtc) + 300;

        CREATE TABLE #Inseridas (LeituraId bigint NOT NULL, MongoId char(24) NOT NULL PRIMARY KEY);

        INSERT dw.FatoMaquinaLeitura (
            MongoId, MaquinaKey, ProgramaKey, DataKey, HoraKey, DataHoraUtc, DataHoraLocal, TimeStartBruto, InicioProducaoMaquina,
            PrimeiraLeitura, NovaProducao, TrocaPrograma, ContadorRetomado, SegundosDesdeAnterior, EstadoMaquina, CodigoErro, SinalLuminoso,
            TimeStopBruto, DadoSuspeito,
            PlacasAcum, TempoRodandoAcum, TempoPlacaAcum, TempoEsperaEntradaAcum, TempoEsperaSaidaAcum, TempoParadaParcialAcum,
            TempoReparoAcum, TempoFalhaAcum, TempoSemComponenteAcum, TempoParadoAcum, PickAcum, PlaceAcum, MissedAcum,
            Placas, TempoRodando, TempoPlaca, TempoEsperaEntrada, TempoEsperaSaida, TempoParadaParcial,
            TempoReparo, TempoFalha, TempoSemComponente, TempoParado, Pick, Place, Missed, CargaId)
        OUTPUT inserted.LeituraId, inserted.MongoId INTO #Inseridas
        SELECT c.MongoId, c.MaquinaKey, c.ProgramaKey,
               CONVERT(int, CONVERT(char(8), t.Local, 112)), DATEPART(HOUR, t.Local),
               c.DataHoraUtc, t.Local,
               c.TimeStart,
               CASE WHEN c.TimeStart BETWEEN @EpochMinimo AND 2147483647
                    THEN DATEADD(SECOND, CAST(c.TimeStart AS int), CAST('19700101' AS datetime2(0))) END,
               c.PrimeiraLeitura, c.NovaProducao, c.TrocaPrograma, c.ContadorRetomado,
               DATEDIFF(SECOND, c.PrevDataHoraUtc, c.DataHoraUtc),
               c.EstadoMaquina, c.CodigoErro, c.SinalLuminoso,
               c.TimeStop,
               -- TimeStart/TimeStop deveriam ser 0 ou epoch atual; valores como 327.169.236 (KE2060-24) são suspeitos
               CASE WHEN c.TimeStart BETWEEN 1 AND @EpochMinimo - 1 OR c.TimeStop BETWEEN 1 AND @EpochMinimo - 1 THEN 1 ELSE 0 END,
               c.PlacasAcum, c.TempoRodandoAcum, c.TempoPlacaAcum, c.TempoEsperaEntradaAcum, c.TempoEsperaSaidaAcum, c.TempoParadaParcialAcum,
               c.TempoReparoAcum, c.TempoFalhaAcum, c.TempoSemComponenteAcum, c.TempoParadoAcum, c.PickAcum, c.PlaceAcum, c.MissedAcum,
               etl.fn_Delta(c.PlacasAcum,             c.pPlacas,     c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(c.TempoRodandoAcum,       c.pRodando,    c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(c.TempoPlacaAcum,         c.pPlaca,      c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(c.TempoEsperaEntradaAcum, c.pEspEntrada, c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(c.TempoEsperaSaidaAcum,   c.pEspSaida,   c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(c.TempoParadaParcialAcum, c.pParcial,    c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(c.TempoReparoAcum,        c.pReparo,     c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(c.TempoFalhaAcum,         c.pFalha,      c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(c.TempoSemComponenteAcum, c.pSemComp,    c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(c.TempoParadoAcum,        c.pParado,     c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(c.PickAcum,               c.pPick,       c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(c.PlaceAcum,              c.pPlace,      c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(c.MissedAcum,             c.pMissed,     c.CalcPrimeira, c.CalcReinicio),
               @CargaId
        FROM #Calc c
        CROSS APPLY (SELECT CONVERT(datetime2(3), (c.DataHoraUtc AT TIME ZONE 'UTC') AT TIME ZONE @Fuso) AS Local) t;

        SET @LeiturasInseridas = @@ROWCOUNT;

        /* ===================== 6. Fato feeder ===================== */
        -- Valores da leitura-base: feeders das leituras novas + feeders já gravados (âncoras e
        -- leituras de registros de produção retomados)
        SELECT MongoId, Lado, FeederPos, Picked, Placed, Missed, NoComp, DiffComp, ErrorVac, Laser, Vision,
               Copla, Verify, Height, LeadBend, Colin
        INTO #FeederAnterior
        FROM #Feeder
        UNION ALL
        SELECT fm.MongoId, f.Lado, f.FeederPos, f.PickedAcum, f.PlacedAcum, f.MissedAcum, f.NoCompAcum, f.DiffCompAcum,
               f.ErrorVacAcum, f.LaserAcum, f.VisionAcum, f.CoplaAcum, f.VerifyAcum, f.HeightAcum, f.LeadBendAcum, f.ColinAcum
        FROM dw.FatoMaquinaLeitura fm
        JOIN dw.FatoFeederLeitura f ON f.LeituraId = fm.LeituraId
        WHERE fm.MongoId IN (SELECT BaseMongoId FROM #Calc)
          AND NOT EXISTS (SELECT 1 FROM #Feeder x WHERE x.MongoId = fm.MongoId);

        CREATE CLUSTERED INDEX IX_FeederAnterior ON #FeederAnterior (MongoId, Lado, FeederPos);

        INSERT dw.FatoFeederLeitura (
            LeituraId, Lado, FeederPos, MaquinaKey, ProgramaKey, ComponenteKey, DataKey, HoraKey, DataHoraUtc, DataHoraLocal,
            PickedAcum, PlacedAcum, MissedAcum, NoCompAcum, DiffCompAcum, ErrorVacAcum, LaserAcum, VisionAcum, CoplaAcum,
            VerifyAcum, HeightAcum, LeadBendAcum, ColinAcum,
            Picked, Placed, Missed, NoComp, DiffComp, ErrorVac, Laser, Vision, Copla, Verify, Height, LeadBend, Colin)
        SELECT i.LeituraId, f.Lado, f.FeederPos, fm.MaquinaKey, fm.ProgramaKey, ISNULL(dc.ComponenteKey, -1),
               fm.DataKey, fm.HoraKey, fm.DataHoraUtc, fm.DataHoraLocal,
               f.Picked, f.Placed, f.Missed, f.NoComp, f.DiffComp, f.ErrorVac, f.Laser, f.Vision, f.Copla,
               f.Verify, f.Height, f.LeadBend, f.Colin,
               etl.fn_Delta(f.Picked,   a.Picked,   c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(f.Placed,   a.Placed,   c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(f.Missed,   a.Missed,   c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(f.NoComp,   a.NoComp,   c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(f.DiffComp, a.DiffComp, c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(f.ErrorVac, a.ErrorVac, c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(f.Laser,    a.Laser,    c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(f.Vision,   a.Vision,   c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(f.Copla,    a.Copla,    c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(f.Verify,   a.Verify,   c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(f.Height,   a.Height,   c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(f.LeadBend, a.LeadBend, c.CalcPrimeira, c.CalcReinicio),
               etl.fn_Delta(f.Colin,    a.Colin,    c.CalcPrimeira, c.CalcReinicio)
        FROM #Inseridas i
        JOIN dw.FatoMaquinaLeitura fm ON fm.LeituraId = i.LeituraId
        JOIN #Calc c   ON c.MongoId = i.MongoId
        JOIN #Feeder f ON f.MongoId = i.MongoId
        LEFT JOIN #FeederAnterior a ON a.MongoId = c.BaseMongoId AND a.Lado = f.Lado AND a.FeederPos = f.FeederPos
        LEFT JOIN dw.DimComponente dc ON dc.Codigo = f.ComponenteCodigo;

        SET @FeedersInseridos = @@ROWCOUNT;

        /* ===================== 7. Eventos ===================== */
        ;WITH e AS (
            SELECT d.*,
                   CASE WHEN d.Tipo = 'AUDIT'                 THEN 'INTERLOCK'
                        WHEN d.Tipo LIKE 'START_AGENDA%'      THEN 'AGENDA'
                        WHEN d.Tipo = 'PICKED'                THEN 'FALHA_CONSUMO'
                        ELSE 'FALHA_COLETA' END AS TipoEvento,
                   -- PICKED: "Feeder: R111 não encontrado!"
                   CASE WHEN d.Tipo = 'PICKED' AND d.Texto LIKE N'Feeder: %'
                        THEN SUBSTRING(d.Texto, 9, CHARINDEX(N' ', d.Texto + N' ', 9) - 9) END AS FeederTexto
            FROM #Doc d
            WHERE d.Tipo = 'AUDIT'
               OR d.Tipo LIKE 'START_AGENDA%'
               OR (d.Tipo IN ('SPEND', 'PICKED') AND d.Sucesso = 0)
        )
        INSERT dw.FatoEvento (
            MongoId, DataHoraUtc, DataHoraLocal, DataKey, HoraKey, LinhaKey, MaquinaKey, Modulo, Origem, TipoEvento,
            TipoOriginal, Sucesso, Status, Codigo, Mensagem, Lado, Slot, Feeder, CodigoFornecedor, CargaId)
        SELECT e.MongoId, e.DataHoraUtc, t.Local,
               CONVERT(int, CONVERT(char(8), t.Local, 112)), DATEPART(HOUR, t.Local),
               l.LinhaKey, dm.MaquinaKey, e.Modulo, e.Colecao, e.TipoEvento, e.Tipo, e.Sucesso, e.Status, e.Codigo, e.Texto,
               COALESCE(ad.side, CASE WHEN LEFT(e.FeederTexto, 1) IN ('F', 'R') THEN LEFT(e.FeederTexto, 1) END),
               COALESCE(ad.slot, TRY_CONVERT(smallint, SUBSTRING(e.FeederTexto, 2, 10))),
               COALESCE(ad.feeder, e.FeederTexto),
               ad.vendorCode,
               @CargaId
        FROM e
        JOIN dw.DimLinha l ON l.MongoDatabase = @MongoDatabase AND l.Sala = e.Sala
        LEFT JOIN dw.DimMaquina dm ON dm.LinhaKey = l.LinhaKey AND dm.Modulo = e.Modulo
        OUTER APPLY OPENJSON(e.DataJson) WITH (
            vendorCode nvarchar(100), slot smallint, side char(1), feeder nvarchar(20)
        ) ad
        CROSS APPLY (SELECT CONVERT(datetime2(3), (e.DataHoraUtc AT TIME ZONE 'UTC') AT TIME ZONE @Fuso) AS Local) t
        WHERE e.DataHoraUtc IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dw.FatoEvento x WHERE x.MongoId = e.MongoId AND x.DataHoraUtc = e.DataHoraUtc);

        SET @EventosInseridos = @@ROWCOUNT;

        /* ===================== 8. Status atual (coleção SPEND) ===================== */
        ;WITH ok AS (
            SELECT dm.MaquinaKey, d.DataHoraUtc, w.*,
                   ROW_NUMBER() OVER (PARTITION BY dm.MaquinaKey ORDER BY d.DataHoraUtc DESC) AS rn
            FROM #Doc d
            JOIN dw.DimLinha l    ON l.MongoDatabase = @MongoDatabase AND l.Sala = d.Sala
            JOIN dw.DimMaquina dm ON dm.LinhaKey = l.LinhaKey AND dm.Modulo = d.Modulo
            CROSS APPLY OPENJSON(d.RowsJson, '$[0]') WITH (
                Arquivo     nvarchar(260) '$.waste.snapshot.Module.FileName',
                Placa       nvarchar(100) '$.waste.snapshot.Module.PwbId',
                MachineStat smallint      '$.waste.snapshot.Module.MachineStat',
                ErrorCode   int           '$.waste.snapshot.Module.ErrorCode',
                ProductNum  int           '$.waste.snapshot.ProductManage.ProductNum',
                StoreJson   nvarchar(max) '$.waste.snapshot.StoreNum' AS JSON,
                FeederJson  nvarchar(max) '$.waste.snapshot.Feeder' AS JSON
            ) w
            WHERE d.Colecao = 'SPEND' AND d.Sucesso = 1
        ), falha AS (
            SELECT dm.MaquinaKey, d.DataHoraUtc, d.Texto,
                   ROW_NUMBER() OVER (PARTITION BY dm.MaquinaKey ORDER BY d.DataHoraUtc DESC) AS rn
            FROM #Doc d
            JOIN dw.DimLinha l    ON l.MongoDatabase = @MongoDatabase AND l.Sala = d.Sala
            JOIN dw.DimMaquina dm ON dm.LinhaKey = l.LinhaKey AND dm.Modulo = d.Modulo
            WHERE d.Colecao = 'SPEND' AND d.Sucesso = 0
        ), st AS (
            SELECT COALESCE(o.MaquinaKey, f.MaquinaKey) AS MaquinaKey,
                   o.DataHoraUtc AS OkUtc, p.ProgramaKey, o.MachineStat, o.ErrorCode, o.ProductNum,
                   (SELECT SUM(Pick)   FROM OPENJSON(o.StoreJson)  WITH (Pick int))   AS Pick,
                   (SELECT SUM(Place)  FROM OPENJSON(o.StoreJson)  WITH (Place int))  AS Place,
                   (SELECT SUM(Missed) FROM OPENJSON(o.FeederJson) WITH (Missed int)) AS Missed,
                   f.DataHoraUtc AS FalhaUtc, f.Texto AS FalhaTexto
            FROM (SELECT * FROM ok WHERE rn = 1) o
            FULL JOIN (SELECT * FROM falha WHERE rn = 1) f ON f.MaquinaKey = o.MaquinaKey
            LEFT JOIN dw.DimPrograma p ON p.Arquivo = o.Arquivo AND p.Placa = o.Placa
        )
        MERGE dw.MaquinaStatusAtual AS t
        USING (
            SELECT st.*,
                   CONVERT(datetime2(3), (st.OkUtc    AT TIME ZONE 'UTC') AT TIME ZONE @Fuso) AS OkLocal,
                   CONVERT(datetime2(3), (st.FalhaUtc AT TIME ZONE 'UTC') AT TIME ZONE @Fuso) AS FalhaLocal
            FROM st
        ) AS s ON t.MaquinaKey = s.MaquinaKey
        WHEN MATCHED THEN UPDATE SET
            UltimaLeituraOkUtc = s.OkUtc, UltimaLeituraOkLocal = s.OkLocal, ProgramaKey = s.ProgramaKey,
            EstadoMaquina = s.MachineStat, CodigoErro = s.ErrorCode, PlacasAcum = s.ProductNum,
            PickAcum = s.Pick, PlaceAcum = s.Place, MissedAcum = s.Missed,
            UltimaFalhaUtc = s.FalhaUtc, UltimaFalhaLocal = s.FalhaLocal, UltimaFalhaMensagem = s.FalhaTexto,
            ColetaOk = CASE WHEN s.FalhaUtc IS NULL OR s.OkUtc > s.FalhaUtc THEN 1 ELSE 0 END,
            AtualizadoEmUtc = @Agora
        WHEN NOT MATCHED THEN INSERT (
            MaquinaKey, UltimaLeituraOkUtc, UltimaLeituraOkLocal, ProgramaKey, EstadoMaquina, CodigoErro, PlacasAcum,
            PickAcum, PlaceAcum, MissedAcum, UltimaFalhaUtc, UltimaFalhaLocal, UltimaFalhaMensagem, ColetaOk, AtualizadoEmUtc)
        VALUES (
            s.MaquinaKey, s.OkUtc, s.OkLocal, s.ProgramaKey, s.MachineStat, s.ErrorCode, s.ProductNum,
            s.Pick, s.Place, s.Missed, s.FalhaUtc, s.FalhaLocal, s.FalhaTexto,
            CASE WHEN s.FalhaUtc IS NULL OR s.OkUtc > s.FalhaUtc THEN 1 ELSE 0 END, @Agora);

        /* ===================== 9. Ajustes finais ===================== */
        -- Máquinas que informam tempos (TimeRun etc.) permitem o cálculo de disponibilidade
        UPDATE dm SET PossuiTempos = 1
        FROM dw.DimMaquina dm
        WHERE dm.PossuiTempos = 0
          AND EXISTS (SELECT 1 FROM #Leitura x WHERE x.MaquinaKey = dm.MaquinaKey AND x.TempoRodandoAcum > 0);

        -- Marca d'água: maior "update" do WATCH recebido nesta carga (nunca retrocede)
        DECLARE @Max datetime2(3) = (SELECT MAX(DataHoraUtc) FROM #Doc WHERE Colecao = 'WATCH');
        IF @Max IS NOT NULL
            MERGE etl.ControleCarga AS t
            USING (SELECT @MongoDatabase AS MongoDatabase, @Max AS UltimaLeituraUtc) AS s
               ON t.MongoDatabase = s.MongoDatabase
            WHEN MATCHED AND s.UltimaLeituraUtc > t.UltimaLeituraUtc THEN
                UPDATE SET UltimaLeituraUtc = s.UltimaLeituraUtc, AtualizadoEm = @Agora
            WHEN NOT MATCHED THEN
                INSERT (MongoDatabase, UltimaLeituraUtc, AtualizadoEm) VALUES (s.MongoDatabase, s.UltimaLeituraUtc, @Agora);

        DELETE stg.MongoDocumento WHERE CargaId = @CargaId;

        UPDATE etl.Carga
        SET Status = 'SUCESSO', Fim = SYSUTCDATETIME(), DocsWatch = @DocsWatch, DocsSpend = @DocsSpend,
            LeiturasInseridas = @LeiturasInseridas, LeiturasRepetidas = @LeiturasRepetidas,
            FeedersInseridos = @FeedersInseridos, EventosInseridos = @EventosInseridos, Mensagem = NULL
        WHERE CargaId = @CargaId;

        COMMIT;

        SELECT CargaId, Status, DocsWatch, DocsSpend, LeiturasInseridas, LeiturasRepetidas, FeedersInseridos, EventosInseridos
        FROM etl.Carga WHERE CargaId = @CargaId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        DECLARE @Erro nvarchar(4000) = CONCAT(N'usp_ProcessarCarga (linha ', ERROR_LINE(), N'): ', ERROR_MESSAGE());
        EXEC etl.usp_RegistrarFalha @CargaId = @CargaId, @Mensagem = @Erro;
        THROW;
    END CATCH
END
GO
