# Instala os pacotes usados por oci_sia_pe.R
repos <- "https://cloud.r-project.org"
for (p in c("data.table", "curl", "arrow")) {
  if (!requireNamespace(p, quietly = TRUE)) install.packages(p, repos = repos)
}

# read.dbc descompacta os .dbc do DATASUS. Tenta o CRAN e, se não estiver
# disponível para esta versão do R, instala do GitHub.
if (!requireNamespace("read.dbc", quietly = TRUE)) {
  tryCatch(install.packages("read.dbc", repos = repos), warning = function(w) NULL)
}
if (!requireNamespace("read.dbc", quietly = TRUE)) {
  if (!requireNamespace("remotes", quietly = TRUE)) install.packages("remotes", repos = repos)
  remotes::install_github("danicat/read.dbc")
}

# arrow é opcional (gera o Parquet). Se a instalação falhar, nanoparquet é
# uma alternativa leve.
if (!requireNamespace("arrow", quietly = TRUE)) install.packages("nanoparquet", repos = repos)

invisible(lapply(c("data.table", "curl", "read.dbc"), library, character.only = TRUE))
message("Pacotes OK")
