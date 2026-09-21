function Get-AcaSite($name) {
  $web = Get-Website -Name $name
  if (-not $web) { throw "IIS site not found: $name" }
  $web
}
# 去掉末尾反斜杠，否则 "$root.bak-x" 会落到站点目录里面被 IIS 对外提供
function Get-AcaRoot($web) { [Environment]::ExpandEnvironmentVariables($web.physicalPath).TrimEnd('\') }
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
function Get-AcaHash($bytes) { [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-' }
# 服务名里的 [ ] 会被 -Name 当通配符，Worker[1] 会取到 Worker1
function Get-AcaService($name) { Get-Service -Name ([Management.Automation.WildcardPattern]::Escape($name)) }
