import { type Config, getTarget } from './config.ts';
import { Ecs, inParallel, type RunResult } from './ecs.ts';
import { renderScript, targetLibs } from './ps.ts';

/** 每个站点和服务在每台服务器上一行：目标、服务器、状态、最新文件的时间、最后一条发布或回退记录；查不了的，状态是 ERROR: 原因 */
export async function overview(cfg: Config): Promise<string[][]> {
  // 服务带上目录，脚本靠它分辨站点和服务
  const targets = [...Object.keys(cfg.sites), ...Object.keys(cfg.services)].map((name) => {
    const target = getTarget(cfg, name);
    return { name, instances: target.instances, line: target.kind === 'service' ? `${name}\t${target.dir}` : name };
  });
  // 一台服务器只跑一次，查完它上面所有的目标
  const onServer = new Map<string, typeof targets>();
  for (const t of targets) for (const instance of t.instances) onServer.set(instance, [...onServer.get(instance) ?? [], t]);
  const ecs = new Ecs(cfg);
  const instances = [...onServer.keys()];
  // 一台服务器查不了（比如关着机）不耽误看别的
  const results = await inParallel(cfg, instances, (instance) => (
    ecs.runPowerShell(instance, renderScript('overview', { TARGETS: onServer.get(instance)!.map((t) => t.line).join('\n') }, [...targetLibs(...onServer.get(instance)!.map((t) => t.name)), 'inspect', 'newest']), 300).catch((e: Error) => e)
  ));
  const lookups = new Map(instances.map((instance, i) => [instance, lookup(results[i])]));
  return targets.flatMap((t) => t.instances.map((instance) => [t.name, instance, ...lookups.get(instance)!(onServer.get(instance)!.indexOf(t))]));
}

function lookup(r: RunResult | Error): (index: number) => string[] {
  const failed = (error: string) => () => [error, '-', '-'];
  if (r instanceof Error) return failed(`ERROR: ${r.message.split('\n')[0]}`);
  if (r.status !== 'Success') return failed(`ERROR: [${r.status}] ${r.error}`.trimEnd());
  // 截断处可能落在哪一行中间，哪一行都信不过
  if (r.dropped) return failed(`ERROR: Cloud Assistant truncated the output by ${r.dropped} bytes`);
  const rows = new Map(r.output.split(/\r?\n/).filter(Boolean).map((row) => {
    const [index, ...rest] = row.split('\t');
    return [index, rest];
  }));
  return (index) => {
    const [state, newest, last] = rows.get(String(index)) ?? ['ERROR: the server printed no line for it'];
    return [state, newest || '-', last || '-'];
  };
}
