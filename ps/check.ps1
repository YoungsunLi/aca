$name = '__NAME__'
$dir = '__DIR__'
$checkOnly = '__CHECK_ONLY__' -eq 'true'
$force = '__FORCE__' -eq 'true'
$work = Join-Path $env:TEMP '__WORK__'
$exclude = [IO.File]::ReadAllLines("$work\exclude.txt")
$new = Join-Path $work 'new'

# 和宿主一样按 SemVer 比较 x.y.z[-预览号]：预览版低于同号的正式版；预览号逐段比，数字段按数值比、低于字母段，前面都相同时段多的高
function Compare-AcaSemver($a, $b) {
  $x, $xp = $a -split '-', 2
  $y, $yp = $b -split '-', 2
  $c = ([version]$x).CompareTo([version]$y)
  if ($c -or $xp -ceq $yp) { return $c }
  if (-not $xp) { return 1 }
  if (-not $yp) { return -1 }
  $xs = $xp -split '\.'
  $ys = $yp -split '\.'
  for ($i = 0; $i -lt $xs.Count -and $i -lt $ys.Count; $i++) {
    $p = $xs[$i]
    $q = $ys[$i]
    $c = if ($p -match '^\d+$' -and $q -match '^\d+$') { ([long]$p).CompareTo([long]$q) } elseif ($p -match '^\d+$') { -1 } elseif ($q -match '^\d+$') { 1 } else { [string]::CompareOrdinal($p, $q) }
    if ($c) { return $c }
  }
  $xs.Count.CompareTo($ys.Count)
}
# runtimeconfig.json 要的共享框架里，服务器上按前滚规则找不到的。只能估计：应用跑在几位上、环境变量里的 DOTNET_ROOT、
# DOTNET_ROLL_FORWARD 都会改变宿主去哪找、认哪个版本，aca 看不全，所以 32 位、64 位两份 dotnet 有一份装着就算，找不到也只提示
function Get-AcaMissingFrameworks($json, $dotnets) {
  $o = ($json | ConvertFrom-Json).runtimeOptions
  # 旧写法 rollForwardOnNoCandidateFx：0 只前滚补丁号，1 前滚次版本号，2 前滚主版本号
  $legacy = @{ '0' = 'LatestPatch'; '1' = 'Minor'; '2' = 'Major' }
  foreach ($fx in @(@($o.framework) + @($o.frameworks) | Where-Object { $_ })) {
    $policy = @($fx.rollForward, $o.rollForward, $legacy["$($fx.rollForwardOnNoCandidateFx)"], $legacy["$($o.rollForwardOnNoCandidateFx)"], 'Minor' | Where-Object { $_ })[0]
    $want = [version]($fx.version -replace '-.*')
    # 宿主先挑正式版，没有合用的才用预览版，所以两种都算
    $have = @(Get-ChildItem -LiteralPath @($dotnets | ForEach-Object { "$_\shared\$($fx.name)" }) -Directory -ErrorAction SilentlyContinue | ForEach-Object Name | Where-Object { $_ -match '^\d+\.\d+\.\d+(-.+)?$' } | Sort-Object { [version]($_ -replace '-.*') }, { $_ } -Unique)
    $ok = @($have | Where-Object {
      $v = [version]($_ -replace '-.*')
      $c = Compare-AcaSemver $_ $fx.version
      $c -ge 0 -and $(if ($policy -eq 'Disable') { $c -eq 0 } elseif ($policy -eq 'LatestPatch') { $v.Major -eq $want.Major -and $v.Minor -eq $want.Minor } elseif ($policy -match 'Major$') { $true } else { $v.Major -eq $want.Major })
    })
    if (-not $ok) { "$($fx.name) $($fx.version)$(if ($policy -ne 'Minor') { " (rollForward $policy)" }); this server has $(if ($have) { $have -join ', ' } else { 'none' })" }
  }
}
# 单文件发布的 runtimeconfig.json 打包在 exe 里：apphost 里这段签名（base64）前面 8 字节是包头的位置，不是单文件的是 0。
# 包头依次是主版本、次版本、文件数、bundle ID（一个字节的长度加内容），.NET 5（主版本 2）起接着是 deps.json、runtimeconfig.json 各自的位置和长度；
# runtimeconfig.json 不压缩
function Read-AcaBundled($path) {
  $b = [IO.File]::ReadAllBytes($path)
  $l = [Text.Encoding]::GetEncoding(28591)
  $i = $l.GetString($b).IndexOf($l.GetString([Convert]::FromBase64String('ixICuWphIDhye5MCFNegMhP1uebvrjMY7jstziSzaq4=')), [StringComparison]::Ordinal)
  if ($i -lt 8) { return }
  $h = [BitConverter]::ToInt64($b, $i - 8)
  if (-not $h -or [BitConverter]::ToUInt32($b, $h) -lt 2) { return }
  $p = $h + 13 + $b[$h + 12]
  [Text.Encoding]::UTF8.GetString($b, [BitConverter]::ToInt64($b, $p + 16), [BitConverter]::ToInt64($b, $p + 24)).TrimStart([char]0xFEFF)
}
# 生效的 runtimeconfig.json，$of 给出文件在哪：从 apphost 启动的单文件发布打包在 exe 里；
# 其余的在旁边，dotnet 启动 App.dll 时目录里留着以前单文件发布的 App.exe 也不算
function Read-AcaRuntimeConfig($app, $apphost, $of) {
  $exe = if ($apphost) { & $of "$app.exe" }
  $json = & $of "$app.runtimeconfig.json"
  $t = if ($exe) { Read-AcaBundled $exe }
  if ($t) { $t } elseif ($json) { [IO.File]::ReadAllText($json) }
}
# 发布后是 .NET Core 的：站点的 web.config 在根路径上配了 aspNetCore，服务跑的程序带着 runtimeconfig.json。
# 是的话留下 netcore，再列出包要的共享框架里服务器上找不到的
function Invoke-AcaCoreCheck($web, $name, $root, $new, $exclude, $work) {
  if ($web) {
    $x = New-Object xml
    $cfg = Get-AcaAfter 'web.config' $new $root $exclude
    # 合并环境配置不动 aspNetCore，看发出去的那份或服务器上那份就行；写坏了的由 analyze、refs 报
    if ($cfg) { try { $x.Load($cfg) } catch { } }
    $handler = Get-AcaCoreHandler $x
    if ($handler) {
      # processPath 是 apphost（.\App.exe），或者是 dotnet、arguments 里是 .\App.dll
      $pp = [Environment]::ExpandEnvironmentVariables($handler.GetAttribute('processPath'))
      $apphost = $pp -match '([^\\/]+)\.exe$' -and $matches[1] -ne 'dotnet'
      $app = if ($apphost) { $matches[1] } elseif ($handler.GetAttribute('arguments') -match '([^\\/\s"]+)\.dll') { $matches[1] }
    }
  } else {
    $cmd = (Get-AcaWmiService $name).PathName
    $pp = Get-AcaExePath $cmd
    if ((Get-AcaProgram $cmd) -match ('^' + [regex]::Escape($root) + '\\([^\\]+)\.(exe|dll)$')) {
      $app = $matches[1]
      $apphost = $matches[2] -eq 'exe'
    }
  }
  $rc = if ($app) { Read-AcaRuntimeConfig $app $apphost { param($rel) Get-AcaAfter $rel $new $root $exclude } }
  if (-not ($handler -or $rc)) { return }
  # refs 看到它就不按 .NET Framework 的规则查引用：.NET Core 按 deps.json 找程序集，目录里的高版本可以顶替引用的低版本，按那套规则会误报
  New-Item -ItemType File -Path "$work\netcore" | Out-Null
  # 和服务器上那份一样的，要的运行时原来就要，不是这次发布带来的
  if ($rc -and $rc -cne (Read-AcaRuntimeConfig $app $apphost { param($rel) if (Test-Path -LiteralPath "$root\$rel") { "$root\$rel" } })) {
    # 站点的 processPath、服务的命令行写了 dotnet.exe 的完整路径，共享框架就只在它旁边找
    $dotnets = if ($pp -match '\\dotnet\.exe$' -and [IO.Path]::IsPathRooted($pp)) { Split-Path $pp } else { "$env:ProgramFiles\dotnet", "${env:ProgramFiles(x86)}\dotnet" }
    Get-AcaMissingFrameworks $rc $dotnets | ForEach-Object { "WARN $app.runtimeconfig.json in the package asks for $_" }
  }
}

