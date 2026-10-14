# Cria uma tarefa no Agendador do Windows que roda a atualização todo dia às 7h.
# Execute no PowerShell a partir da pasta do projeto:  .\agendar_windows.ps1
$pasta   = $PSScriptRoot
$rscript = (Get-ChildItem "C:\Program Files\R\*\bin\Rscript.exe" | Sort-Object FullName | Select-Object -Last 1).FullName
if (-not $rscript) { throw "Rscript.exe não encontrado em C:\Program Files\R" }

$acao    = New-ScheduledTaskAction -Execute "cmd.exe" `
             -Argument "/c `"`"$rscript`" oci_sia_pe.R >> atualizacao.log 2>&1`"" `
             -WorkingDirectory $pasta
$gatilho = New-ScheduledTaskTrigger -Daily -At 7:00
$config  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 5)

Register-ScheduledTask -TaskName "Base OCI SIA-PA PE" -Action $acao -Trigger $gatilho `
  -Settings $config -Description "Atualiza a base de OCI do SIA-PA (DATASUS)" -Force
Write-Host "Tarefa criada. Log em $pasta\atualizacao.log"
