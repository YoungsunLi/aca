import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve, win32 } from 'node:path';
import $Credential from '@alicloud/credentials';

type Deployable = {
  /** 部署了它的实例（别名或 ID），顺序即发布顺序 */
  instances: string[];
  /** 源码里的项目名，站点名和它往往对不上 */
  project?: string;
  /** 本地发布输出目录，deploy 不给路径时用它 */
  publish?: string;
  /** 包里不发布的相对路径（目录或文件），如 bin/Res：服务器上自己维护的密钥、环境配置列在这里，发布就不会覆盖 */
  exclude?: string[];
  /** 每台服务器上保留的备份份数，rollback 最多能连退这么多次 */
  keep?: number;
  note?: string;
};
export type Site = Deployable & {
  /** 预发布站：发本站时包必须是那边最近一次发布的同一份 */
  stage?: string;
  /** 站点前面的传统型负载均衡实例 ID：发布、回退每台服务器前把它在默认服务器组里的权重调成 0 */
  clb?: string;
};
export type Service = Deployable & {
  /** 服务器上的安装目录：服务不像 IIS 站点那样能从服务器上查到目录，只能配 */
  dir: string;
};
export type Target = (Site & { kind: 'site' }) | (Service & { kind: 'service' });
export type Config = {
  region: string;
  oss: { bucket: string; prefix?: string };
  /** 实例别名 → 实例 ID，让 sites 里能写 web1 这种可读名字 */
  instances: Record<string, string>;
  /** key 是 IIS 站点名 */
  sites: Record<string, Site>;
  /** key 是 Windows 服务名 */
  services: Record<string, Service>;
  credential: InstanceType<typeof $Credential.default>;
};

// 配置的校验都在这里做一次，后面的代码直接信任它
export function loadConfig(): Config {
  // 不找当前目录：Agent 在别人的仓库里运行时，会悄悄用上那边的配置
  const file = resolve(process.env.ACA_CONFIG || join(homedir(), '.aca', 'config.json'));
  if (!existsSync(file)) throw new Error(`Config file not found: ${file}`);

  const { region, oss, instances = {}, sites = {}, services = {} } = JSON.parse(readFileSync(file, 'utf8'));
  if (!region || !oss?.bucket) throw new Error(`${file}: region and oss.bucket are required`);
  // 兼容控制台里 oss://bucket/ 的写法
  oss.bucket = oss.bucket.replace(/^oss:\/\/|\/$/g, '');
  // OSS 对象名没有前导斜杠，SDK 写的时候会去掉、列举的时候不会，两边对不上租约就形同虚设
  if (oss.prefix) oss.prefix = oss.prefix.replace(/^\/+/, '');
  for (const [name, site] of Object.entries<Site>(sites)) {
    checkDeployable(file, `site "${name}"`, site, instances);
    if (site.stage !== undefined && (typeof site.stage !== 'string' || site.stage === name || !Object.hasOwn(sites, site.stage))) throw new Error(`${file}: stage "${site.stage}" of site "${name}" is not another site in sites`);
    if (site.clb !== undefined && !(typeof site.clb === 'string' && site.clb.startsWith('lb-'))) throw new Error(`${file}: clb of site "${name}" must be a CLB instance ID (lb-...)`);
  }
  for (const [name, service] of Object.entries<Service>(services)) {
    // deploy 只给一个名字，站点和服务重名就分不出发哪个
    if (Object.hasOwn(sites, name)) throw new Error(`${file}: "${name}" is both a site and a service`);
    checkDeployable(file, `service "${name}"`, service, instances);
    if (typeof service.dir !== 'string') throw new Error(`${file}: service "${name}" has no dir`);
    const dir = win32.normalize(service.dir).replace(/\\+$/, '');
    // 备份和发布记录放在这个目录旁边，盘符根和 UNC 路径放不下
    if (!/^[a-zA-Z]:\\[^\\]/.test(dir)) throw new Error(`${file}: dir "${service.dir}" of service "${name}" is not a directory on a local drive, like D:\\Services\\Worker`);
    service.dir = dir;
  }
  // 预发布过的包要和发正式的是同一份，两边 exclude 不同就不是同一份
  for (const [name, site] of Object.entries<Site>(sites)) {
    if (site.stage && (site.exclude ?? []).join('\n') !== (sites[site.stage].exclude ?? []).join('\n')) {
      throw new Error(`${file}: site "${name}" and its stage site "${site.stage}" have different exclude lists`);
    }
  }
  return { region, oss, instances, sites, services, credential: newCredential() };
}

function checkDeployable(file: string, what: string, d: Deployable, aliases: Record<string, string>) {
  if (!d.instances?.length) throw new Error(`${file}: ${what} has no instances`);
  const bad = d.instances.find((i) => !Object.hasOwn(aliases, i) && !i.startsWith('i-'));
  if (bad) throw new Error(`${file}: "${bad}" in ${what} is neither an alias from instances nor an instance ID`);
  if (d.keep !== undefined && !(Number.isInteger(d.keep) && d.keep > 0)) throw new Error(`${file}: keep of ${what} must be a positive integer`);
  if (d.exclude !== undefined) {
    if (!Array.isArray(d.exclude) || !d.exclude.every((p) => typeof p === 'string')) throw new Error(`${file}: exclude of ${what} must be an array of paths`);
    // 服务器端按 Windows 相对路径做前缀匹配，统一成 bin\Res 的形式；带 . 和 .. 的写法匹配不上会悄悄失效。
    // 排序是因为包 ID 要算进 exclude，写的顺序不同也得是同一个 ID
    d.exclude = d.exclude.map((p) => {
      const n = win32.normalize(p).replace(/^\\+|\\+$/g, '');
      if (!n || n === '.' || n === '..' || n.startsWith('..\\') || win32.isAbsolute(n)) throw new Error(`${file}: exclude "${p}" of ${what} is not a relative path inside the package`);
      return n;
    }).sort();
  }
}

// SDK 的默认凭证链除了环境变量还读 aliyun configure 写的 ~/.aliyun/config.json，和阿里云 CLI 共用一份凭证。
// 它的报错会原样带上那个文件或服务端响应的内容，打印前把密钥遮掉
function newCredential() {
  const chain = $Credential.DefaultCredentialsProvider.builder().build();
  return new $Credential.default(null, {
    getProviderName: () => chain.getProviderName(),
    getCredentials: () => chain.getCredentials().catch((e: Error) => {
      throw new Error(e.message.replace(/((?:secret|token)\w*"?\s*[:=]\s*"?)[^"\s,}]+/gi, '$1***'));
    }),
  });
}

/** 配置里的实例可以写别名，也可以直接写实例 ID */
export const instanceId = (aliases: Record<string, string>, name: string) => aliases[name] ?? name;

export function getSite(cfg: Config, name: string): Site {
  const site = cfg.sites[name];
  if (!site) throw new Error(`No site "${name}" in the config; configured sites: ${Object.keys(cfg.sites).join(', ') || '(none)'}`);
  return site;
}

export function getTarget(cfg: Config, name: string): Target {
  if (Object.hasOwn(cfg.sites, name)) return { kind: 'site', ...cfg.sites[name] };
  if (Object.hasOwn(cfg.services, name)) return { kind: 'service', ...cfg.services[name] };
  throw new Error(`No site or service "${name}" in the config; configured: ${[...Object.keys(cfg.sites), ...Object.keys(cfg.services)].join(', ') || '(none)'}`);
}

/** 服务器上的脚本用 DIR 是否为空分辨站点和服务 */
export const targetVars = (name: string, target: Target) => ({ NAME: name, DIR: target.kind === 'service' ? target.dir : '' });
