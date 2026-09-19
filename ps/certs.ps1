# 每行的格式被 certs.ts 的 ROW 解析，改格式两边一起改
# 在本机按绑定实际握手，不读 IIS 或 http.sys 的配置：SNI 条目指向的证书被删了时，http.sys 改发 IP:端口 条目的证书，配置里看不出来
# .NET 4.8（枚举里有 Tls13）起 None 是让系统选，只开 TLS 1.3 的绑定也握得上；更早的 .NET 里 None 一个协议都不开
$protocols = if ([Enum]::GetNames([Security.Authentication.SslProtocols]) -contains 'Tls13') { 'None' } else { 'Tls,Tls11,Tls12' }
foreach ($web in @(Get-Website | Where-Object { $_.State -eq 'Started' })) {
  foreach ($b in @($web.bindings.Collection | Where-Object { $_.protocol -eq 'https' })) {
    $parts = $b.bindingInformation -split ':'
    $hostName = $parts[-1]
    $ip = ($parts[0..($parts.Count - 3)] -join ':').Trim('[]')
    if ($ip -eq '*') { $ip = '127.0.0.1' }
    $policy = @{}
    $tcp = $null
    try {
      $tcp = New-Object Net.Sockets.TcpClient($ip, [int]$parts[-2])
      $tcp.ReceiveTimeout = 10000
      $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ([Net.Security.RemoteCertificateValidationCallback] { param($sender, $cert, $chain, $errors) $policy.errors = $errors; $true }))
      # 不带域名的绑定按 IP 握手，不发 SNI
      $ssl.AuthenticateAsClient($(if ($hostName) { $hostName } else { $ip }), $null, [Security.Authentication.SslProtocols]$protocols, $false)
      $served = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $ssl.RemoteCertificate
      $nameOk = -not $hostName -or -not $policy.errors.HasFlag([Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch)
      "$($web.name)`t$($b.bindingInformation)`t$($served.Thumbprint)`t$($served.NotAfter.ToString('yyyy-MM-dd'))`t$([Math]::Floor(($served.NotAfter - (Get-Date)).TotalDays))`t$($served.GetNameInfo('SimpleName', $false))`t$nameOk"
    } catch {
      $e = $_.Exception
      while ($e.InnerException) { $e = $e.InnerException }
      "$($web.name)`t$($b.bindingInformation)`tERROR`t$($e.Message -replace '\s+', ' ')"
    } finally {
      if ($tcp) { $tcp.Close() }
    }
  }
}
