$url = '__URL__'
$key = '__KEY__'
$password = '__PASSWORD__'
$thumbprint = '__THUMBPRINT__'
$checkOnly = '__CHECK_ONLY__' -eq 'true'
$force = '__FORCE__' -eq 'true'
$timeout = [int]'__TIMEOUT__'
$started = Get-Date
$download = Join-Path $env:TEMP "aca-$([guid]::NewGuid()).enc"
$lock = $null

function Import-AcaPfx($flags) {
  $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2Collection
  $c.Import($pfxBytes, $password, $flags)
  $c
}
function Read-AcaSource {
  if (-not $url) {
    $cert = @(Get-Item -LiteralPath "Cert:\LocalMachine\My\$thumbprint", "Cert:\LocalMachine\WebHosting\$thumbprint" -ErrorAction SilentlyContinue)[0]
    if ($cert -and -not $cert.HasPrivateKey) { throw "Certificate $thumbprint has no private key on this server" }
    return $cert
  }
  Invoke-WebRequest -Uri $url -OutFile $download -UseBasicParsing
  # 在内存里解密，磁盘上不落明文 PFX；IV 是头 16 字节
  $blob = [IO.File]::ReadAllBytes($download)
  $aes = [Security.Cryptography.Aes]::Create()
  $aes.Key = [Convert]::FromBase64String($key)
  $aes.IV = [byte[]]$blob[0..15]
  $script:pfxBytes = $aes.CreateDecryptor().TransformFinalBlock($blob, 16, $blob.Length - 16)
  try { $content = @(Import-AcaPfx 'MachineKeySet') }
  catch { throw "Cannot open the PFX: $($_.Exception.InnerException.Message) Windows Server 2016 and earlier report AES-encrypted PFX files (OpenSSL 3's default) as a wrong password; re-export with openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1" }
  # 只留公钥部分，临时导入的私钥马上删：这台服务器上没有要换的绑定，就不该留下它
  try {
    $leaf = @($content | Where-Object { $_.HasPrivateKey })
    if ($leaf.Count -ne 1) { throw "The PFX must hold exactly one certificate with a private key, found $($leaf.Count)" }
    New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, $leaf[0].RawData)
  } finally {
    # Server 2012 上 Reset 删不掉 CNG 里的临时私钥，ECC 的私钥只放得进 CNG，要自己删；取 CNG 私钥的托管接口 .NET 4.6.1 才有，更早的 .NET 上不删
    $ecdsa = 'System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions' -as [type]
    foreach ($c in $content) {
      if ($ecdsa -and $c.HasPrivateKey -and $c.PublicKey.Oid.Value -eq '1.2.840.10045.2.1') { $ecdsa::GetECDsaPrivateKey($c).Key.Delete() }
      $c.Reset()
    }
  }
}
# 中间证书放进"中级证书颁发机构"，http.sys 才发得出完整的证书链；根证书信不信任不归这里定
function Install-AcaPfx {
  $my = New-Object Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
  $ca = New-Object Security.Cryptography.X509Certificates.X509Store('CA', 'LocalMachine')
  $my.Open('ReadWrite')
  $ca.Open('ReadWrite')
  try {
    foreach ($c in Import-AcaPfx 'MachineKeySet,PersistKeySet') {
      if ($c.HasPrivateKey) { $my.Add($c) } elseif ($c.Subject -ne $c.Issuer) { $ca.Add($c) }
    }
  } finally {
    $my.Close()
    $ca.Close()
  }
}
# IIS 换证书只带上证书和 SNI 标志，条目上别的设置（客户端证书协商、吊销检查、CTL、别的程序的 AppId）会丢，不是 IIS 默认值的条目不替人换
function Test-AcaPlainEntry($e) {
  $e.DefaultFlags -eq 0 -and $e.CertificateCheckMode -eq 0 -and $e.RevocationFreshnessTime -eq [TimeSpan]::Zero -and $e.RevocationURLRetrievalTimeout -eq [TimeSpan]::Zero -and
    -not $e.CTLIdentifier -and -not $e.CTLStoreName -and "$($e.ApplicationId)" -eq '4dc3e181-e14b-4a21-b022-59fc669b0914'
}
# 条目上的站点自己按 IP、端口、SNI 主机名算：条目自带的 Sites 按 bindingInformation 前缀匹配，*:4433 的站点也会算进 *:443 的条目
function Get-AcaEntrySites($e) {
  $ip = if ("$($e.IPAddress)" -eq '0.0.0.0') { '*' } else { "$($e.IPAddress)" }
  foreach ($web in Get-Website) {
    foreach ($b in @($web.bindings.Collection | Where-Object { $_.protocol -eq 'https' })) {
      $parts = $b.bindingInformation -split ':'
      $sni = ($b.sslFlags -band 1) -ne 0
      if ($parts[-2] -ne "$($e.Port)" -or $sni -ne [bool]$e.Host) { continue }
      if ($(if ($sni) { $parts[-1] -eq $e.Host } else { ($parts[0..($parts.Count - 3)] -join ':') -eq $ip })) { $web.name; break }
    }
  }
}
function Format-AcaEntry($e) {
  $sites = @(Get-AcaEntrySites $e) -join ', '
  "$(if ($e.Host) { $e.Host } else { $e.IPAddress }):$($e.Port)$(if ($sites) { "  ($sites)" })"
}
# 一律删了重建：IIS 的 Set-Item 改不了 SNI 条目（报 address 为 null），改 IP 条目会把 AppId 清成全 0，还只认 My 库里的证书。
# 改完回读核对：没有站点在用的条目，后面的握手检查管不到。证书和域名对不对得上交给握手检查，IIS 按证书使用者名称字面比较的警告压掉
function Set-AcaEntryCert($entry, $cert) {
  $path = "IIS:\SslBindings\$($entry.PSChildName)"
  if (Get-Item $path -ErrorAction SilentlyContinue) { Remove-Item $path }
  New-Item -Path $path -Value $cert -SSLFlags $(if ($entry.Host) { 1 } else { 0 }) -WarningAction SilentlyContinue | Out-Null
  $bound = (Get-Item $path).Thumbprint
  if ($bound -ne $cert.Thumbprint) { throw "$(Format-AcaEntry $entry) still uses $bound" }
}
# 一台服务器要么全换好，要么换回原样
function Switch-AcaCert($targets, $new, $before) {
  $name = Get-AcaCertName $new
  $switched = @()
  try {
    foreach ($t in $targets) {
      $switched += $t
      Set-AcaEntryCert $t.Entry $new
    }
    # 换之前发这个名字证书的绑定，换完都得发新证书；原来域名对得上、证书链验证得过的，换完也得一样。
    # 只拦变坏的：原来就验证不过的（证书过期、服务器缺根证书），不能因此不让换
    $after = @(Get-AcaServedCerts ($started.AddSeconds($timeout - 120)))
    $bad = @($before | Where-Object { $_.Cert -and (Get-AcaCertName $_.Cert) -eq $name } | ForEach-Object {
      $w = $_
      $a = $after | Where-Object { $_.Site -eq $w.Site -and $_.Binding -eq $w.Binding }
      $why = if (-not $a.Cert) { "handshake failed: $($a.Error)" } elseif ($a.Cert.Thumbprint -ne $new.Thumbprint) { "serves $($a.Cert.Thumbprint)" } elseif ($w.NameOk -and -not $a.NameOk) { 'name mismatch' } elseif ($w.ChainOk -and -not $a.ChainOk) { 'certificate chain not trusted on the server' }
      if ($why) { "$($w.Site) $($w.Binding): $why" }
    })
    if ($bad) { throw "Handshake check failed after switching: $($bad -join '; ')" }
  } catch {
    $err = $_.Exception.Message
    $failed = @($switched | ForEach-Object {
      $t = $_
      try { Set-AcaEntryCert $t.Entry $t.Old } catch { "$(Format-AcaEntry $t.Entry): $($_.Exception.Message)" }
    })
    throw "$err; $(if ($failed) { "switching back FAILED for $($failed -join '; ')" } else { 'switched back to the old certificates' })"
  }
}

