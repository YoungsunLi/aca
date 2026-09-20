import { rmSync, statSync } from 'node:fs';
import { open } from 'node:fs/promises';
import { join, win32 } from 'node:path';
import { pipeline } from 'node:stream/promises';
import type { Config } from './config.ts';
import { Ecs, type RunResult } from './ecs.ts';
import { viaOss } from './oss.ts';
import { renderScript } from './ps.ts';

export async function pull(cfg: Config, instance: string, remote: string, local: string): Promise<{ result: RunResult; saved?: string }> {
  const dest = statSync(local, { throwIfNoEntry: false })?.isDirectory() ? join(local, win32.basename(remote)) : local;
  // 动服务器之前先独占创建：本机已有的文件不覆盖（在项目目录里拉 web.config 会盖掉项目自己的那份），同时跑的几个 pull 也不会写进同一个文件
  const out = await open(dest, 'wx');
  const timeout = 1800;
  let done = false;
  try {
    const { result } = await viaOss(
      cfg,
      'pull',
      timeout,
      (vars) => new Ecs(cfg).runPowerShell(instance, renderScript('pull', { PATH: remote, ...vars }, ['upload']), timeout),
      (stream) => pipeline(stream, out.createWriteStream()),
    );
    done = result.status === 'Success';
    return { result, saved: done ? dest : undefined };
  } finally {
    await out.close();
    // 没拉成就删掉本地文件：空的或只写了一半的会被当成完整的
    if (!done) rmSync(dest);
  }
}
