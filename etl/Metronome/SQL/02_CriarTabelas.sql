/* =============================================================================
   Metronome - Camada de análise (Metronome_PRO -> Metronome_DW -> Power BI)
   02 - Schemas, sinônimos da origem e tabelas

   Origem: os sinônimos src.* apontam para Metronome_PRO no mesmo servidor.
   Se a origem estiver em outro banco/servidor (linked server), altere só os sinônimos.

   O modelo dw é recarregado por inteiro em etl.usp_Carregar: as tabelas não têm
   chaves estrangeiras para permitir TRUNCATE; a integridade é garantida pela carga
   (toda chave sem correspondência vira -1 = N/D).
============================================================================= */
USE Metronome_DW;
GO

IF SCHEMA_ID(N'src') IS NULL EXEC (N'CREATE SCHEMA src');
IF SCHEMA_ID(N'etl') IS NULL EXEC (N'CREATE SCHEMA etl');
IF SCHEMA_ID(N'dw')  IS NULL EXEC (N'CREATE SCHEMA dw');
IF SCHEMA_ID(N'bi')  IS NULL EXEC (N'CREATE SCHEMA bi');
GO

/* ------------------------------- Sinônimos ------------------------------- */
DECLARE @Origem sysname = N'Metronome_PRO';   -- banco de origem
DECLARE @t sysname, @sql nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT v FROM (VALUES (N'PartsSupply'), (N'PartsSupplyMovement'), (N'PartsAuditMounter'), (N'PlanAudit'),
                          (N'PlanAuditFeeder'), (N'Parts'), (N'PartsType'), (N'EnumType'), (N'EnumTypeItem'),
                          (N'Equipment'), (N'Thread'), (N'ThreadSchema'), (N'ThreadSchemaLayout'),
                          (N'SupplyPlace'), (N'SupplyBox'), (N'Users')) x (v);
