import { setTimeout as sleep } from 'node:timers/promises';
import $Ecs from '@alicloud/ecs20140526';
import $OpenApi from '@alicloud/openapi-client';
import { type Config, instanceId } from './config.ts';
import type { Lease } from './lease.ts';

/** osType 是 windows 或 linux */
export type Instance = { id: string; name: string; status: string; os: string; osType: string; publicIp: string; privateIp: string };
export type Assistant = { online: boolean; version: string; heartbeat: string };
/** dropped：输出超过云助手上限被丢掉的字节数 */
export type RunResult = { status: string; exitCode: number | undefined; output: string; error: string; dropped: number };

// Terminated 是在控制台点了"停止执行"
const TERMINAL_STATUS = new Set(['Success', 'Failed', 'Error', 'Timeout', 'Cancelled', 'Stopped', 'Terminated', 'Invalid', 'Aborted']);
// Windows 版云助手客户端（实测 2.1.4）按系统 ANSI 代码页解码输出，改成 UTF-8 反而乱码。
// PS 3.0（Server 2012）脚本抛错后退出码仍为 0，trap 保证失败时非 0，aca run 的脚本也要靠它
const PS_PREAMBLE = `[Console]::OutputEncoding = [Text.Encoding]::Default
trap { 'ERROR: ' + $_.Exception.Message; exit 1 }
`;

/** 只读、互不影响的操作几台服务器同时跑，一台台来的话时间要相加 */
export async function inParallel<T>(cfg: Config, instances: string[], run: (instance: string) => Promise<T>): Promise<T[]> {
  // SDK 的默认凭证链第一次取凭证时被并发调用，会有调用拿到链上还没试通的那一环而报错；先取一次把链定下来
  await cfg.credential.getCredential();
  return Promise.all(instances.map(run));
}

export class Ecs {
  #client: InstanceType<typeof $Ecs.default>;
  #region: string;
  #aliases: Record<string, string>;
  #credential: Config['credential'];
  #held?: Lease;

  constructor({ region, credential, instances }: Config, held?: Lease) {
    this.#region = region;
    this.#aliases = instances;
    this.#credential = credential;
    this.#held = held;
    this.#client = new $Ecs.default(new $OpenApi.Config({ credential, endpoint: `ecs.${region}.aliyuncs.com` }));
  }

  async listInstances(): Promise<Instance[]> {
    const result: Instance[] = [];
    let nextToken: string | undefined;
    do {
      const { body } = await this.#client.describeInstances(new $Ecs.DescribeInstancesRequest({ regionId: this.#region, maxResults: 100, nextToken }));
      for (const i of body?.instances?.instance ?? []) {
        result.push({
          id: i.instanceId ?? '',
          name: i.instanceName ?? '',
          status: i.status ?? '',
          os: i.OSName ?? '',
          osType: i.OSType ?? '',
          publicIp: i.eipAddress?.ipAddress || i.publicIpAddress?.ipAddress?.[0] || '',
          privateIp: i.vpcAttributes?.privateIpAddress?.ipAddress?.[0] ?? '',
        });
      }
      nextToken = body?.nextToken || undefined;
    } while (nextToken);
    return result;
  }

  /** 当前地域每台服务器上云助手客户端的状态，按实例 ID */
  async assistantStatus(): Promise<Map<string, Assistant>> {
    const result = new Map<string, Assistant>();
    let nextToken: string | undefined;
    do {
      const { body } = await this.#client.describeCloudAssistantStatus(new $Ecs.DescribeCloudAssistantStatusRequest({ regionId: this.#region, maxResults: 50, nextToken }));
      for (const s of body?.instanceCloudAssistantStatusSet?.instanceCloudAssistantStatus ?? []) {
        result.set(s.instanceId ?? '', { online: s.cloudAssistantStatus === 'true', version: s.cloudAssistantVersion ?? '', heartbeat: s.lastHeartbeatTime ?? '' });
      }
      nextToken = body?.nextToken || undefined;
    } while (nextToken);
    return result;
  }

  /**
   * instance 可以是实例 ID，也可以是配置里的别名。
   * 发命令前查一遍租约；凭证先取到手再交给这一次的客户端，SDK 就不会在查完之后又去刷一次：
   * 刷新要走网络、超时管不到它，命令就可能在别人接手租约之后才发出去
   */
  async runPowerShell(instance: string, script: string, timeoutSec: number): Promise<RunResult> {
    const { accessKeyId, accessKeySecret, securityToken } = await this.#credential.getCredential();
    this.#held?.check();
    const client = new $Ecs.default(new $OpenApi.Config({ accessKeyId, accessKeySecret, securityToken, endpoint: `ecs.${this.#region}.aliyuncs.com` }));
    const { body } = await client.runCommand(new $Ecs.RunCommandRequest({
      regionId: this.#region,
      type: 'RunPowerShellScript',
      contentEncoding: 'Base64',
      commandContent: Buffer.from(PS_PREAMBLE + script).toString('base64'),
      instanceId: [instanceId(this.#aliases, instance)],
      timeout: timeoutSec,
    }));
    // 云助手到时会强杀脚本并置 Timeout，本地再多等一分钟兜底，避免状态没更新时死等
    const deadline = Date.now() + (timeoutSec + 60) * 1000;
    let failures = 0;
    while (Date.now() < deadline) {
      await sleep(2000);
      let r;
      try {
        const res = await this.#client.describeInvocationResults(new $Ecs.DescribeInvocationResultsRequest({
          regionId: this.#region, invokeId: body?.invokeId, contentEncoding: 'PlainText',
        }));
        r = res.body?.invocation?.invocationResults?.invocationResult?.[0];
        failures = 0;
      } catch (e) {
        // 轮询时的网络抖动不该让一次正在进行的发布"看起来失败"，连续 5 次才放弃
        if (++failures >= 5) throw new Error(`Polling Cloud Assistant results failed 5 times in a row, invokeId=${body?.invokeId}; the script may still be running on the server: ${(e as Error).message}`);
        continue;
      }
      if (r?.invocationStatus && TERMINAL_STATUS.has(r.invocationStatus)) {
        return { status: r.invocationStatus, exitCode: r.exitCode, output: r.output ?? '', error: r.errorInfo ?? '', dropped: r.dropped ?? 0 };
      }
    }
    throw new Error(`Timed out waiting for Cloud Assistant results, invokeId=${body?.invokeId}; the script may still be running on the server, see Cloud Assistant in the ECS console`);
  }
}
