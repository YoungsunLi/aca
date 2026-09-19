import { randomBytes } from 'node:crypto';
import { hostname, userInfo } from 'node:os';
import { setTimeout as sleep } from 'node:timers/promises';
import { type Config, getSite } from './config.ts';
import { list, readJson, remove, upload } from './oss.ts';

/** 别人超过这么久没见着续约就把租约抢走 */
const TTL = 180_000;
/** 自己只信到这里，比 TTL 短：OSS 的对象时间只精确到秒，差额还要盖住一次云 API 调用（SLB 客户端连接、读取各 30 秒） */
const OWNED = 115_000;
const RENEW = 30_000;
/** 租约对象只有几百字节，写不动就赶紧失败等下一拍重试，别把 release 挂在那里 */
const WRITE = 20_000;
/** 早就没人续的对象顺手删掉：只靠 TTL 过滤，攒多了会把还活着的那条挤到列举的下一页 */
const STALE = 3_600_000;
/** 两个 aca 同时开跑会互相看见、一起退回重试，这是重试的时限 */
const RETRY = 30_000;

type Holder = { by: string; host: string; what: string; since: string; held: boolean };
type Stamp = { mono: number; wall: number };
const stamp = (): Stamp => ({ mono: performance.now(), wall: Date.now() });
// 两种钟取大的那个：时钟被往回调会让 Date.now() 算少，休眠的时间不计进 performance.now()，两种都会让自己以为租约还有效
const since = (s: Stamp) => Math.max(performance.now() - s.mono, Date.now() - s.wall);
/** check：续不上租约时抛错。每动一台服务器前调一次，别在接手的那个 aca 手底下接着改 */
export type Lease = { check(): void; release(): Promise<void> };

/** 发布、回退整轮持有；站点配了 `clb` 的连 CLB 一起持有，同一个 CLB 上别的站点得排队 */
export async function siteLease(cfg: Config, site: string, what: string): Promise<Lease> {
  const held: Lease[] = [];
  try {
    // 先站点后 CLB，顺序固定：两个 aca 各拿到一个再互等就是死锁
    // 统一小写：IIS 站点名不分大小写，两份配置写成 App 和 app 就会各拿各的租约
    held.push(await acquire(cfg, `site/${encodeURIComponent(site.toLowerCase())}`, what));
    const { clb } = getSite(cfg, site);
    if (clb) held.push(await acquire(cfg, `clb/${clb}`, what));
  } catch (e) {
    await release(held);
    throw e;
  }
  return {
    check: () => { for (const l of held) l.check(); },
    release: () => release(held),
  };
}

const release = async (held: Lease[]) => { for (const l of held) await l.release(); };

async function acquire(cfg: Config, scope: string, what: string): Promise<Lease> {
  const prefix = `${cfg.oss.prefix ?? ''}lease/${cfg.region}/${scope}/`;
  const key = prefix + randomBytes(8).toString('hex');
  const me: Holder = { by: userInfo().username, host: hostname(), what, since: new Date().toISOString(), held: false };
  const started = stamp();
  for (;;) {
    // 自己那条从这一刻起在别人眼里开始变旧
    const claimedAt = stamp();
    let other: Holder | undefined;
    try {
      await write(cfg, key, me);
      other = await liveOther(cfg, prefix, key);
      if (!other) {
        // 标成 held，后来的人看到就直接报错；看到没标的才知道是撞在同一刻、该退回重试
        const mine = { ...me, held: true };
        // 续约从这次写算起：对象在 OSS 上的时间是它盖的，从 claimedAt 算会把抢租约花掉的时间也算进去
        const wroteAt = stamp();
        await write(cfg, key, mine);
        // 两次写加起来超过了失效时限，自己那条在别人眼里已经过期，可能已被接手
        if (since(claimedAt) > OWNED) throw new Error(`${scope}: taking the lease took more than ${OWNED / 1000} seconds, by which time another aca could have taken it; try again`);
        return renewing(cfg, scope, key, mine, wroteAt);
      }
    } catch (e) {
      // 自己那条留着，下一次重试会被自己挡在外面；写报错时对象也可能已经落地
      await remove(cfg, key, undefined).catch(() => {});
      throw e;
    }
    await remove(cfg, key, undefined);
    const who = `${other.by}@${other.host}`;
    if (other.held) throw new Error(`${scope} is held by ${who} since ${other.since} (${other.what}); wait for it to finish, or, if that machine is gone, ${TTL / 1000} seconds after its last renewal`);
    if (since(started) > RETRY) throw new Error(`${scope}: aca on ${who} started at the same moment and neither took the lease within ${RETRY / 1000} seconds; try again`);
    await sleep(1000 + Math.random() * 3000);
  }
}

// 写下自己那条，列一遍，只有自己一条还活着才算拿到：并发的两个都会看到对方、都退回去，
// 所以不靠两台机器的时钟对齐，也不靠 x-oss-forbid-overwrite（bucket 开了版本控制它就失效）
async function liveOther(cfg: Config, prefix: string, key: string): Promise<Holder | undefined> {
  const live: string[] = [];
  for (const o of await list(cfg, prefix)) {
    if (o.name === key) continue;
    if (o.age < TTL) live.push(o.name);
    else if (o.age > STALE) await remove(cfg, o.name, undefined);
  }
  let first: Holder | undefined;
  for (const name of live) {
    // 读的时候已经不在，说明刚放掉，等于没这条
    const holder = await readJson<Holder>(cfg, name);
    // 真正占着的那条优先报给用户，同时开跑的那条只说明该退回重试
    if (holder?.held) return holder;
    first ??= holder;
  }
  return first;
}

function renewing(cfg: Config, scope: string, key: string, me: Holder, wroteAt: Stamp): Lease {
  let renewedAt = wroteAt;
  let lost = false;
  let renewal = Promise.resolve();
  let inFlight = false;
  // 过期是终局：写得慢的那次续约落地时别人可能已经接手，不能靠它把自己救回来
  const expired = () => lost || since(renewedAt) > OWNED;
  const timer = setInterval(() => {
    // 上一次还没落地就跳过这一拍：两次续约重叠时，先发的那次可能在 release 删掉对象之后才写回去。
    // 过了失效时限也不再续：这时别人可能已经拿走，再写回去就是两个都活着的持有者
    if (inFlight || expired()) return;
    inFlight = true;
    // 算起点取发请求的时刻，不是收到响应的：别人是从 OSS 落盘那一刻算这个对象的岁数
    const at = stamp();
    renewal = write(cfg, key, me)
      .then(() => { if (expired()) lost = true; else renewedAt = at; })
      .catch((e: Error) => console.error(`WARN: could not renew the lease on ${scope}: ${e.message}`))
      .finally(() => { inFlight = false; });
  }, RENEW);
  timer.unref();
  return {
    check: () => {
      if (expired()) throw new Error(`The lease on ${scope} could not be renewed for over ${OWNED / 1000} seconds and has expired; another aca may have taken it, so this run stops here`);
    },
    release: async () => {
      clearInterval(timer);
      // 等在路上的那次续约落完，否则它会把刚删掉的对象写回去
      await renewal;
      // 放不掉就等它过期，别盖掉调用方真正的错误
      await remove(cfg, key, undefined).catch((e: Error) => console.error(`WARN: could not release the lease ${key}: ${e.message}; it expires in ${TTL / 1000} seconds`));
    },
  };
}

const write = async (cfg: Config, key: string, holder: Holder) => { await upload(cfg, Buffer.from(JSON.stringify(holder)), key, WRITE); };
