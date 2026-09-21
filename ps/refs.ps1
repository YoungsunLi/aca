$name = '__NAME__'
$dir = '__DIR__'
$checkOnly = '__CHECK_ONLY__' -eq 'true'
$force = '__FORCE__' -eq 'true'
$exclude = @('__EXCLUDE__' -split "`n" | Where-Object { $_ })
$work = Join-Path $env:TEMP '__WORK__'

# 按运行时的规则把发布后每个强名称引用解析一遍：这次发布让原来找得到的引用找不到了，或者新代码引用的版本 bin 里没有，
# 站点或服务往往照样启动，要等用到那段代码才报错，发布后的首页检查拦不住

function Get-AcaToken($an) { ([BitConverter]::ToString($an.GetPublicKeyToken()) -replace '-').ToLower() }
function Get-AcaIdentity($an) { New-Object psobject -Property @{ Version = $an.Version; Token = Get-AcaToken $an } }
# 从字节加载，不锁文件，站点在跑也能读；同一身份在一个进程里只能加载一次，非托管的 dll 加载不了，都跳过
function Read-AcaAssembly($bytes) {
  try { $asm = [Reflection.Assembly]::ReflectionOnlyLoad($bytes) } catch { return }
  $n = $asm.GetName()
  New-Object psobject -Property @{ Name = $n.Name; Identity = Get-AcaIdentity $n; Refs = @($asm.GetReferencedAssemblies() | Where-Object { $_.GetPublicKeyToken() }) }
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
  # 可执行文件旁边有同名 runtimeconfig.json 的服务是 .NET Core：按 deps.json 找程序集，目录里的高版本可以顶替引用的低版本，
  # 下面按 .NET Framework 的规则解析会误报。.NET Core 的站点没有 bin，本来就查不到
  $rc = "$exe.runtimeconfig.json"
  $core = $exe -and ((Test-Path -LiteralPath "$root\$rc") -or ((Test-Path -LiteralPath "$work\new\$rc") -and -not (Test-AcaExcluded $rc $exclude)))
  if (-not $core) {
    $beforeXml = New-Object xml
    try { if ($cfgName -and (Test-Path -LiteralPath "$root\$cfgName")) { $beforeXml.Load("$root\$cfgName") } else { $beforeXml.LoadXml('<configuration/>') } } catch {
      # 写坏了的配置运行时整个忽略
      "WARN $cfgName on the server is not valid XML, which the runtime ignores; references are checked as if it had no binding redirects"
      $beforeXml = New-Object xml
      $beforeXml.LoadXml('<configuration/>')
    }
    $afterXml = $beforeXml
    if ($cfgName -and (Test-Path -LiteralPath "$work\config\$cfgName")) { $afterXml = New-Object xml; $afterXml.Load("$work\config\$cfgName") }
    $before = @(Get-AcaRedirects $beforeXml)
    $after = @(Get-AcaRedirects $afterXml)

    $binBefore = @{}; $binAfter = @{}; $refs = @()
    $pkg = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath "$work\new$sub" -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(dll|exe)$' -and -not (Test-AcaExcluded $_.FullName.Substring($work.Length + 5) $exclude) })) {
      $bytes = [IO.File]::ReadAllBytes($f.FullName)
      $a = Read-AcaAssembly $bytes
      if (-not $a) { continue }
      # 和服务器上那份逐字节相同才算没变：重新编译过的，版本号没变，引用的也可能变了
      $old = "$root$sub\$($f.Name)"
      $a | Add-Member NoteProperty New (-not ((Test-Path -LiteralPath $old) -and (Get-AcaHash $bytes) -eq (Get-AcaHash ([IO.File]::ReadAllBytes($old)))))
      $pkg[$a.Name] = $a
    }
    foreach ($f in @(Get-ChildItem -LiteralPath "$root$sub" -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(dll|exe)$' })) {
      try { $n = [Reflection.AssemblyName]::GetAssemblyName($f.FullName) } catch { continue }
      $binBefore[$n.Name] = Get-AcaIdentity $n
      if ($pkg.ContainsKey($n.Name)) { continue }
      $binAfter[$n.Name] = $binBefore[$n.Name]
      $a = Read-AcaAssembly ([IO.File]::ReadAllBytes($f.FullName))
      if ($a) { foreach ($r in $a.Refs) { $refs += New-Object psobject -Property @{ From = $a.Name; Name = $r.Name; Version = $r.Version; Token = Get-AcaToken $r; New = $false } } }
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

    $broken = @(); $absent = @()
    foreach ($r in $refs) {
      $why = Resolve-AcaRef $r $after $binAfter
      if (-not $why) { continue }
      $line = "$($r.From) -> $($r.Name) $($r.Version): $why"
      if ($r.New -and $why -eq 'absent') { $absent += $line }
      elseif ($r.New -or -not (Resolve-AcaRef $r $before $binBefore)) { $broken += $line }
    }
    $broken = @($broken | Select-Object -Unique)
    $absent | Select-Object -Unique | ForEach-Object { "WARN referenced by the package but found neither in $(if ($web) { 'bin' } else { 'the directory' }) nor in the GAC: $_" }
    if ($broken) {
      "References this deploy breaks$(if ($checkOnly -and -not $force) { ' (deploying needs --force)' }):"
      $broken | ForEach-Object { "  $_" }
      if (-not $checkOnly -and -not $force) { throw "$($broken.Count) references would fail to load after this deploy; fix the binding redirects in the package's $cfgName, or pass --force" }
    }
  }
  if ($checkOnly) { 'CHECK OK (not deployed)' } else { 'Pre-check OK' }
  $passed = $true
} finally {
  if ($checkOnly -or -not $passed) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
