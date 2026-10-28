/* =============================================================================
   SFCS - ETL MongoDB (SPEND / WATCH) -> SQL Server -> Power BI
   04 - Camada de análise (schema bi) consumida pelo Power BI

   As views só leem o modelo dw; não há carga extra. O relatório
   powerbi\SFCS_Producao.pbip importa exatamente estas views.
============================================================================= */
USE SFCS_DW;
GO

IF SCHEMA_ID(N'bi') IS NULL EXEC (N'CREATE SCHEMA bi');
GO

/* ------------------------------- Dimensões ------------------------------- */
CREATE OR ALTER VIEW bi.Maquina AS
SELECT m.MaquinaKey,
       l.Linha,
       l.MongoDatabase                                   AS Thread,
       m.Modulo,
       l.Linha + N' · ' + m.Modulo                       AS LinhaModulo,   -- único: há módulos em mais de uma linha
       m.Familia,
       ISNULL(m.Modelo, m.Familia)                       AS Modelo,
       m.IpModulo,
       CASE WHEN m.PossuiTempos = 1 THEN N'Sim' ELSE N'Não' END AS InformaTempos
FROM dw.DimMaquina m
JOIN dw.DimLinha l ON l.LinhaKey = m.LinhaKey;
GO

CREATE OR ALTER VIEW bi.Programa AS
SELECT ProgramaKey, Arquivo AS Programa, Placa AS Produto
FROM dw.DimPrograma;
GO

CREATE OR ALTER VIEW bi.Componente AS
SELECT ComponenteKey, Codigo AS Componente
FROM dw.DimComponente;
GO

-- Calendário restrito à janela observada: do primeiro dia com leituras até o último dia com dados.
-- (O SPEND guarda a "última falha" de cada máquina, às vezes de meses atrás; esses eventos antigos
-- ficam fora da análise temporal e continuam visíveis em bi.StatusAtual.)
CREATE OR ALTER VIEW bi.Calendario AS
SELECT d.DataKey, d.Data, d.Ano, d.Mes, d.NomeMes, d.AnoMes, d.Dia, d.DiaSemana, d.NomeDiaSemana
FROM dw.DimData d
WHERE d.DataKey BETWEEN (SELECT MIN(DataKey) FROM dw.FatoMaquinaLeitura)
                    AND (SELECT MAX(k) FROM (SELECT MAX(DataKey) FROM dw.FatoMaquinaLeitura UNION ALL SELECT MAX(DataKey) FROM dw.FatoEvento) x(k));
GO

CREATE OR ALTER VIEW bi.Hora AS
SELECT HoraKey, Hora, Turno
FROM dw.DimHora;
GO

/* --------------------------------- Fatos --------------------------------- */
-- Ciclo de referência por máquina e programa (só máquinas que informam tempos).
-- Não há ciclo padrão de engenharia na origem: usa-se a TAXA DEMONSTRADA, o percentil 10 dos
-- segundos rodando por placa em horas com ao menos 5 placas e 10 min rodando (mínimo 2 horas).
CREATE OR ALTER VIEW bi.CicloIdeal AS
WITH h AS (
    SELECT f.MaquinaKey, f.ProgramaKey, DATEADD(HOUR, DATEDIFF(HOUR, 0, f.DataHoraLocal), 0) AS Hora,
           SUM(f.TempoRodando) AS Rodando, SUM(f.Placas) AS Placas
    FROM dw.FatoMaquinaLeitura f
    JOIN dw.DimMaquina m ON m.MaquinaKey = f.MaquinaKey AND m.PossuiTempos = 1
    GROUP BY f.MaquinaKey, f.ProgramaKey, DATEADD(HOUR, DATEDIFF(HOUR, 0, f.DataHoraLocal), 0)
), v AS (
    SELECT MaquinaKey, ProgramaKey,
           PERCENTILE_CONT(0.1) WITHIN GROUP (ORDER BY 1.0 * Rodando / Placas) OVER (PARTITION BY MaquinaKey, ProgramaKey) AS Ciclo,
           COUNT(*) OVER (PARTITION BY MaquinaKey, ProgramaKey) AS Horas
    FROM h
    WHERE Placas >= 5 AND Rodando >= 600
)
SELECT DISTINCT MaquinaKey, ProgramaKey, CAST(Ciclo AS decimal(9,2)) AS CicloIdealSeg, Horas AS HorasBase
FROM v
WHERE Horas >= 2;
GO

