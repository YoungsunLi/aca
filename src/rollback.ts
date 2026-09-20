import { clbOf, outOfClb } from './clb.ts';
import { type Config, getTarget, targetVars } from './config.ts';
import { Ecs, type RunResult } from './ecs.ts';
import { targetLease } from './lease.ts';
import { renderScript } from './ps.ts';

type Backup = { dir: string; deployId: string; restored: number; added: number };
export type RollbackPlan = { deployId: string; steps: { name: string; backup?: Backup }[] };

// 没参与最新那次发布的机器跳过，否则会把它更早的备份错灌回去
export async function planRollback(cfg: Config, name: string): Promise<RollbackPlan> {
  const ecs = new Ecs(cfg);
  const target = getTarget(cfg, name);
  const backups = new Map<string, Backup[]>();
  // 每台服务器按 keep 清理到了哪次发布，没清理过是空串
  const pruned = new Map<string, string>();
  for (const instance of target.instances) {
    const r = await ecs.runPowerShell(instance, renderScript('backups', targetVars(name, target), ['target']), 120);
    if (r.status !== 'Success') throw new Error(`${instance}: failed to list backups: ${r.output.trim() || r.error}`);
    if (r.dropped) throw new Error(`${instance}: Cloud Assistant truncated the backup list by ${r.dropped} bytes; remove old backups before rolling back`);
    // 只认符合格式的行，PowerShell 偶尔混进来的 WARNING 之类不能污染结果
    backups.set(instance, [...r.output.matchAll(/^(.+)\|(\S+)\|(\d+)\|(\d+)\r?$/gm)].map(([, dir, deployId, restored, added]) => (
      { dir, deployId, restored: Number(restored), added: Number(added) }
    )));
    pruned.set(instance, /^pruned\|(.+?)\r?$/m.exec(r.output)?.[1] ?? '');
  }
  const deployId = [...backups.values()].flat().map((b) => b.deployId).sort().at(-1);
  if (!deployId) throw new Error(`${name} has no backups to roll back to`);
  const steps = [...backups].map(([name, list]) => ({ name, backup: list.find((b) => b.deployId === deployId) }));
  // 清理到这次或更晚发布的机器缺这份备份，可能是备份被清理了而不是没参与；跳过它只退其它服务器，各服务器的版本就不一致了
  const unsure = steps.find(({ name, backup }) => !backup && pruned.get(name)! >= deployId);
  if (unsure) throw new Error(`${unsure.name} has pruned backups (keep) up to deploy ${pruned.get(unsure.name)}, so it cannot tell whether it missed deploy ${deployId} or its backup was pruned; to go back further, redeploy an older build`);
  return { deployId, steps };
}

export function printPlan(plan: RollbackPlan) {
  for (const { name, backup } of plan.steps) {
    console.log(`== ${name}: ${backup
      ? `roll back deploy ${plan.deployId}: restore ${backup.restored} files, delete ${backup.added} added files  (${backup.dir})`
      : `no backup of deploy ${plan.deployId}, skipped`}`);
  }
}

export async function* rollback(cfg: Config, name: string): AsyncGenerator<[string, RunResult]> {
  // 计划在租约里算：算完之后别人再发一版，回退就会拿这次发布的备份去盖他那一版
  const held = await targetLease(cfg, name, `rollback ${name}`);
  try {
    const target = getTarget(cfg, name);
    const plan = await planRollback(cfg, name);
    printPlan(plan);
    const ecs = new Ecs(cfg, held);
    const clb = target.kind === 'site' ? clbOf(cfg, name, held) : undefined;
    const steps = plan.steps.filter((s) => s.backup);
    const weights = await clb?.check(steps.map((s) => s.name));
    // 已经留在负载均衡外的先回退：两台服务器的站点发坏一台时，先回退另一台会因为摘了它就没人接流量而报错停下
    steps.sort((a, b) => Number(weights?.get(b.name) === 0) - Number(weights?.get(a.name) === 0));
    for (const { name: instance, backup } of steps) {
      held.check();
      const script = renderScript('rollback', { ...targetVars(name, target), BACKUP: backup!.dir }, ['target']);
      const r = yield* outOfClb(clb, held, instance, () => ecs.runPowerShell(instance, script, 600));
      if (r.status !== 'Success') throw new Error(`${instance}: rollback failed`);
    }
  } finally {
    await held.release();
  }
}
