import { createDecipheriv, randomBytes } from 'node:crypto';
import type { Readable } from 'node:stream';
import OSS from 'ali-oss';
import type { Config } from './config.ts';
import type { RunResult } from './ecs.ts';

// 每次都向凭证链要：STS 类凭证会过期，链会在快过期时换新的
async function options({ region, oss, credential }: Config) {
  const { accessKeyId, accessKeySecret, securityToken } = await credential.getCredential();
  return { region: `oss-${region}`, bucket: oss.bucket, accessKeyId: accessKeyId!, accessKeySecret: accessKeySecret!, stsToken: securityToken, secure: true };
}

const versionOf = (res: OSS.NormalSuccessResponse): string | undefined => (res.headers as Record<string, string>)['x-oss-version-id'];

/**
 * 返回版本 ID：bucket 开了版本控制时，删除要带上它才删得掉这个版本，否则只是加一个删除标记。
 * timeout 默认按几百 MB 的包给，SDK 自己的默认 60 秒传不完
 */
export async function upload(cfg: Config, file: string | Buffer, objectName: string, timeout = 600_000): Promise<string | undefined> {
  const { res } = await new OSS({ ...await options(cfg), timeout }).put(objectName, file);
  return versionOf(res);
}

export async function download(cfg: Config, objectName: string): Promise<{ stream: Readable; versionId: string | undefined }> {
  const { stream, res } = await new OSS(await options(cfg)).getStream(objectName);
  return { stream, versionId: versionOf(res) };
}

export async function exists(cfg: Config, objectName: string): Promise<boolean> {
  try {
    await new OSS(await options(cfg)).head(objectName);
    return true;
  } catch (e) {
    if ((e as { status?: number }).status === 404) return false;
    throw e;
  }
}

/**
 * 试出来的是 ACL 和阻止公共访问叠加后的实际结果，比读 ACL 配置准。
 * 对象不存在时，过了权限这一关才轮得到 404
 */
export async function readableWithoutCredentials(cfg: Config, objectName: string): Promise<boolean> {
  const url = new OSS(await options(cfg)).generateObjectUrl(objectName);
  // 只取 1 个字节：试的可能是已经存在的包
  const res = await fetch(url, { headers: { Range: 'bytes=0-0' } })
    // fetch 连不上时只报一句 fetch failed，原因在 cause 里
    .catch((e: Error) => { throw new Error(`Reading ${url} without credentials failed: ${(e.cause as Error | undefined)?.message ?? e.message}`, { cause: e }); });
  const body = await res.text();
  const ec = res.headers.get('x-oss-ec');
  // 只认 bucket ACL（含阻止公共访问）和文件 ACL 的拒绝：被 bucket policy、防盗链挡下的，换个 Referer、User-Agent 可能就读得到
  if (ec === '0003-00000001' || ec === '0003-00000005') return false;
  if (res.ok || (res.status === 404 && !body.includes('<Code>NoSuchBucket</Code>'))) return true;
  throw new Error(`Reading ${url} without credentials got HTTP ${res.status}: ${/<Message>(.*?)<\/Message>/.exec(body)?.[1] ?? res.statusText}`);
}

/** SDK 没有 GetBucketPolicyStatus，借它的签名发请求 */
export async function policyIsPublic(cfg: Config): Promise<boolean> {
  const client = new OSS(await options(cfg)) as unknown as {
    _bucketRequestParams(method: string, bucket: string, subres: string): { successStatuses?: number[] };
    request(params: object): Promise<{ res: { data: Buffer } }>;
  };
  const params = client._bucketRequestParams('GET', cfg.oss.bucket, 'policyStatus');
  // 不设的话 SDK 把 403 也当成功返回，没权限就被当成了不公开
  params.successStatuses = [200];
  const { res } = await client.request(params).catch((e: Error) => { throw new Error(`Could not read the policy status of bucket ${cfg.oss.bucket} (aca needs oss:GetBucketPolicyStatus): ${e.message}`, { cause: e }); });
  return /<IsPublic>true<\/IsPublic>/.test(res.data.toString());
}