-- Paradas por falha das máquinas que informam tempos: sequência de leituras consecutivas com
-- TimeTrouble ou TimeRepair > 0. Tipo = 'Falha' a partir de FALHA_MIN_MINUTOS (padrão 5, convenção
-- TPM); abaixo disso é 'Microparada' (perda de desempenho, fora do MTBF/MTTR).
-- Início/Fim = horário das leituras (fim do intervalo coletado, ~2 min).
CREATE OR ALTER VIEW bi.FalhaMaquina AS
WITH s AS (
    SELECT f.MaquinaKey, f.ProgramaKey, f.DataKey, f.HoraKey, f.DataHoraLocal, f.TempoFalha, f.TempoReparo,
           -- falha e reparo raramente se sobrepõem; o total nunca passa do tempo parado da leitura
           CASE WHEN f.TempoFalha + f.TempoReparo > f.TempoParado THEN f.TempoParado ELSE f.TempoFalha + f.TempoReparo END AS Parada,
           CASE WHEN f.TempoFalha + f.TempoReparo > 0 THEN 1 ELSE 0 END AS EmFalha,
           ROW_NUMBER() OVER (PARTITION BY f.MaquinaKey ORDER BY f.DataHoraUtc, f.LeituraId) AS n
    FROM dw.FatoMaquinaLeitura f
    JOIN dw.DimMaquina m ON m.MaquinaKey = f.MaquinaKey AND m.PossuiTempos = 1
), g AS (
    SELECT s.*, n - ROW_NUMBER() OVER (PARTITION BY MaquinaKey, EmFalha ORDER BY n) AS Grupo
    FROM s
)
SELECT ROW_NUMBER() OVER (ORDER BY MaquinaKey, MIN(n)) AS FalhaId,
       CASE WHEN SUM(Parada) >= 60 * ISNULL((SELECT TRY_CAST(Valor AS int) FROM etl.Configuracao WHERE Chave = 'FALHA_MIN_MINUTOS'), 5)
            THEN N'Falha' ELSE N'Microparada' END AS Tipo,
       MaquinaKey,
       MIN(ProgramaKey) AS ProgramaKey,   -- programa no início da falha (igual em quase todos os casos)
       MIN(DataKey) AS DataKey,
       CAST(MIN(DataHoraLocal) AS datetime2(0)) AS Inicio,
       CAST(MAX(DataHoraLocal) AS datetime2(0)) AS Fim,
       COUNT(*) AS Leituras,
       CAST(SUM(Parada) / 60.0 AS decimal(9,1))      AS MinutosParada,
       CAST(SUM(TempoFalha) / 60.0 AS decimal(9,1))  AS MinutosFalha,
       CAST(SUM(TempoReparo) / 60.0 AS decimal(9,1)) AS MinutosReparo,
       CAST(DATEPART(HOUR, MIN(DataHoraLocal)) AS tinyint) AS HoraKey
FROM g
WHERE EmFalha = 1
GROUP BY MaquinaKey, Grupo;
GO

-- Uma linha por leitura (~2 min) sem repetidas; valores = diferença desde a leitura anterior
CREATE OR ALTER VIEW bi.Leitura AS
SELECT f.LeituraId, f.MaquinaKey, f.ProgramaKey, f.DataKey, f.HoraKey,
       f.DataHoraLocal,
       CAST(DATEADD(HOUR, DATEDIFF(HOUR, 0, f.DataHoraLocal), 0) AS datetime2(0)) AS HoraLocal,
       CAST(f.NovaProducao  AS int) AS Reinicio,
       CAST(f.TrocaPrograma AS int) AS TrocaPrograma,
       CAST(f.DadoSuspeito  AS int) AS DadoSuspeito,
       CAST(f.ContadorRetomado AS int) AS ContadorRetomado,
       f.EstadoMaquina, f.CodigoErro,
       -- prefixo Qtd: os nomes Placas/Pick/Place ficam para as medidas do Power BI
       f.Placas AS QtdPlacas, f.Pick AS QtdPick, f.Place AS QtdPlace, f.Missed AS QtdMissed,
       f.TempoRodando, f.TempoParado, f.TempoFalha, f.TempoSemComponente, f.TempoReparo,
       f.TempoParadaParcial, f.TempoEsperaEntrada, f.TempoEsperaSaida, f.TempoPlaca,
       -- desempenho do OEE: segundos que as placas levariam no ciclo de referência
       CAST(f.Placas * c.CicloIdealSeg AS decimal(12,2)) AS TempoIdeal,
       CASE WHEN c.CicloIdealSeg IS NULL THEN 0 ELSE 1 END AS TemCiclo
