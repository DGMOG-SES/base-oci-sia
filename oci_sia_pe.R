#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# Base histórica de OCI (Ofertas de Cuidados Integrados) a partir do SIA-PA
#
# Baixa os arquivos mensais de Produção Ambulatorial (PA<UF><AAMM>.dbc) do FTP
# do DATASUS, mantém apenas procedimentos do grupo 09 (OCI), agrega e grava
# uma base consolidada em CSV e Parquet para o Power BI.
#
# A atualização é incremental: cada arquivo do FTP é identificado pelo nome,
# tamanho e data de modificação. Só são baixados os movimentos novos ou os que
# o DATASUS republicou (arquivo com tamanho/data diferente do já processado).
#
# Uso:
#   Rscript oci_sia_pe.R                       # atualização incremental
#   Rscript oci_sia_pe.R --inicio=2025-01      # muda a primeira competência
#   Rscript oci_sia_pe.R --forcar=202503,202504  # reprocessa movimentos
#   Rscript oci_sia_pe.R --reprocessar-tudo    # refaz a base inteira
# ------------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(data.table)
  library(curl)
})

# ---- Configuração -------------------------------------------------------------

CFG <- list(
  uf           = "PE",
  # Primeiro mês de movimento (processamento) a baixar, AAAA-MM. O grupo 09
  # passou a ser usado com o PMAE; meses sem OCI apenas geram partição vazia.
  inicio       = "2024-06",
  ftp_base     = "ftp://ftp.datasus.gov.br/dissemin/publicos/SIASUS/200801_/Dados/",
  extensao     = "dbc",
  prefixo_proc = "09",
  dir_dados    = Sys.getenv("OCI_DIR_DADOS", "dados"),
  manter_brutos = FALSE,     # TRUE guarda os .dbc baixados em dados/brutos
  agregar      = TRUE,       # FALSE grava os registros do SIA sem somar
  tentativas   = 4
)

# Chaves de agrupamento e medidas. No layout do SIA-PA:
#   PA_QTDPRO = quantidade produzida (apresentada)
#   PA_QTDAPR = quantidade aprovada
#   PA_VALPRO = valor produzido (apresentado)
#   PA_VALAPR = valor aprovado
CHAVES   <- c("PA_MVM", "PA_CMP", "PA_GESTAO", "PA_CODUNI", "PA_UFMUN", "PA_PROC_ID")
MEDIDAS  <- c("PA_QTDPRO", "PA_QTDAPR", "PA_VALPRO", "PA_VALAPR")
OBRIGATORIAS <- c("PA_CMP", "PA_GESTAO", "PA_CODUNI", "PA_PROC_ID", MEDIDAS)

# ---- Utilitários ---------------------------------------------------------------

log_msg <- function(...) {
  cat(format(Sys.time(), "[%Y-%m-%d %H:%M:%S] "), sprintf(...), "\n", sep = "")
}

ler_argumentos <- function(args = commandArgs(trailingOnly = TRUE)) {
  opc <- list(forcar = character(), reprocessar_tudo = FALSE)
  for (a in args) {
    if (startsWith(a, "--inicio=")) {
      CFG$inicio <<- sub("^--inicio=", "", a)
    } else if (startsWith(a, "--forcar=")) {
      opc$forcar <- strsplit(sub("^--forcar=", "", a), ",")[[1]]
    } else if (a == "--reprocessar-tudo") {
      opc$reprocessar_tudo <- TRUE
    } else {
      stop("Argumento desconhecido: ", a)
    }
  }
  if (!grepl("^\\d{4}-\\d{2}$", CFG$inicio)) stop("--inicio deve ser AAAA-MM")
  opc
}

# Grava em arquivo temporário e renomeia, para nunca deixar arquivo pela metade.
gravar_atomico <- function(escrever, destino) {
  tmp <- paste0(destino, ".tmp")
  escrever(tmp)
  if (file.exists(destino)) file.remove(destino)
  file.rename(tmp, destino)
}

