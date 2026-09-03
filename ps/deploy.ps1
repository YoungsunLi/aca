$site = '__SITE__'
$url = '__URL__'
$deployId = '__DEPLOY_ID__'
$message = '__MESSAGE__'
$checkOnly = '__CHECK_ONLY__' -eq 'true'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$web = Get-AcaSite $site
$root = Get-AcaRoot $web
$pool = $web.applicationPool
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$work = Join-Path $env:TEMP "aca-$stamp"
$new = Join-Path $work 'new'
$backup = "$root.bak-$stamp"
$manifest = Join-Path $backup 'aca-manifest.txt'

$shared = @(Get-Website | Where-Object { $_.name -ne $site -and $_.applicationPool -eq $pool } | ForEach-Object name)
if ($shared) { "NOTE: app pool $pool is shared with site(s) $($shared -join ', '), which will also be down for a few seconds" }

New-Item -ItemType Directory -Path $work | Out-Null
try {
  # 先下载并解压、做完检查再停站，缩短停机时间
  Invoke-WebRequest -Uri $url -OutFile "$work\pkg.zip" -UseBasicParsing
  [IO.Compression.ZipFile]::ExtractToDirectory("$work\pkg.zip", $new)
  # 包里文件名的 [ ] 会被当通配符，按路径操作的命令都用 -LiteralPath
  $files = @(Get-ChildItem -LiteralPath $new -Recurse -File)
  if (-not $files) { throw 'Package is empty' }
  $rels = @($files | ForEach-Object { $_.FullName.Substring($new.Length + 1) })
  $src = @($rels | Where-Object { $_ -match '^(\.git|\.vs|obj|node_modules)\\|\.(csproj|sln|cs)$' })
  if ($src) { throw "Package looks like a source directory, not publish output, e.g. $($src[0..2] -join ', ')" }
  if ($rels -contains 'web.config') { throw 'Package root contains web.config, which would overwrite the environment config on the server; remove it from the package' }
  if ($rels -contains 'aca-manifest.txt') { throw 'Package root contains aca-manifest.txt, which would overwrite the backup manifest of the same name; remove it from the package' }
  $rootTop = @(Get-ChildItem -LiteralPath $root | ForEach-Object Name)
  $pkgTop = @(Get-ChildItem -LiteralPath $new | ForEach-Object Name)
  if ($rootTop -and -not @($pkgTop | Where-Object { $rootTop -contains $_ })) {
    throw "Package top level ($($pkgTop -join ', ')) shares nothing with the top level of the site directory; wrong site?"
  }
  $size = ($files | Measure-Object Length -Sum).Sum
  $free = (Get-PSDrive $root.Substring(0, 1)).Free
  if ($free -lt 2 * $size) { throw "Only $([int]($free / 1MB))MB free on the site drive, not enough for backup plus overwrite (about $([int](2 * $size / 1MB))MB needed)" }

  $added = @($rels | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
  "$site -> $root  $($rels.Count) files in package: $($rels.Count - $added.Count) to overwrite, $($added.Count) new"
  $addedDll = @($added | Where-Object { $_ -match '\.dll$' })
  if ($addedDll) { "New DLLs (not on the site yet; either new dependencies or the wrong site): $(($addedDll | Select-Object -First 20) -join ', ')" }
  if ($added) { "New files: $(($added | Select-Object -First 20) -join ', ')" }
  if ($checkOnly) { 'CHECK OK (not deployed)'; return }

  try {
    Stop-AcaSite $web
    # 站点目录可能有十几 GB（上传文件、日志），只备份会被覆盖的文件
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($rel in $rels) {
      if ($added -notcontains $rel) { Copy-AcaFile (Join-Path $root $rel) (Join-Path $backup $rel) }
    }
    # 清单第一行是发布 ID，其余是本次新增的文件；备份集合按同一份 $added 算，回退时恢复和删除才不会打架。
    # 备份全部写完才写清单：没清单的目录不算备份，复制到一半的不会被拿去回退
    Set-Content -LiteralPath $manifest -Value (@($deployId) + $added) -Encoding UTF8
    foreach ($f in $files) { Copy-AcaFile $f.FullName (Join-Path $root $f.FullName.Substring($new.Length + 1)) }
  } catch {
    # 还没写清单就是还没开始覆盖，站点没动过，半截的备份没用；先删它，磁盘满时写日志才有空间
    if (-not (Test-Path -LiteralPath $manifest)) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }
    Add-AcaLog $root "deploy $deployId failed | $($_.Exception.Message) | $message"
    throw
  } finally {
    $startErr = Start-AcaSite $web
  }
  if ($startErr) {
    Add-AcaLog $root "deploy $deployId files overwritten but start failed | $startErr | $message"
    throw "Files overwritten, but $startErr"
  }
  Add-AcaLog $root "deploy $deployId | overwrote $($rels.Count - $added.Count) added $($added.Count) | $message"
  "OK: $site -> $root  (backup: $backup)"
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
