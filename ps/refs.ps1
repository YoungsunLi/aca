$name = '__NAME__'
$dir = '__DIR__'
$checkOnly = '__CHECK_ONLY__' -eq 'true'
$force = '__FORCE__' -eq 'true'
$work = Join-Path $env:TEMP '__WORK__'
$exclude = [IO.File]::ReadAllLines("$work\exclude.txt")

# 按 .NET Framework 的规则检查发布后的样子：每个强名称引用都解析得到，服务器上装着包要的 .NET Framework，程序集的位数和进程对得上。
# 这些问题站点或服务往往照样启动，要等用到那段代码才报错，发布后的首页检查拦不住。.NET Core 的运行时由 check 查

function Get-AcaToken($an) { ([BitConverter]::ToString($an.GetPublicKeyToken()) -replace '-').ToLower() }
function Get-AcaIdentity($an) { New-Object psobject -Property @{ Version = $an.Version; Token = Get-AcaToken $an } }
# 从字节加载，不锁文件，站点在跑也能读；同一身份在一个进程里只能加载一次，非托管的 dll 加载不了，都跳过
function Read-AcaAssembly($bytes) {
  try { $asm = [Reflection.Assembly]::ReflectionOnlyLoad($bytes) } catch { return }
  $n = $asm.GetName()
  $pk = [Reflection.PortableExecutableKinds]
  $k = $pk::ILOnly; $m = [Reflection.ImageFileMachine]::I386
  $asm.ManifestModule.GetPEKind([ref]$k, [ref]$m)
  New-Object psobject -Property @{
    Name = $n.Name; Identity = Get-AcaIdentity $n; Refs = @($asm.GetReferencedAssemblies() | Where-Object { $_.GetPublicKeyToken() })
    # 只能在 32 位或只能在 64 位进程里加载的；混合模式（C++/CLI）的不是纯 IL，跟着 PE 的位数走
    Bits = $(if ($k -band $pk::PE32Plus) { 64 } elseif (($k -band $pk::Required32Bit) -or -not ($k -band $pk::ILOnly)) { 32 })
  }
}
# 可执行文件跑在几位的进程里。读 PE 头，不加载：新旧两份同名同版本时，同一个进程里加载不了第二份
function Get-AcaExeBits($path) {
  $b = [IO.File]::ReadAllBytes($path)
  $pe = [BitConverter]::ToInt32($b, 0x3C)
  if ([BitConverter]::ToUInt16($b, $pe + 24) -eq 0x20b) { return 64 }
  # PE32 的原生程序是 32 位；托管的看 CLR 头的 32BITREQUIRED：x86，或者和 32BITPREFERRED 一起表示 AnyCPU 勾了"首选 32 位"
  $clr = [BitConverter]::ToUInt32($b, $pe + 24 + 96 + 14 * 8)
  if (-not $clr) { return 32 }
  $table = $pe + 24 + [BitConverter]::ToUInt16($b, $pe + 20)
  for ($i = 0; $i -lt [BitConverter]::ToUInt16($b, $pe + 6); $i++) {
    $s = $table + 40 * $i
    $va = [BitConverter]::ToUInt32($b, $s + 12)
    if ($clr -ge $va -and $clr -lt $va + [BitConverter]::ToUInt32($b, $s + 8)) { if ([BitConverter]::ToUInt32($b, $clr - $va + [BitConverter]::ToUInt32($b, $s + 20) + 16) -band 2) { return 32 } }
  }
  64
}
function Get-AcaRedirects($x) {
  foreach ($da in @($x.SelectNodes("/configuration/runtime/*[local-name()='assemblyBinding']/*[local-name()='dependentAssembly']"))) {
    $id = $da.SelectSingleNode("*[local-name()='assemblyIdentity']")
    if (-not $id) { continue }
    $name = $id.GetAttribute('name'); $token = $id.GetAttribute('publicKeyToken').ToLower()
    foreach ($b in @($da.SelectNodes("*[local-name()='bindingRedirect']"))) {
      $low, $high = $b.GetAttribute('oldVersion') -split '-'
      New-Object psobject -Property @{ Name = $name; Token = $token; Low = [version]$low; High = [version]$(if ($high) { $high } else { $low }); New = [version]$b.GetAttribute('newVersion') }
    }
    # codeBase 指定了某个版本从哪里加载，那个版本就不在 bin 里找
    foreach ($cb in @($da.SelectNodes("*[local-name()='codeBase']"))) { New-Object psobject -Property @{ Name = $name; Token = $token; CodeBase = [version]$cb.GetAttribute('version') } }
  }
}
# 配置里带版本的类型名（configSections、system.codedom、DbProviderFactories 等）加载时同样按重定向解析
function Get-AcaConfigRefs($x) {
  foreach ($a in @($x.SelectNodes("//@*[not(ancestor::*[local-name()='runtime'])]"))) {
    foreach ($m in [regex]::Matches($a.Value, '([A-Za-z_][\w.]*)\s*,\s*Version=(\d+(?:\.\d+){3})(?:\s*,\s*Culture=[\w-]+)?\s*,\s*PublicKeyToken=([0-9a-fA-F]{16})')) {
      "$($m.Groups[1].Value)|$($m.Groups[2].Value)|$($m.Groups[3].Value.ToLower())"
    }
  }
}
function Test-AcaGac($name, $ver, $token) {
  [bool]@(Get-ChildItem "$env:windir\Microsoft.NET\assembly\GAC_*\$name\v4.0_${ver}__$token", "$env:windir\assembly\GAC*\$name\${ver}__$token" -ErrorAction SilentlyContinue)
}
# 返回空：找得到。第一条覆盖它的重定向说了算，同一个程序集写了两条时运行时只认第一条
function Resolve-AcaRef($r, $redirects, $bin) {
  $want = $r.Version
  $redirected = $false
  foreach ($x in @($redirects | Where-Object { $_.Low })) { if ($x.Name -eq $r.Name -and $x.Token -eq $r.Token -and $x.Low -le $r.Version -and $r.Version -le $x.High) { $want = $x.New; $redirected = $true; break } }
  $has = $bin[$r.Name]
  if ($has -and $has.Version -eq $want -and $has.Token -eq $r.Token) { return }
  if ((Test-AcaGac $r.Name $want $r.Token) -or @($redirects | Where-Object { $_.CodeBase -and $_.Name -eq $r.Name -and $_.Token -eq $r.Token -and $_.CodeBase -eq $want })) { return }
  # 框架程序集没被重定向时，运行时统一成它自己那一版
  if (-not $redirected -and (Test-Path -LiteralPath (Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "$($r.Name).dll"))) { return }
  if ($has) { "bin has $($has.Version)$(if ($has.Token -ne $r.Token) { " signed with another key" }), the reference resolves to $want" } else { 'absent' }
}
# 配置里要的 .NET Framework 版本：站点 compilation、httpRuntime 的 targetFramework，服务 startup 的 sku
function Get-AcaConfigTargets($x) {
  foreach ($a in @($x.SelectNodes("//*[local-name()='compilation' or local-name()='httpRuntime']/@targetFramework | //*[local-name()='supportedRuntime']/@sku"))) {
    if ($a.Value -match '(\d+(?:\.\d+)+)$') { "$($a.OwnerElement.LocalName) $($a.LocalName)|$($matches[1])" }
  }
}
# .NET Framework 4.5 起每个版本在注册表里 Release 值的下限
$acaReleases = [ordered]@{ '4.5' = 378389; '4.5.1' = 378675; '4.5.2' = 379893; '4.6' = 393295; '4.6.1' = 394254; '4.6.2' = 394802; '4.7' = 460798; '4.7.1' = 461308; '4.7.2' = 461808; '4.8' = 528040; '4.8.1' = 533320 }

