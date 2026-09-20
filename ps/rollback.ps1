$deploys = @('__DEPLOYS__' -split "`n")
$name = '__NAME__'
$dir = '__DIR__'
$web = if ($dir) { $null } else { Get-AcaSite $name }
$root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot $web }
$label = if ($web) { 'home' } else { 'service' }

$lock = Lock-Aca $root
try {
  $steps = @(Get-AcaBackups $root | Select-Object -Last $deploys.Count | ForEach-Object {
    $lines = @(Get-Content -LiteralPath (Join-Path $_.FullName 'aca-manifest.txt'))
    New-Object psobject -Property @{ Backup = $_.FullName; Id = $lines[0]; Added = @($lines | Select-Object -Skip 1) }
  })
  [array]::Reverse($steps)
  # 计划和执行之间可能又发布过一次，那样该先退的是更新的那份备份
  if ((($steps | ForEach-Object Id) -join "`n") -ne ($deploys -join "`n")) { throw "$name was deployed again after this rollback was planned (newest backup: $($steps[0].Backup)); run rollback again" }
  # 回退前就停着的服务，回退后也不启动，同发布
  $wasRunning = $web -or (Test-AcaServiceRunning ([string](Get-AcaService $name).Status) $name)
  $step = $steps[0]
  try {
    Stop-AcaTarget $web $name
    # 中间的版本不启动：停机更短，它们起不来也不会把回退卡在半路
    foreach ($step in $steps) {
      $manifest = Join-Path $step.Backup 'aca-manifest.txt'
      $files = @(Get-ChildItem -LiteralPath $step.Backup -Recurse -File | Where-Object { $_.FullName -ne $manifest })
      foreach ($f in $files) { Copy-AcaFile $f.FullName (Join-Path $root $f.FullName.Substring($step.Backup.Length + 1)) }
      foreach ($rel in $step.Added) {
        $p = Join-Path $root $rel
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
      }
      $counts = "restored $($files.Count) deleted $($step.Added.Count)"
      "Rolled back deploy $($step.Id): $counts"
      if ($step.Backup -ne $steps[-1].Backup) {
        # 弃不掉就停在这一份：留着它接着退更早的，下次回退会拿它把文件盖回较新的版本
        Move-AcaBackupToTrash $step.Backup
        Add-AcaLog $root "rollback $($step.Id) | $counts"
      }
    }
  } catch {
    Add-AcaLog $root "rollback $($step.Id) failed | $($_.Exception.Message)"
    throw
  } finally {
    $startErr = if ($wasRunning) { Start-AcaTarget $web $name } else { '' }
  }
  if ($startErr) {
    Add-AcaLog $root "rollback $($step.Id) files restored but start failed | $startErr"
    throw "Files restored, but $startErr"
  }
  # 回退到的那一版本来是否健康无从对照，状态只报告不判失败，少探几次给云助手 600 秒留余量
  $after = Get-AcaHealth $web $name 2
  Add-AcaLog $root "rollback $($step.Id) | $counts | $label $after"
  # 备份用过即弃，再次回退就会退到更早一次发布；最后这份弃不掉只是下次会重复同样的恢复，不算失败
  try { Move-AcaBackupToTrash $step.Backup } catch { "WARN: backup directory not removed, the next rollback will repeat this one: $($_.Exception.Message)" }
  Clear-AcaTrash $root
  # 回退前在跑、回退后没起来，就是退到的这一版也起不来：报错让别的服务器先停下，别都退成这一版
  if ($wasRunning -and -not $web -and $after -ne 'Running') { throw "Files restored, but service ${after}: the version rolled back to does not start either, and the service is left stopped on this server; look into it here before rolling back again" }
  "OK: $name rolled back to before deploy $($step.Id), $label $after"
} finally {
  $lock.Close()
}
