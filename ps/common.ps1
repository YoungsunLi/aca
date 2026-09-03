$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Import-Module WebAdministration

function Get-AcaSite($name) {
  $web = Get-Website -Name $name
  if (-not $web) { throw "IIS site not found: $name" }
  $web
}
# 去掉末尾反斜杠，否则 "$root.bak-x" 会落到站点目录里面被 IIS 对外提供
function Get-AcaRoot($web) { [Environment]::ExpandEnvironmentVariables($web.physicalPath).TrimEnd('\') }
function Copy-AcaFile($src, $dst) {
  New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
  Copy-Item -LiteralPath $src -Destination $dst -Force
}
function Stop-AcaSite($web) {
  if ($web.State -ne 'Stopped') { Stop-Website -Name $web.name }
  $pool = $web.applicationPool
  if ((Get-WebAppPoolState -Name $pool).Value -ne 'Stopped') { Stop-WebAppPool -Name $pool }
  # 等待有上限：卡住会耗光云助手超时被强杀，finally 里的启站就没机会跑
  for ($i = 0; (Get-WebAppPoolState -Name $pool).Value -ne 'Stopped'; $i++) {
    if ($i -ge 120) { throw "App pool $pool did not stop within 120 seconds" }
    Start-Sleep -Seconds 1
  }
}
# 在 finally 里调用，不抛异常以免盖掉真正的错误；返回失败描述，调用方在 finally 之后再报错
function Start-AcaSite($web) {
  $errs = @()
  try { Start-WebAppPool -Name $web.applicationPool } catch { $errs += "failed to start app pool: $($_.Exception.Message)" }
  try { Start-Website -Name $web.name } catch { $errs += "failed to start site: $($_.Exception.Message)" }
  $errs -join '; '
}
# 部署的文件本身不带版本号，站点目录旁的 <root>.aca-log.txt 是"当前是哪个版本"的唯一记录
function Add-AcaLog($root, $text) {
  Add-Content -LiteralPath "$root.aca-log.txt" -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $text) -Encoding UTF8
}
