# Guia: ligar o painel "Monitoramento ATE em Pernambuco" à base automática

O painel deixa de ler a planilha do Google mantida à mão. Ele passa a ler as
tabelas que o GitHub atualiza sozinho todo dia, no repositório
`DGMOG-SES/base-oci-sia`.

A tabela `monitoramento_ate` foi gerada **com os mesmos nomes de coluna da
planilha antiga**. Por isso basta trocar a origem das consultas. Os visuais e
as medidas continuam funcionando sem remapear campo por campo.

**A coluna `Referência` é o mês de processamento (movimento, `PA_MVM`)**, ou
seja, o mês em que a produção foi processada e paga. Na planilha antiga ela era
o mês do atendimento (competência). O mês do atendimento continua disponível na
coluna nova `Competência`. A conferência feita com a planilha, por competência,
bateu nas 2.206 linhas em executor, região, especialidade, OCI e quantidades.
Os totais por movimento batem com a base completa.

Um mês de movimento já publicado não muda mais. Já um mês de competência
continua crescendo quando chegam reapresentações.

> Antes de começar, salve uma cópia do `.pbix`.

---

## 1. Trocar a origem de `Monitoramento_ATE`

1. *Página Inicial > Transformar dados*.
2. Selecione a consulta **Monitoramento_ATE** e abra *Editor Avançado*.
3. Apague tudo e cole:

```powerquery
let
    Fonte = Parquet.Document(Binary.Buffer(Web.Contents(
        "https://raw.githubusercontent.com/DGMOG-SES/base-oci-sia/main/dados/saida/monitoramento_ate.parquet"))),
    Tipos = Table.TransformColumnTypes(Fonte, {
        {"Referência", type date}, {"Competência", type date},
        {"Valor Solicitado", Currency.Type}, {"Valor Aprovado", Currency.Type},
        {"Valor Unitário OCI", Currency.Type},
        {"Qtd. Solicitada", Int64.Type}, {"Qtd. Aprovada", Int64.Type}})
in
    Tipos
```

4. Se o Power BI pedir credencial, escolha **Anônimo**.

## 2. Trocar a origem de `Data_Atualização`

Hoje essa tabela guarda a hora em que o painel foi atualizado. Com a nova
origem, ela passa a guardar **a data e a hora (de Brasília) em que a base
recebeu dados novos do DATASUS** e
**o último mês processado (movimento)**. O nome da tabela e a coluna `Column1`
continuam iguais, então os cartões de data atuais seguem funcionando.

Selecione **Data_Atualização**, abra o *Editor Avançado* e cole:

```powerquery
let
    Fonte = Parquet.Document(Binary.Buffer(Web.Contents(
        "https://raw.githubusercontent.com/DGMOG-SES/base-oci-sia/main/dados/saida/atualizacao.parquet"))),
    // TEXTO_ATUALIZACAO já vem pronto, no horário de Brasília: "15/10/2026 às 12:20 hrs".
    // Se o arquivo vier de um cache antigo, sem a coluna nova, mostra só a data.
    Column1 = Table.AddColumn(Fonte, "Column1",
        each try [TEXTO_ATUALIZACAO]
             otherwise Date.ToText(Date.From([DATA_ATUALIZACAO]), [Format = "dd/MM/yyyy"]),
        type text)
in
    Column1
```

Clique em *Fechar e Aplicar*.

A consulta **Pactuação ABR/2025** não muda. A pactuação não vem do SIA e
continua na planilha.

## 3. Criar a dimensão calendário

1. *Modelagem > Nova tabela* e cole:

```dax
dCalendario =
VAR _fim = MAX ( Monitoramento_ATE[Referência] )
RETURN
    ADDCOLUMNS (
        CALENDAR ( DATE ( 2025, 1, 1 ), EOMONTH ( _fim, 0 ) ),
        "Ano", YEAR ( [Date] ),
        "Mês Nº", MONTH ( [Date] ),
        "Mês", SWITCH ( MONTH ( [Date] ),
            1, "Janeiro", 2, "Fevereiro", 3, "Março", 4, "Abril",
            5, "Maio", 6, "Junho", 7, "Julho", 8, "Agosto",
            9, "Setembro", 10, "Outubro", 11, "Novembro", 12, "Dezembro" ),
        "Mês/Ano", SWITCH ( MONTH ( [Date] ),
            1, "Jan.", 2, "Fev.", 3, "Mar.", 4, "Abr.", 5, "Mai.", 6, "Jun.",
            7, "Jul.", 8, "Ago.", 9, "Set.", 10, "Out.", 11, "Nov.", 12, "Dez." )
            & "/" & YEAR ( [Date] ),
        "AnoMês", YEAR ( [Date] ) * 100 + MONTH ( [Date] )
    )
```

2. Na tabela nova, faça três ajustes:
   - Selecione a coluna **Mês** e use *Classificar por coluna > Mês Nº*.
   - Selecione **Mês/Ano** e use *Classificar por coluna > AnoMês*.
   - Clique com o botão direito na tabela e use *Marcar como tabela de datas*, escolhendo a coluna `Date`.
3. Em *Exibição de modelo*, arraste `dCalendario[Date]` até
   `Monitoramento_ATE[Referência]`. O relacionamento fica de 1 para muitos,
   com filtro em direção única.
