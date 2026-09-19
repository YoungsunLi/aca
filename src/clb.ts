import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import $OpenApi from '@alicloud/openapi-client';
import $Slb from '@alicloud/slb20140515';
import { type Config, getSite, instanceId } from './config.ts';
import type { RunResult } from './ecs.ts';

type TakenOut = { putBack(): Promise<void>; leaveOut(): void };

export const isWeight = (weight: number) => Number.isInteger(weight) && weight > 0 && weight <= 100;

// 失败后留在外面、aca 被中途终止时没放回的服务器，aca clb restore 靠这份记录调回原来的权重
const recordOf = (lb: string, id: string) => join(homedir(), '.aca', 'clb', lb, id);

function readRecord(lb: string, id: string): number | undefined {
  const file = recordOf(lb, id);
  if (!existsSync(file)) return undefined;
  const weight = Number(readFileSync(file, 'utf8'));
  if (!isWeight(weight)) throw new Error(`${file} does not hold a weight from 1 to 100; delete it`);
  return weight;
}

const forgetRecord = (lb: string, id: string) => rmSync(recordOf(lb, id), { force: true });

// 只管默认服务器组。CLB 七层转发到后端用的是短连接，权重调成 0 之后新请求就不再转给这台服务器
export class Clb {
  readonly id: string;
  #region: string;
  #aliases: Record<string, string>;
  #client: InstanceType<typeof $Slb.default>;
  #checkedListeners?: Promise<string[]>;

  constructor({ region, credential, instances }: Config, id: string) {
    this.id = id;
    this.#region = region;
    this.#aliases = instances;
    // SetBackendServers 实测要两三秒才返回，SDK 默认 3 秒没收到数据就报超时（报的是 ConnectTimeout），这时权重多半已经改了
    this.#client = new $Slb.default(new $OpenApi.Config({ credential, regionId: region, connectTimeout: 30_000, readTimeout: 30_000 }));
  }