export async function remove(cfg: Config, objectName: string, versionId: string | undefined) {
  // SDK 支持 versionId，类型声明里没写
  await new OSS(await options(cfg)).delete(objectName, { versionId } as OSS.RequestOptions);
}

// 内网签名 URL：ECS 与 bucket 同地域时走内网，免流量费且更快
export async function signForEcs(cfg: Config, objectName: string, expires: number, method: 'GET' | 'PUT' = 'GET'): Promise<string> {
  return new OSS({ ...await options(cfg), internal: true }).signatureUrl(objectName, { expires, method });
}

/**
 * 云助手的输出有上限，服务器上大块的内容经 OSS 回本机：脚本用 aca 这次生成的一次性密钥加密后上传，
 * aca 下载解密再把对象删掉，bucket 被别人读到也看不到内容。kind 是对象名里的一段，认得出是哪个命令传的。
 * 脚本没跑成时不返回 got
 */
export async function viaOss<T>(
  cfg: Config,
  kind: string,
  expires: number,
  run: (vars: { URL: string; KEY: string; IV: string }) => Promise<RunResult>,
  read: (stream: Readable) => Promise<T>,
): Promise<{ result: RunResult; got?: T }> {
  const key = randomBytes(32);
  const iv = randomBytes(16);
  const objectName = `${cfg.oss.prefix ?? ''}${kind}/${randomBytes(8).toString('hex')}.enc`;
  let versionId: string | undefined;
  try {
    const result = await run({ URL: await signForEcs(cfg, objectName, expires, 'PUT'), KEY: key.toString('base64'), IV: iv.toString('base64') });
    if (result.status !== 'Success') return { result };
    const got = await download(cfg, objectName);
    versionId = got.versionId;
    const plain = got.stream.pipe(createDecipheriv('aes-256-cbc', key, iv));
    // pipe 不把两头的下场连起来：下载断了要让读的那头收到错误，否则它一直等；
    // 读的那头出错（比如本地盘满了）要断掉下载，否则连接挂着，命令跑完也退不出来
    got.stream.on('error', (e: Error) => plain.destroy(e));
    plain.on('close', () => got.stream.destroy());
    return { result, got: await read(plain) };
  } finally {
    // 脚本失败或轮询出错时也删一次：服务器那边可能已经传上去了
    await remove(cfg, objectName, versionId).catch((e: Error) => console.error(`WARN: could not delete ${objectName} from OSS: ${e.message}`));
  }
}

function time(value: string, what: string): number {
  const t = Date.parse(value);
  if (Number.isNaN(t)) throw new Error(`OSS returned an unreadable ${what}: ${value}`);
  return t;
}

/**
 * 列出前缀下的对象，带上年龄（毫秒）：对象多旧只能用 OSS 自己的时钟比，本机可能差很远。
 * 每页拿自己那次响应的时间算，翻页慢了也不会把前面几页算老
 */
export async function list(cfg: Config, prefix: string): Promise<{ name: string; age: number }[]> {
  const oss = new OSS(await options(cfg));
  const objects = [];
  let marker: string | undefined;
  do {
    const r = await oss.list({ prefix, marker, 'max-keys': 1000 }, {});
    const now = time((r.res.headers as Record<string, string>).date, 'response date');
    for (const o of r.objects ?? []) objects.push({ name: o.name, age: now - time(o.lastModified, `last-modified time for ${o.name}`) });
    marker = r.isTruncated ? r.nextMarker : undefined;
  } while (marker);
  return objects;
}

/** 对象不在了返回 undefined */
export async function readJson<T>(cfg: Config, objectName: string): Promise<T | undefined> {
  try {
    return JSON.parse((await new OSS(await options(cfg)).get(objectName)).content.toString()) as T;
  } catch (e) {
    if ((e as { status?: number }).status === 404) return undefined;
    throw e;
  }
}
