# Dashboards Power BI

| Relatório | Banco | Assunto |
|---|---|---|
| [`SFCS_Producao.pbip`](#sfcs_producao) | `SFCS_DW` ([`etl/SFCS_ETL`](../etl/README.md)) | Produção das máquinas: placas, disponibilidade, perdas, trocas, coleta |
| [`Metronome_Abastecimento.pbip`](#metronome_abastecimento) | `Metronome_DW` ([`etl/Metronome`](../etl/Metronome/README.md)) | Abastecimento: interlock, consumo de material, setup, estoque de bobinas, operadores |

Os dois são gerados por scripts em `tools/` que compartilham [`pbip_base.py`](tools/pbip_base.py).

Guia completo do `SFCS_Producao` (páginas, medidas, modelo semântico e por que o OEE é sem qualidade): [`docs/SFCS_Producao/README.md`](docs/SFCS_Producao/README.md).

## SFCS_Producao

Relatório Power BI sobre o banco `SFCS_DW`, que é alimentado pelo ETL em [`etl/`](../etl/README.md). Ele está salvo como **Power BI Project (.pbip)**: o modelo semântico fica em TMDL e o relatório em PBIR, tudo texto e versionável no Git.

### Como abrir

1. No SQL Server, execute `etl/SFCS_ETL/SQL/04_CriarViewsBI.sql`, que cria o schema `bi` lido pelo relatório.
2. Abra `SFCS_Producao.pbip` no Power BI Desktop (versão de 2025 ou posterior, com suporte a PBIR/TMDL).
3. O projeto abre **sem dados**, porque o cache não é versionado. Clique em **Atualizar**.
4. Para usar outro servidor ou banco, vá em *Transformar dados → Editar parâmetros* e altere `Servidor` (padrão `localhost`) e `Banco` (padrão `SFCS_DW`). A conexão usa autenticação Windows.

Na primeira atualização o Desktop pode pedir as credenciais do SQL Server. Escolha *Windows → usar minhas credenciais atuais*.

### Páginas

As páginas têm **1920 × 1080** e um **menu lateral** com um botão por página; a página atual fica destacada. No Power BI Desktop, os botões são acionados com **Ctrl + clique**; no serviço e no link público, com clique simples. As fontes são 30% maiores que o padrão do Power BI (`escala_fonte` em `gerar_pbip.py`).

Todas as páginas têm os filtros **Linha, Máquina, Período e Turno**, sincronizados entre elas.

| Página | Conteúdo |
|---|---|
| **Visão Geral** | Placas, disponibilidade, taxa de perda, trocas, falhas de coleta e interlocks; placas por linha e por hora; status atual de todas as máquinas |
| **Produção** | Placas por máquina, turno e hora do dia; matriz máquina × dia; produção por programa (placas/h rodando, componentes por placa) |
| **Perdas de Componentes** | Picked, Missed, taxa de perda e PPM; perda por máquina e por componente; ocorrências por motivo; feeders com mais perdas |
| **Disponibilidade (KE)** | Disponibilidade por máquina e por hora; horas por categoria de tempo (TimeRun, TimeDown, causas); matriz máquina × categoria |
| **Trocas de Programa** | Trocas e tempo de troca por máquina; histórico de cada troca (programa anterior → novo) |
| **Coleta e Interlock** | Falhas de coleta, falhas de consumo, interlocks e % de máquinas coletando; eventos por linha e hora; mensagens mais frequentes; situação de cada máquina |
| **Confiabilidade e OEE (KE)** | OEE sem qualidade, disponibilidade, desempenho, falhas, MTBF e MTTR; OEE por máquina; lista de paradas por falha; tabela por máquina; ciclo de referência por programa |

### Medidas principais

| Medida | Definição |
|---|---|
| `Placas` | Produção da **linha**: a maior contagem entre as máquinas da linha, porque a mesma placa passa por todas. Por máquina, é a contagem da própria máquina. |
| `Placas Processadas` | Soma das contagens de todas as máquinas (uma placa conta uma vez em cada máquina). |
| `Disponibilidade %` | `TimeRun ÷ (TimeRun + TimeDown)`. Só as KE informam tempos; para SIG e HT a medida fica em branco. |
| `Placas por Hora Rodando` | Placas das KE ÷ horas de TimeRun. |
| `Taxa de Perda %` / `Perdas PPM` | `Missed ÷ Picked` dos feeders. |
| `Ocorrências de Perda` | Ocorrências por motivo (NoComp, ErrorVac, Vision…). Um pick perdido pode registrar mais de um motivo, então **não some** com Missed. |
| `Horas por Categoria` | Horas por categoria de tempo da máquina. As causas de parada **se sobrepõem** (na origem, `TimeSomeStop` e `TimeNoComp` costumam repetir o valor de `TimeDown`); compare as categorias lado a lado, nunca somadas. |
| `Tempo Médio de Troca (min)` | Tempo da última placa do programa anterior até a primeira placa do novo, com precisão de ~2 min (intervalo de coleta). |
| `% Máquinas com Coleta OK` | Máquinas cuja última tentativa de coleta foi bem-sucedida. |
| `Desempenho %` | Placas × ciclo de referência ÷ tempo rodando, limitado a 100%. Não existe ciclo padrão de engenharia na origem. O ciclo usado é a **taxa demonstrada** (`bi.CicloIdeal`): o percentil 10 dos segundos rodando por placa, por máquina e programa, em horas com ao menos 5 placas e 10 min rodando. Se o ciclo padrão for cadastrado, troque a view. |
| `OEE % (sem qualidade)` | `Disponibilidade % × Desempenho %`. A qualidade fica de fora (equivale a 100%) porque a origem não informa placas aprovadas ou reprovadas. A disponibilidade é calculada sobre o tempo ligado, não sobre o tempo planejado do turno. |
| `Falhas`, `Microparadas` | Sequências de leituras com TimeTrouble ou TimeRepair. A partir de `FALHA_MIN_MINUTOS` (padrão 5 min, em `etl.Configuracao`) contam como falha; as mais curtas são microparadas. |
| `MTBF (h)` / `MTTR (min)` | Horas rodando ÷ falhas e minutos parados por falha ÷ falhas, só para máquinas KE. Paradas curtas entre duas coletas (~2 min) não aparecem. O MTTR inclui a espera pelo técnico. **Precisa de semanas de histórico:** com as ~36 h do backup são só 7 falhas. |

O modelo usa `discourageImplicitMeasures`: valores numéricos devem vir das medidas, não de colunas arrastadas.

### Janela de dados

O calendário e os eventos vão do primeiro dia com leituras até o último dia com dados. O SPEND guarda só a *última falha* de cada máquina, às vezes de meses atrás. Essas falhas antigas aparecem no status atual, mas ficam fora dos gráficos por período.

### Regenerar

O relatório foi gerado por [`tools/gerar_pbip.py`](tools/gerar_pbip.py), que lê os tipos das colunas das views `bi.*` no SQL Server:

```powershell
python powerbi\tools\gerar_pbip.py --servidor localhost --banco SFCS_DW
```

**O gerador sobrescreve** o `.SemanticModel` e o `.Report`. Depois que o relatório passar a ser editado no Power BI Desktop, use o Desktop e deixe de rodar o gerador.

## Metronome_Abastecimento

Relatório sobre o banco `Metronome_DW`, que é a camada de análise do `Metronome_PRO`. As regras de tratamento estão em [`etl/Metronome`](../etl/Metronome/README.md).

### Como abrir

1. No SQL Server, execute `etl/Metronome/SQL/01` a `04` e rode `EXEC Metronome_DW.etl.usp_Carregar;`.
2. Abra `Metronome_Abastecimento.pbip` e clique em **Atualizar**. O padrão dos parâmetros é `Servidor = localhost` e `Banco = Metronome_DW`.

### Páginas

O layout é o mesmo do `SFCS_Producao`: páginas de **1920 × 1080**, **menu lateral** com um botão por página (Ctrl + clique no Desktop, clique simples no serviço) e fontes 30% maiores.

As páginas 1 a 4 e 6 têm os filtros **Linha, Máquina, Período e Turno**, sincronizados entre elas.

| Página | Conteúdo |
|---|---|
| **Visão Geral** | Consumo, bobinas esgotadas, setups, taxa de bloqueio, descargas forçadas e data dos dados; consumo e taxa de bloqueio por mês; bloqueio por linha; qualidade dos dados da origem |
| **Interlock e Bloqueios** | Verificações, bloqueios, splicings e descargas forçadas; taxa por linha e por hora; bloqueios por tipo; tabelas por máquina e por tipo de evento |
| **Consumo de Material** | Consumo por mês, linha e tipo de componente; componentes mais consumidos; matriz máquina × turno; baixas fora da máquina |
| **Setup de Programa** | Setups, programas e feeders por setup; tempo mediano de conferência; setups por mês, máquina e hora; projetos mais conferidos; conferências recentes |
| **Estoque e Aging de Bobinas** | Foto atual, que não depende do período: bobinas e peças com saldo, por local e por tempo sem movimento; bobinas paradas; dias do recebimento à montagem |
| **Operadores** | Atividade por operador e taxa de bloqueio por turno. Use para orientar treinamento, não como ranking. |

### Medidas principais

| Medida | Definição |
|---|---|
| `Taxa de Bloqueio %` | `Bloqueios ÷ Verificações`. As verificações só existem desde ago/2025; compare a partir de 2026. |
| `Consumo (peças)` | Queda do saldo das bobinas que passaram por máquina. A data é a do movimento que registrou o novo saldo, normalmente a retirada ou o esgotamento da bobina. |
| `Baixas Fora da Máquina (peças)` | Quedas de saldo sem passagem pela máquina, como baixa no almoxarifado. Não entram no consumo. |
| `Tempo Mediano de Conferência (min)` | Do 1º feeder lido ao último confirmado. Conferências sem feeders ou acima de 1 h ficam de fora. |
| `Bobinas com Saldo`, `Peças em Estoque`, `Bobinas Paradas` | Foto da última carga. Ignoram o filtro de período. "Parada" significa sem movimento há mais de 90 dias. |
| `Dias até Montar` | Do recebimento até a primeira montagem em máquina, agrupado pelo mês de recebimento. |

### Regenerar

```powershell
python powerbi\tools\gerar_pbip_metronome.py --servidor localhost --banco Metronome_DW
```

Como no outro relatório, **o gerador sobrescreve** o `.SemanticModel` e o `.Report`.
