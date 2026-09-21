$name = '__NAME__'
$dir = '__DIR__'
$url = '__URL__'
$sha256 = '__SHA256__'
$checkOnly = '__CHECK_ONLY__' -eq 'true'
$force = '__FORCE__' -eq 'true'
$exclude = @('__EXCLUDE__' -split "`n" | Where-Object { $_ })
# 包解在这里，真发布时留给发布那一步直接用，服务器摘出负载均衡后不用再下载；目录名带随机后缀，同时发别的站点撞不上
$work = Join-Path $env:TEMP '__WORK__'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$web = if ($dir) { $null } else { Get-AcaSite $name }
$root = if ($dir) { Get-AcaServiceRoot $name $dir } else { Get-AcaRoot $web }
$label = if ($web) { 'home' } else { 'service' }

if ($web) {
  $pool = $web.applicationPool
  $shared = @(Get-Website | Where-Object { $_.name -ne $name -and $_.applicationPool -eq $pool } | ForEach-Object name)
  if ($shared) { "NOTE: app pool $pool is shared with site(s) $($shared -join ', '), which will also be down for a few seconds" }
}

# 发布没走到最后一步（别的服务器预检查没过、发布中途失败或被终止）会留下解开的包；没有哪次发布要跑一天，放了一天的都清掉
Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'aca-*' |
  Where-Object { $_.Name -match '^aca-\d{8}T\d{6}Z-[0-9a-f]{8}$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
  ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
$new = Join-Path $work 'new'
New-Item -ItemType Directory -Path $work | Out-Null
$passed = $false
try {
  Invoke-WebRequest -Uri $url -OutFile "$work\pkg.zip" -UseBasicParsing
  # 对 OSS 有写权限的人能在各服务器下载前把包换掉
  $zip = [IO.File]::OpenRead("$work\pkg.zip")
  try { $got = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($zip)) -replace '-' } finally { $zip.Close() }
  if ($got -ne $sha256) { throw 'Downloaded package does not match the local SHA-256: the zip changed during upload, or the package on OSS was replaced' }
  [IO.Compression.ZipFile]::ExtractToDirectory("$work\pkg.zip", $new)
  Remove-Item -LiteralPath "$work\pkg.zip"
  # 包里文件名的 [ ] 会被当通配符，按路径操作的命令都用 -LiteralPath
  $all = @(Get-ChildItem -LiteralPath $new -Recurse -File)
  # 全量构建的包会带上 exclude 里的文件，不能覆盖
  $files = @($all | Where-Object { -not (Test-AcaExcluded $_.FullName.Substring($new.Length + 1) $exclude) })
  if ($files.Count -lt $all.Count) { "Excluded $($all.Count - $files.Count) files ($($exclude -join ', '))" }
  # 构建新加在 exclude 路径下的文件不会发出去，服务器上就一直没有；服务器上没有环境配置由 analyze 提示
  $hidden = @($all | ForEach-Object { $_.FullName.Substring($new.Length + 1) } | Where-Object { (Test-AcaExcluded $_ $exclude) -and -not (Test-AcaEnvConfig $web $_) -and -not (Test-Path -LiteralPath (Join-Path $root $_)) })
  if ($hidden) { "NOTE: new files under excluded paths are not deployed: $(($hidden | Select-Object -First 20) -join ', ')" }
  if (-not $files) { throw 'Package is empty' }
  $rels = @($files | ForEach-Object { $_.FullName.Substring($new.Length + 1) })
  $src = @($rels | Where-Object { $_ -match '^(\.git|\.vs|obj|node_modules)\\|\.(csproj|sln|cs)$' })
  if ($src) { throw "Package looks like a source directory, not publish output, e.g. $($src[0..2] -join ', ')" }
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
  Assert-AcaDiskSpace $root $files $rels $added
  $older = @(Get-AcaOlderFiles $root $files $rels $added)
  if ($older) { "Files older than the copies on the server$(if ($checkOnly -and -not $force) { ' (deploying needs --force)' }): $(($older | Select-Object -First 20) -join ', ')" }
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
