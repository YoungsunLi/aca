import { createDecipheriv, randomBytes } from 'node:crypto';
import { rmSync, statSync } from 'node:fs';
import { open } from 'node:fs/promises';
import { join, win32 } from 'node:path';
import { pipeline } from 'node:stream/promises';
import type { Config } from './config.ts';
import { Ecs, type RunResult } from './ecs.ts';
import { download, remove, signForEcs } from './oss.ts';
import { renderScript } from './ps.ts';

// 文件经 OSS 中转：云助手的输出有上限。服务器用一次性密钥加密后才上传：
// 拉的常是带连接串的 web.config，bucket 被别人读到也看不到内容
export async function pull(cfg: Config, instance: string, remote: string, local: string): Promise<{ result: RunResult; saved?: string }> {
  const dest = statSync(local, { throwIfNoEntry: false })?.isDirectory() ? join(local, win32.basename(remote)) : local;
  // 动服务器之前先独占创建：本机已有的文件不覆盖（在项目目录里拉 web.config 会盖掉项目自己的那份），同时跑的几个 pull 也不会写进同一个文件
  const out = await open(dest, 'wx');
  const key = randomBytes(32);
  const iv = randomBytes(16);
  const objectName = `${cfg.oss.prefix ?? ''}pull/${randomBytes(8).toString('hex')}.enc`;
  const timeout = 1800;
  let versionId: string | undefined;
  let done = false;
  try {
    const result = await new Ecs(cfg).runPowerShell(instance, renderScript('pull', {
      PATH: remote, URL: await signForEcs(cfg, objectName, timeout, 'PUT'), KEY: key.toString('base64'), IV: iv.toString('base64'),
    }), timeout);
    if (result.status !== 'Success') return { result };
    const got = await download(cfg, objectName);
    versionId = got.versionId;
    await pipeline(got.stream, createDecipheriv('aes-256-cbc', key, iv), out.createWriteStream());
    done = true;
    return { result, saved: dest };
  } finally {
    // 脚本失败或轮询出错时也删一次：服务器那边可能已经传上去了
    await remove(cfg, objectName, versionId).catch((e: Error) => console.error(`WARN: could not delete ${objectName} from OSS: ${e.message}`));
    await out.close();
    // 没拉成就删掉本地文件：空的或只写了一半的会被当成完整的
    if (!done) rmSync(dest);
  }
}
