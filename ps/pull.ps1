$path = '__PATH__'
if (Test-Path -LiteralPath $path -PathType Container) { throw "Not a file: $path" }
# 正在写的日志：要允许写入方继续写，以及轮转时改名、删除，否则打不开或者卡住它
$in = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
# URL 签名时没带 Content-Type，请求里也不能有，否则签名对不上
$req = [Net.WebRequest]::Create('__URL__')
$req.Method = 'PUT'
# 文件可能很大、还在变长：分块边读边传，不在内存里缓存
$req.SendChunked = $true
$req.AllowWriteStreamBuffering = $false
$encryptor = [Security.Cryptography.Aes]::Create().CreateEncryptor([Convert]::FromBase64String('__KEY__'), [Convert]::FromBase64String('__IV__'))
$crypto = New-Object Security.Cryptography.CryptoStream($req.GetRequestStream(), $encryptor, 'Write')
$in.CopyTo($crypto)
$crypto.Close()
$req.GetResponse().Close()
