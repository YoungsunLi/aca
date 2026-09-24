# 发布后服务器上生效的那份：包里有、没被排除的是包里那份，否则是服务器上原来那份
function Get-AcaAfter($rel, $new, $root, $exclude) { if ((Test-Path -LiteralPath "$new\$rel") -and -not (Test-AcaExcluded $rel $exclude)) { "$new\$rel" } elseif (Test-Path -LiteralPath "$root\$rel") { "$root\$rel" } }
