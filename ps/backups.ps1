# 每行：备份目录|发布 ID|可恢复文件数|新增文件数；清理过旧备份的再加一行 pruned|清理到的发布 ID
$name = '__NAME__'
$dir = '__DIR__'
$root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot (Get-AcaSite $name) }
Get-AcaBackups $root | ForEach-Object {
  $lines = @(Get-Content -LiteralPath (Join-Path $_.FullName 'aca-manifest.txt'))
  $_.FullName + '|' + $lines[0] + '|' + (@(Get-ChildItem -LiteralPath $_.FullName -Recurse -File).Count - 1) + '|' + ($lines.Count - 1)
}
if (Test-Path -LiteralPath "$root.aca-pruned") { 'pruned|' + (Get-Content -LiteralPath "$root.aca-pruned" | Where-Object { $_ } | Sort-Object | Select-Object -Last 1) }