com_tentativas <- function(f, descricao) {
  for (i in seq_len(CFG$tentativas)) {
    res <- tryCatch(f(), error = function(e) e)
    if (!inherits(res, "error")) return(res)
    log_msg("Falha em %s (tentativa %d/%d): %s",
            descricao, i, CFG$tentativas, conditionMessage(res))
    if (i < CFG$tentativas) Sys.sleep(2^i * 5)
  }
  stop("Desisti de ", descricao, " após ", CFG$tentativas, " tentativas")
}

novo_handle <- function() {
  new_handle(connecttimeout = 60, low_speed_limit = 1000, low_speed_time = 180,
             ftp_use_epsv = FALSE)
}

# ---- FTP -----------------------------------------------------------------------

# Interpreta a listagem do FTP. Aceita o formato MS-DOS (usado pelo DATASUS:
# "10-25-24  02:15PM  123456 PAPE2409.dbc") e o formato Unix ("-rw-r--r-- ...").
interpretar_listagem <- function(linhas) {
  linhas <- trimws(linhas[nzchar(trimws(linhas))])
  if (!length(linhas)) return(data.table(nome = character(), tamanho = numeric(), data = character()))
  partes <- strsplit(linhas, "\\s+")
  rbindlist(lapply(partes, function(p) {
    if (grepl("^\\d{2}-\\d{2}-\\d{2,4}$", p[1]) && length(p) >= 4) {
      data.table(nome = paste(p[4:length(p)], collapse = " "),
                 tamanho = suppressWarnings(as.numeric(p[3])),
                 data = paste(p[1], p[2]))
    } else if (length(p) >= 9) {
      data.table(nome = paste(p[9:length(p)], collapse = " "),
                 tamanho = suppressWarnings(as.numeric(p[5])),
                 data = paste(p[6], p[7], p[8]))
    } else {
      NULL
    }
  }))
}

listar_arquivos_uf <- function() {
  log_msg("Listando %s", CFG$ftp_base)
  res <- com_tentativas(function() curl_fetch_memory(CFG$ftp_base, handle = novo_handle()),
                        "listar o FTP")
  lst <- interpretar_listagem(strsplit(rawToChar(res$content), "\r?\n")[[1]])

  padrao <- sprintf("^PA%s(\\d{2})(\\d{2})([a-z]?)\\.%s$", CFG$uf, CFG$extensao)
  lst <- lst[grepl(padrao, nome, ignore.case = TRUE)]
  lst[, mvm := sub(padrao, "20\\1\\2", nome, ignore.case = TRUE)]
  lst <- lst[mvm >= sub("-", "", CFG$inicio)]
  setorder(lst, mvm, nome)
  lst[, assinatura := paste(nome, tamanho, data, sep = "|")]
  lst
}

baixar <- function(nome, destino) {
  url <- paste0(CFG$ftp_base, nome)
  com_tentativas(function() {
    curl_download(url, destino, handle = novo_handle(), quiet = TRUE)
  }, paste("baixar", nome))
  destino
}

# ---- Leitura e tratamento -------------------------------------------------------

ler_arquivo <- function(caminho) {
  if (grepl("\\.dbc$", caminho, ignore.case = TRUE)) {
    if (requireNamespace("read.dbc", quietly = TRUE)) {
      df <- read.dbc::read.dbc(caminho, as.is = TRUE)
    } else {
      # Alternativa: descompacta com o pyreaddbc (pip install pyreaddbc).
      dbf <- sub("\\.dbc$", ".dbf", caminho, ignore.case = TRUE)
      on.exit(unlink(dbf))
      status <- system2("python3", c("-c", shQuote(sprintf(
        "from pyreaddbc import dbc2dbf; dbc2dbf('%s', '%s')", caminho, dbf))))
      if (status != 0 || !file.exists(dbf)) {
        stop("Não foi possível ler .dbc: instale read.dbc (instalar_pacotes.R) ou pyreaddbc")
      }
      df <- foreign::read.dbf(dbf, as.is = TRUE)
    }
  } else {
    df <- foreign::read.dbf(caminho, as.is = TRUE)
  }
  setDT(df)
}

