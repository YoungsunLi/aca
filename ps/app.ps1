# 站点下的应用程序（站点/路径）：目录、应用池换成应用自己的，状态、绑定、日志还是站点的
function Get-AcaApp($web, $name) {
  $site, $app = $name -split '/', 2
  $a = Get-WebApplication -Site $site -Name $app
  if (-not $a) { throw "IIS application not found: $name" }
  $root = Get-AcaRoot $a
  # 应用目录在站点里别的应用或虚拟目录的目录里时，旁边的备份和发布记录会被 IIS 对外提供，挪到最外层那个目录旁边；
  # 就是那个目录时也挪，否则和它共用备份和锁；只跳过应用自己的根虚拟目录，它下面别的虚拟目录也可能指到上级目录
  $outer = @($web.Collection | ForEach-Object { $p = $_.path; $_.Collection | Where-Object { $p -ne "/$app" -or $_.path -ne '/' } } | ForEach-Object { Get-AcaRoot $_ } | Where-Object { "$root\".StartsWith("$_\", 'OrdinalIgnoreCase') } | Sort-Object Length)[0]
  $base = if ($outer) { "$outer.aca-apps$($root.Substring($outer.Length))" } else { $root }
  $null = New-Item -ItemType Directory -Force (Split-Path $base)
  $web | Add-Member -Force -NotePropertyMembers @{ physicalPath = $root; applicationPool = $a.applicationPool; AppPath = "/$app"; AcaBase = $base; SiteRoot = Get-AcaRoot $web }
  $web
}
