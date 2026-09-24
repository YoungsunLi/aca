# 服务命令行里的可执行文件：带引号的 PathName 引号里是可执行文件；不带引号时路径照样能有空格，取到第一个 .exe 为止。有的安装程序写的是正斜杠
function Get-AcaExePath($pathName) { $(if ($pathName.StartsWith('"')) { $pathName.Split('"')[1] } else { $pathName -replace '(?i)(\.exe).*$', '$1' }) -replace '/', '\' }
