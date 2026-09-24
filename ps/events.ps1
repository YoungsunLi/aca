$name = '__NAME__'
$dir = '__DIR__'
$tail = [int]'__TAIL__'
$since = '__SINCE__'
$until = '__UNTIL__'
# 查询只按写死的来源名和时间筛：服务的显示名可能同时带单双引号，XPath 1.0 的字符串写不下，名字读出来再比
function Format-AcaQuery($providers, $conditions) {
  $all = @($(if ($providers) { 'Provider[' + (@(foreach ($p in $providers) { "@Name='$p'" }) -join ' or ') + ']' })) + $conditions
  if ($all) { "*[System[$($all -join ' and ')]]" } else { '*' }
}
# 用来认领的记录要看得到时间段外的：同一次崩溃的 .NET Runtime 和 Application Error 相隔几秒，时间段可能正好切在中间。
# 所以查询两头各放宽两分钟，列出时再按原样筛
function ConvertFrom-AcaUtc($s) { [datetime]::SpecifyKind([datetime]::ParseExact($s, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), 'Utc') }
$from = if ($since) { ConvertFrom-AcaUtc $since }
$to = if ($until) { (ConvertFrom-AcaUtc $until).AddSeconds(1) }
$window = @($(if ($from) { "TimeCreated[@SystemTime>='$($from.AddMinutes(-2).ToString('s'))Z']" }), $(if ($to) { "TimeCreated[@SystemTime<='$($to.AddMinutes(2).ToString('s'))Z']" }) | Where-Object { $_ })
# 直接用 EventLogReader：日志里几千条时比 Get-WinEvent 快十几倍，没有事件也不报错
function Read-AcaEvents($log, $xpath, $newestFirst) {
  $query = New-Object Diagnostics.Eventing.Reader.EventLogQuery($log, 'LogName', $xpath)
  $query.ReverseDirection = $newestFirst
  $reader = New-Object Diagnostics.Eventing.Reader.EventLogReader($query)
  try { while ($e = $reader.ReadEvent()) { $e } } finally { $reader.Dispose() }
}
# 字段都转成字符串：二进制字段原样会被展开成一个个字节，拿名字和字节比，每比一次都要在内部抛一次转换异常，几万条事件就要几分钟
function Get-AcaValues($e) { foreach ($p in $e.Properties) { "$($p.Value)" } }
# Application Error 是 WER 代记的，崩溃进程的 ID 在第 9 个字段、启动时间（FILETIME）在第 10 个：新系统上是数字，2012 上是不带 0x 的十六进制字符串。
# 别的事件没记进程 ID 的，有的是空、有的记成 0，都当不知道
function Get-AcaEventPid($e) {
  if ($e.ProviderName -ne 'Application Error') { return $(if ($e.ProcessId) { $e.ProcessId }) }
  $v = $e.Properties[8].Value
  if ($v -is [string]) { [Convert]::ToInt32($v, 16) } else { [int]$v }
}
function Get-AcaCrashStart($e) { $v = $e.Properties[9].Value; [datetime]::FromFileTime($(if ($v -is [string]) { [Convert]::ToInt64($v, 16) } else { [long]$v })) }
# 进程 ID 会被复用：已知某一刻属于它的进程（或崩溃的程序），只认那一刻前后一分钟里记下的。按分钟建索引，查一条只要一次
function Add-AcaNear($index, $key, $t) { foreach ($m in -1, 0, 1) { $index["$key $($t.AddMinutes($m).ToString('yyyyMMddHHmm'))"] = 1 } }
function Test-AcaNear($index, $key, $t) { $index.ContainsKey("$key $($t.ToString('yyyyMMddHHmm'))") }
# 已知一段时间里都属于它的进程，这段时间里记下的都算
$spans = @{}
function Add-AcaSpan($p, $begin, $end) { if (-not $spans.ContainsKey($p)) { $spans[$p] = @() }; $spans[$p] += @{ From = $begin; To = $end } }
function Test-AcaSpan($p, $t) { $spans.ContainsKey($p) -and @($spans[$p] | Where-Object { $t -ge $_.From -and $t -le $_.To }).Count -gt 0 }
$near = @{}
$web = if ($dir) { $null } else { Get-AcaSite $name }
if ($web) {
  $pool = $web.applicationPool
  $system = @(foreach ($e in @(Read-AcaEvents System (Format-AcaQuery 'Microsoft-Windows-WAS' $window) $true)) { if (@(Get-AcaValues $e) -contains $pool) { $e } })
  foreach ($e in $system) { foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { if ($d.Name -eq 'ProcessID') { Add-AcaNear $near ([int]$d.'#text') $e.TimeCreated } } }
  $providers = 'ASP.NET 4.0.30319.0', 'ASP.NET 2.0.50727.0', 'IIS AspNetCore Module V2', 'IIS AspNetCore Module', '.NET Runtime', 'Application Error', 'Microsoft-Windows-IIS-W3SVC-WP'
  $procs = @(Get-WmiObject Win32_Process -Filter "Name='w3wp.exe'" | Where-Object { $_.CommandLine -match ('-ap "' + [regex]::Escape($pool) + '"') })
  # ASP.NET 和 ASP.NET Core 模块的事件里写着应用 ID 或配置路径；ASP.NET 的应用程序域是应用 ID 后面接 -<数字>-<数字>，
  # 要整段对上：/api 的后面接 -2-1-<数字> 的是应用 /api-2；更深一层的应用接的是 /
  $appId = '(?im)(^|[\s''"])(' + [regex]::Escape("/LM/W3SVC/$($web.id)/ROOT$($web.AppPath)") + '(-\d+-\d+)?([\s''"]|$)|' + [regex]::Escape("MACHINE/WEBROOT/APPHOST/$($web.name)$($web.AppPath)") + '[''"])'
  # 两样都没写的，ASP.NET Core 模块会写应用目录本身或目录里的文件（App: <目录>\App.dll）；更深一层的是子目录
  $rootFile = '(?i)' + [regex]::Escape("$(Get-AcaRoot $web)\") + '[^\\''"\r\n]*([''"\r\n]|$)'
} else {
  $svc = Get-AcaWmiService $name
  if (-not $svc) { throw "Windows service not found: $name" }
  $exe = Get-AcaExePath $svc.PathName
  # 服务控制管理器的事件里写的多是显示名，有的写服务名
  $display = $svc.DisplayName
  $system = @(foreach ($e in @(Read-AcaEvents System (Format-AcaQuery 'Service Control Manager' $window) $true)) { $v = @(Get-AcaValues $e); if ($v -contains $name -or $v -contains $display) { $e } })
  # 服务自己记的事件：ServiceBase 的 AutoLog 用服务名作来源，.NET 的 EventLog 日志默认用程序名
  $sources = $name, [IO.Path]::GetFileNameWithoutExtension((Get-AcaProgram $svc.PathName))
  $providers = @('.NET Runtime', 'Application Error') + $sources
  $procs = @(if ($svc.ProcessId) { Get-WmiObject Win32_Process -Filter "ProcessId=$($svc.ProcessId)" })
}
foreach ($p in $procs) { Add-AcaSpan ([int]$p.ProcessId) $p.ConvertToDateTime($p.CreationDate) ([datetime]::MaxValue) }
# 写着应用、来源是它、崩溃的是它的可执行文件（按完整路径，别的目录里同名的不算）就能认定，返回真假；认不出的不返回，再看是哪个进程记的
function Test-AcaOwn($e) {
  if ($web) {
    $text = @(Get-AcaValues $e) -join "`n"
    # 写着应用的只按应用认：共用应用池时，同一个进程里还跑着别的站点
    if ($text -match '/LM/W3SVC/\d+/ROOT|MACHINE/WEBROOT/APPHOST/') { return $text -match $appId }
    if ($text -match $rootFile) { return $true }
  } elseif ($sources -contains $e.ProviderName) { return $true }
  elseif ($e.ProviderName -eq 'Application Error') {
    if ("$($e.Properties[10].Value)" -ne $exe) { return $false }
    # 用 dotnet.exe 启动的，别的 .NET 程序崩溃时记的也是它：前后一分钟里服务控制管理器报了这个服务意外终止（7031、7034）的才算，其余再看是哪个进程
    if ((Get-AcaProgram $svc.PathName) -eq $exe -or @($system | Where-Object { (7031, 7034 -contains $_.Id) -and [Math]::Abs(($_.TimeCreated - $e.TimeCreated).TotalMinutes) -le 1 })) { return $true }
  }
}
if ($web) {
  # ASP.NET Core 进程外托管时，应用跑在 w3wp 起的后端进程里，它的崩溃不写应用。从模块报它启动，到报它关掉或 Application Error 报它崩溃，
  # 都算这个应用的；没有结束的记录，就看它现在还在不在，不在了只算启动后一分钟。它可能早在时间段之前就启动了，这些记录从头读
  $open = @{}
  function Close-AcaOpen($p, $t) { Add-AcaSpan $p $open[$p] $t; $open.Remove($p) }
  foreach ($e in @(Read-AcaEvents Application (Format-AcaQuery @('IIS AspNetCore Module V2', 'IIS AspNetCore Module', 'Application Error') @()) $false)) {
    if ($e.ProviderName -eq 'Application Error') {
      $p = Get-AcaEventPid $e
      if ($open.ContainsKey($p)) {
        # 模块报启动时进程早已建好；崩溃的进程建在那之后，就是进程 ID 被别的程序用上了：原来的后端进程在它启动前已经退出，这次崩溃不是它的
        $start = Get-AcaCrashStart $e
        Close-AcaOpen $p $(if ($start -le $open[$p]) { $e.TimeCreated } else { $start })
      }
      continue
    }
    $own = Test-AcaOwn $e
    $text = @(Get-AcaValues $e) -join "`n"
    if ($text -match "started process '(\d+)'") {
      $p = [int]$matches[1]
      # 别的应用的后端进程也用上了这个 ID，原来那个早已退出
      if ($open.ContainsKey($p)) { Close-AcaOpen $p $e.TimeCreated }
      if ($own) { $open[$p] = $e.TimeCreated }
    } elseif ($own -and $text -match "shut down process with Id '(\d+)'" -and $open.ContainsKey([int]$matches[1])) { Close-AcaOpen ([int]$matches[1]) $e.TimeCreated }
  }
  foreach ($p in @($open.Keys)) {
    $alive = @(Get-WmiObject Win32_Process -Filter "ProcessId=$p" | Where-Object { $_.ConvertToDateTime($_.CreationDate) -le $open[$p] })
    Add-AcaSpan $p $open[$p] $(if ($alive) { [datetime]::MaxValue } else { $open[$p].AddMinutes(1) })
  }
}
$candidates = @(foreach ($e in @(Read-AcaEvents Application (Format-AcaQuery @() $window) $true)) { if ($providers -contains $e.ProviderName) { @{ E = $e; Own = Test-AcaOwn $e; Pid = Get-AcaEventPid $e } } })
# 认定是它的事件也说明那一刻那个进程是它的，所以先认完一遍再按进程找
foreach ($c in $candidates) { if ($c.Own -and $null -ne $c.Pid) { Add-AcaNear $near $c.Pid $c.E.TimeCreated } }
$app = @(foreach ($c in $candidates) { if ($c.Own -or ($null -eq $c.Own -and $null -ne $c.Pid -and ((Test-AcaSpan $c.Pid $c.E.TimeCreated) -or (Test-AcaNear $near $c.Pid $c.E.TimeCreated)))) { $c.E } })
# 2019 及更早的系统上，.NET Runtime 这类经典事件不记进程 ID，按崩溃的程序名和时间对上认定了的 Application Error
$crashed = @{}
foreach ($e in $app) { if ($e.ProviderName -eq 'Application Error') { Add-AcaNear $crashed $e.Properties[0].Value $e.TimeCreated } }
$app += @(foreach ($c in $candidates) { if ($null -eq $c.Pid -and $null -eq $c.Own -and $c.E.ProviderName -eq '.NET Runtime' -and (Test-AcaNear $crashed ((("$($c.E.Properties[0].Value)" -split '\r?\n')[0]) -replace '^.*:\s*') $c.E.TimeCreated)) { $c.E } })
$shown = @($system + $app | Where-Object { $t = $_.TimeCreated.ToUniversalTime(); (-not $from -or $t -ge $from) -and (-not $to -or $t -lt $to) })
# 多取一条，用来判断还有没有更早的
$events = @($shown | Sort-Object TimeCreated, RecordId -Descending | Select-Object -First ($tail + 1))
$more = $events.Count -gt $tail
$events = @($events | Select-Object -First $tail)
[array]::Reverse($events)
$reach = foreach ($log in 'System', 'Application') {
  $first = Read-AcaEvents $log '*' $false | Select-Object -First 1
  "the $log log $(if ($first) { 'goes back to ' + $first.TimeCreated.ToString('yyyy-MM-dd HH:mm') } else { 'is empty' })"
}
"Times are the server's local time (UTC$((Get-Date).ToString('zzz'))); $($reach -join ', ')"
if (-not $events) { 'No events' + $(if ($since -or $until) { ' in the time range' }) }
if ($more) { "Showing the last $tail events$(if ($since -or $until) { ' in the time range' }); there may be earlier ones, raise -n to see them" }
$levels = @{ 1 = 'Critical'; 2 = 'Error'; 3 = 'Warning' }
$sb = New-Object Text.StringBuilder
foreach ($e in $events) {
  $level = $levels[[int]$e.Level]
  [void]$sb.AppendLine("$($e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))  $(if ($level) { $level } else { 'Information' })  $($e.ProviderName -replace '^Microsoft-Windows-') $($e.Id)")
  # 来源的消息资源没装（如卸掉了的 ASP.NET Core 模块）时拼不出正文，只有各个字段
  $text = $null
  try { $text = $e.FormatDescription() } catch [Diagnostics.Eventing.Reader.EventLogException] { }
  if (-not $text) { $text = @(Get-AcaValues $e) -join "`n" }
  foreach ($l in ($text.TrimEnd() -split '\r?\n')) { [void]$sb.AppendLine("  $($l.TrimEnd())") }
}
# 带调用栈的事件一条就有几 KB，经 OSS 回本机
Send-AcaEncrypted (New-Object IO.MemoryStream(, [Text.Encoding]::UTF8.GetBytes($sb.ToString()))) '__URL__' '__KEY__' '__IV__'
