# 有 bin 的是 .NET 站，看 bin 就够且快；静态站没有 bin。服务的程序集和它天天写的日志在同一个目录里，所以只看 dll、exe
function Get-AcaNewestFile($web, $root) {
  $bin = Join-Path $root 'bin'
  $files = @(Get-ChildItem -LiteralPath $(if ($web -and (Test-Path -LiteralPath $bin)) { $bin } else { $root }) -Recurse -File)
  if (-not $web) { $files = @($files | Where-Object { $_.Extension -match '^\.(dll|exe)$' }) }
  $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
