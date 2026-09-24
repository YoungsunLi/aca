# 每行一个站点或服务，tab 分隔：种类、名字、状态、目录、最新文件的时间、说明、能不能写进配置草稿，末尾一列是前面部分的长度，见 ecs.ts 的 records
function Out-AcaRow { $row = ($args | ForEach-Object { "$_" -replace '\s', ' ' }) -join "`t"; "$row`t$($row.Length)" }
function Format-AcaNewest($web, $root) {
  $f = Get-AcaNewestFile $web $root
  if ($f) { $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
}
# $item 是站点或站点下的应用：目录、应用池看它，状态、绑定看站点
function Out-AcaSite($name, $web, $item) {
  try {
    $root = Get-AcaRoot $item
    $pool = Get-Item -LiteralPath "IIS:\AppPools\$($item.applicationPool)"
    $state = if ($web.State -ne 'Started') { $web.State } elseif ($pool.state -ne 'Started') { "Started, app pool $($pool.state)" } else { 'Started' }
    $runtime = if ($pool.managedRuntimeVersion) { $pool.managedRuntimeVersion } else { 'no managed code' }
    $bindings = @($web.bindings.Collection | ForEach-Object { "$($_.protocol)/$($_.bindingInformation)" })
    # 绑定多的站点一行能有上千字符，几十个站点就会撑破云助手的输出上限
    $more = if ($bindings.Count -gt 3) { " (+$($bindings.Count - 3) more)" }
    Out-AcaRow site $name $state $root (Format-AcaNewest $web $root) "app pool $($pool.name), $(if ($pool.enable32BitAppOnWin64) { 32 } else { 64 })-bit, $runtime; $(($bindings | Select-Object -First 3) -join ' ')$more" ($state -eq 'Started')
  } catch { Out-AcaRow site $name "ERROR: $($_.Exception.Message)" }
}
# 没装 IIS 的服务器（如数据库服务器）上只有服务
if (Get-Command Get-Website -ErrorAction SilentlyContinue) {
  foreach ($web in @(Get-Website)) {
    Out-AcaSite $web.name $web $web
    foreach ($a in @(Get-WebApplication -Site $web.name)) { Out-AcaSite "$($web.name)$($a.path)" $web $a }
  }
}
# 系统、Program Files、ProgramData 里的是 Windows 自己的和装上的软件（云助手客户端、杀毒、数据库），不是自己发布的程序，不列
$system = @($env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData | Where-Object { $_ })
foreach ($svc in @(Get-WmiObject Win32_Service | Where-Object { $_.PathName })) {
  $exe = Get-AcaExePath $svc.PathName
  if (@($system | Where-Object { $exe.StartsWith($_ + '\', 'OrdinalIgnoreCase') })) { continue }
  try {
    $dir = Split-Path $exe
    # 盘符根 aca 不认，也别去整盘找最新文件
    $mine = $svc.StartMode -ne 'Disabled' -and $dir -match '^[a-zA-Z]:\\[^\\]'
    Out-AcaRow service $svc.Name $svc.State $dir $(if ($mine) { Format-AcaNewest $null $dir }) "$($svc.StartMode) start; $($svc.PathName)" $mine
  } catch { Out-AcaRow service $svc.Name "ERROR: $($_.Exception.Message)" }
}
