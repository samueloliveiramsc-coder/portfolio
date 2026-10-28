/* =============================================================================
   Metronome - Camada de análise (Metronome_PRO -> Metronome_DW -> Power BI)
   03 - Carga

   EXEC etl.usp_Carregar;   -- recarga completa (alguns minutos; agende 1x por turno ou por dia)

   Regras principais:
   - Saldo da bobina: o MENOR saldo válido (0..embalagem) já registrado para ela. Ao montar
     na máquina o saldo costuma vir somado ao da bobina emendada (ex.: 7.184 numa bobina de
     5.000) e há saldos negativos ou absurdos; esses valores e os aumentos são ignorados.
   - Consumo: o Metronome não registra consumo diretamente (QuantityPickedOut é acumulado entre
     bobinas e não serve). O consumo é a QUEDA DO SALDO da bobina entre dois movimentos,
     atribuída à máquina/slot do movimento anterior. Quedas sem a bobina ter saído de uma
     máquina (ex.: almoxarifado -> zero) são baixas de estoque: Origem = 'Fora da máquina'.
   - Movimentos repetidos: mesma bobina, mesmo destino, dentro de REPETIDA_SEGUNDOS.
   - Tipo de movimento: MovementTypeId vem sempre nulo; o tipo é deduzido pelo destino
     (máquina, local de linha, almoxarifado, kit, caixa/cassete).
============================================================================= */
USE Metronome_DW;
GO

