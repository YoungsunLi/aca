$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Import-Module WebAdministration

function Get-AcaSite($name) {
  $web = Get-Website -Name $name
  if (-not $web) { throw "IIS site not found: $name" }
  $web
}
# 去掉末尾反斜杠，否则 "$root.bak-x" 会落到站点目录里面被 IIS 对外提供
function Get-AcaRoot($web) { [Environment]::ExpandEnvironmentVariables($web.physicalPath).TrimEnd('\') }
function Copy-AcaFile($src, $dst) {
  New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
  Copy-Item -LiteralPath $src -Destination $dst -Force
}
function Stop-AcaSite($web) {
  if ($web.State -ne 'Stopped') { Stop-Website -Name $web.name }
  $pool = $web.applicationPool
  if ((Get-WebAppPoolState -Name $pool).Value -ne 'Stopped') { Stop-WebAppPool -Name $pool }
  # 等待有上限：卡住会耗光云助手超时被强杀，finally 里的启站就没机会跑
  for ($i = 0; (Get-WebAppPoolState -Name $pool).Value -ne 'Stopped'; $i++) {
    if ($i -ge 120) { throw "App pool $pool did not stop within 120 seconds" }
    Start-Sleep -Seconds 1
  }
}
# 在 finally 里调用，不抛异常以免盖掉真正的错误；返回失败描述，调用方在 finally 之后再报错
function Start-AcaSite($web) {
  $errs = @()
  try { Start-WebAppPool -Name $web.applicationPool } catch { $errs += "failed to start app pool: $($_.Exception.Message)" }
  try { Start-Website -Name $web.name } catch { $errs += "failed to start site: $($_.Exception.Message)" }
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
# 有的站首页本来就是 500（如只有 API 的站），发布前后一样就不算这次发布弄坏的
function Test-AcaHomeBroken($code, $before) { ($code -eq 0 -or $code -ge 500) -and $code -ne $before }
# 部署的文件本身不带版本号，站点目录旁的 <root>.aca-log.txt 是"当前是哪个版本"的唯一记录
function Add-AcaLog($root, $text) {
  Add-Content -LiteralPath "$root.aca-log.txt" -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $text) -Encoding UTF8
}
