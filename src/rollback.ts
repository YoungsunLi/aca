import { type Config, getSite } from './config.ts';
import { Ecs, type RunResult } from './ecs.ts';
import { renderScript } from './ps.ts';

type Backup = { dir: string; deployId: string; restored: number; added: number };
export type RollbackPlan = { site: string; deployId: string; steps: { name: string; backup?: Backup }[] };

// 没参与最新那次发布的机器跳过，否则会把它更早的备份错灌回去
export async function planRollback(cfg: Config, site: string): Promise<RollbackPlan> {
  const ecs = new Ecs(cfg);
  const backups = new Map<string, Backup[]>();
  for (const name of getSite(cfg, site).instances) {
    const r = await ecs.runPowerShell(name, renderScript('backups', { SITE: site }), 120);
    if (r.status !== 'Success') throw new Error(`${name}: failed to list backups: ${r.output.trim() || r.error}`);
    if (r.dropped) throw new Error(`${name}: Cloud Assistant truncated the backup list by ${r.dropped} bytes; remove old backups before rolling back`);
    // 只认符合格式的行，PowerShell 偶尔混进来的 WARNING 之类不能污染结果
    backups.set(name, [...r.output.matchAll(/^(.+)\|(\S+)\|(\d+)\|(\d+)\r?$/gm)].map(([, dir, deployId, restored, added]) => (
      { dir, deployId, restored: Number(restored), added: Number(added) }
    )));
  }
  const deployId = [...backups.values()].flat().map((b) => b.deployId).sort().at(-1);
  if (!deployId) throw new Error(`${site} has no backups to roll back to`);
  return { site, deployId, steps: [...backups].map(([name, list]) => ({ name, backup: list.find((b) => b.deployId === deployId) })) };
}

export async function* rollback(cfg: Config, plan: RollbackPlan): AsyncGenerator<[string, RunResult]> {
  const ecs = new Ecs(cfg);
  for (const { name, backup } of plan.steps) {
    if (!backup) continue;
    const r = await ecs.runPowerShell(name, renderScript('rollback', { SITE: plan.site, BACKUP: backup.dir }), 600);
    yield [name, r];
    if (r.status !== 'Success') throw new Error(`${name}: rollback failed`);
  }
}
