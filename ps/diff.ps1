$name = '__NAME__'
$dir = '__DIR__'
$sub = '__SUBPATH__'
$exclude = @('__EXCLUDE__' -split "`n" | Where-Object { $_ })
# 站点在跑，别跟 IIS 的工作进程抢 CPU：读几 GB、边读边算哈希要跑几分钟
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
$web = if ($dir) { $null } else { Get-AcaSite $name }
$root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot $web }
# 相对路径始终按站点或服务的目录算，比一个子目录时报出来的路径和 exclude 才对得上
$scope = if ($sub) { Join-Path $root $sub } else { $root }
# 指定的目录本身或它上面哪一层是目录联接，整段路径就可能指到站点目录外面去
$walk = $root
foreach ($seg in @($sub -split '\\' | Where-Object { $_ })) {
  $walk = Join-Path $walk $seg
  if ((Get-Item -LiteralPath $walk -Force -ErrorAction SilentlyContinue).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$walk is a junction, which aca diff does not follow" }
}
# 自己往下走，exclude 的目录不进去：排掉的多是上传、日志目录，文件多，有的还不让枚举。
# -Force 是为了隐藏文件：漏掉一个不一样的，两台服务器就被报成一样的
function Get-AcaFiles($path) {
  foreach ($item in Get-ChildItem -LiteralPath $path -Force) {
    if (Test-AcaExcluded $item.FullName.Substring($root.Length + 1) $exclude) { continue }
    if (-not $item.PSIsContainer) { $item }
    # 目录联接可能指回上层目录，跟着走就绕不出来了
    elseif (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Get-AcaFiles $item.FullName }
  }
}
# 这台服务器上没有指定的这个目录或文件，多半就是漏发了：当成全缺，交给本机比对，不是错误
$files = if ($sub -and -not (Test-Path -LiteralPath $scope)) { @() } else { @(Get-AcaFiles $scope) }
# 服务的程序集和它天天写的日志在同一个目录里，日志各台服务器本来就不一样
if (-not $web) { $files = @($files | Where-Object { $_.Extension -match '^\.(dll|exe)$' }) }
$sha = [Security.Cryptography.SHA256]::Create()
$list = New-Object Text.StringBuilder
foreach ($f in $files) {
  # 站点在跑，文件正被 IIS 或服务占着
  $in = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite, Delete')
  try { $hash = [BitConverter]::ToString($sha.ComputeHash($in)) -replace '-' } finally { $in.Close() }
  [void]$list.AppendLine($f.FullName.Substring($root.Length + 1) + '|' + $hash + '|' + $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
}
# 清单有几百 KB，超过云助手的输出上限，经 OSS 回本机比对
Send-AcaEncrypted (New-Object IO.MemoryStream(, [Text.Encoding]::UTF8.GetBytes($list.ToString()))) '__URL__' '__KEY__' '__IV__'
"$scope|$($files.Count)|$(($files | Measure-Object Length -Sum).Sum)"
