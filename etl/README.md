# SFCS_ETL — MongoDB (SPEND / WATCH) → SQL Server → Power BI

Pacote SSIS que leva os dados de consumo das máquinas SMT (coleções `SPEND` e `WATCH` do banco `thread_NN`) para um modelo estrela no SQL Server, pronto para dashboards no Power BI.

```text
MongoDB rs0 (thread_05)                    SQL Server (SFCS_DW)
┌──────────────┐  ZappySys MongoDB Source  ┌────────────────────┐  etl.usp_ProcessarCarga  ┌──────────────────────┐
│ WATCH        │ ───── RAW JSON ─────────▶ │ stg.MongoDocumento │ ───── OPENJSON ────────▶ │ dw.Dim* / dw.Fato*   │ ──▶ Power BI
│ SPEND        │   (incremental por data)  └────────────────────┘  deltas, repetidas,      └──────────────────────┘
└──────────────┘                                                    eventos, status
```

## Estrutura

| Caminho | Conteúdo |
|---|---|
| `SFCS_ETL.sln` | Solução (Visual Studio 2022/2026 + extensão SSIS) |
| `SFCS_ETL/SFCS_ETL.dtproj` | Projeto SSIS, modelo de implantação por projeto, alvo **SQL Server 2019** |
| `SFCS_ETL/Carga_Mongo_SPEND_WATCH.dtsx` | Pacote ETL |
| `SFCS_ETL/Project.params` | Parâmetros do projeto (conexões) |
| `SFCS_ETL/SQL/01..03_*.sql` | Scripts do banco de destino: banco, tabelas, procedures |
| `SFCS_ETL/SQL/04_CriarViewsBI.sql` | Camada de análise (schema `bi`) lida pelo Power BI ([`powerbi/`](../powerbi/README.md)) |
| `SFCS_ETL/Mongo/01_CriarIndices.js` | Índice no `WATCH` para a extração incremental |
| `tools/GerarPacote.ps1` | Gerador do projeto/pacote (modelo de objetos do SSIS) |

## Pré-requisitos

- SQL Server 2016+ no destino (testado no 2019 Developer). O banco precisa de compatibilidade ≥ 130 (`OPENJSON`).
- SSIS 2019 (DTS 150) e Visual Studio com a extensão *SQL Server Integration Services Projects*.
- **ZappySys SSIS PowerPack** instalado na máquina de desenvolvimento **e** no servidor que executar o pacote. A instalação atual é *trial*: o componente para de funcionar quando a avaliação expira, e é preciso licença para produção.
- Driver *Microsoft OLE DB Driver for SQL Server* (`MSOLEDBSQL`).

## Instalação

1. No SQL Server de destino, executar na ordem:
   `SQL/01_CriarBanco.sql` → `SQL/02_CriarTabelas.sql` → `SQL/03_CriarProcedures.sql` → `SQL/04_CriarViewsBI.sql`
   (os scripts são idempotentes; 03 e 04 usam `CREATE OR ALTER`). Os arquivos estão em UTF-8 **com BOM**, para que
   `sqlcmd` e SSMS leiam os acentos corretamente. Se forem editados, mantenha essa codificação.
2. No MongoDB, executar `Mongo/01_CriarIndices.js` (cria `{update:1, type:1}` no `WATCH` de todos os `thread_NN`).
3. Revisar `etl.Configuracao`:
   - `FUSO_HORARIO` — padrão `SA Western Standard Time` (America/Manaus, igual ao `tmz` do watch_api).
   - `MARGEM_MINUTOS` — sobreposição da extração incremental (padrão 10).
   - `CARGA_INICIAL_DIAS` — histórico da primeira carga (0 = tudo).
4. Revisar os turnos em `dw.DimHora` (padrão 06–14, 14–22, 22–06).
5. Abrir `SFCS_ETL.sln`, ajustar os parâmetros do projeto e executar.

### Parâmetros do projeto

| Parâmetro | Padrão | Uso |
|---|---|---|
| `MongoHost` | `host.docker.internal:27027,…:27028,…:27029` | Hosts do replica set |
| `MongoDatabase` | `thread_05` | Linha a carregar |
| `MongoOpcoes` | `replicaSet=rs0` | Opções da conexão ZappySys |
| `SqlServidor` | `localhost` | SQL Server de destino |
| `SqlBanco` | `SFCS_DW` | Banco de destino |

