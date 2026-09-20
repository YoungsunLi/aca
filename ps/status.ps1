$name = '__NAME__'
$dir = '__DIR__'
$web = if ($dir) { $null } else { Get-AcaSite $name }
$root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot $web }
if (-not $web) { "Service $name is $((Get-AcaService $name).Status)" }
# 有 bin 的是 .NET 站，看 bin 就够且快；静态站没有 bin。服务的程序集和它天天写的日志在同一个目录里，所以只看 dll、exe
$bin = Join-Path $root 'bin'
$scope = if ($web -and (Test-Path -LiteralPath $bin)) { $bin } else { $root }
$files = @(Get-ChildItem -LiteralPath $scope -Recurse -File)
if (-not $web) { $files = @($files | Where-Object { $_.Extension -match '^\.(dll|exe)$' }) }
$newest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newest) { "Newest file: $($newest.FullName.Substring($root.Length + 1))  $($newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" } else { "No files in $scope" }
$log = "$root.aca-log.txt"
if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Select-Object -Last 5 } else { 'No aca deploy log yet' }
