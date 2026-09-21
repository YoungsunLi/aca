# 环境配置（web.config、<exe>.exe.config）里由构建决定的部分跟着包走，其余保持服务器原样。
# 只替换这些部分那一段原文，其余字节不动：XmlDocument 读了再存会把 /> 改成 " />"、把跨行的属性并成一行

$acaTag = '\G<[^\s/>]+(?:\s+[^\s=/>]+\s*=\s*(?:"[^"]*"|''[^'']*''))*\s*/?>'
# 开始标签里带 configSource 的节放在别的文件里，自己不能再有别的属性和内容，否则 .NET 整份配置都不认
$acaExternal = '\sconfigSource\s*='

# 按从根开始的路径找元素，返回每处的 Index、Length、Empty（自闭合）；注释和 CDATA 里同名的文字不会误中
function Find-AcaElements($text, $path) {
  # 行要和 XmlTextReader 数得一样，单独的 CR 它也算换行（FTP 文本模式传过的文件里有 CR CR LF）：少数一行，后面的位置就落到别的元素上
  $starts = @(0) + @([regex]::Matches($text, "`r`n|`r|`n") | ForEach-Object { $_.Index + $_.Length })
  $r = New-Object Xml.XmlTextReader (New-Object IO.StringReader $text)
  $r.WhitespaceHandling = 'None'
  $r.DtdProcessing = 'Ignore'
  $names = New-Object Collections.ArrayList
  $at = New-Object Collections.ArrayList
  try {
    while ($r.Read()) {
      if ($r.NodeType -eq 'Element') {
        [void]$names.Add($r.LocalName)
        [void]$at.Add($starts[$r.LineNumber - 1] + $r.LinePosition - 2)
        if (-not $r.IsEmptyElement) { continue }
        $i = $at[$at.Count - 1]
        if ($names -join '/' -eq $path) { New-Object psobject -Property @{ Index = $i; Length = ([regex]$acaTag).Match($text, $i).Length; Empty = $true } }
      } elseif ($r.NodeType -eq 'EndElement') {
        $i = $at[$at.Count - 1]
        if ($names -join '/' -eq $path) { New-Object psobject -Property @{ Index = $i; Length = $text.IndexOf('>', $starts[$r.LineNumber - 1] + $r.LinePosition - 1) + 1 - $i; Empty = $false } }
      } else { continue }
      $names.RemoveAt($names.Count - 1)
      $at.RemoveAt($at.Count - 1)
    }
  } finally { $r.Close() }
}
function Get-AcaText($text, $e) { $text.Substring($e.Index, $e.Length) }
# 不用 [xml] 转换：转换失败的报错会带上整份原文，配置里有密钥；LoadXml 的报错只有行列号
function Read-AcaXml($text) {
  $x = New-Object xml
  $x.LoadXml($text)
  $x
}
# 片段里的元素不带命名空间声明也能解析；比较用 OuterXml，属性的引号、元素间的空白不算改动
function Read-AcaFragment($fragment) { (Read-AcaXml "<r>$fragment</r>").DocumentElement.FirstChild }
# 插到父元素的结束标签前面；自闭合的父元素（模板生成的 <compilation ... /> 就是）先拆成一对标签
function Add-AcaChild($text, $parent, $child) {
  $tag = Get-AcaText $text $parent
  if ($parent.Empty) {
    $name = [regex]::Match($tag, '^<([^\s/>]+)').Groups[1].Value
    return $text.Substring(0, $parent.Index) + ($tag -replace '\s*/>$', '>') + $child + "</$name>" + $text.Substring($parent.Index + $parent.Length)
  }
  $at = $parent.Index + $tag.LastIndexOf('</')
  $text.Substring(0, $at) + $child + $text.Substring($at)
}

# 集合按条目合并：包里有的条目以包为准；服务器独有的保留，多半是有人为这台服务器补的
$acaCollections = @(
  @{ Label = 'runtime/assemblyBinding'; Path = 'configuration/runtime/assemblyBinding'; Entry = 'dependentAssembly'
     Key = { param($x) $i = $x.SelectSingleNode("*[local-name()='assemblyIdentity']"); if ($i) { ($i.GetAttribute('name') + ',' + $i.GetAttribute('publicKeyToken') + ',' + $i.GetAttribute('culture')).ToLower() } else { $x.OuterXml } }
     Show = { param($x) $i = $x.SelectSingleNode("*[local-name()='assemblyIdentity']"); $b = $x.SelectSingleNode("*[local-name()='bindingRedirect']"); "$(if ($i) { $i.GetAttribute('name') }) $(if ($b) { $b.GetAttribute('oldVersion') + ' -> ' + $b.GetAttribute('newVersion') })" } }
  @{ Label = 'system.codedom/compilers'; Path = 'configuration/system.codedom/compilers'; Entry = 'compiler'
     Key = { param($x) $x.GetAttribute('extension').ToLower() }
     Show = { param($x) "$($x.GetAttribute('extension')) $($x.GetAttribute('type'))" } }
  @{ Label = 'entityFramework/providers'; Path = 'configuration/entityFramework/providers'; Entry = 'provider'
     Key = { param($x) $x.GetAttribute('invariantName') }
     Show = { param($x) "$($x.GetAttribute('invariantName')) $($x.GetAttribute('type'))" } }
  @{ Label = 'system.web/compilation/assemblies'; Path = 'configuration/system.web/compilation/assemblies'; Entry = 'add'
     Key = { param($x) ($x.GetAttribute('assembly') -split ',')[0].Trim().ToLower() }
     Show = { param($x) $x.GetAttribute('assembly') } }
)

