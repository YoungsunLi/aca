import { text } from 'node:stream/consumers';
import { type Config, getTarget, targetVars } from './config.ts';
import { Ecs, inParallel } from './ecs.ts';
import { viaOss } from './oss.ts';
import { renderScript, targetLibs } from './ps.ts';

/** 整个目录要逐个文件算哈希，时限和发布一样给足 */
const TIMEOUT = 1800;
/** 列到这个数为止，再多就只给目录汇总：一台服务器整个没发上时差异有成千上万条 */
const MAX_FILES = 50;
const ROOT = '(root)';

type Entry = { path: string; hash: string; time: string };
const MISSING = { hash: '', time: '' };
type Listing = { instance: string; scope: string; files: number; bytes: number; entries: Map<string, Entry> };
/** 内容相同的服务器归一组，组多于一个这个文件就是漂的 */
type Group = { hash: string; time: string; instances: string[] };
export type Drift = { target: string; sub: string; listings: Listing[]; compared: number; files: { path: string; groups: Group[] }[] };

export async function diff(cfg: Config, name: string, sub: string): Promise<Drift> {
  const target = getTarget(cfg, name);
  if (target.instances.length < 2) throw new Error(`${name} runs on a single server (${target.instances[0]}), so there is nothing to compare`);
  const ecs = new Ecs(cfg);
  const vars = { ...targetVars(name, target), SUBPATH: sub, EXCLUDE: (target.exclude ?? []).join('\n') };
  const listings = await inParallel(cfg, target.instances, (instance) => listFiles(cfg, ecs, vars, instance));
  // 所有服务器上的文件，键是比对用的小写路径，值是报出来时用的原样写法
  const paths = new Map<string, string>();
  for (const l of listings) for (const [key, e] of l.entries) paths.set(key, e.path);
  const files = [];
  for (const key of [...paths.keys()].sort()) {
    const groups: Group[] = [];
    for (const { instance, entries } of listings) {
      const { hash, time } = entries.get(key) ?? MISSING;
      const same = groups.find((g) => g.hash === hash);
      if (same) same.instances.push(instance);
      else groups.push({ hash, time, instances: [instance] });
    }
    if (groups.length > 1) files.push({ path: paths.get(key)!, groups });
  }
  return { target: name, sub, listings, compared: paths.size, files };
}

async function listFiles(cfg: Config, ecs: Ecs, vars: Record<string, string>, instance: string): Promise<Listing> {
  const { result, got } = await viaOss(
    cfg,
    'diff',
    TIMEOUT,
    (oss) => ecs.runPowerShell(instance, renderScript('diff', { ...vars, ...oss }, [...targetLibs(cfg, vars.NAME), 'upload']), TIMEOUT),
    text,
  );
  if (result.status !== 'Success') throw new Error(`${instance}: could not list the files: ${result.output.trim() || result.error}`);
  const summary = /^(.+)\|(\d+)\|(\d*)\r?$/m.exec(result.output);
  if (!summary) throw new Error(`${instance}: listed the files but printed no summary line: ${result.output.trim()}`);
  const entries = new Map<string, Entry>();
  for (const line of got!.split(/\r?\n/)) {
    const [path, hash, time] = line.split('|');
    // 路径按小写认：Windows 不分大小写，同一个文件在两台服务器上写法可能不同
    if (hash) entries.set(path.toLowerCase(), { path, hash, time });
  }
  return { instance, scope: summary[1], files: Number(summary[2]), bytes: Number(summary[3]), entries };
}

/** 返回各台服务器是否一致 */
export function printDiff({ target, sub, listings, compared, files }: Drift): boolean {
  for (const l of listings) console.log(`== ${l.instance}  ${l.scope}  ${l.files} files, ${(l.bytes / 1048576).toFixed(1)} MB`);
  if (!files.length) {
    console.log(`OK: all ${listings.length} servers have the same ${compared} files`);
    return true;
  }
  console.log(`${files.length} of ${compared} files differ across ${listings.length} servers`);
  console.log(['Path', 'Servers'].join('\t'));
  for (const { path, groups } of files.slice(0, MAX_FILES)) {
    console.log([path, ...groups.map((g) => `${g.instances.join(',')}=${g.hash ? `${g.hash.slice(0, 8)} ${g.time}` : 'missing'}`)].join('\t'));
  }
  if (files.length > MAX_FILES) {
    console.log(`... and ${files.length - MAX_FILES} more`);
    printDirs(target, sub, files);
  }
  return false;
}

// 差异几千条时列不完，按比对范围下一层归类，看清楚落在哪几个目录，再挑一个比
function printDirs(target: string, sub: string, files: Drift['files']) {
  const dirs = new Map<string, number>();
  for (const { path } of files) {
    const rest = sub ? path.slice(sub.length + 1) : path;
    const dir = rest.includes('\\') ? rest.slice(0, rest.indexOf('\\')) : ROOT;
    dirs.set(dir, (dirs.get(dir) ?? 0) + 1);
  }
  // 差异全在同一个目录里，汇总一遍没有新东西
  if (dirs.size < 2) return;
  const sorted = [...dirs].sort((a, b) => b[1] - a[1]);
  console.log(['Directory', 'Files differing'].join('\t'));
  for (const [dir, n] of sorted) console.log([dir, n].join('\t'));
  const next = sorted.find(([dir]) => dir !== ROOT)?.[0];
  if (next) console.log(`Narrow it down with: aca diff "${target}" "${sub ? `${sub}\\${next}` : next}"`);
}
