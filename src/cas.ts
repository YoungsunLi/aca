import { randomBytes } from 'node:crypto';
import $Cas from '@alicloud/cas20200407';
import $OpenApi from '@alicloud/openapi-client';
import forge from 'node-forge';
import type { CertSource } from './certs.ts';
import type { Config } from './config.ts';

export type CloudCert = { id: string; name: string; common: string; expires: string; days: number; status: string };

const DAY = 86400000;
// 数字证书管理服务不分地域，证书都挂在这一个端点上
const newClient = (cfg: Config) => new $Cas.default(new $OpenApi.Config({ credential: cfg.credential, endpoint: 'cas.aliyuncs.com' }));

/** 数字证书管理服务里没过期的证书，最急的排在最前；过期的要 status='EXPIRED' 才列得出来，换上去的证书总得是没过期的 */
export async function listCloudCerts(cfg: Config): Promise<CloudCert[]> {
  const client = newClient(cfg);
  const certs: CloudCert[] = [];
  for (let page = 1; ; page++) {
    // CERT 才是证书本身：默认的证书资源包列出的是申请记录，没有证书 ID，取不出 PEM
    const { body } = await client.listUserCertificateOrder(new $Cas.ListUserCertificateOrderRequest({ orderType: 'CERT', showSize: 50, currentPage: page }));
    const list = body?.certificateOrderList ?? [];
    for (const c of list) {
      certs.push({
        id: String(c.certificateId ?? ''),
        name: c.name ?? '',
        common: c.commonName ?? '',
        expires: c.endDate ?? '',
        days: Math.floor(((c.certEndTime ?? 0) - Date.now()) / DAY),
        status: c.status ?? '',
      });
    }
    if (!list.length || certs.length >= (body?.totalCount ?? 0)) break;
  }
  certs.sort((a, b) => a.days - b.days);
  return certs;
}

/** 取云端证书的 PEM 在本机合成 PFX：密码一次性生成，明文私钥不落盘 */
export async function cloudSource(cfg: Config, id: string): Promise<CertSource> {
  const certId = Number(id);
  if (!Number.isInteger(certId) || certId <= 0) throw new Error(`--from-cloud takes a certificate ID as listed by aca certs cloud, got "${id}"`);
  const { body } = await newClient(cfg).getUserCertificateDetail(new $Cas.GetUserCertificateDetailRequest({ certId }));
  if (!body?.cert || !body.key) throw new Error(`Certificate ${id} has no certificate or private key to download; export a PFX in the console and pass the file instead`);
  // node-forge 的 PKCS#12 只做 RSA；算法字段空着时不拦，让下面解析私钥时自己报错
  if (body.algorithm && !body.algorithm.startsWith('RSA')) throw new Error(`Certificate ${id} uses ${body.algorithm}, and aca can only build a PFX from an RSA certificate; export a PFX in the console and pass the file instead`);

  const chain = (body.cert.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g) ?? []).map((pem) => forge.pki.certificateFromPem(pem));
  const key = forge.pki.privateKeyFromPem(body.key) as forge.pki.rsa.PrivateKey;
  // 配得上私钥的那张是服务器证书，PFX 里它得排第一；中间证书跟着进去，http.sys 才发得出完整的链
  const leaf = chain.findIndex((c) => (c.publicKey as forge.pki.rsa.PublicKey).n.equals(key.n));
  if (leaf < 0) throw new Error(`Certificate ${id}: none of the ${chain.length} certificate(s) matches the private key`);

  const password = randomBytes(24).toString('base64url');
  // 3DES 而不是 node-forge 默认的 AES：Server 2016 及更早的系统打不开 AES 加密的 PFX
  const p12 = forge.pkcs12.toPkcs12Asn1(key, [chain[leaf], ...chain.filter((_, i) => i !== leaf)], password, { algorithm: '3des' });
  return { kind: 'pfx', bytes: Buffer.from(forge.asn1.toDer(p12).getBytes(), 'binary'), password };
}
