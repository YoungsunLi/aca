# 备份、发布记录、锁这些状态文件的路径前缀，一般就是目录本身；站点下应用的由 Get-AcaSite 定
function Get-AcaBase($web, $root) { if ($web.AcaBase) { $web.AcaBase } else { $root } }
# 带 aca-manifest.txt 的才是 aca 建的；.trash- 是清理掉或回退用掉之后改了名、等着删的备份。名字里带时间，按名字排就是从旧到新。
# 名字要整个对上：旁边若有站点目录叫 <leaf>.bak-xxx，它的备份也会被 -Filter 匹配到
function Get-AcaBackups($base, $kind = 'bak') {
  $prefix = (Split-Path $base -Leaf) + ".$kind-"
  Get-ChildItem -LiteralPath (Split-Path $base) -Directory -Filter "$prefix*" |
    Where-Object { $_.Name -match ('^' + [regex]::Escape($prefix) + '\d{8}-\d{6}$') -and (Test-Path -LiteralPath (Join-Path $_.FullName 'aca-manifest.txt')) } |
    Sort-Object Name
}
# 清单第一行是发布 ID，其余是这次新增的文件，回退时删掉。带标记的行是清单自己的记录，写成服务器上不会有的相对路径，
# 旧版 aca 回退时当成新增文件去删，找不到就跳过：.aca-excluded\<哈希>\<路径> 是包里被排除的文件的哈希，下次发布拿来比包里那份变没变；
# .aca-dir\<路径> 是这次发布新建的目录，只有回退用，它自己从 Rest 里挑，不占 check 的 24 KB
$acaExcludedTag = '.aca-excluded\'
$acaDirTag = '.aca-dir\'
function Read-AcaManifest($backup) {
  $lines = @(Get-Content -LiteralPath (Join-Path $backup 'aca-manifest.txt'))
  $rest = @($lines | Select-Object -Skip 1)
  $excluded = @{}
  foreach ($l in @($rest | Where-Object { $_.StartsWith($acaExcludedTag) })) { $hash, $rel = $l.Substring($acaExcludedTag.Length) -split '\\', 2; $excluded[$rel] = $hash }
  New-Object psobject -Property @{ Id = $lines[0]; Added = @($rest | Where-Object { -not $_.StartsWith($acaExcludedTag) -and -not $_.StartsWith($acaDirTag) }); Excluded = $excluded; Rest = $rest }
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
# IIS 起来了不代表应用起来了：在本机请求站点的首页（应用是它路径下的首页），优先 http、优先带域名的绑定。
# http 跳到本站的 https 绑定时（强制 https 的站点都这样），跳转说明不了应用起没起来，改请求那个绑定。
# 返回状态码；连不上返回 0，没有 http 和 https 绑定返回 -1。0 和 503 可能只是应用池还没起来，最多试 $tries 次；
# 单次 60 秒够冷启动编译，调用方按自己的云助手超时决定试几次
function Get-AcaHomeStatus($web, $tries) {
  $all = @($web.bindings.Collection | Where-Object { 'http', 'https' -contains $_.protocol })
  $b = @($all | Sort-Object { $_.protocol -ne 'http' }, { -not (Get-AcaBindingHost $_) })[0]
  if (-not $b) { return -1 }
  $hostName = Get-AcaBindingHost $b
  # 应用路径里的空格、中文要转义，请求行只能是 ASCII
  $path = [Uri]::EscapeUriString("$($web.AppPath)/")
  for ($i = 1; ; $i++) {
    $code, $location = Invoke-AcaHome $b $hostName $path
    $https = if ($b.protocol -eq 'http' -and $location -match '^https://([^/:?#]+)(?::(\d+))?') {
      $to = $matches[1]
      $port = if ($matches[2]) { $matches[2] } else { '443' }
      $c = @($all | Where-Object { $_.protocol -eq 'https' -and ($_.bindingInformation -split ':')[-2] -eq $port -and ('', $to) -contains (Get-AcaBindingHost $_) } | Sort-Object { -not (Get-AcaBindingHost $_) })[0]
      # 不带域名的绑定兜着所有域名，可别的站点单独绑了这个域名时，跳过去的是那个站点；本站单独绑了的，上一行已经挑走了
      if ($c -and ((Get-AcaBindingHost $c) -or -not (Get-WebBinding -Protocol https -Port $port -HostHeader $to))) { $c }
    }
    if ($https) {
      $b, $hostName = $https, $to
      $code, $location = Invoke-AcaHome $b $hostName $path
    }
    if (($code -ne 0 -and $code -ne 503) -or $i -ge $tries) { return $code }
    Start-Sleep -Seconds 5
  }
}
function Get-AcaBindingHost($b) { ($b.bindingInformation -split ':')[-1] }
# 返回状态码（连不上是 0）和跳转的目标。只读状态行和响应头，http、https 走同一条路；
# https 不校验证书：要看的是应用，证书归 aca certs 查
function Invoke-AcaHome($b, $hostName, $path) {
  # bindingInformation 形如 IP:端口:域名，IPv6 的 IP 自带冒号，所以从右往左拆
  $parts = $b.bindingInformation -split ':'
  $ip, $port = ($parts[0..($parts.Count - 3)] -join ':'), $parts[-2]
  # 不带域名的绑定 Host 写地址和非默认端口，和浏览器按这个地址访问时一样
  $authority = if ($hostName) { $hostName } else { "$(if ($ip -eq '*') { 'localhost' } else { $ip })$(if ($port -ne @{ http = '80'; https = '443' }[$b.protocol]) { ":$port" })" }
  $ip = if ($ip -eq '*') { '127.0.0.1' } else { $ip.Trim('[]') }
  $s = $null
  try {
    $s = if ($b.protocol -eq 'https') { (Connect-AcaTls $ip $port $hostName).Ssl } else { (New-Object Net.Sockets.TcpClient($ip, [int]$port)).GetStream() }
    $s.ReadTimeout = 60000
    $req = [Text.Encoding]::ASCII.GetBytes("GET $path HTTP/1.1`r`nHost: $authority`r`nConnection: close`r`n`r`n")
    $s.Write($req, 0, $req.Length)
    $r = New-Object IO.StreamReader $s
    if ($r.ReadLine() -notmatch '^HTTP/\S+ (\d{3})') { return 0 }
    $code = [int]$matches[1]
    for ($l = $r.ReadLine(); $l; $l = $r.ReadLine()) { if ($l -match '^Location:\s*(\S+)') { return $code, $matches[1] } }
    $code
  } catch { 0 } finally { if ($s) { $s.Close() } }
}
function Format-AcaHome($code) { switch ($code) { -1 { 'no http or https binding' } 0 { 'unreachable' } default { "$code" } } }
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