FROM dw.FatoMaquinaLeitura f
LEFT JOIN bi.CicloIdeal c ON c.MaquinaKey = f.MaquinaKey AND c.ProgramaKey = f.ProgramaKey;
GO

-- Feeders agregados por hora (somente horas com movimento)
CREATE OR ALTER VIEW bi.Feeder AS
SELECT f.MaquinaKey, f.ProgramaKey, f.ComponenteKey, f.DataKey, f.HoraKey,
       f.Lado, f.FeederPos,
       f.Lado + CAST(f.FeederPos AS varchar(6)) AS Feeder,
       SUM(f.Picked) AS Picked, SUM(f.Placed) AS Placed, SUM(f.Missed) AS Missed
FROM dw.FatoFeederLeitura f
WHERE f.Picked <> 0 OR f.Placed <> 0 OR f.Missed <> 0
GROUP BY f.MaquinaKey, f.ProgramaKey, f.ComponenteKey, f.DataKey, f.HoraKey, f.Lado, f.FeederPos;
GO

-- Ocorrências por motivo de perda. Um mesmo pick perdido pode registrar mais de um motivo:
-- os motivos NÃO somam o total de Missed.
CREATE OR ALTER VIEW bi.PerdaMotivo AS
SELECT f.MaquinaKey, f.ProgramaKey, f.ComponenteKey, f.DataKey, f.HoraKey,
       v.Ordem, v.Motivo, SUM(v.Qtde) AS Ocorrencias
FROM dw.FatoFeederLeitura f
CROSS APPLY (VALUES
    (1,  N'Sem componente (NoComp)',        f.NoComp),
    (2,  N'Componente diferente (DiffComp)', f.DiffComp),
    (3,  N'Vácuo (ErrorVac)',               f.ErrorVac),
    (4,  N'Laser',                          f.Laser),
    (5,  N'Visão (Vision)',                 f.Vision),
    (6,  N'Coplanaridade (Copla)',          f.Copla),
    (7,  N'Verificação (Verify)',           f.Verify),
    (8,  N'Altura (Height)',                f.Height),
    (9,  N'Terminal torto (LeadBend)',      f.LeadBend),
    (10, N'Colin',                          f.Colin)
) v (Ordem, Motivo, Qtde)
WHERE v.Qtde > 0
GROUP BY f.MaquinaKey, f.ProgramaKey, f.ComponenteKey, f.DataKey, f.HoraKey, v.Ordem, v.Motivo;
GO

-- Tempos da máquina (só máquinas que informam tempos). Rodando + Parado ~ tempo ligado;
-- as causas de parada se sobrepõem entre si e NÃO devem ser somadas.
CREATE OR ALTER VIEW bi.TempoMaquina AS
SELECT f.MaquinaKey, f.DataKey, f.HoraKey, v.Ordem, v.Grupo, v.Categoria, SUM(v.Segundos) AS Segundos
FROM dw.FatoMaquinaLeitura f
JOIN dw.DimMaquina m ON m.MaquinaKey = f.MaquinaKey AND m.PossuiTempos = 1
CROSS APPLY (VALUES
    (1, N'Estado',           N'Rodando (TimeRun)',               f.TempoRodando),
    (2, N'Estado',           N'Parado (TimeDown)',               f.TempoParado),
    (3, N'Causa de parada',  N'Sem componente (TimeNoComp)',     f.TempoSemComponente),
    (4, N'Causa de parada',  N'Parada parcial (TimeSomeStop)',   f.TempoParadaParcial),
    (5, N'Causa de parada',  N'Falha (TimeTrouble)',             f.TempoFalha),
    (6, N'Causa de parada',  N'Reparo (TimeRepair)',             f.TempoReparo),
    (7, N'Fluxo de placas',  N'Espera entrada (TimePwbIn)',      f.TempoEsperaEntrada),
    (8, N'Fluxo de placas',  N'Espera saída (TimePwbOut)',       f.TempoEsperaSaida)
) v (Ordem, Grupo, Categoria, Segundos)
GROUP BY f.MaquinaKey, f.DataKey, f.HoraKey, v.Ordem, v.Grupo, v.Categoria;
GO

