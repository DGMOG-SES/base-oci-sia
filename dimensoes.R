#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# Tabelas dimensão da base OCI para o Power BI
#
#   dim_procedimento   SIGTAP vigente (procedimento, grupo, subgrupo, forma de
#                      organização e valores)
#   dim_municipio      base territorial do DATASUS (município, região de saúde,
#                      macrorregião, coordenadas); serve para PA_GESTAO e PA_UFMUN
#   dim_estabelecimento API de dados abertos do CNES
#
# Cada dimensão contém todos os códigos presentes na base de produção. Códigos
# que a fonte não reconhece (ex.: estabelecimento desativado) entram com o nome
# marcado como "não encontrado", para nenhum registro sumir no relacionamento.
#
# Uso: Rscript dimensoes.R   (depois de oci_sia_pe.R)
# ------------------------------------------------------------------------------

source("oci_sia_pe.R")   # reaproveita CFG e utilitários (não executa a extração)

DIM <- list(
  ftp_sigtap      = "ftp://ftp2.datasus.gov.br/pub/sistemas/tup/downloads/",
  ftp_territorial = "ftp://ftp.datasus.gov.br/territorio/tabelas/",
  api_cnes        = "https://apidadosabertos.saude.gov.br/cnes/estabelecimentos/",
  cod_uf          = "26",
  dias_validade_cnes = 28   # depois disso, os dados do CNES são consultados de novo
)

dir_dim <- function() file.path(CFG$dir_dados, "dimensoes")

listar <- function(url) {
  res <- com_tentativas(function() curl_fetch_memory(url, handle = novo_handle()),
                        paste("listar", url))
  interpretar_listagem(strsplit(rawToChar(res$content), "\r?\n")[[1]])
}

baixar_para_tmp <- function(url) {
  destino <- tempfile(fileext = paste0(".", tools::file_ext(url)))
  com_tentativas(function() curl_download(url, destino, handle = novo_handle(), quiet = TRUE),
                 paste("baixar", basename(url)))
  destino
}

ler_ft <- function(arq) {
  fread(arq, colClasses = "character", encoding = "UTF-8", na.strings = "")
}

gravar_dimensao <- function(dt, nome) {
  dir.create(dir_dim(), recursive = TRUE, showWarnings = FALSE)
  base <- file.path(dir_dim(), nome)
  gravar_atomico(function(f) fwrite(dt, f, sep = ";", dec = ",", bom = TRUE), paste0(base, ".csv"))
  if (requireNamespace("arrow", quietly = TRUE)) {
    gravar_atomico(function(f) arrow::write_parquet(dt, f), paste0(base, ".parquet"))
  } else if (requireNamespace("nanoparquet", quietly = TRUE)) {
    gravar_atomico(function(f) nanoparquet::write_parquet(dt, f), paste0(base, ".parquet"))
  }
  log_msg("%s: %d linhas", nome, nrow(dt))
}

codigos_da_base <- function() {
  arqs <- list.files(file.path(CFG$dir_dados, "movimentos"), "^oci_.*\\.csv$", full.names = TRUE)
  base <- rbindlist(lapply(arqs, function(a) fread(a, colClasses = "character",
                                                   select = c("PA_GESTAO", "PA_UFMUN", "PA_CODUNI", "PA_PROC_ID"))))
  list(proc = sort(unique(base$PA_PROC_ID)),
       mun  = sort(unique(na.omit(c(base$PA_GESTAO, base$PA_UFMUN)))),
       cnes = sort(unique(base$PA_CODUNI)),
       mun_estab = unique(base[, .(PA_CODUNI, PA_UFMUN)]))
}

# ---- Procedimentos (SIGTAP) -----------------------------------------------------

# Lê um arquivo de largura fixa do SIGTAP usando o *_layout.txt que vem no zip.
ler_sigtap <- function(dir, tabela) {
  lay <- fread(file.path(dir, paste0(tabela, "_layout.txt")), colClasses = "character")
  linhas <- readLines(file.path(dir, paste0(tabela, ".txt")), encoding = "latin1", warn = FALSE)
  linhas <- enc2utf8(iconv(linhas, "latin1", "UTF-8"))
  dt <- as.data.table(setNames(lapply(seq_len(nrow(lay)), function(i) {
    trimws(substr(linhas, as.integer(lay$Inicio[i]), as.integer(lay$Fim[i])))
  }), lay$Coluna))
  dt
}

