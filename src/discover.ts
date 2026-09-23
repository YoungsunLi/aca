import { type Config, instanceId } from './config.ts';
import { Ecs, inParallel, records } from './ecs.ts';
import { renderScript } from './ps.ts';

/** 盘点出的一个站点或服务；mine 是能写进配置草稿的：开着的站点，没禁用的服务 */
type Found = { server: string; kind: 'site' | 'service'; name: string; state: string; dir: string; newest: string; detail: string; mine: boolean };
type Draft = { instances: Record<string, string>; sites: Record<string, { instances: string[] }>; services: Record<string, { instances: string[]; dir: string }> };

// 每个站点、服务都要翻一遍目录找最新文件，站点多的服务器要一阵
const TIMEOUT = 600;
const DAY = 86_400_000;

type Discovery = { found: Found[]; failures: string[]; notes: string[]; draft: Draft };

export async function discover(cfg: Config, names: string[]): Promise<Discovery> {
  const ecs = new Ecs(cfg);
  const all = await ecs.listInstances();
  const aliasOf = new Map(Object.entries(cfg.instances).map(([alias, id]) => [id, alias]));
  // 没给服务器就盘点当前地域每台开着的 Windows 服务器；配置里没有别名的，用实例名当别名，重名的用实例 ID
  const servers = names.length
    ? names.map((name) => {
      const id = instanceId(cfg.instances, name);
      return { label: aliasOf.get(id) ?? name, id };
    })
    : all.filter((i) => i.osType === 'windows' && i.status === 'Running').map((i) => ({
      label: aliasOf.get(i.id) ?? (i.name && all.filter((o) => o.name === i.name).length === 1 && !Object.hasOwn(cfg.instances, i.name) ? i.name : i.id),
      id: i.id,
    }));
  const failures: string[] = [];
  const found: Found[] = [];
  // 一台查不了（比如云助手客户端离线）不耽误看别的
  const outputs = await inParallel(cfg, servers.map((s) => s.id), (id) => ecs.runPowerShell(id, renderScript('discover', {}, ['target', 'newest']), TIMEOUT).catch((e: Error) => e));
  for (const [i, r] of outputs.entries()) {
    const { label } = servers[i];
    if (r instanceof Error) failures.push(`${label}: ${r.message.split('\n')[0]}`);
    else if (r.status !== 'Success') failures.push(`${label}: [${r.status}] ${r.output.trim() || r.error}`);
    else {
      if (r.dropped) failures.push(`${label}: Cloud Assistant truncated the output by ${r.dropped} bytes, some sites or services are missing`);
      for (const line of records(r)) {
        const [kind, name, state, dir = '', newest = '', detail = '', mine = ''] = line.split('\t');
        // 只认符合格式的行，PowerShell 偶尔混进来的 WARNING 之类不能污染结果
        if (kind !== 'site' && kind !== 'service') continue;
        found.push({ server: label, kind, name, state, dir, newest, detail, mine: mine === 'True' });
        if (state.startsWith('ERROR: ')) failures.push(`${label}: ${kind} ${name}: ${state.slice(7)}`);
      }
    }
  }
  const { notes, draft } = draftConfig(cfg, found, new Map(servers.map((s) => [s.label, s.id])));
  return { found, failures, notes, draft };
}

