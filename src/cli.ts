#!/usr/bin/env node
import { cpSync, readFileSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { Command } from 'commander';
import { checkCerts, replaceCert, type ReplaceOptions } from './certs.ts';
import { getSite, loadConfig } from './config.ts';
import { deploy, type DeployOptions } from './deploy.ts';
import { Ecs, type RunResult } from './ecs.ts';
import { renderScript } from './ps.ts';
import { pull } from './pull.ts';
import { planRollback, rollback } from './rollback.ts';

const program = new Command('aca').description('Run PowerShell on Windows ECS instances and deploy or roll back IIS sites through Alibaba Cloud Cloud Assistant')
  .version(JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version);

program.command('instances').description('List ECS instances in the configured region').action(async () => {
  const list = await new Ecs(loadConfig()).listInstances();
  console.log(['InstanceId', 'Status', 'PublicIp', 'PrivateIp', 'Name', 'OS'].join('\t'));
  for (const i of list) console.log([i.id, i.status, i.publicIp || '-', i.privateIp || '-', i.name, i.os].join('\t'));
});

program.command('sites').description('List configured sites with their project, publish directory on this machine and instances').action(() => {
  const { sites } = loadConfig();
  console.log(['Site', 'Project', 'Publish', 'Instances', 'Note'].join('\t'));
  for (const [name, s] of Object.entries(sites)) {
    console.log([name, s.project ?? '-', s.publish ?? '-', s.instances.join(','), s.note ?? ''].join('\t'));
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

program.command('deploy <site> [path]').description('Deploy a directory or zip to a configured IIS site, one server at a time; path defaults to the site\'s publish directory')
  .option('-c, --check', 'upload and pre-check only: list the files to overwrite and add, without stopping the site')
  .option('-m, --message <text>', 'note for the deploy log on the server, e.g. the commit range or branch')
  .option('-f, --force', 'deploy even if the package has files older than those on the server')
  .option('--skip-stage', 'do not require the package to be the latest deploy on the stage site')
  .action(async (site: string, path: string | undefined, opts: DeployOptions) => {
    // 说明会原样写成服务器发布记录的一行，含换行就能伪造出别的记录行
    if (/[\r\n]/.test(opts.message ?? '')) throw new Error('-m must be a single line');
    await reportEach(deploy(loadConfig(), site, path, opts));
  });

program.command('status <site>').description('Show what each server is running: newest file time and the last 5 deploy/rollback log entries')
  .action(async (site: string) => {
    const cfg = loadConfig();
    const ecs = new Ecs(cfg);
    for (const name of getSite(cfg, site).instances) {
      console.log(`== ${name}`);
      report(await ecs.runPowerShell(name, renderScript('status', { SITE: site }), 120));
    }
  });

const certs = program.command('certs').description('Show the certificate each HTTPS binding of the running sites serves on every server of the configured sites; exits non-zero if one is expired, expires within 30 days, does not match its host name or fails the handshake')
  .action(async () => {
    const { checks, failures } = await checkCerts(loadConfig());
    console.log(['Instance', 'Site', 'Binding', 'Expires', 'Certificate', 'Thumbprint', 'Status'].join('\t'));
    for (const c of checks) console.log([c.instance, c.site, c.binding, c.expires, c.name, c.thumbprint, c.status].join('\t'));
    for (const f of failures) console.error(f);
    if (failures.length || checks.some((c) => c.status !== 'OK')) process.exitCode = 1;
  });

certs.command('replace <source>').description('On every server of the configured sites, switch every HTTPS binding that uses a certificate with the same name to the source: a PFX file, or the thumbprint of a certificate already on the servers (to switch back)')
  .option('--password-file <file>', 'file holding the PFX password')
  .option('-c, --check', 'only list the bindings each server would switch')
  .option('-f, --force', 'switch even if the source certificate does not expire later than the one it replaces')
  .action(async (source: string, opts: ReplaceOptions) => {
    await reportEach(replaceCert(loadConfig(), source, opts));
  });

program.command('rollback <site>').description('Roll back the latest deploy of a site: restore the files it overwrote and delete the files it added')
  .option('-c, --check', 'only show which backup each server would restore')
  .action(async (site: string, opts: { check?: boolean }) => {
    const cfg = loadConfig();
    const plan = await planRollback(cfg, site);
    for (const { name, backup } of plan.steps) {
      console.log(`== ${name}: ${backup
        ? `roll back deploy ${plan.deployId}: restore ${backup.restored} files, delete ${backup.added} added files  (${backup.dir})`
        : `no backup of deploy ${plan.deployId}, skipped`}`);
    }
    if (!opts.check) await reportEach(rollback(cfg, plan));
  });

program.command('skill').description('Agent Skill that lets Claude Code, Codex and other agents use aca')
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