dim_procedimento <- function(codigos) {
  lst <- listar(DIM$ftp_sigtap)
  zips <- sort(grep("^TabelaUnificada_\\d{6}_v\\d+\\.zip$", lst$nome, value = TRUE))
  if (!length(zips)) stop("Nenhuma TabelaUnificada no FTP do SIGTAP")
  zip <- tail(zips, 1)
  log_msg("SIGTAP: %s", zip)

  dir <- tempfile(); dir.create(dir)
  unzip(baixar_para_tmp(paste0(DIM$ftp_sigtap, zip)), exdir = dir,
        files = paste0(rep(c("tb_procedimento", "tb_grupo", "tb_sub_grupo", "tb_forma_organizacao"), each = 2),
                       c(".txt", "_layout.txt")))

  proc  <- ler_sigtap(dir, "tb_procedimento")
  grupo <- ler_sigtap(dir, "tb_grupo")
  sub   <- ler_sigtap(dir, "tb_sub_grupo")
  forma <- ler_sigtap(dir, "tb_forma_organizacao")

  d <- data.table(CO_PROCEDIMENTO = codigos)
  d <- proc[, .(CO_PROCEDIMENTO, NO_PROCEDIMENTO,
                VL_SA = as.numeric(VL_SA) / 100, VL_SP = as.numeric(VL_SP) / 100)][d, on = "CO_PROCEDIMENTO"]
  d[, `:=`(CO_GRUPO = substr(CO_PROCEDIMENTO, 1, 2),
           CO_SUB_GRUPO = substr(CO_PROCEDIMENTO, 3, 4),
           CO_FORMA_ORGANIZACAO = substr(CO_PROCEDIMENTO, 5, 6))]
  d <- grupo[, .(CO_GRUPO, NO_GRUPO)][d, on = "CO_GRUPO"]
  d <- sub[, .(CO_GRUPO, CO_SUB_GRUPO, NO_SUB_GRUPO)][d, on = c("CO_GRUPO", "CO_SUB_GRUPO")]
  d <- forma[, .(CO_GRUPO, CO_SUB_GRUPO, CO_FORMA_ORGANIZACAO, NO_FORMA_ORGANIZACAO)][
    d, on = c("CO_GRUPO", "CO_SUB_GRUPO", "CO_FORMA_ORGANIZACAO")]
  d[is.na(NO_PROCEDIMENTO), NO_PROCEDIMENTO := paste(CO_PROCEDIMENTO, "(não encontrado no SIGTAP vigente)")]

  d[, `:=`(PA_PROC_ID = CO_PROCEDIMENTO,
           CO_SUB_GRUPO = paste0(CO_GRUPO, CO_SUB_GRUPO),
           CO_FORMA_ORGANIZACAO = paste0(CO_GRUPO, CO_SUB_GRUPO, CO_FORMA_ORGANIZACAO),
           COMPETENCIA_SIGTAP = sub("^TabelaUnificada_(\\d{6}).*", "\\1", zip))]
  d <- d[, .(PA_PROC_ID, NO_PROCEDIMENTO, CO_GRUPO, NO_GRUPO, CO_SUB_GRUPO, NO_SUB_GRUPO,
             CO_FORMA_ORGANIZACAO, NO_FORMA_ORGANIZACAO, VL_SA, VL_SP, COMPETENCIA_SIGTAP)]
  setorder(d, PA_PROC_ID)
  d
}

# ---- Municípios (base territorial) ------------------------------------------------