-- Trocas de programa. Tempo de troca = última placa do programa anterior -> primeira placa do novo
-- (precisão de ~2 min, o intervalo de coleta; janela de busca de 24 h).
CREATE OR ALTER VIEW bi.TrocaPrograma AS
WITH t AS (
    SELECT f.LeituraId, f.MaquinaKey, f.ProgramaKey, f.DataKey, f.HoraKey, f.DataHoraUtc, f.DataHoraLocal,
           LAG(f.ProgramaKey) OVER (PARTITION BY f.MaquinaKey ORDER BY f.DataHoraUtc, f.LeituraId) AS ProgramaAnteriorKey,
           f.TrocaPrograma
    FROM dw.FatoMaquinaLeitura f
)
SELECT t.LeituraId, t.MaquinaKey, t.DataKey, t.HoraKey, t.DataHoraLocal,
       pa.Arquivo AS ProgramaAnterior,
       pn.Arquivo AS ProgramaNovo,
       pn.Placa   AS ProdutoNovo,
       CAST(DATEDIFF(SECOND, ua.Ultima, pp.Primeira) / 60.0 AS decimal(9,1)) AS MinutosTroca
FROM t
JOIN dw.DimPrograma pn ON pn.ProgramaKey = t.ProgramaKey
LEFT JOIN dw.DimPrograma pa ON pa.ProgramaKey = t.ProgramaAnteriorKey
OUTER APPLY (SELECT MAX(x.DataHoraUtc) AS Ultima FROM dw.FatoMaquinaLeitura x
             WHERE x.MaquinaKey = t.MaquinaKey AND x.ProgramaKey = t.ProgramaAnteriorKey AND x.Placas > 0
               AND x.DataHoraUtc < t.DataHoraUtc AND x.DataHoraUtc >= DATEADD(HOUR, -24, t.DataHoraUtc)) ua
OUTER APPLY (SELECT MIN(x.DataHoraUtc) AS Primeira FROM dw.FatoMaquinaLeitura x
             WHERE x.MaquinaKey = t.MaquinaKey AND x.ProgramaKey = t.ProgramaKey AND x.Placas > 0
               AND x.DataHoraUtc >= t.DataHoraUtc AND x.DataHoraUtc < DATEADD(HOUR, 24, t.DataHoraUtc)) pp
WHERE t.TrocaPrograma = 1;
GO

-- Eventos das máquinas (falhas de coleta, falhas de consumo e interlocks)
CREATE OR ALTER VIEW bi.Evento AS
SELECT e.EventoId, e.MaquinaKey, e.DataKey, e.HoraKey, e.DataHoraLocal,
       CAST(DATEADD(HOUR, DATEDIFF(HOUR, 0, e.DataHoraLocal), 0) AS datetime2(0)) AS HoraLocal,
       CASE e.TipoEvento WHEN 'FALHA_COLETA'  THEN N'Falha de coleta'
                         WHEN 'FALHA_CONSUMO' THEN N'Falha de consumo'
                         WHEN 'INTERLOCK'     THEN N'Interlock'
                         ELSE e.TipoEvento END AS TipoEvento,
       e.Status, e.Codigo,
       LEFT(e.Mensagem, 200) AS Mensagem,
       e.Lado, e.Slot, e.Feeder, e.CodigoFornecedor
FROM dw.FatoEvento e
WHERE e.MaquinaKey IS NOT NULL AND e.TipoEvento <> 'AGENDA'
  AND e.DataKey >= (SELECT MIN(DataKey) FROM dw.FatoMaquinaLeitura);   -- mesma janela de bi.Calendario
GO

CREATE OR ALTER VIEW bi.StatusAtual AS
SELECT s.MaquinaKey,
       p.Arquivo AS ProgramaAtual,
       s.UltimaLeituraOkLocal, s.UltimaFalhaLocal,
       LEFT(s.UltimaFalhaMensagem, 200) AS UltimaFalhaMensagem,
       CASE WHEN s.ColetaOk = 1 THEN N'OK' ELSE N'Falhando' END AS SituacaoColeta,
       CAST(s.ColetaOk AS int) AS ColetaOk,
       s.PlacasAcum, s.PickAcum, s.MissedAcum
FROM dw.MaquinaStatusAtual s
LEFT JOIN dw.DimPrograma p ON p.ProgramaKey = s.ProgramaKey;
GO
