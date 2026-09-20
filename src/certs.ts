import { createCipheriv, randomBytes } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import type { Config } from './config.ts';
import { Ecs, type RunResult } from './ecs.ts';
import { remove, signForEcs, upload } from './oss.ts';
import { renderScript } from './ps.ts';

/** days：握手不上时没有证书，也就没有剩余天数 */
type CertCheck ={ instance: string; site: string; binding: string; expires: string; days?: number; name: string; thumbprint: string; status: string };
export type CertSource = { kind: 'pfx'; bytes: Buffer; password: string } | { kind: 'thumbprint'; thumbprint: string };
export type ReplaceOptions = { check?: boolean; force?: boolean };

// 剩不到 30 天就报：留出买证书、逐台换的时间
const WARN_DAYS = 30;
const ROW = /^(.+?)\t(\S+)\t(?:([0-9A-F]{40})\t(\S+)\t(-?\d+)\t(.*?)\t(True|False)|ERROR\t(.*?))\r?$/gm;

// 查和换都覆盖登记站点所在服务器上的所有站点：没登记的站点一样在用这些证书
const certInstances = (cfg: Config) => [...new Set(Object.values(cfg.sites).flatMap((s) => s.instances))];

export async function checkCerts(cfg: Config): Promise<{ checks: CertCheck[]; failures: string[] }> {
  const ecs = new Ecs(cfg);
  const checks: CertCheck[] = [];
  const failures: string[] = [];
  // 逐台查而不并发：SDK 默认凭证链首次取凭证时并发调用，会有调用拿到链上还没试通的那一环而报错
  for (const instance of certInstances(cfg)) {
    const r = await ecs.runPowerShell(instance, renderScript('certs', {}, ['certcommon']), 300);
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
      else if (days < WARN_DAYS) problems.push('expiring');
      if (nameOk === 'False') problems.push('name mismatch');
      checks.push({ instance, site, binding, expires, days, name, thumbprint, status: problems.join('; ') || 'OK' });
    }
  }
  // 最急的排在最前：握手不上的先看，再按剩余天数
  checks.sort((a, b) => (a.days ?? Number.MIN_SAFE_INTEGER) - (b.days ?? Number.MIN_SAFE_INTEGER));
  return { checks, failures };
}

export function readSource(source: string | undefined, passwordFile?: string): CertSource {
  if (!source) throw new Error('Pass a PFX file, the thumbprint of a certificate on the servers, or --from-cloud <certificate ID>');
  if (!existsSync(source)) {
    const thumbprint = source.toUpperCase();
    if (!/^[0-9A-F]{40}$/.test(thumbprint)) throw new Error(`${source} is neither a PFX file nor a certificate thumbprint`);
    return { kind: 'thumbprint', thumbprint };
  }
  // 密码从文件读，不出现在命令行和 Agent 的上下文里；去掉编辑器加的 BOM 和末尾换行
  const password = passwordFile ? readFileSync(passwordFile, 'utf8').replace(/^\uFEFF/, '').replace(/[\r\n]+$/, '') : '';
  return { kind: 'pfx', bytes: readFileSync(source), password };
}

// 逐台换、一台失败就停：那台服务器会自己换回旧证书，已换好的服务器不动
export async function* replaceCert(cfg: Config, source: CertSource, { check = false, force = false }: ReplaceOptions): AsyncGenerator<[string, RunResult]> {
  // 私钥不能写进 RunCommand（执行记录里查得到命令内容），只能经 OSS 传。传之前用一次性密钥加密：
  // bucket 被别人读到也拿不到私钥，PFX 自己的密码又常常很弱。密钥和 PFX 密码一样随脚本走
  const key = randomBytes(32);
  const blob = source.kind === 'pfx' ? encrypt(source.bytes, key) : undefined;
  const objectName = blob ? `${cfg.oss.prefix ?? ''}certs/${randomBytes(8).toString('hex')}.enc` : '';
  let versionId: string | undefined;
  try {
    if (blob) versionId = await upload(cfg, blob, objectName);
    const ecs = new Ecs(cfg);
    const instances = certInstances(cfg);
    // 换证书前后各握手一遍所有绑定，绑定多、有的握手卡到超时时 300 秒不够
    const timeout = 1800;
    for (const [i, name] of instances.entries()) {
      const script = renderScript('certreplace', {
        URL: objectName && await signForEcs(cfg, objectName, 300), KEY: key.toString('base64'),
        PASSWORD: source.kind === 'pfx' ? source.password : '', THUMBPRINT: source.kind === 'thumbprint' ? source.thumbprint : '',
        CHECK_ONLY: String(check), FORCE: String(force), TIMEOUT: String(timeout),
      }, ['certcommon']);
      const r = await ecs.runPowerShell(name, script, timeout);
      yield [name, r];
      if (r.status !== 'Success') throw new Error(`${name}: ${check ? 'check' : 'replace'} failed, ${instances.length - i - 1} remaining server(s) not processed`);
    }
  } finally {
    // 上传报错也删一次：请求超时时对象可能已经存上了。aca 中途被杀才靠 bucket 的生命周期规则清理
    if (blob) await remove(cfg, objectName, versionId).catch((e: Error) => console.error(`WARN: could not delete the encrypted PFX ${objectName} from OSS: ${e.message}`));
  }
}

// IV 放在密文前面，服务器从头 16 字节取
function encrypt(data: Buffer, key: Buffer): Buffer {
  const iv = randomBytes(16);
  const cipher = createCipheriv('aes-256-cbc', key, iv);
  return Buffer.concat([iv, cipher.update(data), cipher.final()]);
}
