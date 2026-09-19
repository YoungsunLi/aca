import type { Readable } from 'node:stream';
import OSS from 'ali-oss';
import type { Config } from './config.ts';

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

export async function remove(cfg: Config, objectName: string, versionId: string | undefined) {
  // SDK 支持 versionId，类型声明里没写
  await new OSS(await options(cfg)).delete(objectName, { versionId } as OSS.RequestOptions);
}

// 内网签名 URL：ECS 与 bucket 同地域时走内网，免流量费且更快
export async function signForEcs(cfg: Config, objectName: string, expires: number, method: 'GET' | 'PUT' = 'GET'): Promise<string> {
  return new OSS({ ...await options(cfg), internal: true }).signatureUrl(objectName, { expires, method });
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
