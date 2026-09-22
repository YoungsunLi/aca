$name = '__NAME__'
$dir = '__DIR__'
$deployId = '__DEPLOY_ID__'
$package = '__PACKAGE__'
$sha256 = '__SHA256__'
$message = '__MESSAGE__'
$keep = [int]'__KEEP__'
$force = '__FORCE__' -eq 'true'
$exclude = @('__EXCLUDE__' -split "`n" | Where-Object { $_ })

$web = if ($dir) { $null } else { Get-AcaSite $name }
$root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot $web }
$base = Get-AcaBase $web $root
$label = if ($web) { 'home' } else { 'service' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$work = Join-Path $env:TEMP '__WORK__'
$new = Join-Path $work 'new'
$backup = "$base.bak-$stamp"
$manifest = Join-Path $backup 'aca-manifest.txt'
$locks = @()

try {
  # 先加锁：后面算的"新增文件"和备份清单都依赖目标目录此刻的样子，中途被别的发布改了就错了
  $locks = @(Lock-AcaTarget $web $base)
  if (-not (Test-Path -LiteralPath $new)) { throw "The package unpacked by the pre-check is gone ($new); deploy again" }
  $all = @(Get-ChildItem -LiteralPath $new -Recurse -File)
  $files = @($all | Where-Object { -not (Test-AcaExcluded $_.FullName.Substring($new.Length + 1) $exclude) })
  $rels = @($files | ForEach-Object { $_.FullName.Substring($new.Length + 1) })
  $added = @($rels | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
  # 预检查到现在，前面的服务器在发，这台可能又被占了磁盘，也可能被租约管不到的另一套 aca 或有人手工改了文件
  Assert-AcaDiskSpace $root $files $rels $added
  if (-not $force -and @(Get-AcaOlderFiles $root $files $rels $added)) { throw 'Files on the server changed after the pre-check and are now newer than the package; check what changed, then deploy again or pass --force' }
  # 预检查把包里环境配置中由构建决定的部分合进了服务器上那份，存在这里；服务器上那份之后被改过，合出来的就作废
  $configs = @(Get-ChildItem -LiteralPath (Join-Path $work 'config') -File -Filter '*.config' -ErrorAction SilentlyContinue)
  foreach ($c in $configs) {
    if ((Get-AcaHash ([IO.File]::ReadAllBytes((Join-Path $root $c.Name)))) -ne (Get-Content -LiteralPath "$($c.FullName).base")) { throw "$($c.Name) on the server changed after the pre-check; deploy again" }
  }
  # 包里被排除的文件记下哈希，下次预检查拿来比；这次包里没带的沿用上次记的
  $last = @(Get-AcaBackups $base)[-1]
  $hashes = if ($last) { (Read-AcaManifest $last.FullName).Excluded } else { @{} }
  foreach ($f in @($all | Where-Object { Test-AcaExcluded $_.FullName.Substring($new.Length + 1) $exclude })) { $hashes[$f.FullName.Substring($new.Length + 1)] = Get-AcaFileHash $f.FullName }
  # 发布前的状态留着对照：发布后坏了才知道是这次包的问题还是本来就坏
  $before = Get-AcaHealth $web $name 1
  # 发布前就停着的服务，发布后也不启动：备机上的服务常常是刻意停着的
  $wasRunning = $web -or (Test-AcaServiceRunning $before $name)

  try {
    Stop-AcaTarget $web $name
    # 目标目录可能有十几 GB（上传文件、日志），只备份会被覆盖的文件
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($rel in $rels) {
      if ($added -notcontains $rel) { Copy-AcaFile (Join-Path $root $rel) (Join-Path $backup $rel) }
    }
    foreach ($c in $configs) { Copy-AcaFile (Join-Path $root $c.Name) (Join-Path $backup $c.Name) }
    $newDirs = @()
    foreach ($rel in $added) { for ($d = Split-Path $rel; $d -and $newDirs -notcontains $d -and -not (Test-Path -LiteralPath (Join-Path $root $d)); $d = Split-Path $d) { $newDirs += $d } }
    # 清单的格式见 Read-AcaManifest；新增文件和备份集合按同一份 $added 算，回退时恢复和删除才不会打架。
    # 备份全部写完才写清单：没清单的目录不算备份，复制到一半的不会被拿去回退
    Set-Content -LiteralPath $manifest -Value (@($deployId) + $added + @($newDirs | ForEach-Object { "$acaDirTag$_" }) + @($hashes.Keys | Where-Object { Test-AcaExcluded $_ $exclude } | ForEach-Object { "$acaExcludedTag$($hashes[$_])\$_" })) -Encoding UTF8
    foreach ($f in $files) { Copy-AcaFile $f.FullName (Join-Path $root $f.FullName.Substring($new.Length + 1)) }
    foreach ($c in $configs) { Copy-AcaFile $c.FullName (Join-Path $root $c.Name) }
  } catch {
    # 还没写清单就是还没开始覆盖，目录没动过，半截的备份没用；先删它，磁盘满时写日志才有空间
    if (-not (Test-Path -LiteralPath $manifest)) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }
    Add-AcaLog $base "deploy $deployId failed | $($_.Exception.Message) | $message"
    throw
  } finally {
    $startErr = if ($wasRunning) { Start-AcaTarget $web $name } else { '' }
  }
  if ($startErr) {
    Add-AcaLog $base "deploy $deployId files overwritten but start failed | $startErr | $message"
    throw "Files overwritten, but $startErr"
  }
  $after = Get-AcaHealth $web $name 3
  $healthText = "$label $after (before: $before)"
  if (Test-AcaHealthBroken $web $after $before) {
    Add-AcaLog $base "deploy $deployId files overwritten, but $healthText | $message"
    throw "Files overwritten, but $healthText; if this deploy broke it, undo it with aca rollback"
  }
  # 成功行的格式被 deploy.ts 的 assertStaged 解析，改格式两边一起改
  Add-AcaLog $base "deploy $deployId | pkg=$package | sha256=$sha256 | overwrote $($rels.Count - $added.Count) added $($added.Count) | $healthText | $message"
  Remove-AcaOldBackups $base $backup $keep
  "OK: $name -> $root  $healthText  (backup: $backup)"
} finally {
  foreach ($l in $locks) { $l.Close() }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
