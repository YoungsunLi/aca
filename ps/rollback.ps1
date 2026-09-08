$backup = '__BACKUP__'
$web = Get-AcaSite '__SITE__'
$root = Get-AcaRoot $web
$manifest = Join-Path $backup 'aca-manifest.txt'
$lines = @(Get-Content -LiteralPath $manifest)
$added = @($lines | Select-Object -Skip 1)
$files = @(Get-ChildItem -LiteralPath $backup -Recurse -File | Where-Object { $_.FullName -ne $manifest })

try {
  Stop-AcaSite $web
  foreach ($f in $files) { Copy-AcaFile $f.FullName (Join-Path $root $f.FullName.Substring($backup.Length + 1)) }
  foreach ($rel in $added) {
    $p = Join-Path $root $rel
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
  }
} catch {
  Add-AcaLog $root "rollback $($lines[0]) failed | $($_.Exception.Message)"
  throw
} finally {
  $startErr = Start-AcaSite $web
}
if ($startErr) {
  Add-AcaLog $root "rollback $($lines[0]) files restored but start failed | $startErr"
  throw "Files restored, but $startErr"
}
# 回退到的那一版本来是否健康无从对照，首页状态只报告不判失败，只探一次给云助手 600 秒留余量
$after = Get-AcaHomeStatus $web 1
Add-AcaLog $root "rollback $($lines[0]) | restored $($files.Count) deleted $($added.Count) | home $(Format-AcaHome $after)"
# 备份用过即删，再次回退就会退到更早一次发布；删不掉只是下次会重复同样的恢复，不算失败
try { Remove-Item -LiteralPath $backup -Recurse -Force } catch { "WARN: backup directory not removed, the next rollback will repeat this one: $($_.Exception.Message)" }
"OK: $($web.name) rolled back deploy $($lines[0]): restored $($files.Count) files, deleted $($added.Count) added files, home $(Format-AcaHome $after)"
