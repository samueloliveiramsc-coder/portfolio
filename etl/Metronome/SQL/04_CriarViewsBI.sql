/* =============================================================================
   Metronome - Camada de análise (Metronome_PRO -> Metronome_DW -> Power BI)
   04 - Views do schema bi consumidas pelo Power BI

   As views só leem o modelo dw. O relatório powerbi\Metronome_Abastecimento.pbip
   importa exatamente estas views.
============================================================================= */
USE Metronome_DW;
GO

/* ------------------------------- Dimensões ------------------------------- */
CREATE OR ALTER VIEW bi.Maquina AS
SELECT MaquinaKey, Linha, Maquina, Familia, Modelo,
       CASE WHEN MaquinaKey = -1 THEN N'N/D' ELSE Linha + N' · ' + Maquina END AS LinhaMaquina
FROM dw.DimMaquina;
GO

CREATE OR ALTER VIEW bi.Componente AS
SELECT ComponenteKey, Codigo AS Componente, Nome AS NomeComponente, Descricao AS DescricaoComponente, Tipo AS TipoComponente
FROM dw.DimComponente;
GO

CREATE OR ALTER VIEW bi.Programa AS
SELECT ProgramaKey, Programa, Arquivo, Projeto
FROM dw.DimPrograma;
GO

CREATE OR ALTER VIEW bi.Operador AS
SELECT OperadorKey, Codigo AS Matricula,
       CASE WHEN OperadorKey = -1 OR Nome LIKE N'Matrícula %' THEN Nome ELSE Codigo + N' · ' + Nome END AS Operador
FROM dw.DimOperador;
GO

CREATE OR ALTER VIEW bi.Calendario AS
SELECT DataKey, Data, Ano, Mes, NomeMes, AnoMes, Dia, DiaSemana, NomeDiaSemana
FROM dw.DimData;
GO

CREATE OR ALTER VIEW bi.Hora AS
SELECT HoraKey, Hora, Turno
FROM dw.DimHora;
GO

CREATE OR ALTER VIEW bi.TipoEvento AS
SELECT Codigo AS TipoCodigo, Codigo + N' · ' + Descricao AS TipoEvento, Categoria, Resultado, Ordem
FROM dw.DimTipoEvento;
GO

/* --------------------------------- Fatos --------------------------------- */
CREATE OR ALTER VIEW bi.EventoMaquina AS
SELECT EventoId, DataHora, DataKey, HoraKey, MaquinaKey, OperadorKey, TipoCodigo, Lado
FROM dw.FatoEventoMaquina;
GO

CREATE OR ALTER VIEW bi.Setup AS
SELECT SetupId, DataHora, DataKey, HoraKey, MaquinaKey, ProgramaKey, OperadorKey,
       Feeders, FeedersConferidos,
       CAST(DuracaoSeg / 60.0 AS decimal(9,1)) AS DuracaoMin,
       CAST(DuracaoValida AS int) AS DuracaoValida
FROM dw.FatoSetup;
GO

-- Consumo agregado por hora, máquina, componente e origem (Em máquina | Fora da máquina)
CREATE OR ALTER VIEW bi.Consumo AS
SELECT DataKey, HoraKey, MaquinaKey, ComponenteKey, Origem,
       SUM(CAST(Quantidade AS bigint))  AS Quantidade,
       SUM(CAST(Esgotou AS int))        AS BobinasEsgotadas,
       COUNT(*)                         AS Quedas
FROM dw.FatoConsumo
GROUP BY DataKey, HoraKey, MaquinaKey, ComponenteKey, Origem;
GO

-- Foto atual das bobinas. Esgotadas antes de DATA_INICIAL ficam de fora (não servem a nenhuma análise).
CREATE OR ALTER VIEW bi.Bobina AS
SELECT b.BobinaId, b.CodigoBobina, b.ComponenteKey, b.DataKey, b.MaquinaKey,
       b.Recebimento, b.Embalagem, b.Saldo, b.Situacao, b.UltimoMovimento,
       b.TipoLocal, b.LocalAtual, b.PrimeiraMontagem,
       CAST(b.HorasAteMontar / 24.0 AS decimal(9,1)) AS DiasAteMontar,
       b.DiasSemMovimento, b.FaixaAging, b.FaixaAgingOrdem,
       CASE WHEN b.Situacao = N'Com saldo' AND b.DiasSemMovimento > p.Dias THEN 1 ELSE 0 END AS Parada,
       b.Movimentos AS QtdMovimentos, b.MovimentosRepetidos AS QtdRepetidos
FROM dw.FatoBobina b
CROSS JOIN (SELECT CAST(Valor AS int) AS Dias FROM etl.Configuracao WHERE Chave = 'PARADA_DIAS') p
WHERE b.Situacao <> N'Esgotada'
   OR b.Recebimento >= (SELECT CONVERT(datetime2(0), Valor, 112) FROM etl.Configuracao WHERE Chave = 'DATA_INICIAL');
GO

CREATE OR ALTER VIEW bi.Movimento AS
SELECT DataKey, HoraKey, MaquinaKey, OperadorKey, TipoDestino,
       Movimentos AS QtdMovimentos, Repetidos AS QtdRepetidos
FROM dw.FatoMovimento;
GO

CREATE OR ALTER VIEW bi.QualidadeDados AS
SELECT q.Ordem, q.Indicador, q.Ocorrencias, q.Total,
       CAST(1.0 * q.Ocorrencias / NULLIF(q.Total, 0) AS decimal(9,4)) AS Percentual,
       q.Tratamento,
       c.DataCorte
FROM dw.QualidadeDados q
CROSS JOIN (SELECT TOP 1 DataCorte FROM etl.Carga WHERE Status = 'OK' ORDER BY CargaId DESC) c;
GO
