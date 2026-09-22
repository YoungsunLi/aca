# 站点下的应用连站点的锁一起拿：发站点要停站点，站点下的应用跟着停。调用方在 finally 里逐个 Close
function Lock-AcaTarget($web, $base) {
  if ($web.SiteRoot) { Lock-Aca $web.SiteRoot }
  Lock-Aca $base
}
# 只留最近 $keep 份备份，$backup 是刚做的那份
function Remove-AcaOldBackups($base, $backup, $keep) {
  # 刚做的这份单独留着：服务器时间往回调过的话，按名字排它不一定在最后
  $baks = @(Get-AcaBackups $base | Where-Object { $_.FullName -ne $backup })
  for ($i = 0; $i -lt $baks.Count - ($keep - 1); $i++) {
    $b = $baks[$i]
    try {
      # 回退计划靠它分辨某台服务器缺的备份是被清理了，还是这台服务器没参与那次发布；只追加，写的时候被杀也丢不了之前的记录
      Add-Content -LiteralPath "$base.aca-pruned" -Value (Read-AcaManifest $b.FullName).Id
      Move-AcaBackupToTrash $b.FullName
      "Removed old backup $($b.FullName)"
    } catch {
      # 留着更旧的却删掉较新的，回退链会断档，所以失败就停，下次发布再从这份删起
      "WARN: could not remove old backup $($b.FullName), stopping cleanup until the next deploy: $($_.Exception.Message)"
      break
    }
  }
  Clear-AcaTrash $base
}
# 改名是原子的：改完就不再是备份，后面删到一半失败也不会被拿去回退
function Move-AcaBackupToTrash($backup) {
  Rename-Item -LiteralPath $backup -NewName ((Split-Path $backup -Leaf) -replace '\.bak-(?=[^.]*$)', '.trash-')
}
# 这次改名的和以前没删干净的一起删；清单留到最后，删到一半失败时下次还认得出是 aca 的
function Clear-AcaTrash($base) {
  Get-AcaBackups $base 'trash' | ForEach-Object {
    $d = $_.FullName
    try {
      Get-ChildItem -LiteralPath $d -Force | Where-Object { $_.Name -ne 'aca-manifest.txt' } | Remove-Item -Recurse -Force
      Remove-Item -LiteralPath $d -Recurse -Force
    } catch { "WARN: $d not fully deleted, will retry on the next deploy or rollback: $($_.Exception.Message)" }
  }
}
function Copy-AcaFile($src, $dst) {
  New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
  Copy-Item -LiteralPath $src -Destination $dst -Force
}
# 发布目标是 IIS 站点或 Windows 服务，$web 为空即服务
function Stop-AcaTarget($web, $name) {
  if (-not $web) {
    "Stopping service $name"
    $svc = Get-AcaService $name
    # Stop() 会把依赖它的服务一起停掉，而 aca 事后只起回这一个，所以有依赖在跑就不动它
    $deps = @($svc.DependentServices | Where-Object { $_.Status -ne 'Stopped' })
    if ($deps) { throw "Service $name has dependent service(s) running: $(($deps | ForEach-Object Name) -join ', '); stopping it would stop them too, so deploy this service by hand" }
    # 用 Stop() 而不是 Stop-Service：后者自己等到停下为止，卡在 StopPending 的服务会把等待上限架空
    if ($svc.Status -ne 'Stopped') { $svc.Stop() }
    # 等待有上限：卡住会耗光云助手超时被强杀，finally 里的启动就没机会跑
    try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(120)) } catch { throw "Service $name did not stop within 120 seconds" }
    return
  }
  # clb.ts 靠这一行判断失败时停没停过站：停过的服务器留在负载均衡外
  "Stopping site $name"
  # 应用单独停不了，只停它的应用池，站点照常服务别的应用
  if (-not $web.AppPath -and $web.State -ne 'Stopped') { Stop-Website -Name $name }
  $pool = $web.applicationPool
  if ((Get-WebAppPoolState -Name $pool).Value -ne 'Stopped') { Stop-WebAppPool -Name $pool }
  for ($i = 0; (Get-WebAppPoolState -Name $pool).Value -ne 'Stopped'; $i++) {
    if ($i -ge 120) { throw "App pool $pool did not stop within 120 seconds" }
    Start-Sleep -Seconds 1
  }
}
# 在 finally 里调用，不抛异常以免盖掉真正的错误；返回失败描述，调用方在 finally 之后再报错
function Start-AcaTarget($web, $name) {
  if (-not $web) {
    $svc = Get-AcaService $name
    # 停的那一步失败时服务还在跑，Start() 对在跑的服务会报错
    if ($svc.Status -eq 'Running') { return '' }
    try { $svc.Start() } catch { return "failed to start service: $($_.Exception.Message)" }
    # 同停止那边，Start-Service 也是自己等到底
    try { $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(120)) } catch { return "service did not reach Running within 120 seconds" }
    return ''
  }
  $errs = @()
  try { Start-WebAppPool -Name $web.applicationPool } catch { $errs += "failed to start app pool: $($_.Exception.Message)" }
  if (-not $web.AppPath) { try { Start-Website -Name $name } catch { $errs += "failed to start site: $($_.Exception.Message)" } }
  $errs -join '; '
}
# 有的站首页本来就是 500（如只有 API 的站），发布前后一样就不算这次发布弄坏的
function Test-AcaHealthBroken($web, $health, $before) {
  if ($web) { ($health -eq 'unreachable' -or $health -match '^5\d\d$') -and $health -ne $before } else { $health -ne $before }
}
# 部署的文件本身不带版本号，<base>.aca-log.txt 是"当前是哪个版本"的唯一记录
function Add-AcaLog($base, $text) {
  Add-Content -LiteralPath "$base.aca-log.txt" -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $text) -Encoding UTF8
}