function draftConfig(cfg: Config, found: Found[], ids: Map<string, string>): { notes: string[]; draft: Draft } {
  const notes: string[] = [];
  const draft: Draft = { instances: {}, sites: {}, services: {} };
  // IIS 站点名和服务名都不分大小写，各台服务器上的写法可能不同
  const key = (kind: string, name: string) => `${kind}\t${name.toLowerCase()}`;
  const configured = new Set([...Object.keys(cfg.sites).map((n) => key('site', n)), ...Object.keys(cfg.services).map((n) => key('service', n))]);
  const groups = new Map<string, Found[]>();
  for (const f of found) {
    const k = key(f.kind, f.name);
    groups.set(k, [...groups.get(k) ?? [], f]);
  }
  for (const [k, list] of groups) {
    const { kind, name } = list[0];
    if (configured.has(k)) continue;
    let mine = list.filter((f) => f.mine);
    if (!mine.length) continue;
    const left = list.filter((f) => !f.mine).map((f) => `${f.server} (${f.state})`);
    if (left.length) notes.push(`${kind} ${name} is left out of the draft on ${left.join(', ')}`);
    // 配置里一个服务只有一个 dir，目录不一样的只能按多数的那个写
    if (kind === 'service') {
      const count = new Map<string, number>();
      for (const f of mine) count.set(f.dir.toLowerCase(), (count.get(f.dir.toLowerCase()) ?? 0) + 1);
      const [dir] = [...count].sort((a, b) => b[1] - a[1])[0];
      const other = mine.filter((f) => f.dir.toLowerCase() !== dir);
      if (other.length) notes.push(`service ${name} runs from another directory on ${other.map((f) => `${f.server} (${f.dir})`).join(', ')}; the config takes one dir per service, so the draft leaves them out`);
      mine = mine.filter((f) => f.dir.toLowerCase() === dir);
    }
    // 同名的站点在别的服务器上可能是早就不用的副本：最新文件差出一天以上的，发之前先确认
    const times = mine.filter((f) => f.newest).map((f) => ({ server: f.server, t: Date.parse(f.newest.replace(' ', 'T')) }));
    const newest = Math.max(...times.map((x) => x.t));
    const stale = times.filter((x) => newest - x.t > DAY).map((x) => x.server);
    if (stale.length) notes.push(`${kind} ${name}: the newest file on ${stale.join(', ')} is more than a day older than on ${times.find((x) => x.t === newest)!.server}; make sure it is not a stale copy before deploying there`);
    const instances = mine.map((f) => f.server);
    if (kind === 'site') draft.sites[name] = { instances };
    else draft.services[name] = { instances, dir: mine[0].dir };
    // 直接写实例 ID 的不用别名
    for (const server of instances) if (!Object.hasOwn(cfg.instances, server) && server !== ids.get(server)) draft.instances[server] = ids.get(server)!;
  }
  // 配置里站点和服务不能重名：deploy 只给一个名字，分不出发哪个
  for (const name of new Set([...Object.keys(draft.sites), ...Object.keys(draft.services)])) {
    const site = Object.hasOwn(draft.sites, name) || Object.hasOwn(cfg.sites, name);
    const service = Object.hasOwn(draft.services, name) || Object.hasOwn(cfg.services, name);
    if (!site || !service) continue;
    delete draft.sites[name];
    delete draft.services[name];
    notes.push(`a site and a service are both named ${name}, which the config can't hold; the draft leaves ${name} out`);
  }
  return { notes, draft };
}

/** 返回每个站点、服务是否都盘点到了 */
export function printDiscovery({ found, failures, notes, draft }: Discovery): boolean {
  console.log(['Instance', 'Kind', 'Name', 'State', 'Directory', 'Newest file', 'Detail'].join('\t'));
  for (const f of found) console.log([f.server, f.kind, f.name, f.state, f.dir || '-', f.newest || '-', f.detail || '-'].join('\t'));
  for (const n of notes) console.log(`NOTE: ${n}`);
  if (!Object.keys(draft.sites).length && !Object.keys(draft.services).length) console.log('No running site or enabled service is left to configure');
  else {
    // 一个站点、服务一行：几十个站点展开写要几百行
    const block = (key: string, entries: object) => `  "${key}": {${Object.entries(entries).map(([k, v]) => `\n    ${JSON.stringify(k)}: ${JSON.stringify(v)}`).join(',')}\n  }`;
    console.log('Draft config entries for the running sites and enabled services that are not configured yet:');
    console.log(`{\n${[block('instances', draft.instances), block('sites', draft.sites), block('services', draft.services)].join(',\n')}\n}`);
  }
  for (const f of failures) console.error(f);
  return !failures.length;
}