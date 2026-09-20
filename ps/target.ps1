function Get-AcaSite($name) {
  $web = Get-Website -Name $name
  if (-not $web) { throw "IIS site not found: $name" }
  $web
}
# 去掉末尾反斜杠，否则 "$root.bak-x" 会落到站点目录里面被 IIS 对外提供
function Get-AcaRoot($web) { [Environment]::ExpandEnvironmentVariables($web.physicalPath).TrimEnd('\') }
# 服务的目录只能从 aca 配置来，站点的目录是 IIS 给的：配错了会把包盖到不相干的目录上，所以核对服务的可执行文件确实在里面。
# 服务名不进 WMI 查询串，免得名字里的引号改写查询
function Get-AcaServiceRoot($name, $dir) {
  $svc = @(Get-WmiObject Win32_Service | Where-Object { $_.Name -eq $name })
  if (-not $svc) { throw "Windows service not found: $name" }
  $root = $dir.TrimEnd('\')
  if (-not (Test-Path -LiteralPath $root)) { throw "Directory of service $name not found: $root" }
  # PathName 形如 "D:\Svc\w.exe" -arg，不带引号时路径照样能有空格，所以不拆命令行，只看它是不是从这个目录里启动的
  if (-not $svc[0].PathName.TrimStart('"').StartsWith($root + '\', 'OrdinalIgnoreCase')) { throw "Service $name runs $($svc[0].PathName), which is not inside $root; wrong dir for this service in the aca config?" }
  $root
}
# exclude 里的路径是服务器上自己维护的，发布不覆盖它们，比对也不比
function Test-AcaExcluded($rel, $exclude) {
  [bool]@($exclude | Where-Object { $rel -eq $_ -or $rel.StartsWith($_ + '\', 'OrdinalIgnoreCase') })
}
# 带 aca-manifest.txt 的才是 aca 建的；.trash- 是清理掉或回退用掉之后改了名、等着删的备份。名字里带时间，按名字排就是从旧到新。
# 名字要整个对上：旁边若有站点目录叫 <leaf>.bak-xxx，它的备份也会被 -Filter 匹配到
function Get-AcaBackups($root, $kind = 'bak') {
  $prefix = (Split-Path $root -Leaf) + ".$kind-"
  Get-ChildItem -LiteralPath (Split-Path $root) -Directory -Filter "$prefix*" |
    Where-Object { $_.Name -match ('^' + [regex]::Escape($prefix) + '\d{8}-\d{6}$') -and (Test-Path -LiteralPath (Join-Path $_.FullName 'aca-manifest.txt')) } |
    Sort-Object Name
}
# 只留最近 $keep 份备份，$backup 是刚做的那份
function Remove-AcaOldBackups($root, $backup, $keep) {
  # 刚做的这份单独留着：服务器时间往回调过的话，按名字排它不一定在最后
  $baks = @(Get-AcaBackups $root | Where-Object { $_.FullName -ne $backup })
  for ($i = 0; $i -lt $baks.Count - ($keep - 1); $i++) {
    $b = $baks[$i]
    try {
      # 回退计划靠它分辨某台服务器缺的备份是被清理了，还是这台服务器没参与那次发布；只追加，写的时候被杀也丢不了之前的记录
      Add-Content -LiteralPath "$root.aca-pruned" -Value @(Get-Content -LiteralPath (Join-Path $b.FullName 'aca-manifest.txt'))[0]
      Move-AcaBackupToTrash $b.FullName
      "Removed old backup $($b.FullName)"
    } catch {
      # 留着更旧的却删掉较新的，回退链会断档，所以失败就停，下次发布再从这份删起
      "WARN: could not remove old backup $($b.FullName), stopping cleanup until the next deploy: $($_.Exception.Message)"
      break
    }
  }
  Clear-AcaTrash $root
}
# 改名是原子的：改完就不再是备份，后面删到一半失败也不会被拿去回退
function Move-AcaBackupToTrash($backup) {
  Rename-Item -LiteralPath $backup -NewName ((Split-Path $backup -Leaf) -replace '\.bak-(?=[^.]*$)', '.trash-')
}
# 这次改名的和以前没删干净的一起删；清单留到最后，删到一半失败时下次还认得出是 aca 的
function Clear-AcaTrash($root) {
  Get-AcaBackups $root 'trash' | ForEach-Object {
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
# 服务名里的 [ ] 会被 -Name 当通配符，Worker[1] 会取到 Worker1
function Get-AcaService($name) { Get-Service -Name ([Management.Automation.WildcardPattern]::Escape($name)) }
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
  if ($web.State -ne 'Stopped') { Stop-Website -Name $name }
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
  try { Start-Website -Name $name } catch { $errs += "failed to start site: $($_.Exception.Message)" }
  $errs -join '; '
}
# IIS 起来了不代表应用起来了：在本机按站点的 http 绑定请求首页，优先带域名的绑定。
# 只走 http：本机访问 https 会撞证书，而关掉证书校验的回调在 PS3 里会连累 OSS 下载。
# 返回状态码；连不上返回 0，没有 http 绑定返回 -1。0 和 503 可能只是应用池还没起来，最多试 $tries 次；
# 单次 60 秒够冷启动编译，调用方按自己的云助手超时决定试几次
function Get-AcaHomeStatus($web, $tries) {
  $b = @(Get-WebBinding -Name $web.name -Protocol http | Sort-Object { -not ($_.bindingInformation -split ':')[-1] })[0]
  if (-not $b) { return -1 }
  $hostName = ($b.bindingInformation -split ':')[-1]
  for ($i = 1; ; $i++) {
    $req = [Net.WebRequest]::Create((Get-AcaBindingUrl $b.bindingInformation))
    if ($hostName) { $req.Host = $hostName }
    $req.AllowAutoRedirect = $false
    $req.Timeout = 60000
    try { $resp = $req.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close() } catch {
      $e = $_.Exception
      while ($e.InnerException) { $e = $e.InnerException }
      # 错误响应也占连接，不关掉的话同一地址默认只有两条连接，重试会卡住
      $code = if ($e.Response) { $c = [int]$e.Response.StatusCode; $e.Response.Close(); $c } else { 0 }
    }
    if (($code -ne 0 -and $code -ne 503) -or $i -ge $tries) { return $code }
    Start-Sleep -Seconds 5
  }
}
# bindingInformation 形如 IP:端口:域名，IPv6 的 IP 自带冒号，所以从右往左拆
function Get-AcaBindingUrl($info) {
  $parts = $info -split ':'
  $ip = $parts[0..($parts.Count - 3)] -join ':'
  if ($ip -eq '*') { $ip = 'localhost' }
  "http://${ip}:$($parts[-2])/"
}
function Format-AcaHome($code) { switch ($code) { -1 { 'no http binding' } 0 { 'unreachable' } default { "$code" } } }
# 服务起来了不代表活着：启动即崩的服务过几秒才在 SCM 里变回 Stopped，所以多看几次
function Get-AcaHealth($web, $name, $tries) {
  if ($web) { return Format-AcaHome (Get-AcaHomeStatus $web $tries) }
  for ($i = 1; ; $i++) {
    $status = [string](Get-AcaService $name).Status
    if ($status -ne 'Running' -or $i -ge $tries) { return $status }
    Start-Sleep -Seconds 3
  }
}
# 返回发布、回退后要不要把它起回来；Paused、StartPending 这些状态停了再起回不到原样，交给人处理
function Test-AcaServiceRunning($status, $name) {
  if ($status -ne 'Running' -and $status -ne 'Stopped') { throw "Service $name is $status, neither Running nor Stopped; deploy or roll it back by hand" }
  $status -eq 'Running'
}
# 有的站首页本来就是 500（如只有 API 的站），发布前后一样就不算这次发布弄坏的
function Test-AcaHealthBroken($web, $health, $before) {
  if ($web) { ($health -eq 'unreachable' -or $health -match '^5\d\d$') -and $health -ne $before } else { $health -ne $before }
}
# 部署的文件本身不带版本号，目录旁的 <root>.aca-log.txt 是"当前是哪个版本"的唯一记录
function Add-AcaLog($root, $text) {
  Add-Content -LiteralPath "$root.aca-log.txt" -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $text) -Encoding UTF8
}
