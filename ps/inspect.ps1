# 带 aca-manifest.txt 的才是 aca 建的；.trash- 是清理掉或回退用掉之后改了名、等着删的备份。名字里带时间，按名字排就是从旧到新。
# 名字要整个对上：旁边若有站点目录叫 <leaf>.bak-xxx，它的备份也会被 -Filter 匹配到
function Get-AcaBackups($root, $kind = 'bak') {
  $prefix = (Split-Path $root -Leaf) + ".$kind-"
  Get-ChildItem -LiteralPath (Split-Path $root) -Directory -Filter "$prefix*" |
    Where-Object { $_.Name -match ('^' + [regex]::Escape($prefix) + '\d{8}-\d{6}$') -and (Test-Path -LiteralPath (Join-Path $_.FullName 'aca-manifest.txt')) } |
    Sort-Object Name
}
# 清单第一行是发布 ID，其余是这次新增的文件，回退时删掉。包里被排除的文件的哈希也记在这里，下次发布拿来比包里那份变没变；
# 写成服务器上不会有的相对路径，旧版 aca 回退时当成新增文件去删，找不到就跳过
$acaExcludedTag = '.aca-excluded\'
function Read-AcaManifest($backup) {
  $lines = @(Get-Content -LiteralPath (Join-Path $backup 'aca-manifest.txt'))
  $rest = @($lines | Select-Object -Skip 1)
  $excluded = @{}
  foreach ($l in @($rest | Where-Object { $_.StartsWith($acaExcludedTag) })) { $hash, $rel = $l.Substring($acaExcludedTag.Length) -split '\\', 2; $excluded[$rel] = $hash }
  New-Object psobject -Property @{ Id = $lines[0]; Added = @($rest | Where-Object { -not $_.StartsWith($acaExcludedTag) }); Excluded = $excluded }
}
# 按流算，几 GB 的文件也不整个读进内存
function Get-AcaFileHash($path) {
  $s = [IO.File]::OpenRead($path)
  try { Get-AcaHash $s } finally { $s.Close() }
}
# 备份的是被覆盖的旧文件，盘上要放得下它们再加上新包
function Assert-AcaDiskSpace($root, $files, $rels, $added) {
  $need = ($files | Measure-Object Length -Sum).Sum
  for ($i = 0; $i -lt $files.Count; $i++) {
    if ($added -notcontains $rels[$i]) { $need += (Get-Item -LiteralPath (Join-Path $root $rels[$i])).Length }
  }
  $free = (Get-PSDrive $root.Substring(0, 1)).Free
  if ($free -lt $need) { throw "Only $([int]($free / 1MB))MB free on drive $($root.Substring(0, 1)), not enough for backup plus overwrite (about $([int]($need / 1MB))MB needed)" }
}
# 包比服务器旧：要么拿错了旧构建，要么服务器上有人手改过，两种都不该悄悄覆盖
function Get-AcaOlderFiles($root, $files, $rels, $added) {
  for ($i = 0; $i -lt $files.Count; $i++) {
    if ($added -notcontains $rels[$i] -and (Get-Item -LiteralPath (Join-Path $root $rels[$i])).LastWriteTime -gt $files[$i].LastWriteTime.AddMinutes(1)) { $rels[$i] }
  }
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