function Get-AcaEntries($text, $c) {
  foreach ($e in @(Find-AcaElements $text "$($c.Path)/$($c.Entry)")) {
    $t = Get-AcaText $text $e
    $x = Read-AcaFragment $t
    New-Object psobject -Property @{ Text = $t; Key = & $c.Key $x; Xml = $x.OuterXml; Show = & $c.Show $x }
  }
}
function Get-AcaOthers($fragment, $entry) {
  @((Read-AcaFragment $fragment).ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.LocalName -ne $entry } | ForEach-Object { $_.OuterXml })
}

# 返回 @{ Text = 改好的原文; Lines = 说明 }
function Sync-AcaCollection($srv, $pkg, $c) {
  $out = @{ Text = $srv; Lines = @() }
  $p = @(Find-AcaElements $pkg $c.Path)
  if (-not $p) { return $out }
  $s = @(Find-AcaElements $srv $c.Path)
  if ($p.Count -gt 1 -or $s.Count -gt 1) { $out.Lines = @("WARN $($c.Label) appears more than once, not synced"); return $out }
  $pText = Get-AcaText $pkg $p[0]
  if ($s) {
    $pOthers = Get-AcaOthers $pText $c.Entry
    $lost = @(Get-AcaOthers (Get-AcaText $srv $s[0]) $c.Entry | Where-Object { $pOthers -cnotcontains $_ })
    if ($lost) { $out.Lines = @("WARN $($c.Label) on the server has $($lost -join ' ') that the package lacks, not synced"); return $out }
  }
  $pe = @(Get-AcaEntries $pkg $c)
  $se = @(Get-AcaEntries $srv $c)
  $pKeys = @($pe | ForEach-Object Key)
  $keep = @($se | Where-Object { $pKeys -notcontains $_.Key })
  $seen = @{}
  foreach ($e in $pe) {
    if ($seen[$e.Key]) { continue }
    $seen[$e.Key] = 1
    $old = @($se | Where-Object { $_.Key -eq $e.Key })
    if (-not $old) { $out.Lines += "  $($c.Label): + $($e.Show)" }
    elseif ($old.Count -gt 1 -or $old[0].Xml -cne $e.Xml) { $out.Lines += "  $($c.Label): ~ $(($old | ForEach-Object Show) -join ' / ') => $($e.Show)" }
  }
  if (-not $out.Lines) { return $out }
  if ($keep) {
    $out.Lines += "  $($c.Label): kept, only on the server: $(($keep | ForEach-Object Show) -join '; ')"
    $close = $pText.LastIndexOf('</')
    $head = $pText.Substring(0, $close)
    $body = $head.TrimEnd()
    $indent = if ($pText -match "(?m)^([ `t]*)<$($c.Entry)\b") { $matches[1] } else { '' }
    $nl = if ($srv.Contains("`r`n")) { "`r`n" } else { "`n" }
    $pText = $body + (@($keep | ForEach-Object { $nl + $indent + $_.Text }) -join '') + $head.Substring($body.Length) + $pText.Substring($close)
  }
  if ($s) {
    $out.Text = $srv.Substring(0, $s[0].Index) + $pText + $srv.Substring($s[0].Index + $s[0].Length)
    return $out
  }
  # 服务器上还没有这个集合：插进它的父元素；父元素也没有时，只替 runtime、system.codedom 这种整个归构建的补上
  $parentPath = $c.Path.Substring(0, $c.Path.LastIndexOf('/'))
  $parent = @(Find-AcaElements $srv $parentPath)
  if ($parent.Count -eq 1 -and ([regex]$acaTag).Match($srv, $parent[0].Index).Value -match $acaExternal) { $out.Lines = @("WARN $($c.Label) not synced: its section on the server uses configSource") }
  elseif ($parent.Count -eq 1) { $out.Text = Add-AcaChild $srv $parent[0] $pText }
  elseif (-not $parent -and $parentPath -eq 'configuration/runtime') { $out.Text = Add-AcaChild $srv @(Find-AcaElements $srv 'configuration')[0] "<runtime>$pText</runtime>" }
  elseif (-not $parent -and $parentPath -eq 'configuration/system.codedom') { $out.Text = Add-AcaChild $srv @(Find-AcaElements $srv 'configuration')[0] (Get-AcaText $pkg @(Find-AcaElements $pkg $parentPath)[0]) }
  else { $out.Lines = @("WARN $($c.Label) not synced: the server's config has no $($parentPath -replace '^configuration/', '')") }
  $out
}