A conexão SQL usa autenticação Windows. Para usar autenticação SQL, edite o connection manager `SQL_SFCS_DW`.

## Fluxo do pacote

1. **SQL - Iniciar carga** — `etl.usp_IniciarCarga` abre a carga em `etl.Carga`, limpa a staging da linha e devolve `CargaId` e `FiltroDesdeUtc` (última leitura carregada − margem).
2. **DFT - Extrair WATCH** — ZappySys MongoDB Source em modo *RAW JSON*:
   `{Table:WATCH}` + `{update:{$gt:new ISODate("{{User::FiltroDesdeUtc}}")},$or:[{type:{$ne:"PICKED"}},{success:false}]}`.
   Os `PICKED` bem-sucedidos (~80% do volume, só texto) ficam de fora; as falhas de PICKED entram.
3. **DFT - Extrair SPEND** — coleção `SPEND` inteira (12 documentos por linha).
4. **SQL - Processar carga** — `etl.usp_ProcessarCarga` faz tudo em uma transação:
   achata o JSON, atualiza dimensões, descarta leituras repetidas, calcula diferenças, grava fatos, eventos e status, e avança a marca d'água.
5. **OnError** — `etl.usp_RegistrarFalha` marca a carga como `FALHA` com a mensagem.

Reexecutar é seguro: leituras e eventos já gravados são ignorados (`MongoId`), e a sobreposição de 10 min não duplica nada.

## Modelo (schema `dw`)

| Tabela | Grão | Observações |
|---|---|---|
| `FatoMaquinaLeitura` | 1 leitura SPEND (~2 min) por máquina, sem repetidas | Colunas `…Acum` = contador da máquina; sem sufixo = diferença (somar) |
| `FatoFeederLeitura` | leitura × lado (F/R) × posição | Perdas por motivo; ligada ao componente do setup |
| `FatoEvento` | 1 evento | `FALHA_COLETA` (SPEND 502), `FALHA_CONSUMO` (PICKED "Feeder não encontrado"), `INTERLOCK` (AUDIT), `AGENDA` |
| `MaquinaStatusAtual` | 1 linha por máquina | Foto da coleção SPEND: última leitura ok, programa, última falha |
| `DimLinha`, `DimMaquina`, `DimPrograma`, `DimComponente`, `DimData`, `DimHora` | | `DimData`/`DimHora` usam o horário **local** |

### Regras de tratamento

- **Repetidas**: leitura idêntica à anterior (máquina parada) é descartada. Na carga de teste, 58% das leituras eram repetidas.
- **Diferenças**: `atual − anterior`. A **primeira** leitura de cada máquina vira linha de base (diferença 0).
- **Reinício de contadores** (`NovaProducao = 1`): quando `TimeStart` muda ou um contador diminui. Nesse caso a diferença é o próprio valor atual, exceto nos casos de contador retomado (abaixo).
- **Contador retomado** (`ContadorRetomado = 1`): as KE voltam a registros de produção antigos, e o `TimeStart` e os contadores reaparecem com os valores daquele registro. Na KE2060-10, o registro `326545084` reapareceu com as mesmas 3.314 placas já vistas na véspera.
  - Se o `TimeStart` já foi visto, a diferença é calculada contra a **última leitura daquele registro**.
  - Se não foi visto e o tempo rodando acumulado não cabe no intervalo desde a leitura anterior, a produção é anterior à janela observada e a leitura vira linha de base (diferença 0).
  - Sem essa regra, a L10 aparecia com 17.460 placas em vez de ~1.006. Com ela, as máquinas de uma mesma linha fecham com praticamente a mesma contagem (por exemplo, L08: 1.582–1.587).
- **Troca de programa** (`TrocaPrograma = 1`) é marcada à parte. Ela **nem sempre zera os contadores**: no KE2080-06, de `P25-03679S` para `P25-03680S`, as placas seguiram de 370 para 436.
- **Lado do feeder**: o array `Feeder` traz primeiro os `setup.Front` feeders frontais e depois os traseiros. A posição sozinha se repete nas SIG200A, por isso a chave é lado + posição.
- **Datas**: o Mongo grava em UTC. `DataHoraLocal`, `DataKey` e `HoraKey` usam `FUSO_HORARIO`.

