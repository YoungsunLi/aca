import type { Config } from './config.ts';
import { Ecs } from './ecs.ts';
import { renderScript } from './ps.ts';

type CertCheck = { instance: string; site: string; binding: string; expires: string; name: string; thumbprint: string; status: string };

// 剩不到 30 天就报：留出买证书、逐台换的时间
const WARN_DAYS = 30;
const ROW = /^(.+?)\t(\S+)\t(?:([0-9A-F]{40})\t(\S+)\t(-?\d+)\t(.*?)\t(True|False)|ERROR\t(.*?))\r?$/gm;

// 查登记站点所在的每台服务器上所有运行中的站点：没登记的站点一样对外发证书
export async function checkCerts(cfg: Config): Promise<{ checks: CertCheck[]; failures: string[] }> {
  const ecs = new Ecs(cfg);
  const checks: CertCheck[] = [];
  const failures: string[] = [];
  // 逐台查而不并发：SDK 默认凭证链首次取凭证时并发调用，会有调用拿到链上还没试通的那一环而报错
  for (const instance of new Set(Object.values(cfg.sites).flatMap((s) => s.instances))) {
    const r = await ecs.runPowerShell(instance, renderScript('certs', {}), 300);
    if (r.status !== 'Success') {
      failures.push(`${instance}: ${r.output.trim() || r.error}`);
      continue;
    }
    if (r.dropped) failures.push(`${instance}: Cloud Assistant truncated the output by ${r.dropped} bytes, some bindings are missing`);
    for (const [, site, binding, thumbprint, expires, daysLeft, name, nameOk, error] of r.output.matchAll(ROW)) {
      if (error !== undefined) {
        checks.push({ instance, site, binding, expires: '-', name: '-', thumbprint: '-', status: `handshake failed: ${error}` });
        continue;
      }
      const days = Number(daysLeft);
      const problems = [];
      if (days < 0) problems.push('expired');
      else if (days < WARN_DAYS) problems.push(`expires in ${days} days`);
      if (nameOk === 'False') problems.push('name mismatch');
      checks.push({ instance, site, binding, expires, name, thumbprint, status: problems.join('; ') || 'OK' });
    }
  }
  return { checks, failures };
}