# 整段以包为准：startup 里只有运行时版本，没有环境值
function Sync-AcaElement($srv, $pkg, $path) {
  $out = @{ Text = $srv; Lines = @() }
  $p = @(Find-AcaElements $pkg $path)
  if ($p.Count -ne 1) { return $out }
  $s = @(Find-AcaElements $srv $path)
  if ($s.Count -gt 1) { $out.Lines = @("WARN $($path -replace '^configuration/', '') appears more than once, not synced"); return $out }
  $pText = Get-AcaText $pkg $p[0]
  if (-not $s) { $out.Text = Add-AcaChild $srv @(Find-AcaElements $srv 'configuration')[0] $pText }
  elseif ((Read-AcaFragment (Get-AcaText $srv $s[0])).OuterXml -cne (Read-AcaFragment $pText).OuterXml) { $out.Text = $srv.Substring(0, $s[0].Index) + $pText + $srv.Substring($s[0].Index + $s[0].Length) }
  else { return $out }
  $out.Lines = @("  $($path -replace '^configuration/', ''): replaced with the package's")
  $out
}

# 同一元素里别的属性归环境或运维（compilation 的 debug、httpRuntime 的 maxRequestLength），只换这一个
function Sync-AcaAttribute($srv, $pkg, $path, $attr) {
  $out = @{ Text = $srv; Lines = @() }
  $p = @(Find-AcaElements $pkg $path)
  $s = @(Find-AcaElements $srv $path)
  if ($p.Count -ne 1 -or $s.Count -ne 1) { return $out }
  $value = '\s' + [regex]::Escape($attr) + '\s*=\s*(?:"([^"]*)"|''([^'']*)'')'
  $pm = [regex]::Match(([regex]$acaTag).Match($pkg, $p[0].Index).Value, $value)
  $tag = ([regex]$acaTag).Match($srv, $s[0].Index)
  $sm = [regex]::Match($tag.Value, $value)
  $pv = $pm.Groups[1].Value + $pm.Groups[2].Value
  $sv = $sm.Groups[1].Value + $sm.Groups[2].Value
  if (-not $pm.Success -or ($sm.Success -and $pv -ceq $sv)) { return $out }
  if ($tag.Value -match $acaExternal) { $out.Lines = @("WARN $($path -replace '^configuration/', '') $attr not synced: its section on the server uses configSource"); return $out }
  $newTag = if ($sm.Success) { $tag.Value.Substring(0, $sm.Index) + " $attr=`"$pv`"" + $tag.Value.Substring($sm.Index + $sm.Length) } else { $tag.Value -replace '^(<[^\s/>]+)', "`$1 $attr=`"$pv`"" }
  $out.Text = $srv.Substring(0, $tag.Index) + $newTag + $srv.Substring($tag.Index + $tag.Length)
  $out.Lines = @("  $($path -replace '^configuration/', '') $($attr): $(if ($sm.Success) { $sv } else { '(none)' }) -> $pv")
  $out
}

# 一处读不懂（比如用了没声明的命名空间前缀）不连累别处
function Invoke-AcaSync($state, $what, $step) {
  try { $r = & $step $state.Text } catch { $state.Lines += "WARN $what not synced: $($_.Exception.Message)"; return }
  $state.Text = $r.Text
  $state.Lines += $r.Lines
}
function Sync-AcaConfig($srv, $pkg) {
  $state = @{ Text = $srv; Lines = @() }
  foreach ($c in $acaCollections) { Invoke-AcaSync $state $c.Label { param($t) Sync-AcaCollection $t $pkg $c } }
  Invoke-AcaSync $state 'startup' { param($t) Sync-AcaElement $t $pkg 'configuration/startup' }
  foreach ($e in 'compilation', 'httpRuntime') { Invoke-AcaSync $state "system.web/$e" { param($t) Sync-AcaAttribute $t $pkg "configuration/system.web/$e" 'targetFramework' } }
  # 写坏了的配置运行时会整个忽略，改完先确认还能解析
  [void](Read-AcaXml $state.Text)
  $state
}

# 只处理 UTF-8：按原来有没有 BOM 写回；解码再编码能逐字节还原才动它，改动之外的字节就原样不变
function Read-AcaConfig($path) {
  $bytes = [IO.File]::ReadAllBytes($path)
  $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
  $enc = New-Object Text.UTF8Encoding($bom)
  $skip = if ($bom) { 3 } else { 0 }
  $text = $enc.GetString($bytes, $skip, $bytes.Length - $skip)
  if ([Convert]::ToBase64String([byte[]]($enc.GetPreamble() + $enc.GetBytes($text))) -ne [Convert]::ToBase64String($bytes)) { return $null }
  @{ Text = $text; Encoding = $enc; Hash = Get-AcaHash $bytes }
}
