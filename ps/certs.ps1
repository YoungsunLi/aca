# 每行的格式被 certs.ts 的 ROW 解析，改格式两边一起改；末尾一列是前面部分的长度，见 ecs.ts 的 records
foreach ($s in Get-AcaServedCerts) {
  $row = if ($s.Cert) { "$($s.Site)`t$($s.Binding)`t$($s.Cert.Thumbprint)`t$($s.Cert.NotAfter.ToString('yyyy-MM-dd'))`t$([Math]::Floor(($s.Cert.NotAfter - (Get-Date)).TotalDays))`t$(Get-AcaCertName $s.Cert)`t$($s.NameOk)" }
  else { "$($s.Site)`t$($s.Binding)`tERROR`t$($s.Error)" }
  "$row`t$($row.Length)"
}
