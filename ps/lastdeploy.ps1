$web = Get-AcaSite '__SITE__'
$log = "$(Get-AcaBase $web (Get-AcaRoot $web)).aca-log.txt"
if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Select-Object -Last 1 }
