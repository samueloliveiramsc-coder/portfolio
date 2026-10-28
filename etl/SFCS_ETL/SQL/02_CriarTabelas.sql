/* =============================================================================
   SFCS - ETL MongoDB (SPEND / WATCH) -> SQL Server -> Power BI
   02 - Schemas e tabelas

   Camadas:
     etl  -> controle de cargas, marca d'água (watermark) e configuração
     stg  -> documentos brutos (JSON) extraídos do MongoDB pelo pacote SSIS
     dw   -> modelo estrela consumido pelo Power BI

   Grão das tabelas de fatos:
     dw.FatoMaquinaLeitura -> 1 linha por leitura SPEND (a cada ~2 min) e máquina,
                              sem leituras repetidas, com diferenças (deltas)
     dw.FatoFeederLeitura  -> 1 linha por leitura, lado (F/R) e posição de feeder
     dw.FatoEvento         -> 1 linha por evento (falha de coleta, interlock, agenda)
     dw.MaquinaStatusAtual -> foto atual de cada máquina (coleção SPEND)

   Colunas "...Acum" = contador acumulado como vem da máquina (desde TimeStart).
   Colunas sem sufixo = diferença em relação à leitura anterior (somar no Power BI).
   O script é idempotente: só cria o que ainda não existe.
============================================================================= */
USE SFCS_DW;
GO

IF SCHEMA_ID(N'etl') IS NULL EXEC (N'CREATE SCHEMA etl');
IF SCHEMA_ID(N'stg') IS NULL EXEC (N'CREATE SCHEMA stg');
IF SCHEMA_ID(N'dw')  IS NULL EXEC (N'CREATE SCHEMA dw');
GO

/* -----------------------------------------------------------------------------
   ETL - controle
----------------------------------------------------------------------------- */
IF OBJECT_ID(N'etl.Configuracao') IS NULL
CREATE TABLE etl.Configuracao (
    Chave       varchar(50)    NOT NULL CONSTRAINT PK_etl_Configuracao PRIMARY KEY,
    Valor       nvarchar(200)  NOT NULL,
    Descricao   nvarchar(400)  NULL
);
GO

-- Fuso da fábrica: o watch_api usa "America/Manaus" (UTC-4, sem horário de verão).
IF NOT EXISTS (SELECT 1 FROM etl.Configuracao WHERE Chave = 'FUSO_HORARIO')
    INSERT etl.Configuracao (Chave, Valor, Descricao)
    VALUES ('FUSO_HORARIO', N'SA Western Standard Time',
            N'Nome do fuso no Windows (sys.time_zone_info) usado para gerar DataHoraLocal. America/Manaus = SA Western Standard Time.');
IF NOT EXISTS (SELECT 1 FROM etl.Configuracao WHERE Chave = 'MARGEM_MINUTOS')
    INSERT etl.Configuracao (Chave, Valor, Descricao)
    VALUES ('MARGEM_MINUTOS', N'10',
            N'Minutos de sobreposição na extração incremental do WATCH (documentos já carregados são ignorados).');
IF NOT EXISTS (SELECT 1 FROM etl.Configuracao WHERE Chave = 'CARGA_INICIAL_DIAS')
    INSERT etl.Configuracao (Chave, Valor, Descricao)
    VALUES ('CARGA_INICIAL_DIAS', N'0',
            N'Na primeira carga de um banco Mongo, quantos dias de histórico extrair. 0 = todo o histórico disponível.');
IF NOT EXISTS (SELECT 1 FROM etl.Configuracao WHERE Chave = 'FALHA_MIN_MINUTOS')
    INSERT etl.Configuracao (Chave, Valor, Descricao)
    VALUES ('FALHA_MIN_MINUTOS', N'5',
            N'Paradas por TimeTrouble/TimeRepair a partir desta duração contam como falha (MTBF/MTTR); as menores são microparadas.');
GO

