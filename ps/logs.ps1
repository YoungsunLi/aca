$name = '__NAME__'
$tail = [int]'__TAIL__'
$since = '__SINCE__'
$until = '__UNTIL__'
# 一天的日志能有上百 MB，时间段在文件末尾时要从头读完，别跟 IIS 的工作进程抢 CPU
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
$web = Get-AcaSite $name
# 应用和站点记在同一个日志里，只取应用路径下的请求，再去掉更深一层的应用（/api 下的 /api/v2）；W3C 日志里路径的空格写成 +
$appPrefix = "$($web.AppPath)/" -replace ' ', '+'
$inner = @(if ($web.AppPath) { Get-WebApplication -Site $web.name | Where-Object { $_.path.StartsWith("$($web.AppPath)/", 'OrdinalIgnoreCase') } | ForEach-Object { "$($_.path)/" -replace ' ', '+' } })
$central = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter system.applicationHost/log -Name centralLogFileMode
if ($central -ne 'Site') { throw "IIS on this server writes one log for all sites (centralLogFileMode $central); aca logs reads per-site logs only" }
if ($web.logFile.logFormat -ne 'W3C') { throw "Site $name writes $($web.logFile.logFormat) logs; aca logs reads W3C logs only" }
$dir = Join-Path ([Environment]::ExpandEnvironmentVariables($web.logFile.directory)) "W3SVC$($web.id)"
# 关了日志的站点目录里只剩关之前的文件。IIS 管理器里"禁用"日志改的是 dontLog，logFile.enabled 还是 True；
# logTargetW3C 是 IIS 8.5 才有的，只记到 ETW 时也不写文件
$target = $web.logFile.logTargetW3C
if (-not $web.logFile.enabled -or ($target -and $target -notmatch 'File') -or (Get-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST/$name" -Filter system.webServer/httpLogging -Name dontLog).Value) {
  'WARN: IIS logging is off for this site, so its log stops where logging was turned off'
}
# HTTP.sys 攒满缓冲区或过一分钟才写盘，不刷的话刚发生的请求还不在文件里
netsh http flush logbuffer | Out-Null
if ($LASTEXITCODE) { 'WARN: could not flush the IIS log buffer; requests from the last minute may be missing' }
# 按创建时间排：正在写的文件，修改时间停在它第一次写入的时候。从没记过日志的站点还没有这个目录
$files = @(if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -Filter *.log | Sort-Object CreationTime -Descending })
$chunks = @()
$names = @()
$left = $tail
# 从新到旧，每个文件取时间段里最后 $left 行，凑够 $tail 行为止
foreach ($f in $files) {
  $lines = New-Object 'Collections.Generic.Queue[string]'
  # 每行对应的 #Fields：改过记录的字段，前后的行列就不一样
  $heads = New-Object 'Collections.Generic.Queue[string]'
  $fields = ''
  $first = ''
  # 正在写的日志：要允许 HTTP.sys 接着写
  $reader = New-Object IO.StreamReader([IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite, Delete'), [Text.Encoding]::UTF8)
  try {
    :read while ($null -ne ($line = $reader.ReadLine())) {
      if ($line.StartsWith('#')) {
        if ($line.StartsWith('#Fields:')) {
          if (($since -or $until) -and -not $line.StartsWith('#Fields: date time ')) { throw "$($f.FullName) does not start its lines with date and time, so aca logs cannot pick them by time: $line" }
          $fields = $line
          $uri = [array]::IndexOf($line.Substring(9).Split(' '), 'cs-uri-stem')
          if ($web.AppPath -and $uri -lt 0) { throw "$($f.FullName) does not log cs-uri-stem, so aca logs cannot pick the requests of ${name}: $line" }
        }
        continue
      }
      if (-not $first) { $first = $line }
      # 日志里的时间是 UTC，$since、$until 在本机换算好了，和行首的 date time 按字符比
      if ($since -and [string]::CompareOrdinal($line, 0, $since, 0, 19) -lt 0) { continue }
      if ($until -and [string]::CompareOrdinal($line, 0, $until, 0, 19) -gt 0) { break }
      if ($web.AppPath) {
        $u = $line.Split(' ')[$uri] + '/'
        if (-not $u.StartsWith($appPrefix, 'OrdinalIgnoreCase')) { continue }
        foreach ($i in $inner) { if ($u.StartsWith($i, 'OrdinalIgnoreCase')) { continue read } }
      }
      $lines.Enqueue($line)
      $heads.Enqueue($fields)
      if ($lines.Count -gt $left) { [void]$lines.Dequeue(); [void]$heads.Dequeue() }
    }
  } finally { $reader.Close() }
  if ($lines.Count) {
    $left -= $lines.Count
    $names = @($f.Name) + $names
    $sb = New-Object Text.StringBuilder
    $shown = ''
    while ($lines.Count) {
      $head = $heads.Dequeue()
      if ($head -ne $shown) { [void]$sb.AppendLine($head); $shown = $head }
      [void]$sb.AppendLine($lines.Dequeue())
    }
    $chunks = @($sb.ToString()) + $chunks
  }
  # 这个文件在时间段开始前就在写，更早的文件里不会再有
  if (-not $left -or ($since -and $first -and [string]::CompareOrdinal($first, 0, $since, 0, 19) -lt 0)) { break }
}
if ($names) { "Log files in $dir, times in UTC: $($names -join ', ')" }
else { 'No log lines' + $(if ($since -or $until) { ' in the time range' }) + " in $dir" }
if (($since -or $until) -and -not $left) { "Showing the last $tail lines in the time range; there may be earlier ones, raise -n to see them" }
# 几百行就超过云助手的输出上限，经 OSS 回本机
Send-AcaEncrypted (New-Object IO.MemoryStream(, [Text.Encoding]::UTF8.GetBytes($chunks -join ''))) '__URL__' '__KEY__' '__IV__'
