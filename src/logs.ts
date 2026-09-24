import { text } from 'node:stream/consumers';
import { type Config, getSite, getTarget, targetVars } from './config.ts';
import { Ecs, inParallel, type RunResult } from './ecs.ts';
import { viaOss } from './oss.ts';
import { renderScript, targetLibs } from './ps.ts';

/** 一天的日志能有上百 MB，时间段在文件末尾时要从头读完 */
const TIMEOUT = 600;
const UNIT_MS: Record<string, number> = { m: 60_000, h: 3_600_000, d: 86_400_000 };

export type LogOptions = { tail: string; since?: string; until?: string; httperr?: boolean };
/** lines 是取到的日志行或事件，脚本没跑成时没有 */
export type Tail = { instance: string; result: RunResult; lines?: string }[];

export function readLogs(cfg: Config, site: string, opts: LogOptions) {
  if (opts.httperr && !opts.since) throw new Error('--httperr needs --since: HTTP.sys never deletes its error logs, and without a start aca would read back through all of them');
  return readTail(cfg, 'logs', getSite(cfg, site).instances, { NAME: site, HTTPERR: String(Boolean(opts.httperr)) }, [...targetLibs(cfg, site), 'upload'], opts);
}

export function readEvents(cfg: Config, name: string, opts: LogOptions) {
  const target = getTarget(cfg, name);
  return readTail(cfg, 'events', target.instances, targetVars(name, target), [...targetLibs(cfg, name), 'upload'], opts);
}

async function readTail(cfg: Config, script: string, instances: string[], vars: Record<string, string>, libs: string[], { tail, since, until }: LogOptions): Promise<Tail> {
  const n = Number(tail);
  if (!Number.isInteger(n) || n <= 0) throw new Error(`-n must be a positive integer, got "${tail}"`);
  const all = { ...vars, TAIL: String(n), SINCE: since ? utc(since, '--since') : '', UNTIL: until ? utc(until, '--until') : '' };
  if (all.SINCE && all.UNTIL && all.SINCE > all.UNTIL) throw new Error('--since is later than --until');
  const ecs = new Ecs(cfg);
  // 一台服务器查不了（比如关着机）不耽误看别的，它的错误当作云助手的 Error 结果报
  return inParallel(cfg, instances, async (instance) => {
    try {
      const { result, got } = await viaOss(
        cfg,
        script,
        TIMEOUT,
        (oss) => ecs.runPowerShell(instance, renderScript(script, { ...all, ...oss }, libs), TIMEOUT),
        text,
      );
      return { instance, result, lines: got };
    } catch (e) {
      return { instance, result: { status: 'Error', exitCode: undefined, output: '', error: (e as Error).message, dropped: 0 } };
    }
  });
}

/** 本机时间或往前推的时长，换算成 IIS 日志里 UTC 的写法 */
function utc(value: string, flag: string): string {
  const ago = /^(\d+)([mhd])$/.exec(value);
  const at = /^(\d{4})-(\d\d)-(\d\d)(?:[ T](\d\d):(\d\d)(?::(\d\d))?)?$/.exec(value)?.slice(1).map((v = '0') => Number(v));
  const t = ago ? Date.now() - Number(ago[1]) * UNIT_MS[ago[2]] : at ? localTime(at) : NaN;
  if (Number.isNaN(t)) throw new Error(`${flag} takes a local time like "2026-09-21 10:00" or a duration back from now like 30m, 2h, 1d, got "${value}"`);
  return new Date(t).toISOString().slice(0, 19).replace('T', ' ');
}

// Date 把 2 月 30 日、25 点这种不存在的时间往后顺延而不报错，构造完核对一遍
function localTime([y, mo, d, h, mi, s]: number[]): number {
  const t = new Date(y, mo - 1, d, h, mi, s);
  return [t.getFullYear(), t.getMonth() + 1, t.getDate(), t.getHours(), t.getMinutes(), t.getSeconds()].join() === [y, mo, d, h, mi, s].join() ? t.getTime() : NaN;
}
