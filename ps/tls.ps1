# 在本机和 https 绑定握手，接受任何证书，校验结果放在 Errors 里：查证书的要看它，查首页的不管。
# 回调挂在这一个连接上、握手时同步调用，不像 ServicePointManager 的全局回调那样在 PS3 上连累 OSS 下载。
# 没给域名就按 IP 握手，不发 SNI；调用方用完关 Ssl，连接随它关掉
function Connect-AcaTls($ip, $port, $hostName) {
  # .NET 4.8（枚举里有 Tls13）起 None 是让系统选，只开 TLS 1.3 的绑定也握得上；更早的 .NET 里 None 一个协议都不开
  $protocols = if ([Enum]::GetNames([Security.Authentication.SslProtocols]) -contains 'Tls13') { 'None' } else { 'Tls,Tls11,Tls12' }
  $policy = @{}
  $tcp = New-Object Net.Sockets.TcpClient($ip, [int]$port)
  try {
    $tcp.ReceiveTimeout = 10000
    $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ([Net.Security.RemoteCertificateValidationCallback] { param($sender, $cert, $chain, $errors) $policy.errors = $errors; $true }))
    $ssl.AuthenticateAsClient($(if ($hostName) { $hostName } else { $ip }), $null, [Security.Authentication.SslProtocols]$protocols, $false)
    New-Object PSObject -Property @{ Ssl = $ssl; Errors = $policy.errors }
  } catch {
    $tcp.Close()
    throw
  }
}