4. **Troque os campos das segmentações de data.** Hoje elas usam a hierarquia
   automática de `Referência`. São as segmentações "Mês/Ano de Referência" das
   abas *Monitoramento da Execução* e *Panorama de Execução*.
   - Em cada uma, substitua **Ano** por `dCalendario[Ano]`.
   - Substitua **Mês** por `dCalendario[Mês]`.
5. Desligue a data automática em *Arquivo > Opções e configurações >
   Opções > Arquivo atual > Carregamento de dados*, desmarcando
   **Data/hora automática**. Isso remove as tabelas `LocalDateTable` ocultas.
   Faça isso só depois do passo 4, senão as segmentações ficam sem campo.

## 4. Medidas para o texto dinâmico

Na tabela **Medidas**, crie as três medidas abaixo com *Nova medida*.

```dax
Mês Processado =
VAR d =
    CALCULATE ( MAX ( Monitoramento_ATE[Referência] ), REMOVEFILTERS () )
RETURN
    SWITCH ( MONTH ( d ),
        1, "Jan.", 2, "Fev.", 3, "Mar.", 4, "Abr.", 5, "Mai.", 6, "Jun.",
        7, "Jul.", 8, "Ago.", 9, "Set.", 10, "Out.", 11, "Nov.", 12, "Dez." )
        & "/" & YEAR ( d )
```

```dax
Data Última Atualização =
MAX ( 'Data_Atualização'[Column1] )
```

```dax
Texto Atualização =
"Dados processados até " & [Mês Processado]
    & ". Última atualização: " & [Data Última Atualização]
```

`Mês Processado` usa o último mês de `Referência` (movimento) da base inteira,
ignorando os filtros (`REMOVEFILTERS`). `Data_Atualização` não tem
relacionamento com nenhuma tabela. Por isso nenhuma das duas medidas muda
quando alguém mexe nas segmentações.

## 5. Trocar o texto fixo pelo valor dinâmico

Faça isto nas três abas. Na *Panorama Geral* o texto atual diz "Fev./2026".

1. Clique duas vezes na caixa de texto do rodapé, que começa com
   "\*FONTE: Ministério da Saúde…".
2. Apague o trecho **"Jun./2026"** e deixe "Dados processados até ".
3. Com o cursor no lugar do trecho apagado, clique em **+ Valor**. Em
   "Como você gostaria de calcular este valor?", digite `Mês Processado` e
   escolha a medida.
4. Faça o mesmo no fim do texto, depois de "Última atualização: ", com a
   medida **Data Última Atualização**.
5. Apague o cartão pequeno com a data que fica ao lado da caixa de texto.
   Ele usa `Data_Atualização[Column1]` e agora é redundante. Se preferir
   manter o cartão, ele continua funcionando e mostra a mesma data.

Se for mais simples, apague o texto inteiro do trecho e use um único
**+ Valor** com a medida `Texto Atualização`.

## 6. Ajuste em uma medida existente

Na planilha antiga, a coluna "Valor Solicitado" guardava o **valor unitário
da OCI** (200, 88,40…), e não o total. Com isso, o cartão "Valor Solicitada"
somava preços unitários. Na base nova, "Valor Solicitado" é o **valor
apresentado total** (`PA_VALPRO`), que é o que o nome indica. O valor
unitário continua disponível na coluna nova "Valor Unitário OCI".

A medida de reprovado estava com a subtração invertida. Corrija para:

```dax
Valor Reprovado, =
COALESCE (
    SUM ( Monitoramento_ATE[Valor Solicitado] ) - SUM ( Monitoramento_ATE[Valor Aprovado] ),
    0
)
```

## 7. Publicar e agendar

1. Publique no workspace de sempre.
2. No Power BI Service, abra o modelo semântico e vá em *Configurações >
   Credenciais da fonte de dados*. Para as fontes `raw.githubusercontent.com`,
   escolha **Anônimo**, com nível de privacidade **Público**. Não é preciso
   gateway.
3. Agende a atualização para **depois das 12h30**. O GitHub confere o
   DATASUS às 7h17 e às 12h17.

---

## Diferenças em relação à planilha

- **Referência:** passa a ser o mês de processamento (movimento), e não o mês
  do atendimento. Os números por mês mudam em relação à planilha, mas o total
  geral é o mesmo. Há mais linhas (2.333), porque o mesmo atendimento pode ter
  sido processado em movimentos diferentes.

- **Valor aprovado:** em 3 das 2.206 linhas, todas de Jaboatão dos Guararapes
  (OCI de ginecologia e de câncer colorretal, 12/2025 e 01/2026), a planilha
  calculava quantidade × valor unitário. A base traz o valor aprovado
  registrado no SIA, que é maior nesses casos.
- **`PA_PROC_ID`:** passa a ter os 10 dígitos, com o zero inicial
  (`0902010026`).
- **Nomes das OCI:** vêm de `referencias/nomes_oci.csv`, com os mesmos nomes
  curtos da planilha. Uma OCI nova que ainda não esteja nesse arquivo aparece
  com o nome do SIGTAP. Para dar um nome curto, basta acrescentar uma linha no
  arquivo.
- **Executor:** é o município gestor (`PA_GESTAO`), e o código `260000`
  aparece como "Estado", igual à planilha. Os nomes seguem o IBGE, com a mesma
  grafia do mapa do painel.
