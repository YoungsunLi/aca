import { createWriteStream, statSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ZipArchive } from 'archiver';
import { type Config, getSite } from './config.ts';
import { Ecs, type RunResult } from './ecs.ts';
import { signForEcs, upload } from './oss.ts';
import { renderScript } from './ps.ts';

export type DeployOptions = { check?: boolean; message?: string };

// 多台服务器按配置顺序逐台发布，一台失败就停：坏包只影响一台，负载均衡下其余服务器继续服务
export async function* deploy(cfg: Config, site: string, path: string | undefined, { check = false, message = '' }: DeployOptions): AsyncGenerator<[string, RunResult]> {
  const { instances, publish, exclude = [] } = getSite(cfg, site);
  const localPath = path ?? publish;
  if (!localPath) throw new Error(`No package path given and site ${site} has no publish directory in the config`);
  const isDir = statSync(localPath).isDirectory();
  if (!isDir && !localPath.toLowerCase().endsWith('.zip')) throw new Error(`${localPath} is neither a directory nor a .zip file`);

  const deployId = new Date().toISOString().replace(/[-:]|\.\d+/g, '');
  const zip = isDir ? await zipDir(localPath, join(tmpdir(), `aca-${deployId}.zip`)) : localPath;
  const objectName = `${cfg.oss.prefix ?? ''}${site}/${deployId}.zip`;
  await upload(cfg, zip, objectName);
  if (isDir) unlinkSync(zip);

  const ecs = new Ecs(cfg);
  const timeout = 1800;
  for (const [i, name] of instances.entries()) {
    // 每台服务器现签一个链接，有效期同这台的运行时限：STS 类凭证签出的链接随 token 失效，整批共用一个，排在后面的服务器会下载失败
    const script = renderScript('deploy', {
      SITE: site, URL: await signForEcs(cfg, objectName, timeout), DEPLOY_ID: deployId, MESSAGE: message,
      CHECK_ONLY: String(check), EXCLUDE: exclude.join('\n'),
    });
    const r = await ecs.runPowerShell(name, script, timeout);
    yield [name, r];
    if (r.status !== 'Success') throw new Error(`${name}: ${check ? 'pre-check' : 'deploy'} failed, ${instances.length - i - 1} remaining server(s) not processed`);
  }
}

function zipDir(dir: string, out: string): Promise<string> {
  return new Promise((resolve, reject) => {
    // zip 里存本地时间，否则服务器上解出来的文件时间会差一个时区，对不上本地编译时间
    const archive = new ZipArchive({ zlib: { level: 6 }, forceLocalTime: true });
    archive.on('error', reject);
    // archiver 读不到的文件（被占用、刚被删）只发 warning 然后跳过，那样会打出缺文件的包
    archive.on('warning', reject);
    archive.pipe(createWriteStream(out).on('close', () => resolve(out)).on('error', reject));
    archive.directory(dir, false);
    archive.finalize().catch(reject);
  });
}
