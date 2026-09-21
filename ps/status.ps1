$name = '__NAME__'
$dir = '__DIR__'
$web = if ($dir) { $null } else { Get-AcaSite $name }
$root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot $web }
if (-not $web) { "Service $name is $((Get-AcaService $name).Status)" }
$newest = Get-AcaNewestFile $web $root
if ($newest) { "Newest file: $($newest.FullName.Substring($root.Length + 1))  $($newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" } else { 'No files found' }
$log = "$root.aca-log.txt"
if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Select-Object -Last 5 } else { 'No aca deploy log yet' }
