import type { Readable } from 'node:stream';
import OSS from 'ali-oss';
import type { Config } from './config.ts';

// 每次都向凭证链要：STS 类凭证会过期，链会在快过期时换新的
async function options({ region, oss, credential }: Config) {
  const { accessKeyId, accessKeySecret, securityToken } = await credential.getCredential();
  return { region: `oss-${region}`, bucket: oss.bucket, accessKeyId: accessKeyId!, accessKeySecret: accessKeySecret!, stsToken: securityToken, secure: true };
}

const versionOf = (res: OSS.NormalSuccessResponse): string | undefined => (res.headers as Record<string, string>)['x-oss-version-id'];

/** 返回版本 ID：bucket 开了版本控制时，删除要带上它才删得掉这个版本，否则只是加一个删除标记 */
export async function upload(cfg: Config, file: string | Buffer, objectName: string): Promise<string | undefined> {
  // 默认 60 秒超时，几百 MB 的包传不完
  const { res } = await new OSS({ ...await options(cfg), timeout: 600_000 }).put(objectName, file);
  return versionOf(res);
}

export async function download(cfg: Config, objectName: string): Promise<{ stream: Readable; versionId: string | undefined }> {
  const { stream, res } = await new OSS(await options(cfg)).getStream(objectName);
  return { stream, versionId: versionOf(res) };
}

export async function remove(cfg: Config, objectName: string, versionId: string | undefined) {
  // SDK 支持 versionId，类型声明里没写
  await new OSS(await options(cfg)).delete(objectName, { versionId } as OSS.RequestOptions);
}

// 内网签名 URL：ECS 与 bucket 同地域时走内网，免流量费且更快
export async function signForEcs(cfg: Config, objectName: string, expires: number, method: 'GET' | 'PUT' = 'GET'): Promise<string> {
  return new OSS({ ...await options(cfg), internal: true }).signatureUrl(objectName, { expires, method });
}
