function Send-AcaEncrypted($in, $url, $key, $iv) {
  # URL 签名时没带 Content-Type，请求里也不能有，否则签名对不上
  $req = [Net.WebRequest]::Create($url)
  $req.Method = 'PUT'
  # 内容可能很大、还在变长：分块边读边传，不在内存里缓存
  $req.SendChunked = $true
  $req.AllowWriteStreamBuffering = $false
  $encryptor = [Security.Cryptography.Aes]::Create().CreateEncryptor([Convert]::FromBase64String($key), [Convert]::FromBase64String($iv))
  $crypto = New-Object Security.Cryptography.CryptoStream($req.GetRequestStream(), $encryptor, 'Write')
  $in.CopyTo($crypto)
  $crypto.Close()
  $req.GetResponse().Close()
}