IF OBJECT_ID(N'etl.ControleCarga') IS NULL
CREATE TABLE etl.ControleCarga (
    MongoDatabase     nvarchar(64)  NOT NULL CONSTRAINT PK_etl_ControleCarga PRIMARY KEY,
    UltimaLeituraUtc  datetime2(3)  NOT NULL,   -- maior "update" do WATCH já carregado
    AtualizadoEm      datetime2(3)  NOT NULL CONSTRAINT DF_etl_ControleCarga_AtualizadoEm DEFAULT SYSUTCDATETIME()
);
GO

IF OBJECT_ID(N'etl.Carga') IS NULL
CREATE TABLE etl.Carga (
    CargaId              int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_etl_Carga PRIMARY KEY,
    MongoDatabase        nvarchar(64)   NOT NULL,
    Inicio               datetime2(3)   NOT NULL CONSTRAINT DF_etl_Carga_Inicio DEFAULT SYSUTCDATETIME(),
    Fim                  datetime2(3)   NULL,
    Status               varchar(20)    NOT NULL CONSTRAINT DF_etl_Carga_Status DEFAULT 'EXECUTANDO', -- EXECUTANDO | SUCESSO | FALHA
    FiltroDesdeUtc       datetime2(3)   NULL,
    DocsWatch            int            NULL,
    DocsSpend            int            NULL,
    LeiturasInseridas    int            NULL,
    LeiturasRepetidas    int            NULL,
    FeedersInseridos     int            NULL,
    EventosInseridos     int            NULL,
    Mensagem             nvarchar(4000) NULL
);
GO

