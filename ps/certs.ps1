# 每行的格式被 certs.ts 的 ROW 解析，改格式两边一起改
foreach ($s in Get-AcaServedCerts) {
  if ($s.Cert) { "$($s.Site)`t$($s.Binding)`t$($s.Cert.Thumbprint)`t$($s.Cert.NotAfter.ToString('yyyy-MM-dd'))`t$([Math]::Floor(($s.Cert.NotAfter - (Get-Date)).TotalDays))`t$(Get-AcaCertName $s.Cert)`t$($s.NameOk)" }
  else { "$($s.Site)`t$($s.Binding)`tERROR`t$($s.Error)" }
}
