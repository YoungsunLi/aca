$url = '__URL__'
$sha256 = '__SHA256__'
# 包解在这里，真发布时留给发布那一步直接用，服务器摘出负载均衡后不用再下载；目录名带随机后缀，同时发别的站点撞不上
$work = Join-Path $env:TEMP '__WORK__'
Add-Type -AssemblyName System.IO.Compression.FileSystem

# 发布没走到最后一步（别的服务器预检查没过、发布中途失败或被终止）会留下解开的包；没有哪次发布要跑一天，放了一天的都清掉
Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'aca-*' |
  Where-Object { $_.Name -match '^aca-\d{8}T\d{6}Z-[0-9a-f]{8}$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
  ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $work | Out-Null
# 预检查和发布从这里读 exclude：列表长了会把那几条命令撑过 RunCommand 的 24 KB，只让下载这条带它
[IO.File]::WriteAllText("$work\exclude.txt", '__EXCLUDE__')
$passed = $false
try {
  Invoke-WebRequest -Uri $url -OutFile "$work\pkg.zip" -UseBasicParsing
  # 对 OSS 有写权限的人能在各服务器下载前把包换掉
  if ((Get-AcaFileHash "$work\pkg.zip") -ne $sha256) { throw 'Downloaded package does not match the local SHA-256: the zip changed during upload, or the package on OSS was replaced' }
  [IO.Compression.ZipFile]::ExtractToDirectory("$work\pkg.zip", "$work\new")
  Remove-Item -LiteralPath "$work\pkg.zip"
  $passed = $true
} finally {
  if (-not $passed) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
