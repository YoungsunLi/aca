$backup = '__BACKUP__'
$name = '__NAME__'
$dir = '__DIR__'
$web = if ($dir) { $null } else { Get-AcaSite $name }
$root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot $web }
$label = if ($web) { 'home' } else { 'service' }

$lock = Lock-Aca $root
try {
  # 计划和执行之间可能又发布过一次，那样该退的是更新的那份备份
  $newest = Get-AcaBackups $root | Select-Object -Last 1
  if ($newest.FullName -ne $backup) { throw "$name was deployed again after this rollback was planned (newest backup: $($newest.FullName)); run rollback again" }
  $manifest = Join-Path $backup 'aca-manifest.txt'
  $lines = @(Get-Content -LiteralPath $manifest)
  $added = @($lines | Select-Object -Skip 1)
  $files = @(Get-ChildItem -LiteralPath $backup -Recurse -File | Where-Object { $_.FullName -ne $manifest })
  # 回退前就停着的服务，回退后也不启动，同发布
  $wasRunning = $web -or (Test-AcaServiceRunning ([string](Get-AcaService $name).Status) $name)
  try {
    Stop-AcaTarget $web $name
    foreach ($f in $files) { Copy-AcaFile $f.FullName (Join-Path $root $f.FullName.Substring($backup.Length + 1)) }
    foreach ($rel in $added) {
      $p = Join-Path $root $rel
      if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
  } catch {
    Add-AcaLog $root "rollback $($lines[0]) failed | $($_.Exception.Message)"
    throw
  } finally {
    $startErr = if ($wasRunning) { Start-AcaTarget $web $name } else { '' }
  }
  if ($startErr) {
    Add-AcaLog $root "rollback $($lines[0]) files restored but start failed | $startErr"
    throw "Files restored, but $startErr"
  }
  # 回退到的那一版本来是否健康无从对照，状态只报告不判失败，少探几次给云助手 600 秒留余量
  $after = Get-AcaHealth $web $name 2
  Add-AcaLog $root "rollback $($lines[0]) | restored $($files.Count) deleted $($added.Count) | $label $after"
  # 备份用过即删，再次回退就会退到更早一次发布；删不掉只是下次会重复同样的恢复，不算失败
  try { Remove-Item -LiteralPath $backup -Recurse -Force } catch { "WARN: backup directory not removed, the next rollback will repeat this one: $($_.Exception.Message)" }
  # 回退前在跑、回退后没起来，就是退到的这一版也起不来：报错让别的服务器先停下，别都退成这一版
  if ($wasRunning -and -not $web -and $after -ne 'Running') { throw "Files restored, but service ${after}: the version rolled back to does not start either, and the service is left stopped on this server; look into it here before rolling back again" }
  "OK: $name rolled back deploy $($lines[0]): restored $($files.Count) files, deleted $($added.Count) added files, $label $after"
} finally {
  $lock.Close()
}