filtrar_oci <- function(dt, mvm_arquivo) {
  faltando <- setdiff(OBRIGATORIAS, names(dt))
  if (length(faltando)) stop("Colunas ausentes no arquivo: ", paste(faltando, collapse = ", "))

  dt <- dt[startsWith(trimws(PA_PROC_ID), CFG$prefixo_proc)]
  if (!"PA_MVM" %in% names(dt)) dt[, PA_MVM := mvm_arquivo]
  if (!"PA_UFMUN" %in% names(dt)) dt[, PA_UFMUN := NA_character_]

  dt <- dt[, c(CHAVES, MEDIDAS), with = FALSE]
  for (col in CHAVES)  set(dt, j = col, value = trimws(as.character(dt[[col]])))
  for (col in MEDIDAS) set(dt, j = col, value = as.numeric(dt[[col]]))
  dt
}

processar_movimento <- function(mvm, arquivos) {
  dir_brutos <- file.path(CFG$dir_dados, "brutos")
  dir.create(dir_brutos, recursive = TRUE, showWarnings = FALSE)

  partes <- lapply(arquivos$nome, function(nome) {
    destino <- baixar(nome, file.path(dir_brutos, nome))
    on.exit(if (!CFG$manter_brutos) unlink(destino))
    log_msg("  lendo %s (%.1f MB)", nome, file.size(destino) / 1e6)
    bruto <- ler_arquivo(destino)
    n_total <- nrow(bruto)
    oci <- filtrar_oci(bruto, mvm)
    rm(bruto); gc(verbose = FALSE)
    log_msg("  %s: %s registros, %s de OCI", nome,
            format(n_total, big.mark = ".", decimal.mark = ","), format(nrow(oci), big.mark = ".", decimal.mark = ","))
    oci
  })
  dt <- rbindlist(partes, use.names = TRUE)

  if (CFG$agregar) {
    dt <- dt[, c(lapply(.SD, sum, na.rm = TRUE), list(N_REGISTROS = .N)),
             by = CHAVES, .SDcols = MEDIDAS]
  }
  setorderv(dt, CHAVES)
  dt
}

# ---- Base local ------------------------------------------------------------------

caminho_particao <- function(mvm) {
  file.path(CFG$dir_dados, "movimentos", sprintf("oci_%s_%s.csv", CFG$uf, mvm))
}

caminho_controle <- function() file.path(CFG$dir_dados, "controle", "movimentos_processados.csv")

ler_controle <- function() {
  arq <- caminho_controle()
  if (!file.exists(arq)) {
    return(data.table(mvm = character(), assinatura = character(), linhas = integer(),
                      processado_em = character()))
  }
  fread(arq, colClasses = "character")[, linhas := as.integer(linhas)][]
}

gravar_controle <- function(ctrl) {
  dir.create(dirname(caminho_controle()), recursive = TRUE, showWarnings = FALSE)
  setorder(ctrl, mvm)
  gravar_atomico(function(f) fwrite(ctrl, f), caminho_controle())
}

ler_particao <- function(arq) {
  fread(arq, colClasses = list(character = CHAVES))
}

