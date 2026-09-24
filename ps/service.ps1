# 服务名不进 WMI 查询串，免得名字里的引号改写查询
function Get-AcaWmiService($name) { @(Get-WmiObject Win32_Service | Where-Object { $_.Name -eq $name })[0] }
# 服务的目录只能从 aca 配置来，站点的目录是 IIS 给的：配错了会把包盖到不相干的目录上，所以核对服务跑的程序确实在里面
function Get-AcaServiceRoot($name, $dir) {
  $svc = Get-AcaWmiService $name
  if (-not $svc) { throw "Windows service not found: $name" }
  $root = $dir.TrimEnd('\')
  if (-not (Test-Path -LiteralPath $root)) { throw "Directory of service $name not found: $root" }
  if (-not (Get-AcaProgram $svc.PathName).StartsWith($root + '\', 'OrdinalIgnoreCase')) { throw "Service $name runs $($svc.PathName), which is not inside $root; wrong dir for this service in the aca config?" }
  $root
}
# 服务名里的 [ ] 会被 -Name 当通配符，Worker[1] 会取到 Worker1
function Get-AcaService($name) { Get-Service -Name ([Management.Automation.WildcardPattern]::Escape($name)) }
# 服务命令行里的可执行文件：带引号的 PathName 引号里是可执行文件；不带引号时路径照样能有空格，取到第一个 .exe 为止。有的安装程序写的是正斜杠
function Get-AcaExePath($pathName) { $(if ($pathName.StartsWith('"')) { $pathName.Split('"')[1] } else { $pathName -replace '(?i)(\.exe).*$', '$1' }) -replace '/', '\' }
# 服务跑的程序：框架依赖的 .NET Core 程序可以用 dotnet.exe 启动，跑的是紧跟在它后面的 .dll。
# 那个参数带引号的取引号里的，不带的取到空白为止
function Get-AcaProgram($pathName) {
  $exe = Get-AcaExePath $pathName
  $dll = if ($exe -match '(^|\\)dotnet\.exe$' -and $pathName -match '^(?:"[^"]*"|.*?\.exe)\s+(?:"([^"]*)"|(\S+))') { "$($matches[1])$($matches[2])" -replace '/', '\' }
  if ($dll -match '\.dll$') { $dll } else { $exe }
}
