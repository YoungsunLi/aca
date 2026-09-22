# 在本机按每个运行中站点的 https 绑定实际握手，不读 IIS 或 http.sys 的配置：
# SNI 条目指向的证书被删了时，http.sys 改发 IP:端口 条目的证书，配置里看不出来
function Get-AcaServedCerts($deadline) {
  foreach ($web in @(Get-Website | Where-Object { $_.State -eq 'Started' })) {
    foreach ($b in @($web.bindings.Collection | Where-Object { $_.protocol -eq 'https' })) {
      $parts = $b.bindingInformation -split ':'
      $hostName = $parts[-1]
      $ip = ($parts[0..($parts.Count - 3)] -join ':').Trim('[]')
      if ($ip -eq '*') { $ip = '127.0.0.1' }
      $served = New-Object PSObject -Property @{ Site = $web.name; Binding = $b.bindingInformation; Cert = $null; NameOk = $false; ChainOk = $false; Error = '' }
      # 过了截止时间就不再握手，把剩下的时间留给调用方换回旧证书
      if ($deadline -and (Get-Date) -gt $deadline) { $served.Error = 'not checked, out of time'; $served; continue }
      $conn = $null
      try {
        $conn = Connect-AcaTls $ip $parts[-2] $hostName
        $served.Cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $conn.Ssl.RemoteCertificate
        $served.NameOk = -not $hostName -or -not $conn.Errors.HasFlag([Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch)
        $served.ChainOk = -not $conn.Errors.HasFlag([Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors)
      } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        $served.Error = $e.Message -replace '\s+', ' '
      } finally {
        if ($conn) { $conn.Ssl.Close() }
      }
      $served
    }
  }
}
function Get-AcaCertName($cert) { $cert.GetNameInfo('SimpleName', $false) }