/* -----------------------------------------------------------------------------
   STAGING - documentos brutos
----------------------------------------------------------------------------- */
IF OBJECT_ID(N'stg.MongoDocumento') IS NULL
CREATE TABLE stg.MongoDocumento (
    StgId          bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_stg_MongoDocumento PRIMARY KEY,
    CargaId        int            NOT NULL,
    MongoDatabase  nvarchar(64)   NOT NULL,
    Colecao        varchar(20)    NOT NULL,   -- WATCH | SPEND
    Documento      nvarchar(max)  NOT NULL    -- documento inteiro em JSON (ZappySys, modo RAW JSON)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_stg_MongoDocumento_Carga')
    CREATE INDEX IX_stg_MongoDocumento_Carga ON stg.MongoDocumento (CargaId, Colecao);
GO

/* -----------------------------------------------------------------------------
   DIMENSÕES
----------------------------------------------------------------------------- */
IF OBJECT_ID(N'dw.DimLinha') IS NULL
CREATE TABLE dw.DimLinha (
    LinhaKey       int           IDENTITY(1,1) NOT NULL CONSTRAINT PK_dw_DimLinha PRIMARY KEY,
    MongoDatabase  nvarchar(64)  NOT NULL,   -- ex.: thread_05
    Sala           nvarchar(50)  NOT NULL,   -- campo "room", ex.: ROOM_L05
    Linha          nvarchar(50)  NOT NULL,   -- ex.: L05
    CONSTRAINT UQ_dw_DimLinha UNIQUE (MongoDatabase, Sala)
);
GO

IF OBJECT_ID(N'dw.DimMaquina') IS NULL
CREATE TABLE dw.DimMaquina (
    MaquinaKey     int           IDENTITY(1,1) NOT NULL CONSTRAINT PK_dw_DimMaquina PRIMARY KEY,
    LinhaKey       int           NOT NULL CONSTRAINT FK_dw_DimMaquina_Linha REFERENCES dw.DimLinha (LinhaKey),
    Modulo         nvarchar(50)  NOT NULL,   -- campo "module", ex.: KE2080-05
    Familia        nvarchar(20)  NOT NULL,   -- prefixo do módulo, ex.: KE2080 / SIG200A
    Modelo         nvarchar(50)  NULL,       -- START_AGENDA_*.rows.model, ex.: KE-2080 / SI-G200AA
    NoColetor      nvarchar(20)  NULL,       -- START_AGENDA_*.rows.node, ex.: NT-12
    IpModulo       varchar(45)   NULL,
    PossuiTempos   bit           NOT NULL CONSTRAINT DF_dw_DimMaquina_PossuiTempos DEFAULT 0, -- 1 = máquina informa TimeRun etc. (disponibilidade)
    CONSTRAINT UQ_dw_DimMaquina UNIQUE (LinhaKey, Modulo)
);
GO

IF OBJECT_ID(N'dw.DimPrograma') IS NULL
CREATE TABLE dw.DimPrograma (
    ProgramaKey  int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_dw_DimPrograma PRIMARY KEY,
    Arquivo      nvarchar(260)  NOT NULL,   -- Module.FileName, ex.: P25-03681R.E48
    Placa        nvarchar(100)  NOT NULL,   -- Module.PwbId,   ex.: 149912-1 ODU
    CONSTRAINT UQ_dw_DimPrograma UNIQUE (Arquivo, Placa)
);
GO

IF OBJECT_ID(N'dw.DimComponente') IS NULL
BEGIN
    CREATE TABLE dw.DimComponente (
        ComponenteKey  int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_dw_DimComponente PRIMARY KEY,
        Codigo         nvarchar(100)  NOT NULL CONSTRAINT UQ_dw_DimComponente UNIQUE  -- setup.Feeder.CompoName
    );
    -- Membro "não identificado" para feeders sem correspondência no setup
    SET IDENTITY_INSERT dw.DimComponente ON;
    INSERT dw.DimComponente (ComponenteKey, Codigo) VALUES (-1, N'N/D');
    SET IDENTITY_INSERT dw.DimComponente OFF;
END
GO

IF OBJECT_ID(N'dw.DimData') IS NULL
CREATE TABLE dw.DimData (
    DataKey        int           NOT NULL CONSTRAINT PK_dw_DimData PRIMARY KEY,  -- yyyymmdd
    Data           date          NOT NULL,
    Ano            smallint      NOT NULL,
    Trimestre      tinyint       NOT NULL,
    Mes            tinyint       NOT NULL,
    NomeMes        nvarchar(20)  NOT NULL,
    AnoMes         char(7)       NOT NULL,   -- yyyy-mm
    Dia            tinyint       NOT NULL,
    DiaSemana      tinyint       NOT NULL,   -- 1 = domingo
    NomeDiaSemana  nvarchar(20)  NOT NULL,
    SemanaIso      tinyint       NOT NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM dw.DimData)
BEGIN
    SET DATEFIRST 7;
    WITH n AS (
        SELECT TOP (DATEDIFF(DAY, '20240101', '20301231') + 1)
               ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
        FROM sys.all_objects a CROSS JOIN sys.all_objects b
    ), d AS (SELECT DATEADD(DAY, i, CAST('20240101' AS date)) AS Data FROM n)
    INSERT dw.DimData (DataKey, Data, Ano, Trimestre, Mes, NomeMes, AnoMes, Dia, DiaSemana, NomeDiaSemana, SemanaIso)
    SELECT CONVERT(int, CONVERT(char(8), Data, 112)), Data, YEAR(Data), DATEPART(QUARTER, Data), MONTH(Data),
           FORMAT(Data, 'MMMM', 'pt-BR'), FORMAT(Data, 'yyyy-MM'), DAY(Data), DATEPART(WEEKDAY, Data),
           FORMAT(Data, 'dddd', 'pt-BR'), DATEPART(ISO_WEEK, Data)
    FROM d;
END
GO

IF OBJECT_ID(N'dw.DimHora') IS NULL
CREATE TABLE dw.DimHora (
    HoraKey  tinyint       NOT NULL CONSTRAINT PK_dw_DimHora PRIMARY KEY,  -- 0..23 (hora local)
    Hora     char(5)       NOT NULL,                                       -- 06:00
    Turno    nvarchar(20)  NOT NULL
);
GO

-- Turnos padrão: AJUSTE conforme a escala real da fábrica.
IF NOT EXISTS (SELECT 1 FROM dw.DimHora)
    INSERT dw.DimHora (HoraKey, Hora, Turno)
    SELECT h, RIGHT('0' + CAST(h AS varchar(2)), 2) + ':00',
           CASE WHEN h BETWEEN 6 AND 13 THEN N'1º Turno'
                WHEN h BETWEEN 14 AND 21 THEN N'2º Turno'
                ELSE N'3º Turno' END
    FROM (SELECT TOP (24) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS tinyint) AS h FROM sys.all_objects) x;
