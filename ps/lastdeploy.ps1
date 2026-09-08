$root = Get-AcaRoot (Get-AcaSite '__SITE__')
$log = "$root.aca-log.txt"
if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Select-Object -Last 1 }
