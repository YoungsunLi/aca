$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# 没装 IIS 的服务器（如数据库服务器）上 pull 也要能跑，别的脚本在那里会报找不到 Get-Website 之类的命令
Import-Module WebAdministration -ErrorAction SilentlyContinue

# 两个 aca 同时改一个站（或一台服务器的证书）会交错停站、互相覆盖。锁是独占打开 <path>.aca-lock，握着句柄直到脚本结束；
# 被云助手强杀时句柄随进程释放，不会留下死锁，文件本身留着无妨。调用方在 finally 里 Close。
# clb.ts 认默认的报错原文：锁被占时不把服务器放回负载均衡
function Lock-Aca($path, $busy = 'Another aca operation is modifying this site or service; retry after it finishes') {
  try { [IO.File]::Open("$path.aca-lock", 'OpenOrCreate', 'ReadWrite', 'None') } catch {
    $e = $_.Exception.InnerException
    # 0x80070020 = ERROR_SHARING_VIOLATION，其它 IO 错误（没权限、路径不存在）原样抛出去
    if ($e -is [IO.IOException] -and $e.HResult -eq -2147024864) { throw $busy }
    throw
  }
}
