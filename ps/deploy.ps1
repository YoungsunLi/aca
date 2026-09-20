$name = '__NAME__'
$dir = '__DIR__'
$url = '__URL__'
$sha256 = '__SHA256__'
$deployId = '__DEPLOY_ID__'
$package = '__PACKAGE__'
$message = '__MESSAGE__'
$checkOnly = '__CHECK_ONLY__' -eq 'true'
$force = '__FORCE__' -eq 'true'
$keep = [int]'__KEEP__'
$exclude = @('__EXCLUDE__' -split "`n" | Where-Object { $_ })
Add-Type -AssemblyName System.IO.Compression.FileSystem

$web = if ($dir) { $null } else { Get-AcaSite $name }
$root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot $web }
$label = if ($web) { 'home' } else { 'service' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$work = Join-Path $env:TEMP "aca-$([guid]::NewGuid())"
$new = Join-Path $work 'new'
$backup = "$root.bak-$stamp"
$manifest = Join-Path $backup 'aca-manifest.txt'
$lock = $null

if ($web) {
  $pool = $web.applicationPool
  $shared = @(Get-Website | Where-Object { $_.name -ne $name -and $_.applicationPool -eq $pool } | ForEach-Object name)
  if ($shared) { "NOTE: app pool $pool is shared with site(s) $($shared -join ', '), which will also be down for a few seconds" }
}

New-Item -ItemType Directory -Path $work | Out-Null
try {
  # 下载前就加锁：后面算的"新增文件"等都依赖目标目录此刻的样子，中途被别的发布改了备份清单就错了
  if (-not $checkOnly) { $lock = Lock-Aca $root }
  # 先下载并解压、做完检查再停，缩短停机时间
  Invoke-WebRequest -Uri $url -OutFile "$work\pkg.zip" -UseBasicParsing
  # 对 OSS 有写权限的人能在各服务器下载前把包换掉
  $zip = [IO.File]::OpenRead("$work\pkg.zip")
  try { $got = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($zip)) -replace '-' } finally { $zip.Close() }
  if ($got -ne $sha256) { throw 'Downloaded package does not match the local SHA-256: the zip changed during upload, or the package on OSS was replaced' }
  [IO.Compression.ZipFile]::ExtractToDirectory("$work\pkg.zip", $new)
  # 包里文件名的 [ ] 会被当通配符，按路径操作的命令都用 -LiteralPath
  $all = @(Get-ChildItem -LiteralPath $new -Recurse -File)
  # 全量构建的包会带上 exclude 里的文件，不能覆盖
  $files = @($all | Where-Object { -not (Test-AcaExcluded $_.FullName.Substring($new.Length + 1) $exclude) })
  if ($files.Count -lt $all.Count) { "Excluded $($all.Count - $files.Count) files ($($exclude -join ', '))" }
  if (-not $files) { throw 'Package is empty' }
  $rels = @($files | ForEach-Object { $_.FullName.Substring($new.Length + 1) })
  $src = @($rels | Where-Object { $_ -match '^(\.git|\.vs|obj|node_modules)\\|\.(csproj|sln|cs)$' })
  if ($src) { throw "Package looks like a source directory, not publish output, e.g. $($src[0..2] -join ', ')" }
  # 环境配置是服务器上自己维护的：站点的是 web.config，服务的是 <可执行文件>.exe.config
  $envConfig = @($rels | Where-Object { if ($web) { $_ -eq 'web.config' } else { $_ -match '^[^\\]+\.exe\.config$' } })
  if ($envConfig) { throw "Package root contains $($envConfig -join ', '), which would overwrite the environment config on the server; add it to exclude in the aca config" }
  if ($rels -contains 'aca-manifest.txt') { throw 'Package root contains aca-manifest.txt, which would overwrite the backup manifest of the same name; remove it from the package' }
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
  # 备份的是被覆盖的旧文件，盘上要放得下它们再加上新包
  $need = ($files | Measure-Object Length -Sum).Sum
  # 包比服务器旧：要么拿错了旧构建，要么服务器上有人手改过，两种都不该悄悄覆盖。
  # 预检查只提示不拦，站点有多台服务器时才能一次看全所有服务器再决定要不要 --force
  $older = @()
  for ($i = 0; $i -lt $files.Count; $i++) {
    if ($added -contains $rels[$i]) { continue }
    $existing = Get-Item -LiteralPath (Join-Path $root $rels[$i])
    $need += $existing.Length
    if ($existing.LastWriteTime -gt $files[$i].LastWriteTime.AddMinutes(1)) { $older += $rels[$i] }
  }
  $free = (Get-PSDrive $root.Substring(0, 1)).Free
  if ($free -lt $need) { throw "Only $([int]($free / 1MB))MB free on drive $($root.Substring(0, 1)), not enough for backup plus overwrite (about $([int]($need / 1MB))MB needed)" }
  if ($older) {
    "Files older than the copies on the server: $(($older | Select-Object -First 20) -join ', ')"
    if (-not $force -and -not $checkOnly) { throw "$($older.Count) files in the package are older than the copies on the server; pass --force to overwrite them anyway" }
  }
  # 发布前的状态留着对照：发布后坏了才知道是这次包的问题还是本来就坏
  $before = Get-AcaHealth $web $name 1
  "$label now: $before"
  # 发布前就停着的服务，发布后也不启动：备机上的服务常常是刻意停着的
  $wasRunning = $web -or (Test-AcaServiceRunning $before $name)
  if ($checkOnly) { "CHECK OK (not deployed$(if ($older -and -not $force) { '; deploying needs --force' }))"; return }

  try {
    Stop-AcaTarget $web $name
    # 目标目录可能有十几 GB（上传文件、日志），只备份会被覆盖的文件
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($rel in $rels) {
      if ($added -notcontains $rel) { Copy-AcaFile (Join-Path $root $rel) (Join-Path $backup $rel) }
    }
    # 清单第一行是发布 ID，其余是本次新增的文件；备份集合按同一份 $added 算，回退时恢复和删除才不会打架。
    # 备份全部写完才写清单：没清单的目录不算备份，复制到一半的不会被拿去回退
    Set-Content -LiteralPath $manifest -Value (@($deployId) + $added) -Encoding UTF8
    foreach ($f in $files) { Copy-AcaFile $f.FullName (Join-Path $root $f.FullName.Substring($new.Length + 1)) }
  } catch {
    # 还没写清单就是还没开始覆盖，目录没动过，半截的备份没用；先删它，磁盘满时写日志才有空间
    if (-not (Test-Path -LiteralPath $manifest)) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }
    Add-AcaLog $root "deploy $deployId failed | $($_.Exception.Message) | $message"
    throw
  } finally {
    $startErr = if ($wasRunning) { Start-AcaTarget $web $name } else { '' }
  }
  if ($startErr) {
    Add-AcaLog $root "deploy $deployId files overwritten but start failed | $startErr | $message"
    throw "Files overwritten, but $startErr"
  }
  $after = Get-AcaHealth $web $name 3
  $healthText = "$label $after (before: $before)"
  if (Test-AcaHealthBroken $web $after $before) {
    Add-AcaLog $root "deploy $deployId files overwritten, but $healthText | $message"
    throw "Files overwritten, but $healthText; if this deploy broke it, undo it with aca rollback"
  }
  # 成功行的格式被 deploy.ts 的 assertStaged 解析，改格式两边一起改
  Add-AcaLog $root "deploy $deployId | pkg=$package | sha256=$sha256 | overwrote $($rels.Count - $added.Count) added $($added.Count) | $healthText | $message"
  Remove-AcaOldBackups $root $backup $keep
  "OK: $name -> $root  $healthText  (backup: $backup)"
} finally {
  if ($lock) { $lock.Close() }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