$passed = $false
try {
  # 包已经由 fetch 解开，找不到目标时也要删掉它
  $web = if ($dir) { $null } else { Get-AcaSite $name }
  $root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot $web }
  $base = Get-AcaBase $web $root
  $label = if ($web) { 'home' } else { 'service' }
  # 包里文件名的 [ ] 会被当通配符，按路径操作的命令都用 -LiteralPath
  $all = @(Get-ChildItem -LiteralPath $new -Recurse -File)
  # 全量构建的包会带上 exclude 里的文件，不能覆盖
  $files = @($all | Where-Object { -not (Test-AcaExcluded $_.FullName.Substring($new.Length + 1) $exclude) })
  if ($files.Count -lt $all.Count) { "Excluded $($all.Count - $files.Count) files ($($exclude -join ', '))" }
  $excluded = @($all | ForEach-Object { $_.FullName.Substring($new.Length + 1) } | Where-Object { Test-AcaExcluded $_ $exclude })
  # 构建新加在 exclude 路径下的文件不会发出去，服务器上就一直没有；服务器上没有环境配置由 analyze 提示
  $hidden = @($excluded | Where-Object { -not (Test-AcaEnvConfig $web $_) -and -not (Test-Path -LiteralPath (Join-Path $root $_)) })
  if ($hidden) { "NOTE: new files under excluded paths are not deployed: $(($hidden | Select-Object -First 20) -join ', ')" }
  # 被排除的文件包里那份和上次发布时的不一样，是开发改过它，服务器上那份可能也得跟着改
  $last = @(Get-AcaBackups $base)[-1]
  $was = if ($last) { (Read-AcaManifest $last.FullName).Excluded } else { @{} }
  $changed = @($excluded | Where-Object { $was[$_] -and $was[$_] -ne (Get-AcaFileHash (Join-Path $new $_)) })
  if ($changed) { "NOTE: excluded files changed in the package since the last deploy, the server's copies may need the same change: $(($changed | Select-Object -First 20) -join ', ')" }
  if (-not $files) { throw 'Package is empty' }
  $rels = @($files | ForEach-Object { $_.FullName.Substring($new.Length + 1) })
  $src = @($rels | Where-Object { $_ -match '^(\.git|\.vs|obj|node_modules)\\|\.(csproj|sln|cs)$' })
  if ($src) { throw "Package looks like a source directory, not publish output, e.g. $($src[0..2] -join ', ')" }
  if ($rels -contains 'aca-manifest.txt') { throw 'Package root contains aca-manifest.txt, which would overwrite the backup manifest of the same name; remove it from the package' }
  if (@($rels | Where-Object { $_.StartsWith('.aca-') })) { throw 'Package has a top-level path starting with .aca-, a prefix the backup manifest keeps for its own records; remove it from the package' }
  $rootTop = @(Get-ChildItem -LiteralPath $root | ForEach-Object Name)
  $pkgTop = @($rels | ForEach-Object { ($_ -split '\\')[0] } | Select-Object -Unique)
  if ($rootTop -and -not @($pkgTop | Where-Object { $rootTop -contains $_ })) {
    throw "Package top level ($($pkgTop -join ', ')) shares nothing with the top level of $root; wrong target?"
  }

  $added = @($rels | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
  "$name -> $root  $($rels.Count) files in package: $($rels.Count - $added.Count) to overwrite, $($added.Count) new"
  $addedDll = @($added | Where-Object { $_ -match '\.dll$' })
  if ($addedDll) { "New DLLs (not there yet; either new dependencies or the wrong target): $(($addedDll | Select-Object -First 20) -join ', ')" }
  # 只提示不拦：有的站点本来就要发 source map
  $maps = @($rels | Where-Object { $_ -match '\.map$' })
  if ($maps) { "Source maps in package, which can reveal the original source: $(($maps | Select-Object -First 20) -join ', ')" }
  if ($added) { "New files: $(($added | Select-Object -First 20) -join ', ')" }
  $newest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  "Newest file in package: $($newest.FullName.Substring($new.Length + 1))  $($newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
  Assert-AcaDiskSpace $root $files $rels $added
  $older = @(Get-AcaOlderFiles $root $files $rels $added)
  if ($older) { "Files older than the copies on the server$(if ($checkOnly -and -not $force) { ' (deploying needs --force)' }): $(($older | Select-Object -First 20) -join ', ')" }
  Invoke-AcaCoreCheck $web $name $root $new $exclude $work
  $before = Get-AcaHealth $web $name 1
  "$label now: $before"
  if (-not $web) { [void](Test-AcaServiceRunning $before $name) }
  # 只预检查时只提示不拦：每台服务器上旧的文件都列出来，再决定要不要 --force
  if ($older -and -not $force -and -not $checkOnly) { throw "$($older.Count) files in the package are older than the copies on the server; pass --force to overwrite them anyway" }
  $passed = $true
} finally {
  # 通过了就留着解开的包：预检查的下一步 analyze 还要用
  if (-not $passed) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($web) {
  $pool = $web.applicationPool
  # 站点的根应用和站点下的应用都可能用着这个应用池
  $shared = @(Get-Website | ForEach-Object {
    $s = $_.name
    if ($_.applicationPool -eq $pool) { $s }
    Get-WebApplication -Site $s | Where-Object { $_.applicationPool -eq $pool } | ForEach-Object { "$s$($_.path)" }
  } | Where-Object { $_ -ne $name })
  if ($shared) { "NOTE: app pool $pool is shared with $($shared -join ', '), which will also be down for a few seconds" }
}