dim_municipio <- function(codigos) {
  anos <- listar(DIM$ftp_territorial)[grepl("^\\d{4}$", nome)]$nome
  zip <- NULL
  for (ano in sort(anos, decreasing = TRUE)) {
    z <- grep("base_territorial.*\\.zip$", listar(paste0(DIM$ftp_territorial, ano, "/"))$nome,
              value = TRUE, ignore.case = TRUE)
    if (length(z)) { zip <- paste0(ano, "/", tail(sort(z), 1)); break }
  }
  if (is.null(zip)) stop("Base territorial não encontrada")
  log_msg("Base territorial: %s", zip)

  dir <- tempfile(); dir.create(dir)
  unzip(baixar_para_tmp(paste0(DIM$ftp_territorial, zip)), exdir = dir)
  ler <- function(t) ler_ft(file.path(dir, paste0(t, ".csv")))

  mun <- ler("tb_municip")[, .(CO_MUNICIP, CO_MUNICDV, CO_STATUS, DS_NOME, UF, IN_CAPITAL,
                               NU_LATITUD = as.numeric(sub(",", ".", NU_LATITUD)),
                               NU_LONGIT  = as.numeric(sub(",", ".", NU_LONGIT)))]
  regsaud <- merge(ler("rl_municip_regsaud"), ler("tb_regsaud")[, .(CO_REGSAUD, NO_REGSAUD = DS_NOME)],
                   by = "CO_REGSAUD", all.x = TRUE)
  macsaud <- merge(ler("rl_municip_macsaud"), ler("tb_macsaud")[, .(CO_MACSAUD, NO_MACSAUD = DS_NOME)],
                   by = "CO_MACSAUD", all.x = TRUE)

  alvo <- unique(c(mun[startsWith(CO_MUNICIP, DIM$cod_uf) & CO_STATUS == "ATIVO"]$CO_MUNICIP, codigos))
  d <- data.table(CO_MUNICIP = alvo)
  d <- mun[d, on = "CO_MUNICIP"]
  d <- regsaud[, .(CO_MUNICIP, CO_REGSAUD, NO_REGSAUD)][d, on = "CO_MUNICIP", mult = "first"]
  d <- macsaud[, .(CO_MUNICIP, CO_MACSAUD, NO_MACSAUD)][d, on = "CO_MUNICIP", mult = "first"]

  # Código de gestor da Secretaria Estadual (UF + 0000).
  estadual <- paste0(DIM$cod_uf, "0000")
  d[CO_MUNICIP == estadual, `:=`(DS_NOME = paste("Gestão Estadual -", CFG$uf), UF = CFG$uf,
                                 CO_REGSAUD = NA, NO_REGSAUD = NA, CO_MACSAUD = NA, NO_MACSAUD = NA)]
  d[is.na(DS_NOME), DS_NOME := paste(CO_MUNICIP, "(não encontrado)")]

  # Nomes oficiais do IBGE, com acento (o DATASUS publica sem acento). Mesma
  # grafia do mapa de municípios do painel.
  ibge <- fread("referencias/municipios_pe_ibge.csv", colClasses = "character", encoding = "UTF-8")
  d[ibge, on = c(CO_MUNICIP = "CO_MUNICIPIO"), DS_NOME := i.MUNICIPIO]

  d <- d[, .(CO_MUNICIPIO = CO_MUNICIP, CO_MUNICIPIO_IBGE = CO_MUNICDV, MUNICIPIO = DS_NOME, UF,
             CO_REGIAO_SAUDE = CO_REGSAUD, REGIAO_SAUDE = NO_REGSAUD,
             CO_MACRORREGIAO = CO_MACSAUD, MACRORREGIAO = NO_MACSAUD,
             CAPITAL = IN_CAPITAL == "S", LATITUDE = NU_LATITUD, LONGITUDE = NU_LONGIT)]
  setorder(d, CO_MUNICIPIO)
  d
}

# ---- Estabelecimentos (API do CNES) -----------------------------------------------

consultar_cnes <- function(cnes) {
  url <- paste0(DIM$api_cnes, as.integer(cnes))
  res <- com_tentativas(function() {
    r <- curl_fetch_memory(url, handle = novo_handle())
    if (r$status_code >= 500) stop("HTTP ", r$status_code)
    r
  }, paste("consultar CNES", cnes))
  if (res$status_code != 200) return(NULL)
  j <- jsonlite::fromJSON(rawToChar(res$content))
  campo <- function(n) if (!is.null(j[[n]])) as.character(j[[n]]) else NA_character_
  data.table(
    CNES          = cnes,
    NOME_FANTASIA = campo("nome_fantasia"),
    RAZAO_SOCIAL  = campo("nome_razao_social"),
    CNPJ          = campo("numero_cnpj_entidade"),
    CO_MUNICIPIO_CNES = campo("codigo_municipio"),
    ESFERA_ADMINISTRATIVA = campo("descricao_esfera_administrativa"),
    TIPO_GESTAO   = campo("tipo_gestao"),
    CO_TIPO_UNIDADE = campo("codigo_tipo_unidade"),
    LATITUDE      = suppressWarnings(as.numeric(campo("latitude_estabelecimento_decimo_grau"))),
    LONGITUDE     = suppressWarnings(as.numeric(campo("longitude_estabelecimento_decimo_grau")))
  )
}

