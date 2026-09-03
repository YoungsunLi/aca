# 每行：备份目录|发布 ID|可恢复文件数|新增文件数；没有清单的旧备份不列
$web = Get-AcaSite '__SITE__'
$root = Get-AcaRoot $web
Get-ChildItem -LiteralPath (Split-Path $root) -Directory -Filter ((Split-Path $root -Leaf) + '.bak-*') | ForEach-Object {
  $manifest = Join-Path $_.FullName 'aca-manifest.txt'
  if (Test-Path -LiteralPath $manifest) {
    $lines = @(Get-Content -LiteralPath $manifest)
    $_.FullName + '|' + $lines[0] + '|' + (@(Get-ChildItem -LiteralPath $_.FullName -Recurse -File).Count - 1) + '|' + ($lines.Count - 1)
  }
}
