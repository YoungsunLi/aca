# 每个目标一行，tab 分隔：序号、状态、最新文件的时间、最后一条发布记录；查不了的目标是 序号、ERROR: 原因。
# 按序号而不按名字对应：输出按服务器的代码页回传，代码页外的字符会变成问号
$targets = @('__TARGETS__' -split "`n")
for ($i = 0; $i -lt $targets.Count; $i++) {
  $name, $dir = $targets[$i] -split "`t"
  try {
    $web = if ($dir) { $null } else { Get-AcaSite $name }
    $root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot $web }
    # 站点开着不等于应用池开着：应用池里的程序接连崩溃，IIS 会停掉应用池
    $state = if (-not $web) { [string](Get-AcaService $name).Status } elseif ($web.State -ne 'Started') { $web.State } else {
      $pool = (Get-WebAppPoolState -Name $web.applicationPool).Value
      if ($pool -eq 'Started') { 'Started' } else { "Started, app pool $pool" }
    }
    $newest = Get-AcaNewestFile $web $root
    $log = "$root.aca-log.txt"
    $last = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Select-Object -Last 1 }
    # 按 tab 分列、按换行分行：-m 里写得进 tab，异常信息里可能有换行
    "$i`t$state`t$(if ($newest) { $newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm') })`t$($last -replace "`t", ' ')"
  } catch { "$i`tERROR: $($_.Exception.Message -replace '\s+', ' ')" }
}
