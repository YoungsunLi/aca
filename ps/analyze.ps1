$name = '__NAME__'
$dir = '__DIR__'
$work = Join-Path $env:TEMP '__WORK__'
$exclude = [IO.File]::ReadAllLines("$work\exclude.txt")
$overwrite = '__OVERWRITE_CONFIG__' -eq 'true'
$new = Join-Path $work 'new'

$web = if ($dir) { $null } else { Get-AcaSite $name }
$root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot $web }
$passed = $false
try {
  $configs = @(Get-ChildItem -LiteralPath $new -File | Where-Object { Test-AcaEnvConfig $web $_.Name })
  # 没排除的会整份覆盖服务器上那份，只放行两种：配了 overwriteConfig；ASP.NET Core 的 web.config，它不放环境值
  foreach ($f in @($configs | Where-Object { -not (Test-AcaExcluded $_.Name $exclude) })) {
    # 服务没配 overwriteConfig 怎样都拦，不用读
    $x = if ($overwrite -or $web) { try { Read-AcaXml ([IO.File]::ReadAllText($f.FullName)) } catch { throw "$($f.Name) in the package is not valid XML: $($_.Exception.Message)" } }
    if (-not $overwrite -and -not ($x -and (Get-AcaCoreHandler $x))) { throw "Package root contains $($f.Name), which would overwrite the environment config on the server; add it to exclude in the aca config, or set overwriteConfig if the package's copy suits every server" }
    # 包里这份是刚生成的，总比服务器上那份新，"比服务器旧"的检查认不出有人在服务器上改过它
    $path = Join-Path $root $f.Name
    if ((Test-Path -LiteralPath $path) -and [IO.File]::ReadAllText($path) -cne [IO.File]::ReadAllText($f.FullName)) { "NOTE: $($f.Name) on the server differs from the package's copy, which replaces it whole: settings added on the server will be lost" }
  }
  # 被 exclude 挡着不发的，只把其中由构建决定的部分合进服务器上那份
  foreach ($f in @($configs | Where-Object { Test-AcaExcluded $_.Name $exclude })) {
    $path = Join-Path $root $f.Name
    if (-not (Test-Path -LiteralPath $path)) { "NOTE: $($f.Name) is not on the server, and the package's copy is not deployed (it is in exclude)"; continue }
    $cfg = Read-AcaConfig $path
    if (-not $cfg) { "WARN $($f.Name) on the server is not UTF-8, so the parts that follow the build are not synced"; continue }
    $pkgText = [IO.File]::ReadAllText($f.FullName)
    try { $r = Sync-AcaConfig $cfg.Text $pkgText } catch { "WARN $($f.Name) not synced: $($_.Exception.Message)"; continue }
    $changes = @($r.Lines | Where-Object { $_ -notmatch '^WARN ' })
    if ($changes) { "$($f.Name) follows the package in:"; $changes }
    $r.Lines | Where-Object { $_ -match '^WARN ' } | ForEach-Object { "WARN $($f.Name): $($_.Substring(5))" }
    $missing = @(Get-AcaMissing $r.Text $pkgText)
    if ($missing) { "NOTE: $($f.Name) on the server lacks these from the package's copy; add them there if the new build reads them: $($missing -join '; ')" }
    if (-not $changes) { continue }
    # 引用检查按它解析，发布那一步拿它换掉服务器上那份；记下合并时读到的那份的哈希，到时对不上就是这之后有人改过
    $dst = Join-Path $work 'config'
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dst $f.Name), $r.Text, $cfg.Encoding)
    Set-Content -LiteralPath (Join-Path $dst "$($f.Name).base") -Value $cfg.Hash
  }
  $passed = $true
} finally {
  if (-not $passed) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
