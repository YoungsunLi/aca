import { createHash, randomBytes } from 'node:crypto';
import { once } from 'node:events';
import { createReadStream, createWriteStream, readdirSync, readFileSync, statSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ZipArchive } from 'archiver';
import { type Config, getSite } from './config.ts';
import { Ecs, type RunResult } from './ecs.ts';
import { signForEcs, upload } from './oss.ts';
import { renderScript } from './ps.ts';

export type DeployOptions = { check?: boolean; message?: string; force?: boolean; skipStage?: boolean };
/** id 是 zip 里字节加 exclude 的内容哈希：同一目录重新构建后 DLL 会变，exclude 改了服务器实际收到的也变。
 *  sha256 是整个 zip 文件的、和 id 出自同一次读取，服务器下载后核对它，发出去的就一定是 id 说的那份 */
type Package = { zip: string; id: string; sha256: string };

// 多台服务器按配置顺序逐台发布，一台失败就停：坏包只影响一台，负载均衡下其余服务器继续服务
export async function* deploy(cfg: Config, site: string, path: string | undefined, { check = false, message = '', force = false, skipStage = false }: DeployOptions): AsyncGenerator<[string, RunResult]> {
  const { instances, publish, exclude = [], stage, keep = 5 } = getSite(cfg, site);
  const localPath = path ?? publish;
  if (!localPath) throw new Error(`No package path given and site ${site} has no publish directory in the config`);
  const isDir = statSync(localPath).isDirectory();
  if (!isDir && !localPath.toLowerCase().endsWith('.zip')) throw new Error(`${localPath} is neither a directory nor a .zip file`);

  const deployId = new Date().toISOString().replace(/[-:]|\.\d+/g, '');
  // deployId 只到秒，本地临时 zip 和 OSS 对象名都带随机串，同一秒起的两次发布才不会互相覆盖对方的包
  const pkgName = `${deployId}-${randomBytes(4).toString('hex')}`;
  // 先定格再核对、上传：ID 和上传的必须是同一份字节，目录在这期间还可能被构建改写
  const pkg = isDir ? await zipDir(localPath, join(tmpdir(), `aca-${pkgName}.zip`), exclude) : await hashZip(localPath, exclude);
  const ecs = new Ecs(cfg);
  const objectName = `${cfg.oss.prefix ?? ''}${site}/${pkgName}.zip`;
  try {
    if (stage && !skipStage) await assertStaged(cfg, ecs, stage, pkg.id);
    await upload(cfg, pkg.zip, objectName);
  } finally {
    if (isDir) unlinkSync(pkg.zip);
  }

  const timeout = 1800;
  for (const [i, name] of instances.entries()) {
    // 每台服务器现签一个链接，有效期同这台的运行时限：STS 类凭证签出的链接随 token 失效，整批共用一个，排在后面的服务器会下载失败
    const script = renderScript('deploy', {
      SITE: site, URL: await signForEcs(cfg, objectName, timeout), SHA256: pkg.sha256, DEPLOY_ID: deployId, PACKAGE: pkg.id, MESSAGE: message,
      CHECK_ONLY: String(check), FORCE: String(force), EXCLUDE: exclude.join('\n'), KEEP: String(keep),
    });
    const r = await ecs.runPowerShell(name, script, timeout);
    yield [name, r];
    if (r.status !== 'Success') throw new Error(`${name}: ${check ? 'pre-check' : 'deploy'} failed, ${instances.length - i - 1} remaining server(s) not processed`);
  }
}

function newHash(exclude: string[]) {
  return createHash('sha256').update(`exclude:${exclude.join('\n')}\n`);
}

async function hashZip(path: string, exclude: string[]): Promise<Package> {
  const id = newHash(exclude);
  const sha256 = createHash('sha256');
  for await (const chunk of createReadStream(path)) {
    id.update(chunk as Buffer);
    sha256.update(chunk as Buffer);
  }
  return { zip: path, id: id.digest('hex').slice(0, 12), sha256: sha256.digest('hex') };
}

// 要求预发布站每台服务器的最后一条记录都是这个包的成功发布：最后一条是回退或失败，说明这一版在预发布没过。
// 锚定整行前缀，-m 里写什么都伪造不出成功记录
async function assertStaged(cfg: Config, ecs: Ecs, stage: string, packageId: string) {
  for (const name of getSite(cfg, stage).instances) {
    const r = await ecs.runPowerShell(name, renderScript('lastdeploy', { SITE: stage }), 60);
    if (r.status !== 'Success') throw new Error(`Failed to read the deploy log of stage site ${stage} (${name}): ${r.output.trim() || r.error}`);
    const last = r.output.trim();
    if (/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \| deploy \S+ \| pkg=([0-9a-f]+) \| /.exec(last)?.[1] !== packageId) {
      throw new Error(`Package ${packageId} is not the latest deploy on stage site ${stage} (${name}), whose last log entry is: ${last || '(none)'}; deploy to the stage site first, or pass --skip-stage`);
    }
  }
  console.log(`Stage site ${stage} last deployed this same package ${packageId}`);
}

// 等 archiver 写完一个条目再读下一个文件，内存里只有一个文件；哈希的就是写进 zip 的那份字节
async function zipDir(dir: string, out: string, exclude: string[]): Promise<Package> {
  const hash = newHash(exclude);
  const sha256 = createHash('sha256');
  // zip 里存本地时间，否则服务器上解出来的文件时间会差一个时区，对不上本地编译时间
  const archive = new ZipArchive({ zlib: { level: 6 }, forceLocalTime: true });
  const closed = new Promise<void>((resolve, reject) => {
    archive.on('error', reject);
    archive.pipe(createWriteStream(out).on('close', resolve).on('error', reject));
  });
  closed.catch(() => {});
  archive.on('data', (chunk: Buffer) => sha256.update(chunk));
  for (const rel of readdirSync(dir, { recursive: true, encoding: 'utf8' }).sort()) {
    const full = join(dir, rel);
    const stat = statSync(full);
    if (stat.isDirectory()) continue;
    const bytes = readFileSync(full);
    const name = rel.replaceAll('\\', '/');
    // 名字和内容都带长度，文件内容里的分隔符才伪造不出另一组文件
    hash.update(`${name.length}:${name}:${bytes.length}:`).update(bytes);
    const written = once(archive, 'entry');
    archive.append(bytes, { name, date: stat.mtime });
    await written;
  }
  await archive.finalize();
  await closed;
  return { zip: out, id: hash.digest('hex').slice(0, 12), sha256: sha256.digest('hex') };
}
