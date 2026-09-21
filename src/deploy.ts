import { createHash, randomBytes } from 'node:crypto';
import { once } from 'node:events';
import { createReadStream, createWriteStream, rmSync, statSync } from 'node:fs';
import { copyFile, readdir, readFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ZipArchive } from 'archiver';
import { clbOf, outOfClb } from './clb.ts';
import { type Config, getSite, getTarget, targetVars } from './config.ts';
import { Ecs, inParallel, type RunResult } from './ecs.ts';
import { targetLease } from './lease.ts';
import { exists, signForEcs, upload } from './oss.ts';
import { renderScript } from './ps.ts';

export type DeployOptions = { check?: boolean; message?: string; force?: boolean; skipStage?: boolean; fromStage?: boolean };
type Package = { id: string; sha256: string };

// 重新构建后 zip 会变，exclude 改了服务器实际收到的也变，两样都算进 ID，才能判断是不是预发布站发过的那份
const packageId = (sha256: string, exclude: string[]) => createHash('sha256').update(`exclude:${exclude.join('\n')}\n${sha256}`).digest('hex').slice(0, 12);
// 包按内容命名、不分站点：--from-stage 凭预发布站发布记录里的 sha256 就能找到包，预发布站自己也可能是 --from-stage 发的
const objectOf = (cfg: Config, sha256: string) => `${cfg.oss.prefix ?? ''}${sha256}.zip`;

// 多台服务器按配置顺序逐台发布，一台失败就停：坏包只影响一台，负载均衡下其余服务器继续服务
export async function* deploy(cfg: Config, name: string, path: string | undefined, { check = false, message = '', force = false, skipStage = false, fromStage = false }: DeployOptions): AsyncGenerator<[string, RunResult]> {
  const target = getTarget(cfg, name);
  const { instances, publish, exclude = [], keep = 5 } = target;
  const stage = target.kind === 'site' ? target.stage : undefined;
  // 预检查不改服务器上的任何东西
  const held = check ? undefined : await targetLease(cfg, name, `deploy ${name}`);
  try {
    const deployId = new Date().toISOString().replace(/[-:]|\.\d+/g, '');
    const ecs = new Ecs(cfg, held);
    const clb = target.kind === 'site' ? clbOf(cfg, name, held) : undefined;
    await clb?.check(instances);
    let pkg: Package;
    if (fromStage) {
      if (!stage) throw new Error(`${name} has no stage site in the config`);
      if (path) throw new Error('--from-stage takes no path');
      pkg = await assertStaged(cfg, ecs, stage);
      if (packageId(pkg.sha256, exclude) !== pkg.id) throw new Error(`Package ${pkg.id} was deployed to stage site ${stage} with a different exclude list; deploy to the stage site again`);
    } else {
      const localPath = path ?? publish;
      if (!localPath) throw new Error(`No package path given and ${name} has no publish directory in the config`);
      pkg = await uploadLocal(cfg, ecs, localPath, exclude, skipStage ? undefined : stage);
    }
    const object = objectOf(cfg, pkg.sha256);
    if (fromStage && !await exists(cfg, object)) throw new Error(`Package ${pkg.id} is no longer on OSS, most likely removed by the bucket's lifecycle rule; deploy the same build from a local path instead`);

    const timeout = 1800;
    const vars = { ...targetVars(name, target), WORK: `aca-${deployId}-${randomBytes(4).toString('hex')}`, DEPLOY_ID: deployId, SHA256: pkg.sha256, EXCLUDE: exclude.join('\n'), FORCE: String(force) };
    // 先查完每台服务器再动手：发到一半才发现后面的服务器过不了预检查，负载均衡后面就是新旧两个版本
    const checkScript = renderScript('check', { ...vars, URL: await signForEcs(cfg, object, timeout), CHECK_ONLY: String(check) }, ['target', 'inspect']);
    const checks = await inParallel(cfg, instances, async (instance): Promise<[string, RunResult]> => [instance, await ecs.runPowerShell(instance, checkScript, timeout)]);
    yield* checks;
    if (check) return;
    const failed = checks.filter(([, r]) => r.status !== 'Success').map(([instance]) => instance);
    if (failed.length) throw new Error(`Pre-check failed on ${failed.join(', ')}; no server was deployed`);
    const script = renderScript('deploy', { ...vars, PACKAGE: pkg.id, MESSAGE: message, KEEP: String(keep) }, ['target', 'inspect', 'release']);
    for (const [i, instance] of instances.entries()) {
      held?.check();
      const r = yield* outOfClb(clb, held, instance, () => ecs.runPowerShell(instance, script, timeout));
      if (r.status !== 'Success') throw new Error(`${instance}: deploy failed, ${instances.length - i - 1} remaining server(s) not processed`);
    }
  } finally {
    await held?.release();
  }
}

