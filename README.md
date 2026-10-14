# Base de OCI do SIA-PA (Pernambuco)

Extrai mensalmente a produção ambulatorial do SIA/SUS (arquivos `PAPEaamm.dbc`
do FTP do DATASUS), mantém só os procedimentos de Ofertas de Cuidados
Integrados (grupo `09`) e grava uma base histórica para o Power BI.

## Por que não usar o microdatasus

O `microdatasus` funciona, mas para este caso a leitura direta é melhor:

| | microdatasus | este script (curl + read.dbc) |
|---|---|---|
| Atualização incremental | não sabe o que já foi baixado | só baixa movimentos novos ou republicados |
| Arquivos republicados pelo DATASUS | não detecta | compara nome, tamanho e data do FTP |
| Arquivos em partes (`PAPE2502a`, `b`...) | sim | sim |
| Memória | lê o mês inteiro e decodifica rótulos | filtra o grupo 09 logo após ler cada parte |
| Falha de rede | interrompe | 4 tentativas por arquivo; mês com falha fica para a próxima execução |

As duas opções usam o mesmo leitor (`read.dbc`), então os números são os mesmos.

## Campos

| Coluna | Significado no layout do SIA-PA |
|---|---|
| `PA_CMP` | competência de realização do atendimento (AAAAMM) |
| `PA_MVM` | competência de processamento, ou seja, o arquivo em que o registro veio |
| `PA_GESTAO` | município gestor (`260000` = gestão estadual de PE) |
| `PA_CODUNI` | CNES do estabelecimento |
| `PA_UFMUN` | município do estabelecimento |
| `PA_PROC_ID` | procedimento SIGTAP (filtrado por `09...`) |
| `PA_QTDPRO` | quantidade **apresentada** (produzida) |
| `PA_QTDAPR` | quantidade **aprovada** |
| `PA_VALPRO` | valor **apresentado** (produzido) |
| `PA_VALAPR` | valor **aprovado** |
| `N_REGISTROS` | linhas do SIA somadas naquela combinação |
| `COMPETENCIA`, `MOVIMENTO` | `PA_CMP` e `PA_MVM` como data (dia 1), prontas para o eixo de tempo |

Atenção: `PA_QTDAPR` é a quantidade aprovada; a apresentada é `PA_QTDPRO`.
Não existe `PA_QTDAPRO` no layout.

A base é agregada por `PA_MVM + PA_CMP + PA_GESTAO + PA_CODUNI + PA_UFMUN + PA_PROC_ID`.
Para gravar as linhas do SIA sem somar, use `agregar = FALSE` no `CFG`.

## Competência x movimento (reapresentações)

Cada arquivo mensal do DATASUS é um **movimento** (`PA_MVM`) e traz produção de
várias **competências** (`PA_CMP`): a do mês e as anteriores apresentadas com
atraso ou reapresentadas após glosa. Por isso:

- A produção de uma competência continua mudando nos meses seguintes. Os
  últimos 3 a 4 meses do painel devem ser lidos como parciais.
- Um procedimento glosado em um movimento e reapresentado em outro aparece duas
  vezes como **apresentado**, mas só uma como **aprovado**. Para "apresentado
  sem reapresentação", filtre `PA_MVM == PA_CMP` ou analise por `MOVIMENTO`.
- Quando o DATASUS republica um arquivo já processado, o script detecta a
  mudança de tamanho/data e refaz só aquele movimento.

## Uso

```r
# uma vez
Rscript instalar_pacotes.R

# a cada execução (incremental)
Rscript oci_sia_pe.R
Rscript oci_sia_pe.R --forcar=202503        # reprocessa um movimento
Rscript oci_sia_pe.R --reprocessar-tudo     # refaz tudo
Rscript oci_sia_pe.R --inicio=2025-01       # muda o primeiro movimento
```

A primeira carga baixa todos os meses desde `inicio` (padrão `2025-02`, quando as OCI começaram em PE); cada
mês de PE tem dezenas a centenas de MB compactados, então leva um tempo. As
execuções seguintes só listam o FTP e saem, até aparecer um mês novo.

Estrutura gerada em `dados/`:

```
dados/
  movimentos/oci_PE_AAAAMM.csv          um arquivo por movimento (fonte da verdade)
  controle/movimentos_processados.csv   o que foi baixado e com qual assinatura do FTP
  saida/oci_sia_pe.parquet              base consolidada para o Power BI
  saida/oci_sia_pe.csv                  idem em CSV (; e vírgula decimal, UTF-8)
```

## Tabelas dimensão

`dimensoes.R` roda logo depois da extração e grava em `dados/dimensoes/`
(Parquet e CSV). Cada dimensão tem todos os códigos que aparecem na base; o que
a fonte não reconhece entra como "(não encontrado)", para nenhuma linha sumir.

| Arquivo | Chave | Fonte | Conteúdo |
|---|---|---|---|
| `dim_procedimento` | `PA_PROC_ID` | SIGTAP vigente (FTP do DATASUS) | nome da OCI, grupo, subgrupo (especialidade), forma de organização, valores SA/SP |
| `dim_municipio` | `CO_MUNICIPIO` | base territorial do DATASUS | município, região de saúde, macrorregião, capital, latitude/longitude; inclui `260000` = Gestão Estadual |
| `dim_estabelecimento` | `PA_CODUNI` | API de dados abertos do CNES | nome fantasia, razão social, CNPJ, esfera, tipo de unidade, coordenadas, município |

Os dados do CNES são consultados de novo a cada 28 dias; estabelecimentos novos
na base são consultados no mesmo dia.

### Modelo no Power BI

```
dim_procedimento[PA_PROC_ID]        1 ──* oci_sia_pe[PA_PROC_ID]
dim_estabelecimento[PA_CODUNI]      1 ──* oci_sia_pe[PA_CODUNI]
dim_municipio[CO_MUNICIPIO]         1 ──* oci_sia_pe[PA_GESTAO]   (ativo)
dim_municipio[CO_MUNICIPIO]         1 ──* oci_sia_pe[PA_UFMUN]    (inativo)
dCalendario[Data]                   1 ──* oci_sia_pe[COMPETENCIA]
```

O município aparece em dois papéis. O mais simples é carregar `dim_municipio`
duas vezes, como "Município gestor" e "Município do estabelecimento", cada
cópia com um relacionamento ativo. Alternativa: um só relacionamento ativo e
`USERELATIONSHIP` nas medidas que precisarem do outro.

## Power BI

- Prefira o Parquet: *Obter dados > Parquet*, apontando para `oci_sia_pe.parquet`.
  Os tipos já vêm certos.
- No CSV, defina `PA_GESTAO`, `PA_CODUNI`, `PA_UFMUN`, `PA_PROC_ID` como texto
  para não perder zeros à esquerda do CNES.

## Automação

Duas opções, escolha uma:

1. **GitHub Actions** (`.github/workflows/atualizar_oci.yml`): coloque esta
   pasta num repositório. O job roda todo dia, só processa quando há arquivo
   novo e faz commit de `dados/` no próprio repositório (os dados filtrados de
   OCI são pequenos). Também dá para rodar manualmente pela aba *Actions*.
   Com repositório público, o Power BI lê o CSV/Parquet pela URL *raw*.
2. **Agendador do Windows** (`agendar_windows.ps1`): roda o script na máquina
   local todo dia às 7h. Deixe a pasta dentro do OneDrive/SharePoint para o
   Power BI Service atualizar o relatório a partir dela.

O DATASUS não tem data fixa de publicação, por isso a checagem é diária.

## Próximos passos possíveis

- Outras UFs: mude `uf` no `CFG`.
