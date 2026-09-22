import { clbOf, outOfClb } from './clb.ts';
import { type Config, getTarget, targetVars } from './config.ts';
import { Ecs, type RunResult } from './ecs.ts';
import { targetLease } from './lease.ts';
import { renderScript, targetLibs } from './ps.ts';

/** log：服务器发布记录里那次发布的一行；被云助手强杀的发布没有，备份太多时较旧的也不带 */
type Backup = { deployId: string; restored: number; added: number; bytes: number; log: string };
/** backups 从新到旧，undo 是其中这次要退的 */
export type RollbackPlan = { since: string; steps: { name: string; backups: Backup[]; undo: Backup[] }[] };

// 备份是一层层叠上去的，退 since 那次发布就得连它之后的一起退。
// 没参与这些发布的服务器跳过，否则会把它更早的备份错灌回去
export async function planRollback(cfg: Config, name: string, deployId?: string): Promise<RollbackPlan> {
  const ecs = new Ecs(cfg);
  const target = getTarget(cfg, name);
  const backups = new Map<string, Backup[]>();
  // 每台服务器按 keep 清理到了哪次发布，没清理过是空串
  const pruned = new Map<string, string>();
  for (const instance of target.instances) {
    const r = await ecs.runPowerShell(instance, renderScript('backups', targetVars(name, target), [...targetLibs(name), 'inspect']), 120);
    if (r.status !== 'Success') throw new Error(`${instance}: failed to list backups: ${r.output.trim() || r.error}`);
    if (r.dropped) throw new Error(`${instance}: Cloud Assistant truncated the backup list by ${r.dropped} bytes; remove old backups before rolling back`);
    // 只认符合格式的行，PowerShell 偶尔混进来的 WARNING 之类不能污染结果
    backups.set(instance, [...r.output.matchAll(/^(\d{8}T\d{6}Z)\|(\d+)\|(\d+)\|(\d+)\|(.*?)\r?$/gm)].map(([, deployId, restored, added, bytes, log]) => (
      { deployId, restored: Number(restored), added: Number(added), bytes: Number(bytes), log }
    )));
    pruned.set(instance, /^pruned\|(.+?)\r?$/m.exec(r.output)?.[1] ?? '');
  }
  const ids = [...backups.values()].flat().map((b) => b.deployId).sort();
  if (!ids.length) throw new Error(`${name} has no backups to roll back to`);
  if (deployId && !ids.includes(deployId)) throw new Error(`No server has a backup of deploy ${deployId}; list the backups that are left with aca rollback ${name} --check`);
  const since = deployId ?? ids.at(-1)!;
  // 清理掉的备份里有 since 或更晚的发布，这台服务器就退不全；跳过它只退其它服务器，各服务器的版本就不一致了
  const broken = [...pruned].find(([, id]) => id >= since);
  if (broken) throw new Error(`${broken[0]} has pruned its backup of deploy ${broken[1]} (keep), so it cannot roll back every deploy since ${since}; to go back further, redeploy an older build`);
  const steps = [...backups].map(([name, list]) => ({ name, backups: list, undo: list.filter((b) => b.deployId >= since) }));
  // 备份按目录名里的服务器时间排先后，服务器时间往回调过，这个先后就和发布 ID 对不上，照着退会退出错的版本
  const disordered = steps.find(({ backups, undo }) => undo.some((b, i) => b !== backups[i] || (i > 0 && b.deployId > undo[i - 1].deployId)));
  if (disordered) throw new Error(`${disordered.name}: its backups of deploy ${since} and later are not in deploy order, most likely because the server clock was set back between deploys; roll this server back by hand`);
  return { since, steps };
}

const mb = (backups: Backup[]) => `${(backups.reduce((sum, b) => sum + b.bytes, 0) / 1048576).toFixed(1)} MB`;

export function printPlan(plan: RollbackPlan) {
  for (const { name, backups, undo } of plan.steps) {
    console.log(`== ${name}: ${backups.length} backup(s), ${mb(backups)}${undo.length ? '' : `; none of deploy ${plan.since} or later, skipped`}`);
    for (const b of backups) {
      console.log(`${undo.includes(b) ? 'undo' : 'keep'}  ${b.deployId}  restore ${b.restored} files, delete ${b.added} added files, ${mb([b])}`);
      if (b.log) console.log(`      ${b.log}`);
    }
  }
}

export async function* rollback(cfg: Config, name: string, deployId?: string): AsyncGenerator<[string, RunResult]> {
  // 计划在租约里算：算完之后别人再发一版，回退就会拿这次发布的备份去盖他那一版
  const held = await targetLease(cfg, name, `rollback ${name}`);
  try {
    const target = getTarget(cfg, name);
    const plan = await planRollback(cfg, name, deployId);
    printPlan(plan);
    const ecs = new Ecs(cfg, held);
    const clb = target.kind === 'site' ? clbOf(cfg, name, held) : undefined;
    const steps = plan.steps.filter((s) => s.undo.length);
    const weights = await clb?.check(steps.map((s) => s.name));
    // 已经留在负载均衡外的先回退：两台服务器的站点发坏一台时，先回退另一台会因为摘了它就没人接流量而报错停下
    steps.sort((a, b) => Number(weights?.get(b.name) === 0) - Number(weights?.get(a.name) === 0));
    for (const { name: instance, undo } of steps) {
      held.check();
      const script = renderScript('rollback', { ...targetVars(name, target), DEPLOYS: undo.map((b) => b.deployId).join('\n') }, [...targetLibs(name), 'inspect', 'release', 'tls']);
      const r = yield* outOfClb(clb, held, instance, () => ecs.runPowerShell(instance, script, 600));
      if (r.status !== 'Success') throw new Error(`${instance}: rollback failed`);
    }
  } finally {
    await held.release();
  }
}