try {
  $new = Read-AcaSource
  # 旧证书只在用过它的服务器上
  if (-not $new) { "Nothing to replace: certificate $thumbprint is not in LocalMachine\My or WebHosting on this server"; return }
  $name = Get-AcaCertName $new
  # 没有名字的证书和所有没名字的证书都算同名
  if (-not $name) { throw 'The certificate has no subject name' }
  "New certificate: $name  expires $($new.NotAfter.ToString('yyyy-MM-dd'))  $($new.Thumbprint)"
  # 有效期在换之前拦：原来的证书已经过期时，换完的握手检查看不出新证书也用不了
  $now = Get-Date
  if ($new.NotBefore -gt $now -or $new.NotAfter -le $now) { throw "The new certificate is not valid now, only from $($new.NotBefore.ToString('yyyy-MM-dd HH:mm')) to $($new.NotAfter.ToString('yyyy-MM-dd HH:mm'))" }

  # 两个 certs replace 同时跑，各自的握手检查会看到对方换上的证书而把它换回去；锁从找条目一直握到换完或换回
  if (-not $checkOnly) { $lock = Lock-Aca (Join-Path $env:ProgramData 'aca-certs') 'Another aca certs replace is running on this server; retry after it finishes' }
  # 按 http.sys 的条目换、不按站点：不带 SNI 的绑定共用一个 IP:端口 条目，换一个站就连带同条目的所有站
  $targets = @(Get-ChildItem IIS:\SslBindings | Where-Object { $_.Thumbprint -and $_.Thumbprint -ne $new.Thumbprint } | ForEach-Object {
    $old = Get-Item -LiteralPath "Cert:\LocalMachine\$($_.Store)\$($_.Thumbprint)" -ErrorAction SilentlyContinue
    if ($old -and (Get-AcaCertName $old) -eq $name) { New-Object PSObject -Property @{ Entry = $_; Old = $old } }
  })
  if (-not $targets) { "Nothing to replace: no binding uses another certificate named $name"; return }
  foreach ($t in $targets) { "$(Format-AcaEntry $t.Entry)  $($t.Old.Thumbprint) expires $($t.Old.NotAfter.ToString('yyyy-MM-dd'))" }
  $custom = @($targets | Where-Object { -not (Test-AcaPlainEntry $_.Entry) })
  if ($custom) { throw "$(($custom | ForEach-Object { Format-AcaEntry $_.Entry }) -join '; ') carry http.sys settings beyond the IIS defaults, which switching would drop; switch them by hand" }
  # 新证书不比旧的晚到期，多半是拿错了文件
  $notLater = @($targets | Where-Object { $_.Old.NotAfter -ge $new.NotAfter })
  if ($checkOnly) { "CHECK OK (not replaced$(if ($notLater -and -not $force) { '; replacing needs --force: the new certificate does not expire later' }))"; return }
  if ($notLater -and -not $force) { throw "The new certificate does not expire later than $($notLater[0].Old.Thumbprint) it would replace; pass --force to replace anyway" }

  $t0 = Get-Date
  $before = @(Get-AcaServedCerts)
  $pass = ((Get-Date) - $t0).TotalSeconds
  # 换完还要再握手一遍、不行还得换回去：剩下的时间不够就不动手，否则云助手到点强杀，换回那一步没机会跑
  if (((Get-Date) - $started).TotalSeconds + $pass + 120 -gt $timeout) { throw "Not enough time left to verify and switch back: one handshake pass took $([int]$pass)s" }
  if ($url) {
    Install-AcaPfx
    $new = Get-Item -LiteralPath "Cert:\LocalMachine\My\$($new.Thumbprint)"
  }
  Switch-AcaCert $targets $new $before
  "OK: $($targets.Count) http.sys binding(s) switched to $($new.Thumbprint); the old certificates stay in the store"
} finally {
  if ($lock) { $lock.Close() }
  Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
}
