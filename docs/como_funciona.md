# Como funciona a base OCI: extração e automação

Este texto explica, sem pressupor conhecimento de programação, o caminho que
os dados percorrem desde o DATASUS até o painel no Power BI.

## Visão geral

```
DATASUS (FTP)  →  GitHub Actions (computador emprestado)  →  Repositório no GitHub  →  Power BI
 arquivos PAPE       baixa, filtra OCI, soma, junta nomes       guarda as tabelas         lê as tabelas
```

Ninguém precisa ligar nada. Duas vezes por dia, o GitHub empresta um
computador, executa os programas, guarda o resultado e desliga o computador.

---

## 1. De onde vêm os dados

O Ministério da Saúde publica a produção ambulatorial (SIA) em um servidor
público de arquivos, o **FTP do DATASUS**. Cada estado tem um arquivo por mês,
com nome no formato `PAPEaamm.dbc`:

- `PA` = Produção Ambulatorial
- `PE` = Pernambuco
- `aamm` = ano e mês do **movimento**, que é o mês em que a produção foi
  processada e paga. Por exemplo, `PAPE2607.dbc` é o movimento de julho/2026.

Cada linha desse arquivo é um registro de produção: qual procedimento, qual
estabelecimento, qual município gestor, quantas unidades foram apresentadas e
aprovadas, e quanto isso custou. O arquivo de PE tem centenas de milhares de
linhas por mês, de todos os procedimentos. As OCI são uma pequena parte.

O formato `.dbc` é um formato antigo e comprimido, próprio do DATASUS. Por isso
é preciso um leitor específico (o pacote `read.dbc`, ou, como reserva, o
`pyreaddbc`).

## 2. O que o programa faz (a extração)

O programa principal é o arquivo `oci_sia_pe.R`, escrito na linguagem R. Ele
segue estes passos:

1. **Olha a lista de arquivos do FTP.** Ele vê quais arquivos `PAPE` existem,
   a partir de fevereiro/2025 (início das OCI em PE), e anota o tamanho e a
   data de cada um.
2. **Compara com o que já foi feito.** Existe uma "ficha de controle"
   (`dados/controle/movimentos_processados.csv`) com cada mês já processado e
   a "assinatura" do arquivo naquele momento (nome, tamanho e data). Se a
   assinatura é a mesma, o mês é pulado. Assim, o programa só baixa o que é
   novo ou o que o DATASUS republicou. Isso se chama **processamento
   incremental**.
3. **Baixa o arquivo novo** (com novas tentativas se a conexão cair) e o lê.
4. **Filtra as OCI.** Mantém apenas as linhas em que o código do procedimento
   (`PA_PROC_ID`) começa com `09`.
5. **Soma.** Junta as linhas iguais e soma as quantidades e os valores. Linhas
   iguais têm o mesmo movimento, competência, município gestor, estabelecimento
   e procedimento. Os campos somados são:
   - `PA_QTDPRO`: quantidade apresentada
   - `PA_QTDAPR`: quantidade aprovada
   - `PA_VALPRO`: valor apresentado
   - `PA_VALAPR`: valor aprovado
6. **Consolida.** Junta o mês novo aos meses anteriores em uma só tabela,
   `oci_sia_pe`, e atualiza a ficha de controle.

### Competência x movimento

- **Competência** (`PA_CMP`) é o mês em que o atendimento aconteceu.
- **Movimento** (`PA_MVM`) é o mês em que a produção foi processada e paga.

Um atendimento de maio pode ser apresentado em maio, junho ou julho. Por isso
um mês de competência continua "crescendo" depois de publicado, enquanto um mês
de movimento, uma vez publicado, não muda mais. O painel usa o **movimento**
como "Referência". A competência continua disponível na coluna `Competência`.

## 3. Os nomes: tabelas dimensão

A tabela de produção guarda apenas códigos, como `2611606` ou `0902010026`. Os
nomes ficam em tabelas separadas, as **tabelas dimensão**, geradas pelo
`dimensoes.R`:

| Tabela | O que traz | De onde vem |
|---|---|---|
| `dim_procedimento` | Nome da OCI, grupo, subgrupo, valor | SIGTAP (tabela de procedimentos do SUS), no FTP do DATASUS |
| `dim_municipio` | Nome do município, região de saúde, macrorregião | Base territorial do DATASUS + nomes oficiais do IBGE |
| `dim_estabelecimento` | Nome do estabelecimento, município | API de dados abertos do CNES |