GO

/* -----------------------------------------------------------------------------
   FATOS
----------------------------------------------------------------------------- */
IF OBJECT_ID(N'dw.FatoMaquinaLeitura') IS NULL
CREATE TABLE dw.FatoMaquinaLeitura (
    LeituraId                bigint        IDENTITY(1,1) NOT NULL CONSTRAINT PK_dw_FatoMaquinaLeitura PRIMARY KEY,
    MongoId                  char(24)      NOT NULL,   -- _id do documento no WATCH
    MaquinaKey               int           NOT NULL CONSTRAINT FK_dw_FatoMaquinaLeitura_Maquina  REFERENCES dw.DimMaquina (MaquinaKey),
    ProgramaKey              int           NOT NULL CONSTRAINT FK_dw_FatoMaquinaLeitura_Programa REFERENCES dw.DimPrograma (ProgramaKey),
    DataKey                  int           NOT NULL CONSTRAINT FK_dw_FatoMaquinaLeitura_Data     REFERENCES dw.DimData (DataKey),
    HoraKey                  tinyint       NOT NULL CONSTRAINT FK_dw_FatoMaquinaLeitura_Hora     REFERENCES dw.DimHora (HoraKey),
    DataHoraUtc              datetime2(3)  NOT NULL,
    DataHoraLocal            datetime2(3)  NOT NULL,
    TimeStartBruto           bigint        NOT NULL,   -- ProductManage.TimeStart sem tratamento (0 nas SIG)
    InicioProducaoMaquina    datetime2(0)  NULL,       -- TimeStart convertido pelo relógio da MÁQUINA (não é UTC);
                                                       -- NULL quando 0 ou fora do padrão epoch (ex.: KE2060 aponta para 1980)
    PrimeiraLeitura          bit           NOT NULL,   -- 1 = sem leitura anterior: deltas zerados (linha de base)
    NovaProducao             bit           NOT NULL,   -- 1 = contadores reiniciaram (TimeStart mudou ou contador diminuiu)
    TrocaPrograma            bit           NOT NULL,   -- 1 = programa (FileName/PwbId) diferente da leitura anterior
    ContadorRetomado         bit           NOT NULL,   -- 1 = a máquina voltou a um registro de produção anterior (TimeStart
                                                       --     já visto ou produção anterior à janela): diferença calculada
                                                       --     contra a última leitura daquele registro, ou zerada
    SegundosDesdeAnterior    int           NULL,
    EstadoMaquina            smallint      NULL,       -- Module.MachineStat
    CodigoErro               int           NULL,       -- Module.ErrorCode
    SinalLuminoso            smallint      NULL,       -- Module.SigLight
    TimeStopBruto            bigint        NULL,       -- ProductManage.TimeStop sem tratamento
    DadoSuspeito             bit           NOT NULL CONSTRAINT DF_dw_FatoMaquinaLeitura_DadoSuspeito DEFAULT 0,
    -- Acumulados (como vêm da máquina; segundos para tempos)
    PlacasAcum               int           NOT NULL,   -- ProductManage.ProductNum
    TempoRodandoAcum         int           NOT NULL,   -- TimeRun
    TempoPlacaAcum           int           NOT NULL,   -- TimePwb
    TempoEsperaEntradaAcum   int           NOT NULL,   -- TimePwbIn
    TempoEsperaSaidaAcum     int           NOT NULL,   -- TimePwbOut
    TempoParadaParcialAcum   int           NOT NULL,   -- TimeSomeStop
    TempoReparoAcum          int           NOT NULL,   -- TimeRepair
    TempoFalhaAcum           int           NOT NULL,   -- TimeTrouble
    TempoSemComponenteAcum   int           NOT NULL,   -- TimeNoComp
    TempoParadoAcum          int           NOT NULL,   -- TimeDown
    PickAcum                 int           NOT NULL,   -- soma de StoreNum[].Pick
    PlaceAcum                int           NOT NULL,   -- soma de StoreNum[].Place
    MissedAcum               int           NOT NULL,   -- soma de Feeder[].Missed
    -- Diferenças em relação à leitura anterior (aditivas)
    Placas                   int           NOT NULL,
    TempoRodando             int           NOT NULL,
    TempoPlaca               int           NOT NULL,
    TempoEsperaEntrada       int           NOT NULL,
    TempoEsperaSaida         int           NOT NULL,
    TempoParadaParcial       int           NOT NULL,
    TempoReparo              int           NOT NULL,
    TempoFalha               int           NOT NULL,
    TempoSemComponente       int           NOT NULL,
    TempoParado              int           NOT NULL,
    Pick                     int           NOT NULL,
    Place                    int           NOT NULL,
    Missed                   int           NOT NULL,
    CargaId                  int           NOT NULL,
    CONSTRAINT UQ_dw_FatoMaquinaLeitura_MongoId UNIQUE (MongoId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_dw_FatoMaquinaLeitura_Maquina_Data')
    CREATE INDEX IX_dw_FatoMaquinaLeitura_Maquina_Data ON dw.FatoMaquinaLeitura (MaquinaKey, DataHoraUtc);
GO

IF OBJECT_ID(N'dw.FatoFeederLeitura') IS NULL
CREATE TABLE dw.FatoFeederLeitura (
    LeituraId       bigint        NOT NULL CONSTRAINT FK_dw_FatoFeederLeitura_Leitura REFERENCES dw.FatoMaquinaLeitura (LeituraId),
    Lado            char(1)       NOT NULL,   -- F = frontal, R = traseiro (ordem do array Feeder x setup.Front)
    FeederPos       smallint      NOT NULL,
    MaquinaKey      int           NOT NULL CONSTRAINT FK_dw_FatoFeederLeitura_Maquina    REFERENCES dw.DimMaquina (MaquinaKey),
    ProgramaKey     int           NOT NULL CONSTRAINT FK_dw_FatoFeederLeitura_Programa   REFERENCES dw.DimPrograma (ProgramaKey),
    ComponenteKey   int           NOT NULL CONSTRAINT FK_dw_FatoFeederLeitura_Componente REFERENCES dw.DimComponente (ComponenteKey),
    DataKey         int           NOT NULL CONSTRAINT FK_dw_FatoFeederLeitura_Data       REFERENCES dw.DimData (DataKey),
    HoraKey         tinyint       NOT NULL CONSTRAINT FK_dw_FatoFeederLeitura_Hora       REFERENCES dw.DimHora (HoraKey),
    DataHoraUtc     datetime2(3)  NOT NULL,
    DataHoraLocal   datetime2(3)  NOT NULL,
    -- Acumulados
    PickedAcum      int NOT NULL,  PlacedAcum    int NOT NULL,  MissedAcum   int NOT NULL,
    NoCompAcum      int NOT NULL,  DiffCompAcum  int NOT NULL,  ErrorVacAcum int NOT NULL,
    LaserAcum       int NOT NULL,  VisionAcum    int NOT NULL,  CoplaAcum    int NOT NULL,
    VerifyAcum      int NOT NULL,  HeightAcum    int NOT NULL,  LeadBendAcum int NOT NULL,
    ColinAcum       int NOT NULL,
    -- Diferenças (motivos de perda: NoComp=sem componente, ErrorVac=vácuo, Laser, Vision=visão,
    -- Copla=coplanaridade, Verify, Height=altura, LeadBend=terminal torto, Colin)
    Picked          int NOT NULL,  Placed        int NOT NULL,  Missed       int NOT NULL,
    NoComp          int NOT NULL,  DiffComp      int NOT NULL,  ErrorVac     int NOT NULL,
    Laser           int NOT NULL,  Vision        int NOT NULL,  Copla        int NOT NULL,
    Verify          int NOT NULL,  Height        int NOT NULL,  LeadBend     int NOT NULL,
    Colin           int NOT NULL,
    CONSTRAINT PK_dw_FatoFeederLeitura PRIMARY KEY (LeituraId, Lado, FeederPos)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_dw_FatoFeederLeitura_Maquina_Data')
    CREATE INDEX IX_dw_FatoFeederLeitura_Maquina_Data ON dw.FatoFeederLeitura (MaquinaKey, DataHoraUtc) INCLUDE (ComponenteKey, Picked, Missed);
GO

IF OBJECT_ID(N'dw.FatoEvento') IS NULL
CREATE TABLE dw.FatoEvento (
    EventoId          bigint          IDENTITY(1,1) NOT NULL CONSTRAINT PK_dw_FatoEvento PRIMARY KEY,
    MongoId           char(24)        NOT NULL,
    DataHoraUtc       datetime2(3)    NOT NULL,
    DataHoraLocal     datetime2(3)    NOT NULL,
    DataKey           int             NOT NULL CONSTRAINT FK_dw_FatoEvento_Data  REFERENCES dw.DimData (DataKey),
    HoraKey           tinyint         NOT NULL CONSTRAINT FK_dw_FatoEvento_Hora  REFERENCES dw.DimHora (HoraKey),
    LinhaKey          int             NOT NULL CONSTRAINT FK_dw_FatoEvento_Linha REFERENCES dw.DimLinha (LinhaKey),
    MaquinaKey        int             NULL     CONSTRAINT FK_dw_FatoEvento_Maquina REFERENCES dw.DimMaquina (MaquinaKey), -- NULL para eventos do coletor (THREAD_xx)
    Modulo            nvarchar(50)    NOT NULL,
    Origem            varchar(10)     NOT NULL,   -- WATCH | SPEND
    TipoEvento        varchar(20)     NOT NULL,   -- FALHA_COLETA (SPEND) | FALHA_CONSUMO (PICKED) | INTERLOCK (AUDIT) | AGENDA
    TipoOriginal      varchar(50)     NOT NULL,   -- campo "type"
    Sucesso           bit             NULL,
    Status            nvarchar(50)    NULL,       -- 200 / 502 / INTERLOCK_ERROR ...
    Codigo            nvarchar(50)    NULL,       -- message.code
    Mensagem          nvarchar(1000)  NULL,       -- text
    Lado              char(1)         NULL,       -- data.side (AUDIT) ou 1ª letra do feeder no texto (PICKED)
    Slot              smallint        NULL,       -- data.slot (AUDIT) ou número do feeder no texto (PICKED)
    Feeder            nvarchar(20)    NULL,       -- data.feeder (AUDIT) ou "Feeder: R111 ..." (PICKED)
    CodigoFornecedor  nvarchar(100)   NULL,       -- data.vendorCode (AUDIT)
    CargaId           int             NOT NULL,
    CONSTRAINT UQ_dw_FatoEvento UNIQUE (MongoId, DataHoraUtc)  -- SPEND é atualizado no lugar: mesmo _id, "update" diferente
);
GO

IF OBJECT_ID(N'dw.MaquinaStatusAtual') IS NULL
CREATE TABLE dw.MaquinaStatusAtual (
    MaquinaKey           int             NOT NULL CONSTRAINT PK_dw_MaquinaStatusAtual PRIMARY KEY
                                         CONSTRAINT FK_dw_MaquinaStatusAtual_Maquina REFERENCES dw.DimMaquina (MaquinaKey),
    UltimaLeituraOkUtc   datetime2(3)    NULL,
    UltimaLeituraOkLocal datetime2(3)    NULL,
    ProgramaKey          int             NULL CONSTRAINT FK_dw_MaquinaStatusAtual_Programa REFERENCES dw.DimPrograma (ProgramaKey),
    EstadoMaquina        smallint        NULL,
    CodigoErro           int             NULL,
    PlacasAcum           int             NULL,
    PickAcum             int             NULL,
    PlaceAcum            int             NULL,
    MissedAcum           int             NULL,
    UltimaFalhaUtc       datetime2(3)    NULL,
    UltimaFalhaLocal     datetime2(3)    NULL,
    UltimaFalhaMensagem  nvarchar(1000)  NULL,
    ColetaOk             bit             NOT NULL,   -- 1 = última tentativa de coleta foi bem-sucedida
    AtualizadoEmUtc      datetime2(3)    NOT NULL
);
GO
