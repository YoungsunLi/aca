#!/usr/bin/env node
import { cpSync, readFileSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { Command } from 'commander';
import { cloudSource, listCloudCerts } from './cas.ts';
import { checkCerts, readSource, replaceCert, type ReplaceOptions } from './certs.ts';
import { isWeight, siteClb } from './clb.ts';
import { getSite, getTarget, loadConfig, relativePath, targetVars } from './config.ts';
import { deploy, type DeployOptions } from './deploy.ts';
import { diff, printDiff } from './diff.ts';
import { discover, printDiscovery } from './discover.ts';
import { type Assistant, Ecs, type RunResult } from './ecs.ts';
import { targetLease } from './lease.ts';
import { type LogOptions, readLogs } from './logs.ts';
import { overview } from './overview.ts';
import { renderScript, targetLibs } from './ps.ts';
import { pull } from './pull.ts';
import { planRollback, printPlan, rollback } from './rollback.ts';

const program = new Command('aca').description('Run PowerShell on Windows ECS instances and deploy or roll back IIS sites and Windows services through Alibaba Cloud Cloud Assistant')
  .version(JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version);

program.command('instances').description('List ECS instances in the configured region, with the version of the Cloud Assistant client on each, or when it went offline').action(async () => {
  const ecs = new Ecs(loadConfig());
  const list = await ecs.listInstances();
  // 这一列另要 ecs:DescribeCloudAssistantStatus，AccessKey 没给它时照样列出实例
  const assistant = await ecs.assistantStatus().catch((e: Error) => {
    console.error(`WARN: could not read the Cloud Assistant status, which needs ecs:DescribeCloudAssistantStatus: ${e.message.split('\n')[0]}`);
    return new Map<string, Assistant>();
  });
  console.log(['InstanceId', 'Status', 'PublicIp', 'PrivateIp', 'Name', 'OS', 'CloudAssistant'].join('\t'));
  for (const i of list) {
    const a = assistant.get(i.id);
    console.log([i.id, i.status, i.publicIp || '-', i.privateIp || '-', i.name, i.os, a ? (a.online ? a.version : `offline since ${a.heartbeat || '?'}`) : '-'].join('\t'));
  }
});

program.command('discover [instances...]').description('List the IIS sites, and the Windows services installed outside the Windows, Program Files and ProgramData directories, on servers (instance IDs or aliases from the config; every running Windows instance in the region by default), with a draft of config entries for the running sites and enabled services not configured yet')
  .action(async (names: string[]) => {
    if (!printDiscovery(await discover(loadConfig(), names))) process.exitCode = 1;
  });

program.command('sites').description('List configured sites with their project, publish directory on this machine and instances').action(() => {
  const { sites } = loadConfig();
  console.log(['Site', 'Project', 'Publish', 'Instances', 'Note'].join('\t'));
  for (const [name, s] of Object.entries(sites)) {
    console.log([name, s.project ?? '-', s.publish ?? '-', s.instances.join(','), s.note ?? ''].join('\t'));
  }
});

program.command('services').description('List configured Windows services with their project, publish directory on this machine, directory on the servers and instances').action(() => {
  const { services } = loadConfig();
  console.log(['Service', 'Project', 'Publish', 'Directory', 'Instances', 'Note'].join('\t'));
  for (const [name, s] of Object.entries(services)) {
    console.log([name, s.project ?? '-', s.publish ?? '-', s.dir, s.instances.join(','), s.note ?? ''].join('\t'));
  }
});

program.command('run <instance> <script>').description('Run PowerShell on a server (instance ID or alias from the config) and wait for its output')
  .option('-t, --timeout <sec>', 'seconds before Cloud Assistant kills the script', '300')
  .action(async (instance: string, script: string, opts: { timeout: string }) => {
    const timeout = Number(opts.timeout);
    if (!Number.isInteger(timeout) || timeout <= 0) throw new Error(`--timeout must be a positive integer of seconds, got "${opts.timeout}"`);
    // 放进子作用域：否则前缀里兜底的 trap 会抢在用户自己的 trap 之前接住异常
    report(await new Ecs(loadConfig()).runPowerShell(instance, `& {\n${script}\n}`, timeout));
  });

program.command('pull <instance> <file> [local]').description('Copy a file from a server (instance ID or alias from the config) to this machine through OSS, free of the Cloud Assistant output limit; local defaults to the current directory, and an existing local file is never overwritten')
  .action(async (instance: string, file: string, local = '.') => {
    const { result, saved } = await pull(loadConfig(), instance, file, local);
    report(result);
    if (saved) console.log(`Saved ${saved}`);
  });

program.command('logs <site>').description('Print the IIS log of a site from each of its servers: the latest lines, or the latest lines in a time range; times in the log are UTC')
  .option('-n, --tail <lines>', 'lines to show from each server', '20')
  .option('--since <time>', 'start of the time range: a local time like "2026-09-21 10:00", or a duration back from now like 30m, 2h, 1d')
  .option('--until <time>', 'end of the time range, in the same forms as --since')
  .action(async (site: string, opts: LogOptions) => {
    for (const { instance, result, lines } of await readLogs(loadConfig(), site, opts)) {
      console.log(`== ${instance}`);
      report(result);
      if (lines) console.log(lines.trimEnd());
    }
  });

program.command('deploy <target> [path]').description('Deploy a directory or zip to a configured IIS site or Windows service: pre-check every server, then deploy one server at a time; path defaults to its publish directory')
  .option('-c, --check', 'upload and pre-check every server only: list the files to overwrite and add, without stopping the site or service')
  .option('-m, --message <text>', 'note for the deploy log on the server, e.g. the commit range or branch')
  .option('-f, --force', 'deploy even if the package has files older than those on the server, assembly references that would fail to load, or needs a runtime the server lacks')
  .option('--skip-stage', 'do not require the package to be the latest deploy on the stage site')
  .option('--from-stage', 'deploy the package the stage site last deployed, straight from OSS, instead of a local directory or zip')
  .action(async (name: string, path: string | undefined, opts: DeployOptions) => {
    // 说明会原样写成服务器发布记录的一行，含换行就能伪造出别的记录行
    if (/[\r\n]/.test(opts.message ?? '')) throw new Error('-m must be a single line');
    await reportEach(deploy(loadConfig(), name, path, opts));
  });

program.command('status [target]').description('Show what each server is running: newest file time, for a service its state, and the last 5 deploy/rollback log entries; without a target, one line for every configured site and service on each of its servers, with its state, newest file time and last log entry')
  .action(async (name: string | undefined) => {
    const cfg = loadConfig();
    if (!name) {
      const rows = await overview(cfg);
      console.log(['Target', 'Instance', 'State', 'Newest file', 'Last deploy/rollback'].join('\t'));
      for (const row of rows) console.log(row.join('\t'));
      if (rows.some(([, , state]) => state.startsWith('ERROR: '))) process.exitCode = 1;
      return;
    }
    const target = getTarget(cfg, name);
    const ecs = new Ecs(cfg);
    for (const instance of target.instances) {
      console.log(`== ${instance}`);
      report(await ecs.runPowerShell(instance, renderScript('status', targetVars(name, target), [...targetLibs(name), 'inspect', 'newest']), 120));
    }
  });

program.command('diff <target> [path]').description('Compare the files of a site or service across its servers by content hash and list the ones that differ; path narrows the comparison to one directory or file under it; exits non-zero if any differ')
  .action(async (name: string, path: string | undefined) => {
    const sub = path ? relativePath(path) : '';
    if (path && !sub) throw new Error(`"${path}" is not a relative path inside the directory of ${name}`);
    if (!printDiff(await diff(loadConfig(), name, sub))) process.exitCode = 1;
  });

const certs = program.command('certs').description('Show the certificate each HTTPS binding of the running sites serves on every server of the configured sites, most urgent first; exits non-zero if one is expired, expires within 30 days, does not match its host name or fails the handshake')
  .action(async () => {
    const { checks, failures } = await checkCerts(loadConfig());
    console.log(['Instance', 'Site', 'Binding', 'Expires', 'Days', 'Certificate', 'Thumbprint', 'Status'].join('\t'));
    for (const c of checks) console.log([c.instance, c.site, c.binding, c.expires, c.days ?? '-', c.name, c.thumbprint, c.status].join('\t'));
    for (const f of failures) console.error(f);
    if (failures.length || checks.some((c) => c.status !== 'OK')) process.exitCode = 1;
  });

certs.command('cloud').description('List the unexpired certificates in Certificate Management Service, the soonest to expire first; their IDs are what --from-cloud takes')
  .action(async () => {
    const list = await listCloudCerts(loadConfig());
    console.log(['CertificateId', 'Name', 'Certificate', 'Expires', 'Days', 'Status'].join('\t'));
    for (const c of list) console.log([c.id, c.name, c.common, c.expires, c.days, c.status].join('\t'));
  });

certs.command('replace [source]').description('On every server of the configured sites, switch every HTTPS binding that uses a certificate with the same name to the source: a PFX file, or the thumbprint of a certificate already on the servers (to switch back)')
  .option('--from-cloud <id>', 'certificate ID from aca certs cloud: aca downloads its PEM and builds the PFX on this machine instead')
  .option('--password-file <file>', 'file holding the PFX password')
  .option('-c, --check', 'only list the bindings each server would switch')
  .option('-f, --force', 'switch even if the source certificate does not expire later than the one it replaces')
  .action(async (source: string | undefined, opts: ReplaceOptions & { fromCloud?: string; passwordFile?: string }) => {
    const { fromCloud, passwordFile } = opts;
    if (fromCloud && (source || passwordFile)) throw new Error('--from-cloud takes no source and no --password-file: aca builds the PFX itself, with a password of its own');
    const cfg = loadConfig();
    await reportEach(replaceCert(cfg, fromCloud ? await cloudSource(cfg, fromCloud) : readSource(source, passwordFile), opts));
  });

program.command('rollback <target> [deploy]').description('Roll back a deploy of a site or service together with every deploy after it, the latest deploy by default: restore the files they overwrote and delete the files they added; deploy is a deploy ID from --check')
  .option('-c, --check', 'only list the backups each server has, their size, and which of them would be rolled back')
  .action(async (name: string, deployId: string | undefined, opts: { check?: boolean }) => {
    const cfg = loadConfig();
    if (opts.check) printPlan(await planRollback(cfg, name, deployId));
    else await reportEach(rollback(cfg, name, deployId));
  });

const clb = program.command('clb <site>').description('Show the weight of each server of the site in the default server group of its CLB')
  .action(async (site: string) => {
    const cfg = loadConfig();
    await siteClb(cfg, site).check(getSite(cfg, site).instances);
  });

clb.command('restore <site> <instance>').description('Put a server back into the CLB of the site with the weight aca recorded on this machine when taking it out, or with --weight')
  .option('--weight <n>', 'weight from 1 to 100, for a server aca has no record of')
  .action(async (site: string, instance: string, opts: { weight?: string }) => {
    const weight = opts.weight === undefined ? undefined : Number(opts.weight);
    if (weight !== undefined && !isWeight(weight)) throw new Error(`--weight must be an integer from 1 to 100, got "${opts.weight}"`);
    const cfg = loadConfig();
    // 占着和发布同一份租约：正发着的那台服务器停着站，放回去就会把请求转给它
    const held = await targetLease(cfg, site, `clb restore ${site} ${instance}`);
    try {
      await siteClb(cfg, site, held).restore(instance, weight);
    } finally {
      await held.release();
    }
  });

program.command('skill').description('Agent Skill that lets Claude Code, Codex and other AI agents use aca')
  .command('install').description('Install or update the skill in ~/.claude/skills (Claude Code) and ~/.agents/skills (Codex); run again after upgrading aca')
  .action(() => {
    for (const agentDir of ['.claude', '.agents']) {
      const dst = join(homedir(), agentDir, 'skills', 'aca');
      // 先删再拷，旧版多出来的文件不留；npx skills 装的是链接，rmSync 删的是链接本身
      rmSync(dst, { recursive: true, force: true });
      cpSync(new URL('../.claude/skills/aca', import.meta.url), dst, { recursive: true });
      console.log(`Installed ${dst}`);
    }
  });

async function reportEach(results: AsyncIterable<[string, RunResult]>) {
  for await (const [name, r] of results) {
    console.log(`== ${name}`);
    report(r);
  }
}

function report(r: RunResult) {
  if (r.output) console.log(r.output.trimEnd());
  if (r.dropped) console.error(`[output exceeded the Cloud Assistant limit, ${r.dropped} bytes dropped]`);
  if (r.status !== 'Success') {
    console.error(`[${r.status}] exitCode=${r.exitCode ?? '?'} ${r.error}`.trimEnd());
    process.exitCode = r.exitCode || 1;
  }
}

// 不用 process.exit：被管道接走时它会丢掉还没写完的 stdout
program.parseAsync().catch((e: Error) => {
  console.error(e.message);
  process.exitCode = 1;
});
