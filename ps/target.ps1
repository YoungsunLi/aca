# 站点下的应用程序写成 站点/路径，Get-AcaApp 在 app.ps1 里，目标是应用时才带上；服务用的函数同理在 service.ps1 里
function Get-AcaSite($name) {
  $site = ($name -split '/')[0]
  $web = Get-Website -Name $site
  if (-not $web) { throw "IIS site not found: $site" }
  if ($site -ne $name) { return Get-AcaApp $web $name }
  $web
}
# 去掉末尾反斜杠，否则 "$root.bak-x" 会落到站点目录里面被 IIS 对外提供；规范成完整路径，IIS 里写成 C:/x 的比包含关系时才对得上
function Get-AcaRoot($web) { [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($web.physicalPath)).TrimEnd('\') }
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
