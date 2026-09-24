import { rmSync, statSync } from 'node:fs';
import { open } from 'node:fs/promises';
import { join, win32 } from 'node:path';
import { pipeline } from 'node:stream/promises';
import type { Config } from './config.ts';
import { Ecs, type RunResult } from './ecs.ts';
import { type OssVars, viaOss } from './oss.ts';
import { renderScript } from './ps.ts';

export type Saved = { result: RunResult; saved?: string };

export async function pull(cfg: Config, instance: string, remote: string, local: string): Promise<Saved> {
  const dest = statSync(local, { throwIfNoEntry: false })?.isDirectory() ? join(local, win32.basename(remote)) : local;
  return save(cfg, instance, dest, 'pull', 1800, (vars) => renderScript('pull', { PATH: remote, ...vars }, ['upload']));
}

/** 脚本失败但已经把内容传上来的也存下：aca run -o 要留着失败前的输出 */
export async function save(cfg: Config, instance: string, dest: string, kind: string, timeout: number, script: (vars: OssVars) => string): Promise<Saved> {
  // 动服务器之前先独占创建：本机已有的文件不覆盖（在项目目录里拉 web.config 会盖掉项目自己的那份），同时跑的几个 pull 也不会写进同一个文件
  const out = await open(dest, 'wx');
  let done = false;
  try {
    const { result } = await viaOss(
      cfg,
      kind,
      timeout,
      (vars) => new Ecs(cfg).runPowerShell(instance, script(vars), timeout),
      async (stream) => {
        await pipeline(stream, out.createWriteStream());
        done = true;
      },
    );
    return { result, saved: done ? dest : undefined };
  } finally {
    await out.close();
    // 没拉成就删掉本地文件：空的或只写了一半的会被当成完整的
    if (!done) rmSync(dest);
  }
}
