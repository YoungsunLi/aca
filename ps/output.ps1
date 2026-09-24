# aca run -o：$acaScript 是 aca 放在前面的用户脚本，它输出的内容边收边存，脚本 exit 或出错时也在 finally 里传走。
# 只收输出流：把错误流也并进来的话，PS 5.1 在 $ErrorActionPreference = 'Stop' 时会把原生命令写到 stderr 的第一行当成异常抛出
$acaOut = New-Object Text.StringBuilder
try {
  & $acaScript | Out-String -Stream | ForEach-Object { [void]$acaOut.AppendLine($_) }
} catch {
  # 传完再交给前缀里的 trap 报：finally 里上传失败的异常会盖掉脚本自己的
  $acaErr = $_
} finally {
  try {
    # Windows PowerShell 默认只用 SSL 3.0 和 TLS 1.0，bucket 可以设成只收 TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Send-AcaEncrypted (New-Object IO.MemoryStream(, [Text.Encoding]::UTF8.GetBytes($acaOut.ToString()))) '__URL__' '__KEY__' '__IV__'
  } catch {
    'ERROR: could not save the output: ' + $_.Exception.Message
    if (-not $acaErr) { exit 1 }
  }
}
if ($acaErr) { throw $acaErr }
