$name = '__NAME__'
$dir = '__DIR__'
$work = Join-Path $env:TEMP '__WORK__'

$web = if ($dir) { $null } else { Get-AcaSite $name }
$root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot $web }
$passed = $false
try {
  # 包里的环境配置被 exclude 挡着不发（预检查保证了这一点），只把其中由构建决定的部分合进服务器上那份
  foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $work 'new') -File | Where-Object { Test-AcaEnvConfig $web $_.Name })) {
    $path = Join-Path $root $f.Name
    if (-not (Test-Path -LiteralPath $path)) { "NOTE: $($f.Name) is not on the server, and the package's copy is not deployed (it is in exclude)"; continue }
    $cfg = Read-AcaConfig $path
    if (-not $cfg) { "WARN $($f.Name) on the server is not UTF-8, so the parts that follow the build are not synced"; continue }
    try { $r = Sync-AcaConfig $cfg.Text ([IO.File]::ReadAllText($f.FullName)) } catch { "WARN $($f.Name) not synced: $($_.Exception.Message)"; continue }
    $changes = @($r.Lines | Where-Object { $_ -notmatch '^WARN ' })
    if ($changes) { "$($f.Name) follows the package in:"; $changes }
    $r.Lines | Where-Object { $_ -match '^WARN ' } | ForEach-Object { "WARN $($f.Name): $($_.Substring(5))" }
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
