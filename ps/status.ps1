$web = Get-AcaSite '__SITE__'
$root = Get-AcaRoot $web
# 有 bin 的是 .NET 站，看 bin 就够且快；静态站没有 bin，只能看整个目录
$bin = Join-Path $root 'bin'
$scope = if (Test-Path -LiteralPath $bin) { $bin } else { $root }
$newest = Get-ChildItem -LiteralPath $scope -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newest) { "Newest file: $($newest.FullName.Substring($root.Length + 1))  $($newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" } else { 'Site directory is empty' }
$log = "$root.aca-log.txt"
if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Select-Object -Last 5 } else { 'No aca deploy log yet' }
