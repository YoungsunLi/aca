# 服务的目录只能从 aca 配置来，站点的目录是 IIS 给的：配错了会把包盖到不相干的目录上，所以核对服务的可执行文件确实在里面。
# 服务名不进 WMI 查询串，免得名字里的引号改写查询
function Get-AcaServiceRoot($name, $dir) {
  $svc = @(Get-WmiObject Win32_Service | Where-Object { $_.Name -eq $name })
  if (-not $svc) { throw "Windows service not found: $name" }
  $root = $dir.TrimEnd('\')
  if (-not (Test-Path -LiteralPath $root)) { throw "Directory of service $name not found: $root" }
  # PathName 形如 "D:\Svc\w.exe" -arg，不带引号时路径照样能有空格，所以不拆命令行，只看它是不是从这个目录里启动的
  if (-not $svc[0].PathName.TrimStart('"').StartsWith($root + '\', 'OrdinalIgnoreCase')) { throw "Service $name runs $($svc[0].PathName), which is not inside $root; wrong dir for this service in the aca config?" }
  $root
}
# 服务名里的 [ ] 会被 -Name 当通配符，Worker[1] 会取到 Worker1
function Get-AcaService($name) { Get-Service -Name ([Management.Automation.WildcardPattern]::Escape($name)) }
# 服务命令行里的可执行文件：带引号的 PathName 引号里是可执行文件；不带引号时路径照样能有空格，取到第一个 .exe 为止。有的安装程序写的是正斜杠
function Get-AcaExePath($pathName) { $(if ($pathName.StartsWith('"')) { $pathName.Split('"')[1] } else { $pathName -replace '(?i)(\.exe).*$', '$1' }) -replace '/', '\' }
