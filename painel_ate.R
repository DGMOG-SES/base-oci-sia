#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# Tabelas prontas para o painel "Monitoramento ATE em Pernambuco"
#
#   monitoramento_ate  mesmo formato (nomes e conteúdo das colunas) da antiga
#                      planilha Monitoramento_ATE: produção por competência,
#                      município gestor (executor) e OCI. Assim o painel troca
#                      só a origem da consulta, sem remapear os visuais.
#   atualizacao        última competência da base e data da última atualização,
#                      para os textos dinâmicos do painel.
#
# Uso: Rscript painel_ate.R   (depois de oci_sia_pe.R e dimensoes.R)
# ------------------------------------------------------------------------------

source("oci_sia_pe.R")   # reaproveita CFG e utilitários (não executa a extração)

ler_csv_br <- function(arq, texto) {
  fread(arq, sep = ";", dec = ",", encoding = "UTF-8", colClasses = list(character = texto))
}

gravar_saida <- function(dt, nome) {
  base <- file.path(CFG$dir_dados, "saida", nome)
  gravar_atomico(function(f) fwrite(dt, f, sep = ";", dec = ",", bom = TRUE), paste0(base, ".csv"))
  if (requireNamespace("arrow", quietly = TRUE)) {
    gravar_atomico(function(f) arrow::write_parquet(dt, f), paste0(base, ".parquet"))
  } else if (requireNamespace("nanoparquet", quietly = TRUE)) {
    gravar_atomico(function(f) nanoparquet::write_parquet(dt, f), paste0(base, ".parquet"))
  }
  log_msg("%s: %d linhas", nome, nrow(dt))
}

# Algarismo romano da região de saúde ("X Região de Saúde - PE" -> "X").
romano_regiao <- function(x) {
  r <- sub("^\\s*([IVXL]+)\\s+Regi.*$", "\\1", x)
  fifelse(is.na(x) | r == x, "-", r)
}

# Especialidade a partir do subgrupo do SIGTAP, para OCI ainda sem nome curto.
especialidade_sigtap <- function(x) {
  e <- trimws(sub("^Atenção em ", "", x))
  fifelse(e == "Saúde Mulher", "Ginecologia", e)
}

# "OCI AVALIAÇÃO DE ESTRABISMO" -> "Avaliação de estrabismo"
nome_sigtap <- function(x) {
  x <- tolower(sub("^OCI\\s+", "", x))
  paste0(toupper(substr(x, 1, 1)), substr(x, 2, nchar(x)))
}

monitoramento_ate <- function() {
  dir_saida <- file.path(CFG$dir_dados, "saida")
  dir_dim   <- file.path(CFG$dir_dados, "dimensoes")
  base <- ler_csv_br(file.path(dir_saida, sprintf("oci_sia_%s.csv", tolower(CFG$uf))),
                     c("PA_CMP", "PA_MVM", "PA_GESTAO", "PA_CODUNI", "PA_UFMUN", "PA_PROC_ID"))
  proc <- ler_csv_br(file.path(dir_dim, "dim_procedimento.csv"), c("PA_PROC_ID", "CO_GRUPO", "CO_SUB_GRUPO"))
  mun  <- ler_csv_br(file.path(dir_dim, "dim_municipio.csv"), c("CO_MUNICIPIO", "CO_MUNICIPIO_IBGE"))
  nomes <- fread("referencias/nomes_oci.csv", colClasses = "character", encoding = "UTF-8")

  # Mesmo recorte da planilha: competência x município gestor x OCI.
  d <- base[, .(QTD_SOL = sum(PA_QTDPRO), QTD_APR = sum(PA_QTDAPR),
                VAL_SOL = sum(PA_VALPRO), VAL_APR = sum(PA_VALAPR)),
            by = .(PA_CMP, PA_GESTAO, PA_PROC_ID)]

  d <- mun[, .(PA_GESTAO = CO_MUNICIPIO, MUNICIPIO, REGIAO_SAUDE)][d, on = "PA_GESTAO"]
  d <- proc[, .(PA_PROC_ID, NO_PROCEDIMENTO, NO_SUB_GRUPO)][d, on = "PA_PROC_ID"]
  d <- nomes[d, on = "PA_PROC_ID"]

  estadual <- d$PA_GESTAO == paste0(substr(d$PA_GESTAO, 1, 2), "0000")
  d[, `:=`(
    EXECUTOR = fifelse(estadual, "Estado", MUNICIPIO),
    REGIAO = fifelse(estadual, "-", romano_regiao(REGIAO_SAUDE)),
    PROCEDIMENTO_OCI = fifelse(is.na(PROCEDIMENTO_OCI), nome_sigtap(NO_PROCEDIMENTO), PROCEDIMENTO_OCI),
    ESPECIALIDADE_OCI = fifelse(is.na(ESPECIALIDADE_OCI), especialidade_sigtap(NO_SUB_GRUPO), ESPECIALIDADE_OCI)
  )]

  # Nomes de colunas idênticos aos da planilha antiga.
  out <- d[, .(
    `PA_UFMUN,C,6`     = PA_GESTAO,
    `PA_CMP,C,6`       = PA_CMP,
    `PA_PROC_ID,C,10`  = PA_PROC_ID,
    `Referência`       = as.IDate(paste0(substr(PA_CMP, 1, 4), "-", substr(PA_CMP, 5, 6), "-01")),
    `Região de Saúde`  = REGIAO,
    `Cod. Município`   = PA_GESTAO,
    `Executor`         = EXECUTOR,
    `Cod. Especialidade` = PA_PROC_ID,
    `Especialidade OCI`  = ESPECIALIDADE_OCI,
    `Cod. OCI`         = sub("^0", "", substr(PA_PROC_ID, 1, 4)),
    `Procedimento OCI` = PROCEDIMENTO_OCI,
    `Valor Solicitado` = round(VAL_SOL, 2),
    `Qtd. Solicitada`  = as.integer(QTD_SOL),
    `Qtd. Aprovada`    = as.integer(QTD_APR),
    `Valor Aprovado`   = round(VAL_APR, 2),
    `Valor Unitário OCI` = round(fifelse(QTD_SOL > 0, VAL_SOL / QTD_SOL, NA_real_), 2)
  )]
  setorderv(out, c("Procedimento OCI", "PA_CMP,C,6", "Cod. Município"))
  out
}

atualizacao <- function() {
  base <- ler_csv_br(file.path(CFG$dir_dados, "saida", sprintf("oci_sia_%s.csv", tolower(CFG$uf))),
                     c("PA_CMP", "PA_MVM"))
  ctrl <- fread(file.path(CFG$dir_dados, "controle", "movimentos_processados.csv"), colClasses = "character")
  ultima <- max(as.POSIXct(ctrl$processado_em, tz = "UTC"))
  cmp <- max(base$PA_CMP)
  data.table(
    ULTIMA_COMPETENCIA = as.IDate(paste0(substr(cmp, 1, 4), "-", substr(cmp, 5, 6), "-01")),
    ULTIMO_MOVIMENTO   = max(base$PA_MVM),
    DATA_ATUALIZACAO   = as.IDate(format(ultima, tz = "America/Sao_Paulo", "%Y-%m-%d"))
  )
}

main_painel <- function() {
  gravar_saida(monitoramento_ate(), "monitoramento_ate")
  gravar_saida(atualizacao(), "atualizacao")
}

if (sys.nframe() == 0L) main_painel()
