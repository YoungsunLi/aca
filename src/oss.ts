import OSS from 'ali-oss';
import type { Config } from './config.ts';

// 每次都向凭证链要：STS 类凭证会过期，链会在快过期时换新的
async function options({ region, oss, credential }: Config) {
  const { accessKeyId, accessKeySecret, securityToken } = await credential.getCredential();
  return { region: `oss-${region}`, bucket: oss.bucket, accessKeyId: accessKeyId!, accessKeySecret: accessKeySecret!, stsToken: securityToken, secure: true };
}

export async function upload(cfg: Config, localFile: string, objectName: string) {
  // 默认 60 秒超时，几百 MB 的包传不完
  await new OSS({ ...await options(cfg), timeout: 600_000 }).put(objectName, localFile);
}

// 内网签名 URL：ECS 与 bucket 同地域时走内网，免流量费且更快
export async function signForEcs(cfg: Config, objectName: string, expires: number): Promise<string> {
  return new OSS({ ...await options(cfg), internal: true }).signatureUrl(objectName, { expires });
}