consolidar <- function() {
  arqs <- sort(list.files(file.path(CFG$dir_dados, "movimentos"),
                          pattern = "^oci_.*\\.csv$", full.names = TRUE))
  base <- rbindlist(lapply(arqs, ler_particao), use.names = TRUE, fill = TRUE)
  if (!nrow(base)) {
    log_msg("Nenhum registro de OCI na base ainda.")
    return(invisible(base))
  }

  base[, COMPETENCIA := as.IDate(paste0(substr(PA_CMP, 1, 4), "-", substr(PA_CMP, 5, 6), "-01"))]
  base[, MOVIMENTO   := as.IDate(paste0(substr(PA_MVM, 1, 4), "-", substr(PA_MVM, 5, 6), "-01"))]
  setcolorder(base, c("COMPETENCIA", "MOVIMENTO"))
  setorderv(base, c("PA_CMP", "PA_MVM", "PA_GESTAO", "PA_CODUNI", "PA_PROC_ID"))

  dir_saida <- file.path(CFG$dir_dados, "saida")
  dir.create(dir_saida, recursive = TRUE, showWarnings = FALSE)
  nome <- file.path(dir_saida, sprintf("oci_sia_%s", tolower(CFG$uf)))

  # CSV no padrão brasileiro (; e vírgula decimal, UTF-8 com BOM).
  gravar_atomico(function(f) fwrite(base, f, sep = ";", dec = ",", bom = TRUE),
                 paste0(nome, ".csv"))

  if (requireNamespace("arrow", quietly = TRUE)) {
    gravar_atomico(function(f) arrow::write_parquet(base, f), paste0(nome, ".parquet"))
  } else if (requireNamespace("nanoparquet", quietly = TRUE)) {
    gravar_atomico(function(f) nanoparquet::write_parquet(base, f), paste0(nome, ".parquet"))
  } else {
    log_msg("Aviso: arrow/nanoparquet não instalados; Parquet não foi gerado.")
  }

  log_msg("Base consolidada: %s linhas, competências %s a %s, %s",
          format(nrow(base), big.mark = ".", decimal.mark = ","), min(base$PA_CMP), max(base$PA_CMP), nome)
  invisible(base)
}

# ---- Execução --------------------------------------------------------------------

main <- function() {
  opc <- ler_argumentos()
  dir.create(file.path(CFG$dir_dados, "movimentos"), recursive = TRUE, showWarnings = FALSE)

  ftp <- listar_arquivos_uf()
  if (!nrow(ftp)) stop("Nenhum arquivo PA", CFG$uf, " encontrado a partir de ", CFG$inicio)

  movimentos <- ftp[, .(assinatura = paste(assinatura, collapse = ";")), by = mvm]
  ctrl <- ler_controle()

  pendentes <- movimentos[!ctrl, on = .(mvm, assinatura)]$mvm
  if (opc$reprocessar_tudo) pendentes <- movimentos$mvm
  pendentes <- sort(unique(c(pendentes, intersect(opc$forcar, movimentos$mvm))))

  log_msg("%d movimentos no FTP desde %s; %d a processar%s", nrow(movimentos), CFG$inicio,
          length(pendentes), if (length(pendentes)) paste0(": ", paste(pendentes, collapse = ", ")) else "")

  falhas <- character()
  for (m in pendentes) {
    log_msg("Movimento %s", m)
    ok <- tryCatch({
      dt <- processar_movimento(m, ftp[mvm == m])
      gravar_atomico(function(f) fwrite(dt, f), caminho_particao(m))
      ctrl <- rbind(ctrl[mvm != m],
                    data.table(mvm = m, assinatura = movimentos[mvm == m, assinatura],
                               linhas = nrow(dt), processado_em = format(Sys.time(), "%Y-%m-%d %H:%M:%S")))
      gravar_controle(ctrl)
      TRUE
    }, error = function(e) {
      log_msg("ERRO no movimento %s: %s", m, conditionMessage(e))
      FALSE
    })
    if (!ok) falhas <- c(falhas, m)
  }

  consolidar()

  if (length(falhas)) {
    log_msg("Movimentos com falha (serão tentados na próxima execução): %s",
            paste(falhas, collapse = ", "))
    quit(status = 1)
  }
  log_msg("Concluído.")
}

if (sys.nframe() == 0L) main()
