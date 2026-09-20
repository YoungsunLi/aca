$path = '__PATH__'
if (Test-Path -LiteralPath $path -PathType Container) { throw "Not a file: $path" }
# 正在写的日志：要允许写入方继续写，以及轮转时改名、删除，否则打不开或者卡住它
$in = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
Send-AcaEncrypted $in '__URL__' '__KEY__' '__IV__'