$web = if ($dir) { $null } else { Get-AcaSite $name }
$root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot $web }
$passed = $false
try {
  # 运行时只在站点的 bin、服务的目录顶层找程序集，子目录里是附属资源或别的进程用的
  $sub = if ($web) { '\bin' } else { '' }
  $exe = if (-not $web) {
    $cmd = @(Get-WmiObject Win32_Service | Where-Object { $_.Name -eq $name })[0].PathName
    if ($cmd -match ('^"?' + [regex]::Escape($root) + '\\([^\\"]+?)\.exe')) { $matches[1] }
  }
  # 管绑定的是站点的 web.config、服务可执行文件的 .config
  $cfgName = if ($web) { 'web.config' } elseif ($exe) { "$exe.exe.config" }
  $beforeXml = New-Object xml
  try { if ($cfgName -and (Test-Path -LiteralPath "$root\$cfgName")) { $beforeXml.Load("$root\$cfgName") } else { $beforeXml.LoadXml('<configuration/>') } } catch {
    # 写坏了的配置运行时整个忽略
    "WARN $cfgName on the server is not valid XML, which the runtime ignores; references are checked as if it had no binding redirects"
    $beforeXml = New-Object xml
    $beforeXml.LoadXml('<configuration/>')
  }
  # 发布后生效的：排除了的是预检查合好的那份（没有要合的就还是服务器上那份），没排除的是整份发出去的包里那份
  $afterPath = if (-not $cfgName) { '' } elseif (Test-AcaExcluded $cfgName $exclude) { "$work\config\$cfgName" } else { "$work\new\$cfgName" }
  $afterXml = $beforeXml
  if ($afterPath -and (Test-Path -LiteralPath $afterPath)) { $afterXml = New-Object xml; $afterXml.Load($afterPath) }
  $broken = @(); $lacks = @()
  # check 认出发布后是 .NET Core 时留下它：.NET Core 按 deps.json 找程序集，目录里的高版本可以顶替引用的低版本，下面按 .NET Framework 的规则解析会误报
  if (-not (Test-Path -LiteralPath "$work\netcore")) {
    $before = @(Get-AcaRedirects $beforeXml)
    $after = @(Get-AcaRedirects $afterXml)
    $binBefore = @{}; $binAfter = @{}; $refs = @(); $targets = @(); $retained = @()
    $pkg = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath "$work\new$sub" -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(dll|exe)$' -and -not (Test-AcaExcluded $_.FullName.Substring($work.Length + 5) $exclude) })) {
      $bytes = [IO.File]::ReadAllBytes($f.FullName)
      $a = Read-AcaAssembly $bytes
      if (-not $a) { continue }
      # 和服务器上那份逐字节相同才算没变：重新编译过的，版本号没变，引用的也可能变了
      $old = "$root$sub\$($f.Name)"
      $a | Add-Member NoteProperty New (-not ((Test-Path -LiteralPath $old) -and (Get-AcaHash $bytes) -eq (Get-AcaHash ([IO.File]::ReadAllBytes($old)))))
      $pkg[$a.Name] = $a
      # 目标框架在字节里找：按反射读特性要加载特性类型所在的程序集，只按字节加载时往往找不到
      if ($a.New -and [Text.Encoding]::ASCII.GetString($bytes) -match '\.NETFramework,Version=v(\d+(?:\.\d+)+)') { $targets += New-Object psobject -Property @{ Version = $matches[1]; From = $f.Name } }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath "$root$sub" -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(dll|exe)$' })) {
      try { $n = [Reflection.AssemblyName]::GetAssemblyName($f.FullName) } catch { continue }
      $binBefore[$n.Name] = Get-AcaIdentity $n
      if ($pkg.ContainsKey($n.Name)) { continue }
      $binAfter[$n.Name] = $binBefore[$n.Name]
      $a = Read-AcaAssembly ([IO.File]::ReadAllBytes($f.FullName))
      if (-not $a) { continue }
      $retained += $a
      foreach ($r in $a.Refs) { $refs += New-Object psobject -Property @{ From = $a.Name; Name = $r.Name; Version = $r.Version; Token = Get-AcaToken $r; New = $false } }
    }
    foreach ($a in $pkg.Values) {
      $binAfter[$a.Name] = $a.Identity
      foreach ($r in $a.Refs) { $refs += New-Object psobject -Property @{ From = $a.Name; Name = $r.Name; Version = $r.Version; Token = Get-AcaToken $r; New = $a.New } }
    }
    $oldStrings = @(Get-AcaConfigRefs $beforeXml)
    foreach ($s in @(Get-AcaConfigRefs $afterXml | Select-Object -Unique)) {
      $n, $v, $t = $s -split '\|'
      $refs += New-Object psobject -Property @{ From = $cfgName; Name = $n; Version = [version]$v; Token = $t; New = $oldStrings -notcontains $s }
    }

    $absent = @()
    foreach ($r in $refs) {
      $why = Resolve-AcaRef $r $after $binAfter
      if (-not $why) { continue }
      $line = "$($r.From) -> $($r.Name) $($r.Version): $why"
      if ($r.New -and $why -eq 'absent') { $absent += $line }
      elseif ($r.New -or -not (Resolve-AcaRef $r $before $binBefore)) { $broken += $line }
    }
    $broken = @($broken | Select-Object -Unique)
    $absent | Select-Object -Unique | ForEach-Object { "WARN referenced by the package but found neither in $(if ($web) { 'bin' } else { 'the directory' }) nor in the GAC: $_" }

    # 进程的位数：站点看应用池，服务看可执行文件。这次发布换了可执行文件的位数，原来就在的程序集也要重新对一遍
    $exeAfter = if ($exe) { Get-AcaAfter "$exe.exe" "$work\new" $root $exclude }
    $bits = if ($web) { if ((Get-Item -LiteralPath "IIS:\AppPools\$($web.applicationPool)").enable32BitAppOnWin64) { 32 } else { 64 } } elseif ($exeAfter) { Get-AcaExeBits $exeAfter }
    $flipped = $exeAfter -and (Test-Path -LiteralPath "$root\$exe.exe") -and (Get-AcaExeBits "$root\$exe.exe") -ne $bits
    $wrong = @(@($pkg.Values) + $retained | Where-Object { ($_.New -or $flipped) -and $bits -and $_.Bits -and $_.Bits -ne $bits } | ForEach-Object Name)
    if ($wrong) { $lacks += "the $(if ($web) { 'app pool' } else { 'service' }) runs $bits-bit, but these load only in $(if ($bits -eq 32) { 64 } else { 32 })-bit: $($wrong -join ', ')" }
    # 这次发布带来的目标框架：变了的程序集编译时的目标，和配置里新写上的 targetFramework、sku
    $oldTargets = @(Get-AcaConfigTargets $beforeXml)
    foreach ($t in @(Get-AcaConfigTargets $afterXml | Where-Object { $oldTargets -notcontains $_ })) { $from, $v = $t -split '\|'; $targets += New-Object psobject -Property @{ Version = $v; From = "$cfgName $from" } }
    $release = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
    $need = @($targets | Where-Object { $acaReleases.Contains($_.Version) -and $release -lt $acaReleases[$_.Version] })
    if ($need) {
      $has = @($acaReleases.Keys | Where-Object { $release -ge $acaReleases[$_] })[-1]
      $lacks += ".NET Framework $(($need | Sort-Object { [version]$_.Version } | Select-Object -Last 1).Version), targeted by $(($need | ForEach-Object From | Select-Object -Unique | Select-Object -First 10) -join ', '): this server has $(if ($has) { $has } else { 'nothing from 4.5 on' })"
    }
  }

  $blocking = if ($checkOnly -and -not $force) { ' (deploying needs --force)' }
  if ($broken) { "References this deploy breaks${blocking}:"; $broken | ForEach-Object { "  $_" } }
  if ($lacks) { "This server lacks what the package needs${blocking}:"; $lacks | ForEach-Object { "  $_" } }
  if (-not $checkOnly -and -not $force) {
    if ($broken) { throw "$($broken.Count) references would fail to load after this deploy; fix the binding redirects in the package's $cfgName, or pass --force" }
    if ($lacks) { throw 'This server lacks what the package needs; install it on the server, or pass --force' }
  }
  if ($checkOnly) { 'CHECK OK (not deployed)' } else { 'Pre-check OK' }
  $passed = $true
} finally {
  if ($checkOnly -or -not $passed) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