### Particularidades dos dados (verificadas no backup de 20–21/10)

- **SIG200A**: os tempos (`TimeRun`…) e o `MachineStat` vêm zerados (`DimMaquina.PossuiTempos = 0`). Elas não entram em indicadores de disponibilidade.
- **Feeders × máquina**: a soma de `Feeder[].Picked` não bate com `StoreNum.Pick` na origem. Bate 100% na KE2060, fica em 67–90% na KE2080-07 e chega a até 8× nas SIG. Use a taxa de perda **dentro** de cada tabela e não compare totais entre elas.
- **TimeStart**: nas KE2080 fica ~4 h à frente do UTC das leituras (relógio da máquina). Na KE2060-24 não é um epoch (aponta para 1980), e as leituras dela saem com `DadoSuspeito = 1`. Por isso a coluna se chama `InicioProducaoMaquina`, e o valor bruto fica em `TimeStartBruto`.
- **Histórico curto**: o backup tinha ~36 h de `WATCH`. Agende o pacote com intervalo bem menor que a retenção do `WATCH` em produção.

## Power BI

O relatório pronto está em [`powerbi/SFCS_Producao.pbip`](../powerbi/README.md) e lê as views `bi.*`. Dois cuidados valem para qualquer análise feita direto no `dw`:

- **Produção da linha não é a soma das máquinas.** A mesma placa passa por todas as máquinas da linha; use a maior contagem entre elas.
- **Tempos das KE:** em cada intervalo, `TimeRun + TimeDown` ≈ tempo decorrido, e `TimeSomeStop`/`TimeNoComp` costumam repetir o valor de `TimeDown`. As causas se sobrepõem. Disponibilidade = `TimeRun ÷ (TimeRun + TimeDown)`.
- **Falhas, MTBF e MTTR** (`bi.FalhaMaquina`): uma falha é uma sequência de leituras com `TimeTrouble` ou `TimeRepair` > 0. Falha e reparo quase nunca se sobrepõem na mesma leitura, e o total é limitado ao `TimeDown`. Paradas a partir de `FALHA_MIN_MINUTOS` (`etl.Configuracao`, padrão 5) são falhas; as menores são microparadas.
- **Ciclo de referência** (`bi.CicloIdeal`): não há ciclo padrão na origem; usa-se a taxa demonstrada (percentil 10 dos segundos por placa por máquina e programa). É a base do desempenho do OEE.

## Execução agendada

- **SSISDB**: implantar `bin\Development\SFCS_ETL.ispac` no catálogo e criar um job no SQL Server Agent (a cada 10–15 min).
- **dtexec** a partir do `.ispac` (sem catálogo). `/Par` só funciona com `/ISServer`; com `/Project` o parâmetro é trocado via `/Set`:

  ```bat
  dtexec /Project SFCS_ETL.ispac /Package Carga_Mongo_SPEND_WATCH.dtsx /Set "\Package.Variables[$Project::MongoDatabase];thread_06"
  ```

- **dtexec** a partir do catálogo SSISDB:

  ```bat
  dtexec /ISServer "\SSISDB\SFCS\SFCS_ETL\Carga_Mongo_SPEND_WATCH.dtsx" /Server localhost /Par "$Project::MongoDatabase";thread_06
  ```

- **Outras linhas**: mesmo pacote, trocando `MongoDatabase`. Rode as linhas **em sequência**, não em paralelo, porque as dimensões são compartilhadas.

## Regenerar o pacote

`tools/GerarPacote.ps1` recria `.sln`, `.dtproj`, `.dtsx`, `Project.params` e `.database`. Ele lê os metadados do Mongo e da staging, então os dois precisam estar acessíveis. **Isso sobrescreve alterações feitas no Visual Studio nesses arquivos.** Depois que o pacote passar a ser mantido pelo designer, deixe de usar o gerador.

```powershell
powershell -ExecutionPolicy Bypass -File etl\tools\GerarPacote.ps1 -MongoDatabase thread_05 -SqlServidor localhost
```