Separar códigos e nomes evita repetir o mesmo nome milhares de vezes e
permite corrigir um nome em um só lugar.

## 4. As tabelas do painel

O `painel_ate.R` monta duas tabelas já no formato que o painel espera:

- **`monitoramento_ate`**: a produção por movimento, competência, executor
  (município gestor) e OCI, já com nomes, região de saúde e especialidade. Os
  nomes das colunas são iguais aos da planilha antiga. Os nomes curtos das OCI
  vêm de `referencias/nomes_oci.csv`.
- **`atualizacao`**: uma linha com o último mês processado e a data e hora em
  que a base recebeu dados novos. Ela alimenta o texto "Dados processados
  até… Última atualização…".

Todas as tabelas são salvas em dois formatos:

- **CSV**: abre no Excel. Usa ponto e vírgula e vírgula decimal.
- **Parquet**: formato compacto, que guarda os tipos (data, número, texto).
  É o que o Power BI lê.

## 5. A automação: GitHub e GitHub Actions

- O **repositório** `DGMOG-SES/base-oci-sia` é uma pasta na internet que
  guarda os programas e as tabelas, com o histórico de cada alteração.
- O **GitHub Actions** é um serviço do GitHub que executa tarefas em um
  computador temporário. A receita dessa tarefa está em
  `.github/workflows/atualizar_oci.yml`.

### Quando roda

- Todo dia às **7h17** e às **12h17** (horário de Brasília). O GitHub às vezes
  atrasa esses horários, por isso há duas checagens: a segunda cobre a
  primeira.
- Sempre que um dos programas é alterado.
- Quando alguém clica em *Run workflow* na aba **Actions** do repositório.

### O que cada execução faz

1. Liga um computador Linux emprestado pelo GitHub.
2. Copia o repositório para ele, incluindo a ficha de controle.
3. Instala o R e os pacotes necessários.
4. Roda a extração (`oci_sia_pe.R`). Na maior parte dos dias não há arquivo
   novo e ela termina em segundos.
5. Atualiza as dimensões (`dimensoes.R`).
6. Gera as tabelas do painel (`painel_ate.R`).
7. Se alguma tabela mudou, grava as mudanças no repositório (um *commit*),
   com a mensagem "Atualiza base OCI SIA-PA PE (data)".
8. Desliga o computador.

Se algo falhar, a execução aparece com um **X vermelho** na aba *Actions*, e o
GitHub costuma avisar por e-mail a conta que configurou o agendamento. A base publicada
continua a da última execução bem-sucedida. Ela nunca fica pela metade, porque
cada arquivo só é substituído depois de gravado por inteiro.

## 6. Como o Power BI lê

O Power BI lê os arquivos Parquet direto do endereço público do GitHub
(`raw.githubusercontent.com/...`). Como o repositório é público, não é preciso
senha (credencial **Anônimo**) nem gateway. A atualização agendada do Power BI
Service, depois das 12h30, busca a versão mais recente.

O GitHub guarda uma cópia do arquivo por cerca de 5 minutos. Por isso uma
mudança pode demorar alguns minutos para aparecer.

## 7. Onde conferir

| Quero saber… | Onde olhar |
|---|---|
| Se rodou hoje | Aba **Actions** do repositório (✓ verde ou ✗ vermelho) |
| Se entrou mês novo | Aba **Code > commits**: aparece "Atualiza base OCI…" |
| Quais meses já foram processados | `dados/controle/movimentos_processados.csv` |
| As tabelas | Pasta `dados/saida` (produção) e `dados/dimensoes` (nomes) |

## 8. Situações comuns

- **Reprocessar um mês:** na aba *Actions*, clique em *Run workflow* e preencha
  `--forcar=202603` (ano e mês do movimento).
- **Refazer tudo do zero:** use `--reprocessar-tudo`.
- **Dar nome curto a uma OCI nova:** acrescente uma linha em
  `referencias/nomes_oci.csv`. A execução seguinte já usa o nome novo.
- **O DATASUS ainda não publicou o mês:** é normal. O movimento costuma sair
  cerca de dois meses depois, e a automação o pega no dia em que ele aparecer.
