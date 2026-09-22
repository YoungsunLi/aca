import { type KeyObject, X509Certificate, createHash, createPrivateKey, randomBytes } from 'node:crypto';
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

  const chain = (body.cert.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g) ?? []).map((pem) => new X509Certificate(pem));
  const key = createPrivateKey(body.key);
  // 配得上私钥的那张是服务器证书，PFX 里它得排第一；中间证书跟着进去，http.sys 才发得出完整的链
  const leaf = chain.findIndex((c) => c.checkPrivateKey(key));
  if (leaf < 0) throw new Error(`Certificate ${id}: none of the ${chain.length} certificate(s) matches the private key`);

  const password = randomBytes(24).toString('base64url');
  return { kind: 'pfx', bytes: toPfx([chain[leaf], ...chain.filter((_, i) => i !== leaf)], key, password), password };
}

// node-forge 解析不了 ECC 的证书和私钥，用不了它的 toPkcs12Asn1：证书和私钥原样拼进 PKCS#12，只借它的 3DES 加密和 MAC。
// 3DES 而不是 AES：Server 2016 及更早的系统打不开 AES 加密的 PFX
function toPfx(chain: X509Certificate[], key: KeyObject, password: string): Buffer {
  const { asn1, pki } = forge;
  const { UNIVERSAL } = asn1.Class;
  const seq = (...items: forge.asn1.Asn1[]) => asn1.create(UNIVERSAL, asn1.Type.SEQUENCE, true, items);
  const set = (...items: forge.asn1.Asn1[]) => asn1.create(UNIVERSAL, asn1.Type.SET, true, items);
  const oid = (name: string) => asn1.create(UNIVERSAL, asn1.Type.OID, false, asn1.oidToDer(pki.oids[name]).getBytes());
  const octets = (bytes: string) => asn1.create(UNIVERSAL, asn1.Type.OCTETSTRING, false, bytes);
  const int = (n: number) => asn1.create(UNIVERSAL, asn1.Type.INTEGER, false, asn1.integerToDer(n).getBytes());
  const explicit = (item: forge.asn1.Asn1) => asn1.create(asn1.Class.CONTEXT_SPECIFIC, 0, true, [item]);
  const der = (item: forge.asn1.Asn1) => asn1.toDer(item).getBytes();
  const data = (bytes: string) => seq(oid('data'), explicit(octets(bytes)));

  // Windows 导入时靠同一个 localKeyId 把私钥配给服务器证书
  const keyId = set(seq(oid('localKeyId'), set(octets(createHash('sha1').update(chain[0].raw).digest('binary')))));
  const certBags = chain.map((c, i) => seq(oid('certBag'), explicit(seq(oid('x509Certificate'), explicit(octets(c.raw.toString('binary'))))), ...(i ? [] : [keyId])));
  const keyInfo = asn1.fromDer(key.export({ type: 'pkcs8', format: 'der' }).toString('binary'));
  const keyBag = seq(oid('pkcs8ShroudedKeyBag'), explicit(pki.encryptPrivateKeyInfo(keyInfo, password, { algorithm: '3des' })), keyId);
  const safe = der(seq(data(der(seq(...certBags))), data(der(seq(keyBag)))));

  const salt = randomBytes(8).toString('binary');
  const iterations = 2048;
  const mac = forge.hmac.create();
  mac.start('sha1', forge.pkcs12.generateKey(password, forge.util.createBuffer(salt), 3, iterations, 20));
  mac.update(safe);
  const macData = seq(seq(seq(oid('sha1'), asn1.create(UNIVERSAL, asn1.Type.NULL, false, '')), octets(mac.getMac().getBytes())), octets(salt), int(iterations));
  return Buffer.from(der(seq(int(3), data(safe), macData)), 'binary');
}
