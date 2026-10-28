# Metronome_DW — Metronome_PRO → SQL Server → Power BI

Camada de análise sobre o `Metronome_PRO`, o banco transacional do SFCS: bobinas, movimentos, interlocks nas máquinas e conferência de setup. O relatório [`powerbi/Metronome_Abastecimento.pbip`](../../powerbi/README.md) lê as views `bi.*` deste banco.

O `Metronome_PRO` **não registra placas produzidas**; essas vêm do `SFCS_DW` ([`etl/SFCS_ETL`](../README.md)). Os dois bancos usam o mesmo nome de máquina (`KE2060-12`) e o mesmo arquivo de programa (`P25-04209M.e46`), então podem ser cruzados, desde que cubram o mesmo período.

```text
Metronome_PRO (sfcs.*)  ──sinônimos src.*──▶  etl.usp_Carregar  ──▶  dw.Dim* / dw.Fato*  ──▶  bi.*  ──▶  Power BI
```

## Instalação

Execute no SQL Server, nesta ordem:

```text
SQL/01_CriarBanco.sql → SQL/02_CriarTabelas.sql → SQL/03_CriarProcedures.sql → SQL/04_CriarViewsBI.sql
```

Depois rode a primeira carga com `EXEC Metronome_DW.etl.usp_Carregar;`.

- O banco é criado com a ordenação da origem (`SQL_Latin1_General_CP1_CI_AS`). Se o servidor usar outra, as junções com `src.*` dão erro de conflito de collation.
- Os sinônimos `src.*` apontam para `Metronome_PRO` no mesmo servidor. Para usar outro banco ou um linked server, altere `@Origem` no script 02.
- Os scripts estão em UTF-8 **com BOM** (acentos corretos no `sqlcmd`). Se forem editados, mantenha essa codificação.
- A procedure usa só recursos do SQL Server 2019. Não use `WINDOW` nem outras sintaxes do 2022.

## Carga

`etl.usp_Carregar` faz uma **recarga completa** em uma transação e registra cada execução em `etl.Carga`. Os 5,6 milhões de movimentos levam cerca de 25 s em uma máquina de desenvolvimento. Agende 1 vez por turno ou por dia no SQL Server Agent.

`etl.Configuracao`:

| Chave | Padrão | Uso |
|---|---|---|
| `DATA_INICIAL` | `20240101` | Eventos, setups, consumo e movimentos a partir desta data. Todas as bobinas entram. |
| `REPETIDA_SEGUNDOS` | `60` | Leitura da mesma bobina no mesmo destino dentro deste intervalo conta como repetida. |
| `SETUP_MAX_SEGUNDOS` | `3600` | Conferências de setup mais longas que isto ficam fora das médias. |
| `PARADA_DIAS` | `90` | Bobina com saldo e sem movimento há mais que isto é considerada parada. |

## Modelo (schema `dw`)

| Tabela | Grão | Origem |
|---|---|---|
| `FatoEventoMaquina` | 1 evento de auditoria | `PartsAuditMounter` |
| `FatoSetup` | 1 conferência de setup | `PlanAudit` + `PlanAuditFeeder` |
| `FatoConsumo` | 1 queda de saldo de bobina | `PartsSupplyMovement` |
| `FatoBobina` | 1 bobina (foto atual) | `PartsSupply` + último movimento |
| `FatoMovimento` | movimentos por hora × máquina × operador × destino | `PartsSupplyMovement` |
| `QualidadeDados` | 1 indicador | calculado na carga |
| `DimMaquina`, `DimComponente`, `DimPrograma`, `DimOperador`, `DimTipoEvento`, `DimData`, `DimHora` | | A linha da máquina vem do layout ativo (`ThreadSchemaLayout`). |

## Regras de tratamento

- **Saldo da bobina** é o **menor saldo válido** (0 até a embalagem) já registrado para ela.
  - Ao montar na máquina, o saldo costuma vir somado ao da bobina emendada. Exemplo: 7.184 numa bobina de 5.000.
  - Também há saldos negativos ou absurdos, chegando a 993 milhões.
  - Esses valores e os aumentos de saldo são ignorados.
- **Consumo** é a queda desse saldo entre dois movimentos, atribuída à máquina e ao slot do movimento anterior.
  - `QuantityPickedOut` **não é usado**: é acumulado entre bobinas e passa da embalagem em 55% delas.
  - Quedas em que a bobina não saiu de uma máquina (por exemplo, almoxarifado → zero) são **baixas de estoque** e ficam com `Origem = 'Fora da máquina'`, fora do consumo.
- **Tipo de movimento**: `MovementTypeId` vem sempre nulo. O tipo é deduzido pelo destino: máquina, local de linha (`Line Lxx`), almoxarifado (`ALMOX`), kit (`KW`/`KIT`), estufa (`DRY`) ou caixa/cassete.
- **Interlock**:
  - Os códigos "in process" (`5130`, `5132`, `5134`, `5136`, `5138`) contam como **Verificação**.
  - Os "Blocked" (`5131`, `5133`, `5135`, `5137`, `5139`) contam como **Bloqueio**.
  - Esses códigos só existem desde ago/2025, então compare taxas de bloqueio a partir de jan/2026.
- **Datas**: a origem grava hora local (`GETDATE()` do servidor). Os turnos em `dw.DimHora` são os mesmos do `SFCS_DW` (06–14, 14–22, 22–06). Ajuste se a escala for outra.

## Particularidades da origem

Recalculadas a cada carga em `dw.QualidadeDados` e mostradas na Visão Geral do relatório. Na carga de 24/10/2026:

| Indicador | Ocorrências |
|---|---|
| Movimentos repetidos (< 60 s) | 1.681.768 de 5.624.948 (29,9%) |
| Saldos fora da faixa | 618.784 (11,0%) |
| `QuantityPickedOut` acima da embalagem | 324.918 de 595.154 bobinas |
| Conferências de setup sem feeders ou > 1 h | 133 de 16.424 |

Outras observações:

- **Bobinas de dez/2023 com embalagem 0.** São da implantação do sistema e ficam com "Saldo inválido".
- **Tabelas de planejamento sem dados reais.** `ProductionPlanning`, `ProductModel`, `ProductionShift`, `LearningCurve` e `CalendarDate` têm só dados de teste ou de 2022, por isso não há comparação de planejado com realizado.
