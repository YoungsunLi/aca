import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve, win32 } from 'node:path';
import $Credential from '@alicloud/credentials';

export type Site = {
  /** 部署了该站点的实例（别名或 ID），顺序即发布顺序 */
  instances: string[];
  /** 源码里的项目名，站点名和它往往对不上 */
  project?: string;
  /** 本地发布输出目录，deploy 不给路径时用它 */
  publish?: string;
  /** 包里不发布的相对路径（目录或文件），如 bin/Res：服务器上自己维护的密钥、环境配置列在这里，发布就不会覆盖 */
  exclude?: string[];
  /** 预发布站：发本站时包必须是那边最近一次发布的同一份 */
  stage?: string;
  /** 每台服务器上为本站保留的备份份数，rollback 最多能连退这么多次 */
  keep?: number;
  /** 站点前面的传统型负载均衡实例 ID：发布、回退每台服务器前把它在默认服务器组里的权重调成 0 */
  clb?: string;
  note?: string;
};
export type Config = {
  region: string;
  oss: { bucket: string; prefix?: string };
  /** 实例别名 → 实例 ID，让 sites 里能写 web1 这种可读名字 */
  instances: Record<string, string>;
  /** key 是 IIS 站点名 */
  sites: Record<string, Site>;
  credential: InstanceType<typeof $Credential.default>;
};

// 配置的校验都在这里做一次，后面的代码直接信任它
export function loadConfig(): Config {
  // 不找当前目录：Agent 在别人的仓库里运行时，会悄悄用上那边的配置
  const file = resolve(process.env.ACA_CONFIG || join(homedir(), '.aca', 'config.json'));
  if (!existsSync(file)) throw new Error(`Config file not found: ${file}`);

  const { region, oss, instances = {}, sites = {} } = JSON.parse(readFileSync(file, 'utf8'));
  if (!region || !oss?.bucket) throw new Error(`${file}: region and oss.bucket are required`);
  // 兼容控制台里 oss://bucket/ 的写法
  oss.bucket = oss.bucket.replace(/^oss:\/\/|\/$/g, '');
  for (const [name, site] of Object.entries<Site>(sites)) {
    if (!site.instances?.length) throw new Error(`${file}: site "${name}" has no instances`);
    const bad = site.instances.find((i) => !Object.hasOwn(instances, i) && !i.startsWith('i-'));
    if (bad) throw new Error(`${file}: "${bad}" in site "${name}" is neither an alias from instances nor an instance ID`);
    if (site.stage !== undefined && (typeof site.stage !== 'string' || site.stage === name || !Object.hasOwn(sites, site.stage))) throw new Error(`${file}: stage "${site.stage}" of site "${name}" is not another site in sites`);
    if (site.keep !== undefined && !(Number.isInteger(site.keep) && site.keep > 0)) throw new Error(`${file}: keep of site "${name}" must be a positive integer`);
    if (site.clb !== undefined && !(typeof site.clb === 'string' && site.clb.startsWith('lb-'))) throw new Error(`${file}: clb of site "${name}" must be a CLB instance ID (lb-...)`);
    if (site.exclude !== undefined) {
      if (!Array.isArray(site.exclude) || !site.exclude.every((p) => typeof p === 'string')) throw new Error(`${file}: exclude of site "${name}" must be an array of paths`);
      // 服务器端按 Windows 相对路径做前缀匹配，统一成 bin\Res 的形式；带 . 和 .. 的写法匹配不上会悄悄失效。
      // 排序是因为包 ID 要算进 exclude，写的顺序不同也得是同一个 ID
      site.exclude = site.exclude.map((p) => {
        const n = win32.normalize(p).replace(/^\\+|\\+$/g, '');
        if (!n || n === '.' || n === '..' || n.startsWith('..\\') || win32.isAbsolute(n)) throw new Error(`${file}: exclude "${p}" of site "${name}" is not a relative path inside the package`);
        return n;
      }).sort();
    }
  }
  // 预发布过的包要和发正式的是同一份，两边 exclude 不同就不是同一份
  for (const [name, site] of Object.entries<Site>(sites)) {
    if (site.stage && (site.exclude ?? []).join('\n') !== (sites[site.stage].exclude ?? []).join('\n')) {
      throw new Error(`${file}: site "${name}" and its stage site "${site.stage}" have different exclude lists`);
    }
  }
  return { region, oss, instances, sites, credential: newCredential() };
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
