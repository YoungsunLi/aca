# 从新到旧每行：发布 ID|可恢复文件数|新增文件数|占用字节数|那次发布的记录；清理过旧备份的再加一行 pruned|清理到的发布 ID
$name = '__NAME__'
$dir = '__DIR__'
$root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot (Get-AcaSite $name) }
$log = if (Test-Path -LiteralPath "$root.aca-log.txt") { @(Get-Content -LiteralPath "$root.aca-log.txt") } else { @() }
$ids = @()
# 回退靠这份列表，输出超过云助手的上限就退不了；记录只是给人看的，给它一个额度，备份太多时较旧的不带
$room = 12KB
Get-AcaBackups $root | Sort-Object Name -Descending | ForEach-Object {
  $lines = @(Get-Content -LiteralPath (Join-Path $_.FullName 'aca-manifest.txt'))
  $ids += $lines[0]
  $files = @(Get-ChildItem -LiteralPath $_.FullName -Recurse -File)
  # 锚定行首：-m 里写一段 | deploy <别的发布 ID> | 也配不到那次发布头上
  $entry = $log | Where-Object { $_ -match ('^[\d-]+ [\d:]+ \| deploy ' + [regex]::Escape($lines[0]) + ' ') } | Select-Object -Last 1
  $room -= [Text.Encoding]::Default.GetByteCount("$entry")
  if ($room -lt 0) { $entry = '' }
  $lines[0] + '|' + ($files.Count - 1) + '|' + ($lines.Count - 1) + '|' + ($files | Measure-Object Length -Sum).Sum + '|' + $entry
}
# 清理是先记录再改名，改名失败的备份还在，不算清理掉了
if (Test-Path -LiteralPath "$root.aca-pruned") { 'pruned|' + (Get-Content -LiteralPath "$root.aca-pruned" | Where-Object { $_ -and $ids -notcontains $_ } | Sort-Object | Select-Object -Last 1) }
