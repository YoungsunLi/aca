# 站点下的应用程序写成 站点/路径，Get-AcaApp 在 app.ps1 里，目标是应用时才带上
function Get-AcaSite($name) {
  $site = ($name -split '/')[0]
  $web = Get-Website -Name $site
  if (-not $web) { throw "IIS site not found: $site" }
  if ($site -ne $name) { return Get-AcaApp $web $name }
  $web
}
# 去掉末尾反斜杠，否则 "$root.bak-x" 会落到站点目录里面被 IIS 对外提供；规范成完整路径，IIS 里写成 C:/x 的比包含关系时才对得上
function Get-AcaRoot($web) { [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($web.physicalPath)).TrimEnd('\') }
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
# exclude 里的路径是服务器上自己维护的，发布不覆盖它们，比对也不比
function Test-AcaExcluded($rel, $exclude) {
  [bool]@($exclude | Where-Object { $rel -eq $_ -or $rel.StartsWith($_ + '\', 'OrdinalIgnoreCase') })
}
# 环境配置是服务器上自己维护的：站点的是 web.config，服务的是 <可执行文件>.exe.config
function Test-AcaEnvConfig($web, $rel) { if ($web) { $rel -eq 'web.config' } else { $rel -match '^[^\\]+\.exe\.config$' } }
# 在根路径上生效的节的容器：configuration 本身，和 path 为空或 "." 的 location；写在子路径 location 里的只对子路径生效。
# 按 local-name 找：ASP.NET 2.0 的工具给 configuration 加过默认命名空间，老站点的 web.config 还带着
$acaRoots = "(/* | /*/*[local-name()='location'][not(@path) or @path='' or @path='.'])"
# ASP.NET Core 的站点：web.config 是发布时生成的，在根路径上配了 aspNetCore
function Get-AcaCoreHandler($x) { $x.SelectSingleNode("$acaRoots/*[local-name()='system.webServer']/*[local-name()='aspNetCore']") }
function Get-AcaHash($data) { [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($data)) -replace '-' }
# 服务名里的 [ ] 会被 -Name 当通配符，Worker[1] 会取到 Worker1
function Get-AcaService($name) { Get-Service -Name ([Management.Automation.WildcardPattern]::Escape($name)) }