  // 处理第一台服务器之前核对：处理到一半才发现有服务器不在组里，服务器之间的版本就不一致了
  async check(names: string[]): Promise<Map<string, number>> {
    const all = await this.#weights();
    const weights = new Map(names.map((name) => [name, this.#weightOf(all, name)]));
    console.log(`CLB ${this.id} weights: ${[...weights].map(([name, weight]) => {
      const before = weight === 0 && readRecord(this.id, instanceId(this.#aliases, name));
      return `${name} ${weight}${before ? ` (${before} before aca took it out)` : ''}`;
    }).join(', ')}`);
    return weights;
  }

  /** weight 为空时用 aca 摘它时记下的权重 */
  async restore(name: string, weight?: number) {
    const id = instanceId(this.#aliases, name);
    const current = this.#weightOf(await this.#weights(), name);
    if (current > 0) {
      // 在控制台放回过的：记录留着，以后在控制台再摘下，会被当成 aca 摘的、按这个旧权重放回
      forgetRecord(this.id, id);
      console.log(`CLB ${this.id}: ${name} already has weight ${current}`);
      return;
    }
    const target = weight ?? readRecord(this.id, id);
    if (!target) throw new Error(`No record of the weight ${name} had before aca took it out of CLB ${this.id} on this machine; give it with --weight`);
    await this.#putBack(id, name, target);
  }

  /** 返回 undefined：这台服务器的权重本来就是 0，aca 不动它 */
  async takeOut(name: string): Promise<TakenOut | undefined> {
    const id = instanceId(this.#aliases, name);
    const deadline = Date.now() + 300_000;
    for (let waiting = false; ; waiting = true) {
      const weights = await this.#weights();
      const weight = this.#weightOf(weights, name);
      if (weight === 0) {
        console.log(`CLB ${this.id}: ${name} already has weight 0, aca leaves it as is`);
        return undefined;
      }
      // 别的服务器权重都是 0 时等也没用：留在外面的要人确认站点正常后才放回
      if (![...weights].some(([other, w]) => other !== id && w > 0)) throw new Error(`CLB ${this.id}: every other server in the default server group has weight 0, and taking ${name} out would stop the service; put back the ones whose sites work first (aca clb restore)`);
      const putBack = () => this.#putBack(id, name, weight);
      // 还有别的服务器在接流量才摘，否则整个站点都停了。刚放回去的服务器要等健康检查连续成功几次才重新接流量。
      // 摘完再查一遍：别的 aca 可能同时摘了另一台，那就先放回去再等。摘的请求报错时可能已经生效，复查出错时已经摘了，都先放回去
      if (await this.#othersServing(id, weights)) {
        const record = recordOf(this.id, id);
        mkdirSync(dirname(record), { recursive: true });
        writeFileSync(record, String(weight));
        const serving = await this.#setWeight(id, 0).then(async () => {
          console.log(`CLB ${this.id}: ${name} weight ${weight} -> 0`);
          return this.#othersServing(id, await this.#weights());
        }).catch(async (e: unknown) => {
          await putBack();
          throw e;
        });
        if (serving) {
          // 实测接口返回后约 2 秒 CLB 才不再往这台转新请求，回退脚本开始后一两秒就停站
          await sleep(5000);
          return { putBack, leaveOut: () => console.error(`WARN: ${name} stays out of CLB ${this.id} with weight 0 (was ${weight}); once its sites work, put it back with aca clb restore`) };
        }
        await putBack();
      }
      if (Date.now() > deadline) throw new Error(`CLB ${this.id}: no other server in the default server group took traffic (weight above 0, enabled health checks normal) within 300 seconds, and taking ${name} out would stop the service`);
      if (!waiting) console.log(`CLB ${this.id}: waiting for another server to take traffic before taking ${name} out`);
      // 随机错开：两个 aca 同时摘、同时放回后，下一轮别再撞上
      await sleep(3000 + Math.random() * 4000);
    }
  }

  // 只认 ECS：弹性网卡、弹性容器实例一个 ID 下可以挂几个 IP、各有权重和健康状态，按 ID 合在一起会把不接流量的当成在接
  async #weights(): Promise<Map<string, number>> {
    const { body } = await this.#client.describeLoadBalancerAttribute(new $Slb.DescribeLoadBalancerAttributeRequest({ regionId: this.#region, loadBalancerId: this.id }));
    return new Map(body?.backendServers?.backendServer?.filter((s) => s.type === 'ecs').map((s) => [s.serverId!, s.weight!]));
  }

  #weightOf(weights: Map<string, number>, name: string): number {
    const weight = weights.get(instanceId(this.#aliases, name));
    if (weight === undefined) throw new Error(`${name} is not in the default server group of CLB ${this.id}`);
    return weight;
  }

  // 在接流量：权重不为 0，走默认服务器组、开了健康检查的每个监听上都是 normal。健康状态按协议、监听端口、后端端口对上号：
  // UDP 监听可以和 TCP 监听用同一个端口号；同一个监听上转发规则的服务器组可能用这台服务器的另一个端口。
  // 同一个号上有几条（转发规则自己另开了健康检查）要条条 normal，分不出哪条是默认服务器组的
  async #othersServing(id: string, weights: Map<string, number>): Promise<boolean> {
    this.#checkedListeners ??= this.#listCheckedListeners();
    const listeners = await this.#checkedListeners;
    const { body } = await this.#client.describeHealthStatus(new $Slb.DescribeHealthStatusRequest({ regionId: this.#region, loadBalancerId: this.id }));
    const normal = new Map<string, boolean>();
    for (const h of body?.backendServers?.backendServer ?? []) {
      const key = `${h.serverId} ${h.protocol} ${h.listenerPort} ${h.port}`;
      normal.set(key, normal.get(key) !== false && h.serverHealthStatus === 'normal');
    }
    return [...weights].some(([other, weight]) => other !== id && weight > 0 && listeners.every((l) => normal.get(`${other} ${l}`)));
  }

  // 健康状态 unavailable 既可能是没开检查，也可能是还没查完，开没开得看监听配置。监听在发布过程中不会变，查一次
  async #listCheckedListeners(): Promise<string[]> {
    const listeners = [];
    let nextToken: string | undefined;
    do {
      const { body } = await this.#client.describeLoadBalancerListeners(new $Slb.DescribeLoadBalancerListenersRequest({ regionId: this.#region, loadBalancerId: [this.id], maxResults: 100, nextToken }));
      listeners.push(...body?.listeners ?? []);
      nextToken = body?.nextToken || undefined;
    } while (nextToken);
    return listeners.filter((l) => {
      const conf = { http: l.HTTPListenerConfig, https: l.HTTPSListenerConfig, tcp: l.TCPListenerConfig, udp: l.UDPListenerConfig }[l.listenerProtocol!];
      // 用虚拟服务器组、主备服务器组的监听不走默认服务器组；http 跳 https 的监听不转给后端，配置里的健康检查却可能显示开着
      const elsewhere = l.VServerGroupId || l.TCPListenerConfig?.masterSlaveServerGroupId || l.UDPListenerConfig?.masterSlaveServerGroupId || l.HTTPListenerConfig?.listenerForward === 'on';
      return l.status === 'running' && !elsewhere && conf?.healthCheck === 'on';
    }).map((l) => `${l.listenerProtocol} ${l.listenerPort} ${l.backendServerPort}`);
  }

  async #putBack(id: string, name: string, weight: number) {
    await this.#setWeight(id, weight).catch((e: Error) => {
      throw new Error(`CLB ${this.id}: failed to set the weight of ${name} back to ${weight}: ${e.message}`);
    });
    forgetRecord(this.id, id);
    console.log(`CLB ${this.id}: ${name} weight 0 -> ${weight}`);
  }

  async #setWeight(id: string, weight: number) {
    await this.#client.setBackendServers(new $Slb.SetBackendServersRequest({
      regionId: this.#region, loadBalancerId: this.id, backendServers: JSON.stringify([{ ServerId: id, Weight: String(weight) }]),
    }));
  }
}

export function clbOf(cfg: Config, site: string): Clb | undefined {
  const id = getSite(cfg, site).clb;
  return id ? new Clb(cfg, id) : undefined;
}

export function siteClb(cfg: Config, site: string): Clb {
  const clb = clbOf(cfg, site);
  if (!clb) throw new Error(`Site ${site} has no clb in the config`);
  return clb;
}

// 停过站还失败的留在外面：CLB 的健康检查查的不一定是这个站点，放回去用户就会撞上没起来或发坏了的站点
export async function* outOfClb(clb: Clb | undefined, name: string, run: () => Promise<RunResult>): AsyncGenerator<[string, RunResult], RunResult> {
  const out = await clb?.takeOut(name);
  const r = await run().catch((e: unknown) => {
    out?.leaveOut();
    throw e;
  });
  yield [name, r];
  // 脚本在停站之前报错退出的（预检查没过等）放回去，Stop-AcaSite 停站前先打印 Stopping site。锁被占时不放回：
  // 占着锁的 aca 可能也摘了这台、正停着站。超时被杀等别的状态和输出被截断的，看不准停没停过，当停过
  const untouched = r.status === 'Failed' && !r.dropped && !/^Stopping site |Another aca operation is modifying this site/m.test(r.output);
  if (r.status === 'Success' || untouched) await out?.putBack();
  else out?.leaveOut();
  return r;
}