CREATE OR ALTER PROCEDURE etl.usp_Carregar
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET DATEFIRST 7;

    DECLARE @CargaId int, @Inicio datetime2(0), @Repetida int, @SetupMax int, @ParadaDias int, @Corte datetime2(0);

    SELECT @Inicio     = CONVERT(datetime2(0), MAX(CASE WHEN Chave = 'DATA_INICIAL'       THEN Valor END), 112),
           @Repetida   = MAX(CASE WHEN Chave = 'REPETIDA_SEGUNDOS'  THEN CAST(Valor AS int) END),
           @SetupMax   = MAX(CASE WHEN Chave = 'SETUP_MAX_SEGUNDOS' THEN CAST(Valor AS int) END),
           @ParadaDias = MAX(CASE WHEN Chave = 'PARADA_DIAS'        THEN CAST(Valor AS int) END)
    FROM etl.Configuracao;

    INSERT etl.Carga DEFAULT VALUES;
    SET @CargaId = SCOPE_IDENTITY();

    BEGIN TRY
        /* ---------------------------------------------------------------
           1. Movimentos de bobinas (todo o histórico: o saldo anterior pode ser antigo)
        --------------------------------------------------------------- */
        SELECT l.Id,
               LEFT(l.Name, 100) AS Nome,
               CASE WHEN l.Name LIKE N'Line %' OR l.PlaceType BETWEEN '009' AND '020' THEN N'Linha'
                    WHEN l.Name LIKE N'%ALMOX%' OR l.Name = N'Almoxarifado'            THEN N'Almoxarifado'
                    WHEN l.Name LIKE N'%[_]KW[_]%' OR l.Name LIKE N'%KIT%'             THEN N'Kit (preparação)'
                    WHEN l.Name LIKE N'DRY%'                                           THEN N'Estufa (DRY)'
                    ELSE N'Outros locais' END AS Tipo
        INTO #Local
        FROM src.SupplyPlace l;

        SELECT m.Id, m.PartsSupplyId,
               CAST(m.DateInsert AS datetime2(0)) AS DataHora,
               NULLIF(LTRIM(RTRIM(m.Mounter)), '')  AS Maquina,
               CASE WHEN m.MounterSide IN ('F', 'R') THEN m.MounterSide ELSE '-' END AS Lado,
               m.SlotNumber AS Slot,
               m.SupplyPlaceId, m.SupplyBoxId,
               NULLIF(LTRIM(RTRIM(m.UserCode)), '') AS Operador,
               m.QuantityAvailable AS Qtd,
               CASE WHEN m.MovementTypeId IS NULL THEN 1 ELSE 0 END AS SemTipo
        INTO #Mov
        FROM src.PartsSupplyMovement m;
        CREATE CLUSTERED INDEX IX_Mov ON #Mov (PartsSupplyId, Id);

        SELECT m.*,
               CASE WHEN m.Maquina IS NOT NULL       THEN N'Máquina'
                    WHEN m.SupplyPlaceId IS NOT NULL THEN ISNULL(l.Tipo, N'Outros locais')
                    WHEN m.SupplyBoxId IS NOT NULL   THEN N'Caixa / cassete'
                    ELSE N'Sem local' END AS TipoDestino,
               CASE WHEN m.Maquina IS NOT NULL       THEN CONCAT(m.Maquina, ' ', NULLIF(m.Lado, '-'), m.Slot)
                    WHEN m.SupplyPlaceId IS NOT NULL THEN l.Nome
                    ELSE b.Code END AS NomeDestino,
               LAG(m.Qtd)      OVER (PARTITION BY m.PartsSupplyId ORDER BY m.Id) AS QtdAnterior,
               LAG(m.Maquina)  OVER (PARTITION BY m.PartsSupplyId ORDER BY m.Id) AS MaquinaAnterior,
               LAG(m.Lado)     OVER (PARTITION BY m.PartsSupplyId ORDER BY m.Id) AS LadoAnterior,
               LAG(m.Slot)     OVER (PARTITION BY m.PartsSupplyId ORDER BY m.Id) AS SlotAnterior,
               CASE WHEN LAG(CONCAT(m.Maquina, '|', m.SupplyBoxId, '|', m.SupplyPlaceId)) OVER (PARTITION BY m.PartsSupplyId ORDER BY m.Id)
                         = CONCAT(m.Maquina, '|', m.SupplyBoxId, '|', m.SupplyPlaceId)
                     AND DATEDIFF(SECOND, LAG(m.DataHora) OVER (PARTITION BY m.PartsSupplyId ORDER BY m.Id), m.DataHora) < @Repetida
                    THEN 1 ELSE 0 END AS Repetido,
               MIN(CASE WHEN m.Qtd BETWEEN 0 AND s.QuantityPackaging THEN m.Qtd END)
                   OVER (PARTITION BY m.PartsSupplyId ORDER BY m.Id ROWS UNBOUNDED PRECEDING) AS Saldo,
               s.QuantityPackaging AS Embalagem
        INTO #MovL
        FROM #Mov m
        JOIN src.PartsSupply s ON s.Id = m.PartsSupplyId
        LEFT JOIN #Local l ON l.Id = m.SupplyPlaceId
        LEFT JOIN src.SupplyBox b ON b.Id = m.SupplyBoxId;
        CREATE CLUSTERED INDEX IX_MovL ON #MovL (PartsSupplyId, Id);

        SELECT @Corte = MAX(d) FROM (SELECT MAX(DataHora) FROM #Mov
                                     UNION ALL SELECT MAX(CAST(DateInsert AS datetime2(0))) FROM src.PartsAuditMounter) x (d);

        /* ---------------------------------------------------------------
           2. Dimensões
        --------------------------------------------------------------- */
        -- máquina -> linha pelo layout ativo de cada linha
        SELECT e.Code AS Maquina, MIN(th.Code) AS Linha
        INTO #Layout
        FROM src.ThreadSchemaLayout l
        JOIN src.ThreadSchema ts ON ts.Id = l.ThreadSchemaId AND ts.IsActive = 1
        JOIN src.Thread th       ON th.Id = ts.ThreadId
        JOIN src.Equipment e     ON e.Id = l.EquipmentId
        WHERE l.IsActive = 1
        GROUP BY e.Code;

        SELECT n.Maquina,
               ISNULL(ly.Linha, 'N/D') AS Linha,
               CASE WHEN CHARINDEX('-', n.Maquina) > 1 THEN LEFT(n.Maquina, CHARINDEX('-', n.Maquina) - 1) ELSE n.Maquina END AS Familia,
               (SELECT MAX(e.Name) FROM src.Equipment e WHERE e.Code = n.Maquina) AS Modelo
        INTO #Maquina
        FROM (SELECT Maquina FROM #Mov WHERE Maquina IS NOT NULL
              UNION SELECT NULLIF(LTRIM(RTRIM(Mounter)), '') FROM src.PartsAuditMounter
              UNION SELECT NULLIF(LTRIM(RTRIM(Module)), '')  FROM src.PlanAudit
              UNION SELECT Maquina FROM #Layout) n
        LEFT JOIN #Layout ly ON ly.Maquina = n.Maquina
        WHERE n.Maquina IS NOT NULL;

        SELECT NULLIF(LTRIM(RTRIM(f.FileName)), '') AS Arquivo
        INTO #Arquivo
        FROM src.PlanAudit f
        WHERE f.DateInsert >= @Inicio
        GROUP BY NULLIF(LTRIM(RTRIM(f.FileName)), '');

        SELECT c.Codigo, LEFT(ISNULL(u.FullName, N'Matrícula ' + c.Codigo), 150) AS Nome
        INTO #Operador
        FROM (SELECT Operador AS Codigo FROM #Mov WHERE Operador IS NOT NULL
              UNION SELECT NULLIF(LTRIM(RTRIM(UserCode)), '') FROM src.PartsAuditMounter
              UNION SELECT NULLIF(LTRIM(RTRIM(UserCode)), '') FROM src.PlanAudit) c
        LEFT JOIN src.Users u ON u.UserCode = c.Codigo
        WHERE c.Codigo IS NOT NULL;

        SELECT t.Codigo,
               ISNULL(t.Descricao, N'Código ' + t.Codigo) AS Descricao,
               CASE WHEN t.Codigo IN ('5001', '5130', '5131')                         THEN N'Barcode'
                    WHEN t.Codigo IN ('5005', '5103', '5118', '5127', '5132', '5133') THEN N'Splicing'
                    WHEN t.Codigo IN ('5134', '5135')                                 THEN N'Realimentação'
                    WHEN t.Codigo IN ('5003', '5004', '5136', '5137')                 THEN N'Troca de cassete'
                    WHEN t.Codigo IN ('5006', '5138', '5139')                         THEN N'Descarga de bobina'
                    WHEN t.Codigo IN ('5008', '5129')                                 THEN N'Descarga forçada'
                    WHEN t.Codigo = '5140'                                            THEN N'Interlock automático'
                    ELSE N'Outros' END AS Categoria,
               CASE WHEN t.Codigo IN ('5130', '5132', '5134', '5136', '5138') THEN N'Verificação'
                    WHEN t.Codigo IN ('5131', '5133', '5135', '5137', '5139') THEN N'Bloqueio'
                    ELSE N'Registro' END AS Resultado
        INTO #TipoEvento
        FROM (SELECT ISNULL(i.Code, a.Codigo) AS Codigo,
                     -- algumas descrições do enum vêm com quebra de linha no fim
                     LEFT(LTRIM(RTRIM(REPLACE(REPLACE(i.Description, CHAR(13), ''), CHAR(10), ''))), 100) AS Descricao
              FROM (SELECT i.Code, i.Description FROM src.EnumTypeItem i
                    JOIN src.EnumType t ON t.Id = i.EnumTypeId AND t.Name = 'AUDIT_TYPE') i
              FULL JOIN (SELECT DISTINCT ISNULL(LTRIM(RTRIM(AuditType)), '?') AS Codigo FROM src.PartsAuditMounter) a
                     ON a.Codigo = i.Code) t;

        /* ---------------------------------------------------------------
           3. Gravação (uma transação: o Power BI nunca vê a carga pela metade)
        --------------------------------------------------------------- */
        BEGIN TRANSACTION;

        TRUNCATE TABLE dw.DimMaquina;
        INSERT dw.DimMaquina (MaquinaKey, Maquina, Linha, Familia, Modelo) VALUES (-1, 'N/D', 'N/D', 'N/D', NULL);
        INSERT dw.DimMaquina (MaquinaKey, Maquina, Linha, Familia, Modelo)
        SELECT ROW_NUMBER() OVER (ORDER BY Maquina), LEFT(Maquina, 30), Linha, LEFT(Familia, 20), LEFT(Modelo, 100)
        FROM #Maquina;

        TRUNCATE TABLE dw.DimComponente;
        INSERT dw.DimComponente (ComponenteKey, Codigo, Nome, Descricao, Tipo) VALUES (-1, 'N/D', NULL, NULL, N'N/D');
        INSERT dw.DimComponente (ComponenteKey, Codigo, Nome, Descricao, Tipo)
        SELECT p.Id, LEFT(ISNULL(NULLIF(LTRIM(RTRIM(p.Code)), ''), CAST(p.Id AS varchar(12))), 50),
               LEFT(LTRIM(RTRIM(p.Name)), 100), LEFT(LTRIM(RTRIM(p.Description)), 200),
               LEFT(UPPER(COALESCE(pt.Name, NULLIF(LEFT(LTRIM(p.Name), CHARINDEX(' ', LTRIM(p.Name) + ' ') - 1), ''), N'N/D')), 50)
        FROM src.Parts p
        LEFT JOIN src.PartsType pt ON pt.Id = p.PartsTypeId;

        TRUNCATE TABLE dw.DimPrograma;
        INSERT dw.DimPrograma (ProgramaKey, Arquivo, Programa, Projeto) VALUES (-1, 'N/D', 'N/D', 'N/D');
        INSERT dw.DimPrograma (ProgramaKey, Arquivo, Programa, Projeto)
        SELECT ROW_NUMBER() OVER (ORDER BY a.Arquivo), a.Arquivo, p.Programa,
               CASE WHEN p.Programa LIKE 'P[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][A-Za-z]%' THEN LEFT(p.Programa, 9) ELSE p.Programa END
        FROM #Arquivo a
        CROSS APPLY (SELECT LEFT(a.Arquivo, CHARINDEX('.', a.Arquivo + '.') - 1) AS Programa) p
        WHERE a.Arquivo IS NOT NULL;

        TRUNCATE TABLE dw.DimOperador;
        INSERT dw.DimOperador (OperadorKey, Codigo, Nome) VALUES (-1, 'N/D', N'Não informado');
        INSERT dw.DimOperador (OperadorKey, Codigo, Nome)
        SELECT ROW_NUMBER() OVER (ORDER BY Codigo), LEFT(Codigo, 30), Nome FROM #Operador;

        TRUNCATE TABLE dw.DimTipoEvento;
        INSERT dw.DimTipoEvento (Codigo, Descricao, Categoria, Resultado, Ordem)
        SELECT Codigo, Descricao, Categoria, Resultado,
               CASE Categoria WHEN N'Barcode' THEN 1 WHEN N'Splicing' THEN 2 WHEN N'Realimentação' THEN 3
                              WHEN N'Troca de cassete' THEN 4 WHEN N'Descarga de bobina' THEN 5
                              WHEN N'Descarga forçada' THEN 6 WHEN N'Interlock automático' THEN 7 ELSE 9 END
        FROM #TipoEvento;

        TRUNCATE TABLE dw.FatoEventoMaquina;
        INSERT dw.FatoEventoMaquina (EventoId, DataHora, DataKey, HoraKey, MaquinaKey, OperadorKey, TipoCodigo, Lado)
        SELECT a.Id, x.DataHora, CONVERT(int, CONVERT(char(8), x.DataHora, 112)), DATEPART(HOUR, x.DataHora),
               ISNULL(m.MaquinaKey, -1), ISNULL(o.OperadorKey, -1),
               ISNULL(LTRIM(RTRIM(a.AuditType)), '?'),
               CASE WHEN a.MounterSide IN ('F', 'R') THEN a.MounterSide ELSE '-' END
        FROM src.PartsAuditMounter a
        CROSS APPLY (SELECT CAST(a.DateInsert AS datetime2(0)) AS DataHora) x
        LEFT JOIN dw.DimMaquina  m ON m.Maquina = LTRIM(RTRIM(a.Mounter))
        LEFT JOIN dw.DimOperador o ON o.Codigo  = LTRIM(RTRIM(a.UserCode))
        WHERE a.DateInsert >= @Inicio;

        TRUNCATE TABLE dw.FatoSetup;
        INSERT dw.FatoSetup (SetupId, DataHora, DataKey, HoraKey, MaquinaKey, ProgramaKey, OperadorKey,
                             Feeders, FeedersConferidos, DuracaoSeg, DuracaoValida)
        SELECT p.Id, x.DataHora, CONVERT(int, CONVERT(char(8), x.DataHora, 112)), DATEPART(HOUR, x.DataHora),
               ISNULL(m.MaquinaKey, -1), ISNULL(g.ProgramaKey, -1), ISNULL(o.OperadorKey, -1),
               ISNULL(f.Feeders, 0), ISNULL(f.Conferidos, 0), f.Duracao,
               CASE WHEN f.Feeders > 0 AND f.Duracao BETWEEN 0 AND @SetupMax THEN 1 ELSE 0 END
        FROM src.PlanAudit p
        CROSS APPLY (SELECT CAST(p.DateInsert AS datetime2(0)) AS DataHora) x
        LEFT JOIN (SELECT PlanAuditId, COUNT(*) AS Feeders, SUM(CASE WHEN IsFinished = 1 THEN 1 ELSE 0 END) AS Conferidos,
                          DATEDIFF(SECOND, MIN(DateInsert), MAX(ISNULL(DateUpdate, DateInsert))) AS Duracao
                   FROM src.PlanAuditFeeder GROUP BY PlanAuditId) f ON f.PlanAuditId = p.Id
        LEFT JOIN dw.DimMaquina  m ON m.Maquina = LTRIM(RTRIM(p.Module))
        LEFT JOIN dw.DimPrograma g ON g.Arquivo = LTRIM(RTRIM(p.FileName))
        LEFT JOIN dw.DimOperador o ON o.Codigo  = LTRIM(RTRIM(p.UserCode))
        WHERE p.DateInsert >= @Inicio;

        TRUNCATE TABLE dw.FatoConsumo;
        INSERT dw.FatoConsumo (MovimentoId, BobinaId, DataHora, DataKey, HoraKey, MaquinaKey, ComponenteKey, Lado, Slot, Quantidade, Esgotou, Origem)
        SELECT v.Id, v.PartsSupplyId, v.DataHora, CONVERT(int, CONVERT(char(8), v.DataHora, 112)), DATEPART(HOUR, v.DataHora),
               ISNULL(m.MaquinaKey, -1), ISNULL(c.ComponenteKey, -1), ISNULL(v.LadoAnterior, '-'), v.SlotAnterior,
               v.SaldoAnterior - v.Saldo, CASE WHEN v.Saldo = 0 THEN 1 ELSE 0 END,
               -- queda sem passagem pela máquina = baixa de estoque, não consumo de produção
               CASE WHEN v.MaquinaAnterior IS NOT NULL THEN N'Em máquina' ELSE N'Fora da máquina' END
        FROM (SELECT x.*, LAG(x.Saldo) OVER (PARTITION BY x.PartsSupplyId ORDER BY x.Id) AS SaldoAnterior FROM #MovL x) v
        JOIN src.PartsSupply s ON s.Id = v.PartsSupplyId
        LEFT JOIN dw.DimComponente c ON c.ComponenteKey = s.PartsId
        LEFT JOIN dw.DimMaquina m ON m.Maquina = v.MaquinaAnterior
        WHERE v.DataHora >= @Inicio
          AND v.SaldoAnterior > v.Saldo;

        TRUNCATE TABLE dw.FatoBobina;
        WITH u AS (SELECT v.*, ROW_NUMBER() OVER (PARTITION BY v.PartsSupplyId ORDER BY v.Id DESC) AS rn FROM #MovL v),
             a AS (SELECT PartsSupplyId, COUNT(*) AS Movimentos, SUM(Repetido) AS Repetidos,
                          MIN(CASE WHEN Maquina IS NOT NULL THEN DataHora END) AS PrimeiraMontagem
                   FROM #MovL GROUP BY PartsSupplyId)
        INSERT dw.FatoBobina (BobinaId, CodigoBobina, ComponenteKey, DataKey, Recebimento, Embalagem, Saldo, SaldoValido, Situacao,
                              UltimoMovimento, TipoLocal, LocalAtual, MaquinaKey, PrimeiraMontagem, HorasAteMontar, DiasSemMovimento,
                              FaixaAging, FaixaAgingOrdem, Movimentos, MovimentosRepetidos)
        SELECT s.Id, LEFT(s.SupplyCode, 50), ISNULL(c.ComponenteKey, -1),
               CONVERT(int, CONVERT(char(8), r.Recebimento, 112)), r.Recebimento, ISNULL(s.QuantityPackaging, 0),
               CASE WHEN k.Valido = 1 THEN k.Saldo END, k.Valido,
               CASE WHEN k.Valido = 0 THEN N'Saldo inválido' WHEN k.Saldo = 0 THEN N'Esgotada' ELSE N'Com saldo' END,
               u.DataHora, ISNULL(u.TipoDestino, N'Sem movimento'), LEFT(u.NomeDestino, 100),
               CASE WHEN u.Maquina IS NOT NULL THEN ISNULL(m.MaquinaKey, -1) ELSE -1 END,
               a.PrimeiraMontagem,
               CASE WHEN a.PrimeiraMontagem >= r.Recebimento THEN DATEDIFF(HOUR, r.Recebimento, a.PrimeiraMontagem) END,
               d.Dias,
               CASE WHEN k.Valido = 0 OR k.Saldo = 0 THEN N'Sem saldo'
                    WHEN d.Dias <= 7   THEN N'0–7 dias'    WHEN d.Dias <= 30  THEN N'8–30 dias'
                    WHEN d.Dias <= 90  THEN N'31–90 dias'  WHEN d.Dias <= 180 THEN N'91–180 dias'
                    WHEN d.Dias <= 365 THEN N'181–365 dias' ELSE N'Mais de 1 ano' END,
               CASE WHEN k.Valido = 0 OR k.Saldo = 0 THEN 9
                    WHEN d.Dias <= 7 THEN 1 WHEN d.Dias <= 30 THEN 2 WHEN d.Dias <= 90 THEN 3
                    WHEN d.Dias <= 180 THEN 4 WHEN d.Dias <= 365 THEN 5 ELSE 6 END,
               ISNULL(a.Movimentos, 0), ISNULL(a.Repetidos, 0)
        FROM src.PartsSupply s
        LEFT JOIN u ON u.PartsSupplyId = s.Id AND u.rn = 1
        LEFT JOIN a ON a.PartsSupplyId = s.Id
        LEFT JOIN dw.DimComponente c ON c.ComponenteKey = s.PartsId
        LEFT JOIN dw.DimMaquina m ON m.Maquina = u.Maquina
        CROSS APPLY (SELECT CAST(ISNULL(s.DateInsert, u.DataHora) AS datetime2(0)) AS Recebimento) r
        CROSS APPLY (SELECT CASE WHEN u.Id IS NULL THEN s.QuantityAvailable ELSE u.Saldo END AS Saldo) q
        CROSS APPLY (SELECT q.Saldo, CASE WHEN q.Saldo BETWEEN 0 AND s.QuantityPackaging THEN 1 ELSE 0 END AS Valido) k
        CROSS APPLY (SELECT DATEDIFF(DAY, ISNULL(u.DataHora, r.Recebimento), @Corte) AS Dias) d
        WHERE r.Recebimento IS NOT NULL;

        TRUNCATE TABLE dw.FatoMovimento;
        INSERT dw.FatoMovimento (DataKey, HoraKey, MaquinaKey, OperadorKey, TipoDestino, Movimentos, Repetidos)
        SELECT CONVERT(int, CONVERT(char(8), v.DataHora, 112)), DATEPART(HOUR, v.DataHora),
               ISNULL(m.MaquinaKey, -1), ISNULL(o.OperadorKey, -1), v.TipoDestino, COUNT(*), SUM(v.Repetido)
        FROM #MovL v
        LEFT JOIN dw.DimMaquina  m ON m.Maquina = v.Maquina
        LEFT JOIN dw.DimOperador o ON o.Codigo  = v.Operador
        WHERE v.DataHora >= @Inicio
        GROUP BY CONVERT(int, CONVERT(char(8), v.DataHora, 112)), DATEPART(HOUR, v.DataHora),
                 ISNULL(m.MaquinaKey, -1), ISNULL(o.OperadorKey, -1), v.TipoDestino;

        -- Calendário: do recebimento mais antigo de bobina até a data de corte
        TRUNCATE TABLE dw.DimData;
        DECLARE @De date = (SELECT CAST(MIN(Recebimento) AS date) FROM dw.FatoBobina);
        IF @De IS NULL OR @De > @Inicio SET @De = CAST(@Inicio AS date);
        WITH n AS (SELECT TOP (DATEDIFF(DAY, @De, CAST(@Corte AS date)) + 1)
                          ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
                   FROM sys.all_objects a CROSS JOIN sys.all_objects b),
             d AS (SELECT DATEADD(DAY, i, @De) AS Data FROM n)
        INSERT dw.DimData (DataKey, Data, Ano, Mes, NomeMes, AnoMes, Dia, DiaSemana, NomeDiaSemana)
        SELECT CONVERT(int, CONVERT(char(8), Data, 112)), Data, YEAR(Data), MONTH(Data),
               FORMAT(Data, 'MMMM', 'pt-BR'), FORMAT(Data, 'yyyy-MM'), DAY(Data), DATEPART(WEEKDAY, Data),
               FORMAT(Data, 'dddd', 'pt-BR')
        FROM d;

        TRUNCATE TABLE dw.QualidadeDados;
        INSERT dw.QualidadeDados (Ordem, Indicador, Ocorrencias, Total, Tratamento)
        SELECT 1, N'Movimentos repetidos (mesma bobina e destino em menos de ' + CAST(@Repetida AS nvarchar(10)) + N' s)',
               SUM(Repetido), COUNT(*), N'Contados à parte; não alteram o consumo.' FROM #MovL
        UNION ALL
        SELECT 2, N'Movimentos sem tipo (MovementTypeId nulo)', SUM(SemTipo), COUNT(*),
               N'O tipo é deduzido pelo destino: máquina, linha, almoxarifado, kit, caixa.' FROM #MovL
        UNION ALL
        SELECT 3, N'Saldos fora da faixa (negativo ou acima da embalagem)',
               SUM(CASE WHEN Qtd < 0 OR Qtd > Embalagem THEN 1 ELSE 0 END), COUNT(*),
               N'Ignorados. Ao montar, o saldo costuma vir somado ao da bobina emendada.' FROM #MovL
        UNION ALL
        SELECT 4, N'Aumentos de saldo dentro da faixa',
               SUM(CASE WHEN Qtd BETWEEN 0 AND Embalagem AND Qtd > SaldoAnterior THEN 1 ELSE 0 END), COUNT(*),
               N'Ignorados: o saldo da bobina é o menor saldo válido já registrado.'
        FROM (SELECT Qtd, Embalagem, LAG(Saldo) OVER (PARTITION BY PartsSupplyId ORDER BY Id) AS SaldoAnterior FROM #MovL) x
        UNION ALL
        SELECT 5, N'Bobinas com QuantityPickedOut acima da embalagem',
               SUM(CASE WHEN QuantityPickedOut > QuantityPackaging THEN 1 ELSE 0 END), COUNT(*),
               N'Coluna não usada: é acumulada entre bobinas.' FROM src.PartsSupply
        UNION ALL
        SELECT 6, N'Bobinas "na máquina" sem movimento há mais de ' + CAST(@ParadaDias AS nvarchar(10)) + N' dias',
               SUM(CASE WHEN DiasSemMovimento > @ParadaDias THEN 1 ELSE 0 END), COUNT(*),
               N'Provável retirada não registrada; continuam no estoque como Máquina.'
        FROM dw.FatoBobina WHERE TipoLocal = N'Máquina' AND Situacao = N'Com saldo'
        UNION ALL
        SELECT 7, N'Conferências de setup sem feeders ou acima de ' + CAST(@SetupMax / 60 AS nvarchar(10)) + N' min',
               SUM(CASE WHEN DuracaoValida = 0 THEN 1 ELSE 0 END), COUNT(*),
               N'Fora das médias de duração.' FROM dw.FatoSetup;

        UPDATE etl.Carga SET Fim = SYSDATETIME(), Status = 'OK', DataCorte = @Corte WHERE CargaId = @CargaId;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        UPDATE etl.Carga SET Fim = SYSDATETIME(), Status = 'FALHA', Mensagem = LEFT(ERROR_MESSAGE(), 4000) WHERE CargaId = @CargaId;
        THROW;
    END CATCH
END;
GO
