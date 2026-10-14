# Instala os pacotes usados por oci_sia_pe.R

# Usa o repositório já configurado (no GitHub Actions, binários pré-compilados
# do Posit Package Manager); senão, o CRAN.
repos <- getOption("repos")
if (is.null(repos) || identical(unname(repos["CRAN"]), "@CRAN@")) repos <- "https://cloud.r-project.org"

for (p in c("data.table", "curl", "arrow")) {
  if (!requireNamespace(p, quietly = TRUE)) install.packages(p, repos = repos)
}

# read.dbc descompacta os .dbc do DATASUS. Ele entra e sai do CRAN, então
# tenta o CRAN, depois versões arquivadas e por fim o GitHub. Se nada der
# certo, oci_sia_pe.R usa o pyreaddbc (Python) como alternativa.
instalado <- function() requireNamespace("read.dbc", quietly = TRUE)
tentar <- function(expr) tryCatch(expr, error = function(e) NULL, warning = function(w) NULL)

if (!instalado()) tentar(install.packages("read.dbc", repos = repos))
for (v in c("1.0.7", "1.0.6", "1.0.5")) {
  if (instalado()) break
  tentar(install.packages(
    sprintf("https://cloud.r-project.org/src/contrib/Archive/read.dbc/read.dbc_%s.tar.gz", v),
    repos = NULL, type = "source"))
}
if (!instalado()) {
  if (!requireNamespace("remotes", quietly = TRUE)) install.packages("remotes", repos = repos)
  tentar(remotes::install_github("danicat/read.dbc", upgrade = "never"))
}

if (!requireNamespace("arrow", quietly = TRUE)) install.packages("nanoparquet", repos = repos)

invisible(lapply(c("data.table", "curl"), library, character.only = TRUE))
message("Pacotes OK. read.dbc: ", if (instalado()) "instalado" else "indisponível (será usado o pyreaddbc)")