// 先把目录或 zip 定格成临时文件再算哈希、核对、上传：构建可能同时在改写它们，
// 上传的字节要是和按哈希起的名字对不上，就会顶掉 OSS 上预发布站那份同名的包
async function uploadLocal(cfg: Config, ecs: Ecs, path: string, exclude: string[], stage: string | undefined): Promise<Package> {
  const isDir = statSync(path).isDirectory();
  if (!isDir && !path.toLowerCase().endsWith('.zip')) throw new Error(`${path} is neither a directory nor a .zip file`);
  const zip = join(tmpdir(), `aca-${randomBytes(8).toString('hex')}.zip`);
  try {
    if (isDir) await zipDir(path, zip);
    else await copyFile(path, zip);
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(zip)) hash.update(chunk as Buffer);
    const sha256 = hash.digest('hex');
    const id = packageId(sha256, exclude);
    if (stage) await assertStaged(cfg, ecs, stage, id);
    await upload(cfg, zip, objectOf(cfg, sha256));
    return { id, sha256 };
  } finally {
    rmSync(zip, { force: true });
  }
}

// 要求预发布站每台服务器的最后一条记录都是同一个包的成功发布：最后一条是回退或失败，说明这一版在预发布没过。
// 锚定整行前缀，-m 里写什么都伪造不出成功记录
async function assertStaged(cfg: Config, ecs: Ecs, stage: string, id?: string): Promise<Package> {
  let staged: Package | undefined;
  for (const name of getSite(cfg, stage).instances) {
    const r = await ecs.runPowerShell(name, renderScript('lastdeploy', { SITE: stage }, ['target']), 60);
    if (r.status !== 'Success') throw new Error(`Failed to read the deploy log of stage site ${stage} (${name}): ${r.output.trim() || r.error}`);
    const last = r.output.trim();
    const m = /^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \| deploy \S+ \| pkg=([0-9a-f]+) \| sha256=([0-9a-f]{64}) \| /.exec(last);
    if (!m) throw new Error(`The last log entry of stage site ${stage} (${name}) is not a successful deploy: ${last || '(none)'}; deploy to the stage site first`);
    id ??= m[1];
    if (m[1] !== id) throw new Error(`Package ${id} is not the latest deploy on stage site ${stage} (${name}), whose last log entry is: ${last}; deploy to the stage site first`);
    staged = { id, sha256: m[2] };
  }
  console.log(`Stage site ${stage} last deployed package ${id}`);
  return staged!;
}

// 按名字排序：同一目录打出的 zip 要逐字节相同，包 ID 才对得上预发布站。等 archiver 写完一个条目再读下一个文件，内存里只有一个文件
async function zipDir(dir: string, out: string) {
  // zip 里存本地时间，否则服务器上解出来的文件时间会差一个时区，对不上本地编译时间
  const archive = new ZipArchive({ zlib: { level: 6 }, forceLocalTime: true });
  const closed = new Promise<void>((resolve, reject) => {
    archive.on('error', reject);
    archive.pipe(createWriteStream(out).on('close', resolve).on('error', reject));
  });
  closed.catch(() => {});
  // 这里不用同步 fs：网络盘上枚举或读一个大文件会把事件循环堵死，租约就续不上了
  for (const rel of (await readdir(dir, { recursive: true, encoding: 'utf8' })).sort()) {
    const full = join(dir, rel);
    const info = await stat(full);
    if (info.isDirectory()) continue;
    const written = once(archive, 'entry');
    archive.append(await readFile(full), { name: rel.replaceAll('\\', '/'), date: info.mtime });
    await written;
  }
  await archive.finalize();
  await closed;
}