dim_estabelecimento <- function(codigos, mun_estab) {
  arq <- file.path(dir_dim(), "dim_estabelecimento.csv")
  atual <- if (file.exists(arq)) fread(arq, sep = ";", dec = ",", colClasses = "character", encoding = "UTF-8") else NULL

  if (!is.null(atual) && all(c("PA_CODUNI", "CONSULTADO_EM") %in% names(atual))) {
    setnames(atual, "PA_CODUNI", "CNES")
    sobra <- intersect(c("ESTABELECIMENTO", "CO_MUNICIPIO", "i.CO_MUNICIPIO"), names(atual))
    if (length(sobra)) atual[, (sobra) := NULL]
    validos <- atual[ENCONTRADO_NO_CNES == "TRUE" &
                       as.Date(CONSULTADO_EM) > Sys.Date() - DIM$dias_validade_cnes]
  } else {
    validos <- NULL
  }
  consultar <- setdiff(codigos, validos$CNES)
  log_msg("CNES: %d estabelecimentos, %d a consultar na API", length(codigos), length(consultar))

  novos <- rbindlist(lapply(consultar, function(cn) {
    Sys.sleep(0.2)
    r <- tryCatch(consultar_cnes(cn), error = function(e) {
      log_msg("Aviso: falha ao consultar CNES %s: %s", cn, conditionMessage(e)); NULL
    })
    if (is.null(r)) r <- data.table(CNES = cn, NOME_FANTASIA = NA_character_, RAZAO_SOCIAL = NA_character_)
    r
  }), fill = TRUE)

  if (nrow(novos)) {
    novos[, ENCONTRADO_NO_CNES := !is.na(NOME_FANTASIA) | !is.na(RAZAO_SOCIAL)]
    novos[, CONSULTADO_EM := as.character(Sys.Date())]
  }
  d <- rbindlist(list(validos, novos), fill = TRUE, use.names = TRUE)
  d[, ENCONTRADO_NO_CNES := as.logical(ENCONTRADO_NO_CNES)]
  for (col in intersect(c("LATITUDE", "LONGITUDE"), names(d))) {
    set(d, j = col, value = as.numeric(sub(",", ".", as.character(d[[col]]), fixed = TRUE)))
  }
  d <- d[CNES %in% codigos]

  # Município do estabelecimento segundo a própria produção (PA_UFMUN).
  m <- mun_estab[, .(CO_MUNICIPIO = PA_UFMUN[1]), by = .(CNES = PA_CODUNI)]
  sobra <- intersect(c("CO_MUNICIPIO", "i.CO_MUNICIPIO"), names(d))
  if (length(sobra)) d[, (sobra) := NULL]
  d <- m[d, on = "CNES"]

  d[, ESTABELECIMENTO := fifelse(!is.na(NOME_FANTASIA) & nzchar(NOME_FANTASIA), NOME_FANTASIA,
                          fifelse(!is.na(RAZAO_SOCIAL), RAZAO_SOCIAL,
                                  paste(CNES, "(não encontrado no CNES)")))]
  d[, PA_CODUNI := CNES]
  setcolorder(d, c("PA_CODUNI", "ESTABELECIMENTO"))
  d[, CNES := NULL]
  setorder(d, PA_CODUNI)
  d
}

# ---- Execução ---------------------------------------------------------------------

main_dimensoes <- function() {
  cod <- codigos_da_base()
  falhas <- character()
  passo <- function(nome, f) {
    ok <- tryCatch({ gravar_dimensao(f(), nome); TRUE },
                   error = function(e) { log_msg("ERRO em %s: %s", nome, conditionMessage(e)); FALSE })
    if (!ok) falhas <<- c(falhas, nome)
  }
  passo("dim_procedimento",    function() dim_procedimento(cod$proc))
  passo("dim_municipio",       function() dim_municipio(cod$mun))
  passo("dim_estabelecimento", function() dim_estabelecimento(cod$cnes, cod$mun_estab))
  if (length(falhas)) {
    log_msg("Dimensões com falha (mantida a versão anterior): %s", paste(falhas, collapse = ", "))
    quit(status = 1)
  }
  log_msg("Dimensões concluídas.")
}

if (sys.nframe() == 0L) main_dimensoes()