OPEN c;
FETCH NEXT FROM c INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'IF OBJECT_ID(N''src.' + @t + N''', N''SN'') IS NOT NULL DROP SYNONYM src.' + QUOTENAME(@t) + N'; '
             + N'CREATE SYNONYM src.' + QUOTENAME(@t) + N' FOR ' + QUOTENAME(@Origem) + N'.sfcs.' + QUOTENAME(@t) + N';';
    EXEC (@sql);
    FETCH NEXT FROM c INTO @t;
END
CLOSE c; DEALLOCATE c;
GO

/* ------------------------------ Controle --------------------------------- */
IF OBJECT_ID(N'etl.Configuracao') IS NULL
CREATE TABLE etl.Configuracao (
    Chave      varchar(50)    NOT NULL CONSTRAINT PK_etl_Configuracao PRIMARY KEY,
    Valor      nvarchar(100)  NOT NULL,
    Descricao  nvarchar(300)  NULL
);
GO

MERGE etl.Configuracao AS d
USING (VALUES
    ('DATA_INICIAL',          N'20240101', N'Eventos, setups, consumo e movimentos a partir desta data (yyyymmdd). As bobinas entram todas.'),
    ('REPETIDA_SEGUNDOS',     N'60',       N'Leitura da mesma bobina no mesmo destino dentro deste intervalo é considerada repetida.'),
    ('SETUP_MAX_SEGUNDOS',    N'3600',     N'Conferências de setup mais longas que isto (sessão esquecida aberta) ficam fora das médias.'),
    ('PARADA_DIAS',           N'90',       N'Bobina com saldo sem movimento há mais que isto é considerada parada.')
) AS o (Chave, Valor, Descricao)
ON d.Chave = o.Chave
WHEN NOT MATCHED THEN INSERT (Chave, Valor, Descricao) VALUES (o.Chave, o.Valor, o.Descricao);
GO

IF OBJECT_ID(N'etl.Carga') IS NULL
CREATE TABLE etl.Carga (
    CargaId      int            IDENTITY CONSTRAINT PK_etl_Carga PRIMARY KEY,
    Inicio       datetime2(0)   NOT NULL CONSTRAINT DF_etl_Carga_Inicio DEFAULT SYSDATETIME(),
    Fim          datetime2(0)   NULL,
    Status       varchar(10)    NOT NULL CONSTRAINT DF_etl_Carga_Status DEFAULT 'EXECUTANDO',   -- EXECUTANDO | OK | FALHA
    DataCorte    datetime2(0)   NULL,   -- último registro da origem (referência para "dias sem movimento")
    Mensagem     nvarchar(4000) NULL
);
GO

/* ------------------------------- Dimensões ------------------------------- */
IF OBJECT_ID(N'dw.DimData') IS NULL
CREATE TABLE dw.DimData (
    DataKey        int           NOT NULL CONSTRAINT PK_dw_DimData PRIMARY KEY,  -- yyyymmdd
    Data           date          NOT NULL,
    Ano            smallint      NOT NULL,
    Mes            tinyint       NOT NULL,
    NomeMes        nvarchar(20)  NOT NULL,
    AnoMes         char(7)       NOT NULL,   -- yyyy-mm
    Dia            tinyint       NOT NULL,
    DiaSemana      tinyint       NOT NULL,   -- 1 = domingo
    NomeDiaSemana  nvarchar(20)  NOT NULL
);
GO

IF OBJECT_ID(N'dw.DimHora') IS NULL
CREATE TABLE dw.DimHora (
    HoraKey  tinyint       NOT NULL CONSTRAINT PK_dw_DimHora PRIMARY KEY,  -- 0..23
    Hora     char(5)       NOT NULL,                                       -- 06:00
    Turno    nvarchar(20)  NOT NULL
);
GO

-- Turnos padrão (os mesmos do SFCS_DW): AJUSTE conforme a escala real da fábrica.
IF NOT EXISTS (SELECT 1 FROM dw.DimHora)
    INSERT dw.DimHora (HoraKey, Hora, Turno)
    SELECT h, RIGHT('0' + CAST(h AS varchar(2)), 2) + ':00',
           CASE WHEN h BETWEEN 6 AND 13 THEN N'1º Turno'
                WHEN h BETWEEN 14 AND 21 THEN N'2º Turno'
                ELSE N'3º Turno' END
    FROM (SELECT TOP (24) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS tinyint) AS h FROM sys.all_objects) x;
GO

IF OBJECT_ID(N'dw.DimMaquina') IS NULL
CREATE TABLE dw.DimMaquina (
    MaquinaKey  int           NOT NULL CONSTRAINT PK_dw_DimMaquina PRIMARY KEY,   -- -1 = N/D
    Maquina     varchar(30)   NOT NULL CONSTRAINT UQ_dw_DimMaquina UNIQUE,        -- KE2060-12
    Linha       varchar(10)   NOT NULL,                                           -- L05 (layout ativo) ou N/D
    Familia     varchar(20)   NOT NULL,                                           -- KE2060, KE2080, SIG200A, HT122
    Modelo      nvarchar(100) NULL
);
GO

IF OBJECT_ID(N'dw.DimComponente') IS NULL
CREATE TABLE dw.DimComponente (
    ComponenteKey  int            NOT NULL CONSTRAINT PK_dw_DimComponente PRIMARY KEY,   -- sfcs.Parts.Id; -1 = N/D
    Codigo         varchar(50)    NOT NULL,
    Nome           nvarchar(100)  NULL,
    Descricao      nvarchar(200)  NULL,
    Tipo           nvarchar(50)   NOT NULL    -- PartsType ou 1ª palavra do nome (CAPACITOR, RESISTOR...)
);
GO

IF OBJECT_ID(N'dw.DimPrograma') IS NULL
CREATE TABLE dw.DimPrograma (
    ProgramaKey  int            NOT NULL CONSTRAINT PK_dw_DimPrograma PRIMARY KEY,
    Arquivo      varchar(100)   NOT NULL CONSTRAINT UQ_dw_DimPrograma UNIQUE,   -- P25-04209M.e46
    Programa     varchar(100)   NOT NULL,                                       -- P25-04209M
    Projeto      varchar(100)   NOT NULL                                        -- P25-04209 (programas da mesma placa)
);
GO

IF OBJECT_ID(N'dw.DimOperador') IS NULL
CREATE TABLE dw.DimOperador (
    OperadorKey  int            NOT NULL CONSTRAINT PK_dw_DimOperador PRIMARY KEY,   -- -1 = N/D
    Codigo       varchar(30)    NOT NULL CONSTRAINT UQ_dw_DimOperador UNIQUE,        -- matrícula (UserCode)
    Nome         nvarchar(150)  NOT NULL
);
GO

IF OBJECT_ID(N'dw.DimTipoEvento') IS NULL
CREATE TABLE dw.DimTipoEvento (
    Codigo     varchar(10)    NOT NULL CONSTRAINT PK_dw_DimTipoEvento PRIMARY KEY,   -- AUDIT_TYPE (5001...)
    Descricao  nvarchar(100)  NOT NULL,
    Categoria  nvarchar(50)   NOT NULL,   -- Barcode, Splicing, Realimentação, Troca de cassete...
    Resultado  nvarchar(20)   NOT NULL,   -- Verificado | Bloqueado | Registro
    Ordem      tinyint        NOT NULL
);
GO

/* --------------------------------- Fatos --------------------------------- */
-- Eventos de auditoria das máquinas (sfcs.PartsAuditMounter)
IF OBJECT_ID(N'dw.FatoEventoMaquina') IS NULL
CREATE TABLE dw.FatoEventoMaquina (
    EventoId     int           NOT NULL CONSTRAINT PK_dw_FatoEventoMaquina PRIMARY KEY,
    DataHora     datetime2(0)  NOT NULL,
    DataKey      int           NOT NULL,
    HoraKey      tinyint       NOT NULL,
    MaquinaKey   int           NOT NULL,
    OperadorKey  int           NOT NULL,
    TipoCodigo   varchar(10)   NOT NULL,
    Lado         char(1)       NOT NULL    -- F | R | -
);
GO

-- Conferências de setup (sfcs.PlanAudit + PlanAuditFeeder)
IF OBJECT_ID(N'dw.FatoSetup') IS NULL
CREATE TABLE dw.FatoSetup (
    SetupId            int           NOT NULL CONSTRAINT PK_dw_FatoSetup PRIMARY KEY,
    DataHora           datetime2(0)  NOT NULL,
    DataKey            int           NOT NULL,
    HoraKey            tinyint       NOT NULL,
    MaquinaKey         int           NOT NULL,
    ProgramaKey        int           NOT NULL,
    OperadorKey        int           NOT NULL,
    Feeders            int           NOT NULL,
    FeedersConferidos  int           NOT NULL,
    DuracaoSeg         int           NULL,      -- 1º feeder lido -> último feeder confirmado
    DuracaoValida      bit           NOT NULL   -- 0 = sem feeders ou acima de SETUP_MAX_SEGUNDOS
);
GO

-- Consumo: queda de saldo de uma bobina entre dois movimentos, atribuída à máquina onde ela estava
IF OBJECT_ID(N'dw.FatoConsumo') IS NULL
CREATE TABLE dw.FatoConsumo (
    MovimentoId    int           NOT NULL CONSTRAINT PK_dw_FatoConsumo PRIMARY KEY,   -- movimento que registrou o novo saldo
    BobinaId       int           NOT NULL,
    DataHora       datetime2(0)  NOT NULL,
    DataKey        int           NOT NULL,
    HoraKey        tinyint       NOT NULL,
    MaquinaKey     int           NOT NULL,
    ComponenteKey  int           NOT NULL,
    Lado           char(1)       NOT NULL,
    Slot           int           NULL,
    Quantidade     int           NOT NULL,
    Esgotou        bit           NOT NULL,    -- a bobina chegou a zero neste movimento
    Origem         nvarchar(30)  NOT NULL     -- Em máquina | Fora da máquina (baixa no almoxarifado, kit, caixa)
);
GO

-- Foto atual de cada bobina (sfcs.PartsSupply + último movimento)
IF OBJECT_ID(N'dw.FatoBobina') IS NULL
CREATE TABLE dw.FatoBobina (
    BobinaId            int            NOT NULL CONSTRAINT PK_dw_FatoBobina PRIMARY KEY,
    CodigoBobina        varchar(50)    NULL,       -- SupplyCode (etiqueta MK...)
    ComponenteKey       int            NOT NULL,
    DataKey             int            NOT NULL,   -- data de recebimento
    Recebimento         datetime2(0)   NOT NULL,
    Embalagem           int            NOT NULL,
    Saldo               int            NULL,       -- NULL quando o saldo da origem é inválido (negativo ou > embalagem)
    SaldoValido         bit            NOT NULL,
    Situacao            nvarchar(20)   NOT NULL,   -- Com saldo | Esgotada | Saldo inválido
    UltimoMovimento     datetime2(0)   NULL,
    TipoLocal           nvarchar(30)   NOT NULL,   -- Almoxarifado | Kit (preparação) | Linha | Caixa / cassete | Máquina | ...
    LocalAtual          nvarchar(100)  NULL,
    MaquinaKey          int            NOT NULL,   -- máquina onde está montada (-1 se não estiver)
    PrimeiraMontagem    datetime2(0)   NULL,
    HorasAteMontar      int            NULL,
    DiasSemMovimento    int            NULL,       -- em relação à data de corte da carga
    FaixaAging          nvarchar(20)   NOT NULL,
    FaixaAgingOrdem     tinyint        NOT NULL,
    Movimentos          int            NOT NULL,
    MovimentosRepetidos int            NOT NULL
);
GO

-- Movimentos de bobinas agregados por hora, destino e operador
IF OBJECT_ID(N'dw.FatoMovimento') IS NULL
CREATE TABLE dw.FatoMovimento (
    DataKey       int           NOT NULL,
    HoraKey       tinyint       NOT NULL,
    MaquinaKey    int           NOT NULL,
    OperadorKey   int           NOT NULL,
    TipoDestino   nvarchar(30)  NOT NULL,
    Movimentos    int           NOT NULL,
    Repetidos     int           NOT NULL,
    CONSTRAINT PK_dw_FatoMovimento PRIMARY KEY (DataKey, HoraKey, MaquinaKey, OperadorKey, TipoDestino)
);
GO

-- Indicadores de qualidade da origem, recalculados a cada carga
IF OBJECT_ID(N'dw.QualidadeDados') IS NULL
CREATE TABLE dw.QualidadeDados (
    Ordem       tinyint        NOT NULL CONSTRAINT PK_dw_QualidadeDados PRIMARY KEY,
    Indicador   nvarchar(100)  NOT NULL,
    Ocorrencias bigint         NOT NULL,
    Total       bigint         NOT NULL,
    Tratamento  nvarchar(300)  NOT NULL
);
GO
