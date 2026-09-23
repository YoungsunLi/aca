<div align="center">

![aca — Aliyun Cloud Assistant CLI](.github/banner.svg)

[![npm](https://img.shields.io/npm/v/@ninesols/aca-cli?logo=npm)](https://www.npmjs.com/package/@ninesols/aca-cli)
[![node](https://img.shields.io/node/v/@ninesols/aca-cli?logo=nodedotjs)](https://nodejs.org/)
[![license](https://img.shields.io/npm/l/@ninesols/aca-cli)](LICENSE)

[简体中文](README.md) | English

</div>

Deploy IIS sites and Windows services to Windows ECS instances automatically, roll them back, run PowerShell, and check or replace SSL certificates.

- **Nothing else to install and no ports to open on the servers**: aca works through Alibaba Cloud [Cloud Assistant](https://www.alibabacloud.com/help/en/ecs/user-guide/overview-10) and needs just an AccessKey.
- **A pre-check before every deploy**: it blocks a deploy with a stale build or assembly references that fail only when the code runs, or one that needs a .NET Framework version the server lacks.
- **aca doesn't overwrite the `web.config` of a .NET Framework site whole**: it merges in only what the build decides, such as binding redirects, and leaves connection strings alone.
- **aca deploys to multiple servers automatically**: one server at a time, it stops the site or service, backs up, copies over, starts and checks it, and stops at the first failure; with CLB, it takes the server out of the load balancer first and puts it back after.
- **You can roll back a bad deploy**: aca backs up the files every deploy overwrites, and one `aca rollback` can undo several deploys.
- **See what each server really has**: `aca diff` compares file contents across servers, and `aca certs` shows the certificates actually served.
- **Replace certificates across servers with `aca certs replace`**: aca does a handshake on the server itself afterwards and switches back to the old certificate if anything is wrong.
- **Comes with an Agent Skill**: tell Claude Code, Codex or another AI agent "deploy MyApp to the test site", and it runs `--check` first, shows you the result and deploys after you confirm.

> [!CAUTION]
> Cloud Assistant runs as SYSTEM, so `aca run` can run **any** PowerShell on the servers: whoever holds this AccessKey, human or AI agent, is their administrator. The skill tells AI agents to ask you before changing a server; that is a rule for the AI agent to follow, not a permission control.

## Install

Requires Node 22.12+.

```sh
npm install -g @ninesols/aca-cli
aca skill install  # the skill for Claude Code and Codex; run it again after upgrading aca
```

Other AI agents that support the open Agent Skills standard can install it with `npx skills add YoungsunLi/aca -g`, which asks which AI agents to install it for; it installs the latest skill on GitHub, which may not match your aca version.

## Configuration

Write a config at `~/.aca/config.json`, or point the `ACA_CONFIG` environment variable at another path. Start with `region` and `oss`, then run `aca discover`: aca lists the sites and services on every server and ends with a draft of `instances`, `sites` and `services` to fill the rest from.

```json
{
  "region": "cn-hangzhou",
  "oss": { "bucket": "my-deploy-bucket", "prefix": "deploy/" },
  "instances": { "web1": "i-bp1xxxxxxxx", "web2": "i-bp1yyyyyyyy" },
  "sites": {
    "Default Web Site": {
      "instances": ["web1", "web2"],
      "project": "MyApp.Web",
      "publish": "D:\\Publish\\MyApp",
      "exclude": ["web.config", "bin/Res"],
      "stage": "Default Web Site TEST",
      "clb": "lb-bp1zzzzzzzz",
      "note": "production"
    },
    "Default Web Site TEST": { "instances": ["web1"], "publish": "D:\\Publish\\MyApp", "exclude": ["web.config", "bin/Res"] }
  },
  "services": {
    "MyApp.Worker": {
      "instances": ["web1", "web2"],
      "publish": "D:\\Publish\\Worker",
      "dir": "D:\\Services\\Worker",
      "exclude": ["MyApp.Worker.exe.config"]
    }
  }
}
```

The keys of `sites` are IIS site names, with an application under a site written as `site name/path` (see "Applications under a site" below); `deploy`, `rollback` and `status` only accept sites registered here and the services registered in `services` below. Every field except `instances` is optional:

| Field | Description |
| --- | --- |
| `instances` | The servers (aliases or instance IDs) hosting the site, in deploy order |
| `publish` | The publish directory on this machine, used when `deploy` is given no path |
| `exclude` | Paths in the package (directories or files) that are not deployed: list where the server keeps its own secrets and environment config, and deploys won't overwrite them |
| `overwriteConfig` | When `true`, the environment config (see the `aca deploy` section) is overwritten as a whole with the package's copy like any other file, without listing it in `exclude`: for projects that keep no environment values in that file, such as keeping them all in files that `configSource` points to and that are listed in `exclude` |
| `stage` | Names the staging site: this site only takes the package that was the latest successful deploy on the staging site, and not once the staging site has rolled it back; `--skip-stage` skips this requirement. `--from-stage` deploys exactly that package; given a local path, aca compares the zip it would upload, so a rebuild is a different package, and both sides must use the same kind of input: both a directory, or both the same zip file |
| `keep` | How many backups of the site each server keeps, 5 by default; `rollback` can undo at most that many of the latest deploys |
| `clb` | ID of the Classic Load Balancer (CLB) instance in front of the site: before `deploy` or `rollback` works on each server, aca takes it out of the load balancer; see `aca deploy` |
| `project`<br>`note` | Only shown by `aca sites` and `aca services`, to help find the right site or service |

The keys of `services` are Windows service names (the ones `sc query` lists, not the display names). The fields are the same as for a site, without `stage` and `clb`, plus a required `dir`: the installation directory on the servers; aca checks that the service's executable really is inside it and refuses to deploy otherwise.

### Applications under a site

An IIS application under a site (the kind "Add Application" creates in IIS Manager) is written as `site name/path`, such as `Default Web Site/api`, and registered in `sites` with the same fields as a site. Where it differs from a site:

- **Only the application's own app pool is stopped**, and the site keeps serving its other applications; when the app pool is shared with the site or other applications, the pre-check lists the ones that go down with it.
- **The home page check requests `/<path>/`**, and `aca logs` takes only the requests under that path.
- **When the application's directory is inside the site's, or another application's or virtual directory's of the same site, its backups and deploy log go next to the outermost directory containing it**, under `<that directory>.aca-apps\<relative path>`: next to the application's directory they would land inside that directory and IIS would serve them. If the site itself is deployed too, list the application's directory in the site's `exclude`, so `aca diff` of the site doesn't compare the application's files as well.
- **Deploying an application holds the lease and the server-side lock of its site too**: deploying the site stops it, and the applications under it with it.

### Credentials and permissions

Credentials are resolved by the Alibaba Cloud SDK's [default credential chain](https://www.alibabacloud.com/help/en/sdk/developer-reference/v2-manage-node-js-access-credentials), shared with the Alibaba Cloud CLI: once you have run `aliyun configure` there is nothing more to set up; you can also set the environment variables `ALIBABA_CLOUD_ACCESS_KEY_ID` and `ALIBABA_CLOUD_ACCESS_KEY_SECRET`, which take precedence over `aliyun configure`.

**RAM permissions**:

| Product | Permissions |
| --- | --- |
| ECS | `ecs:DescribeInstances`, `ecs:DescribeCloudAssistantStatus` (without it `aca instances` can't show the state of the Cloud Assistant client), `ecs:RunCommand`, `ecs:DescribeInvocationResults` |
| OSS | `oss:PutObject`, `oss:GetObject`, `oss:ListObjects`, `oss:GetBucketPolicyStatus`, `oss:DeleteObject`; on a versioned bucket, `pull`, `logs`, `diff` and `certs replace` need `oss:DeleteObjectVersion` to delete the files they pass through OSS |
| CLB | For sites with `clb`: `slb:DescribeLoadBalancerAttribute`, `slb:DescribeLoadBalancerListeners`, `slb:DescribeHealthStatus`, `slb:SetBackendServers` |
| Certificate Management Service | To take certificates from the cloud: `yundun-cert:ListUserCertificateOrder`, `yundun-cert:GetUserCertificateDetail`; the service authorizes per operation, so the resource can only be `*` |

> [!WARNING]
> Grant `ecs:RunCommand` per instance ID, never `*`: this AccessKey is an administrator of every instance it is granted on.

## Constraints

- **ECS and the OSS bucket are in the same region**; packages are downloaded over the OSS internal network.
- **Servers need the [Cloud Assistant client](https://www.alibabacloud.com/help/en/ecs/user-guide/install-the-cloud-assistant-agent#775c8cd747xcj)** (preinstalled on servers created from public images since December 2017).
- **Cloud Assistant returns output in the server's ANSI code page**: characters outside it (e.g. Chinese on English Windows) in site names, paths and `-m` notes turn into question marks.
- **A site or service directory must be a plain directory on a local drive**, not a drive root or a UNC path, and not nested inside another target's directory (applications under a site aside, see "Applications under a site"): backups and the deploy log live next to it.
- **The `<root>.bak-<time>` backups and `<root>.aca-*` files next to that directory are aca's state; don't delete them by hand**: without the latest backup, `rollback` skips that deploy and restores a mix that was never deployed.
- **After a deploy the site and its app pool are started**, even if they had been stopped by hand; a service is the opposite: one stopped before the deploy is left stopped, since on a standby server a service is often stopped on purpose.
- **This machine and the servers must be in the same time zone**: file times in the package are stored as local time, and the check for files older than the copies on the server relies on them.
- **Packages (`--check` uploads too) stay in OSS under `<prefix>`, named by their SHA-256**; aca doesn't delete them; set up a lifecycle rule on the bucket to expire them, with more days than you take from deploying to the staging site to deploying production with `--from-stage`.
- **The bucket must be private, and its hotlink protection must allow an empty Referer**: packages are not encrypted, so on every `deploy` (`--check` too) aca first makes sure the packages under `<prefix>` can't be read without credentials and that the bucket policy opens nothing to anonymous users, and stops with an error otherwise. A policy statement that lets anonymous users in only with certain Referers or User-Agents still counts as open; one limited to source IPs, VPCs or AccessKeys doesn't. The servers download packages without a Referer.

## Commands

Every command prints plain text and exits non-zero on failure.

**Servers and config**

```sh
aca instances                                   # list instances with the version of the Cloud Assistant client on each
aca discover                                    # list the sites and services on every Windows server, with a config draft
aca discover web1 web2                          # only these servers
aca sites                                       # list sites with their project, publish directory and instances
aca services                                    # list Windows services with their directory on the servers
```

**Troubleshooting and ad-hoc operations**

```sh
aca run web1 "Get-Website | select name,state"  # run any PowerShell as SYSTEM
aca run web1 --file ./check.ps1                 # run the script in a file, for scripts with $, quotes or line breaks
aca pull web1 "C:\inetpub\logs\LogFiles\W3SVC1\u_ex260919.log"  # copy a file from a server to the current directory
aca logs "Default Web Site"                     # the latest 20 lines of the site's IIS log on each server
aca logs "Default Web Site" --since 30m -n 500  # the latest 500 lines of the last 30 minutes
aca diff "Default Web Site"                     # compare the files on every server by content hash and list the ones that differ
aca diff "Default Web Site" bin                 # compare one directory under the site directory only
```

**Deploy and roll back**

```sh
aca deploy "Default Web Site" --check           # pre-check only: list the files to overwrite and add, the site keeps running
aca deploy "Default Web Site" -m "release-2026-09"  # deploy the directory in the publish field of the config; -m goes into the deploy log
aca deploy "Default Web Site" ./MyApp.zip -m "release-2026-09"  # deploy another directory or zip, ignoring the publish field
aca deploy "Default Web Site" --from-stage -m "release-2026-09"  # deploy the package the staging site last deployed
aca deploy MyApp.Worker -m "release-2026-09"    # deploy a Windows service, same options as a site
aca deploy "Default Web Site/api" ./api -m "release-2026-09"  # deploy an application under a site
aca status "Default Web Site"                   # newest file time, a service's state + last 5 deploy/rollback entries of each server
aca status                                      # a line per server for every site and service: state, newest file time, last deploy/rollback
aca rollback "Default Web Site" --check         # the backups each server still has, their size, and which deploys would be undone
aca rollback "Default Web Site"                 # roll back the latest deploy
aca rollback "Default Web Site" 20260918T020100Z  # roll back that deploy and every deploy after it
aca clb "Default Web Site"                      # weight of each server in the CLB
aca clb restore "Default Web Site" web1         # put web1, taken out earlier, back into the load balancer
```

**Certificates**

```sh
aca certs                                       # certificates the HTTPS bindings of running sites actually serve on each server
aca certs replace ./a.pfx --password-file ./pw.txt --check  # see which HTTPS bindings each server would switch to this certificate
aca certs replace ./a.pfx --password-file ./pw.txt  # switch them
aca certs cloud                                 # unexpired certificates in Certificate Management Service, and their IDs
aca certs replace --from-cloud 22863954         # switch to that cloud certificate, PFX built by aca
```

### `aca discover`

aca lists the IIS sites and Windows services on the servers, and ends with a config draft to fill the config from. Without servers, it covers every running Windows server in the region.

- **One line per site or service**: its state, directory and newest file time; a site adds its app pool, bitness, runtime and first three bindings, a service its start mode and command line.
- **Only services installed outside the Windows, Program Files and ProgramData directories are listed**: the ones in there are Windows's own and installed software (the Cloud Assistant client, antivirus, databases), not programs you deploy yourself.
- **The draft takes only what the config doesn't have yet**: running sites, and services that aren't disabled. Servers go by their alias in the config, or by instance name if they have none.
- **A `NOTE` line comes when a site or service's newest file on one server is more than a day older than on another**: the copy on that server may be long out of use; make sure before adding it to the config or deploying there.
- **A server that can't be looked at** (for example with its Cloud Assistant client offline) doesn't hold up the others; aca reports it at the end and exits non-zero.

### `aca run`

aca runs any PowerShell on the server as SYSTEM and prints the output when it finishes; if the script exits non-zero (an uncaught exception included), aca exits with the same code.

- **Handy for ad-hoc operations** such as reading logs, checking disk space or restarting an app pool; the instance can be an alias from the config or any instance ID in the configured region.
- **Use `--file <file>` for a script with `$`, quotes or line breaks**: a script on the command line goes through the local shell first, which may silently change them; the file must be UTF-8.
- **`-t` kills the script after this many seconds** (default 300).
- **By default a failing PowerShell command only reports an error** and the exit code stays 0; start the script with `$ErrorActionPreference = 'Stop'` to make any error a failure.
- **The script plus the prefix aca adds must fit in 24 KB after base64** (about 18 KB of plain English text); output beyond the Cloud Assistant limit keeps only its beginning and end, and aca reports how many bytes were dropped from the middle, so filter large output in the script; to read a whole file, use `aca pull`.
- **Change site files with `aca deploy`**: whatever you change with `aca run` has no backup, and `aca rollback` can't undo it.

### `aca pull`

aca copies a file from a server to this machine, free of the Cloud Assistant output limit: read a whole log (even one still being written) or compare `web.config` across servers.

- **The local path defaults to a file of the same name in the current directory**; given an existing directory, the file goes into it. If the local file already exists, aca refuses to overwrite it.
- **The file goes through OSS**: the server encrypts it with a one-time key aca generates for this pull before uploading; aca downloads and decrypts it, then deletes it from OSS. The key stays in the Cloud Assistant invocation history.

### `aca logs`

aca finds the site's log files on each server from the site's logging settings in IIS and prints the latest `-n` lines (20 by default).

- **With `--since` or `--until`, only lines in that time range count**, still the latest `-n` of them; aca says so when the range may hold earlier lines. Give a local time (`"2026-09-21 10:00"`; a date alone means midnight) or a duration back from now (`30m`, `2h`, `1d`).
- **Times in the log are UTC**: that is how the IIS W3C format records them; aca prints the lines as they are and converts only `--since` and `--until` to UTC to compare.
- **Requests from a moment ago are there too**: HTTP.sys holds log entries for a while before writing them, and aca has it write them out before reading.
- **Only the W3C format** (the IIS default) is read; the lines go through OSS, encrypted and deleted after reading, like `aca pull`.

### `aca diff`

When the servers behind a load balancer hold different files, the site works on one refresh and fails on the next. `aca diff <site or service>` hashes the files on every server and lists the ones that are not the same everywhere.

- **It compares every file under the site directory** (for a service, under `dir` from the config), except the paths in `exclude`: those are maintained on the server and are meant to differ. List upload and log directories in `exclude` too and they are skipped as well. Directory junctions are not followed; hidden files are compared.
- **For a service only `.dll` and `.exe` are compared**: a service keeps its assemblies in the same directory as the logs it writes every day.
- **One line per file that differs**, followed by the servers grouped by content (`web1,web2=<first 8 hash characters> <last write time>`); a server without the file shows `missing`. aca exits non-zero when any differ.
- **Beyond 50 differing files, the first 50 are followed by a per-directory summary**: see which directories they fall into, then narrow the comparison with `aca diff <site> <directory or file>`, for example `aca diff "Default Web Site" bin`. A server without that directory counts as missing every file in it.
- **Every server reads its whole directory to hash it**, which takes minutes on a directory of a few GB, and Cloud Assistant kills the script after 30 minutes. The script runs at `BelowNormal` priority so it loses the CPU to the IIS worker processes.
- **The file list goes through OSS**, encrypted with a one-time key like `aca pull` and deleted right after: a list of a few thousand files exceeds the Cloud Assistant output limit.
- **Read-only, and it takes no lease**: run during a deploy of this site, it reports the half-deployed state.

### `aca deploy`

aca first downloads, extracts and pre-checks on every server at the same time; once every server passes, it goes one server at a time: stop the site or service → back up the files about to be overwritten to `<root>.bak-<time>` → copy over → start it again → check its state → delete backups beyond the latest `keep`.

- **Deploys are incremental**: whatever is in the package gets overwritten (except `exclude`), so you can ship just a few changed files; uploads and logs already in the directory stay untouched, the environment config changes only where described below, and files removed from the package are not cleaned up.
- **`--from-stage` deploys the package the staging site last deployed successfully**: aca takes that package from OSS, with no local build and no new upload; once the bucket's lifecycle rule has removed it, aca reports an error, and you deploy the same build from a local path instead.

#### Pre-check

- **When the pre-check fails on any server** (source code traces, an environment config at the package root, looks like the wrong target, not enough disk space, files older than the copies on the server, assembly references that would fail to load, a runtime the package needs but the server lacks), aca deploys to none of them and exits. Files older than the copies on the server mean an old build was picked up, or someone edited files on the server; add `-f` if you do want to overwrite them.
- **Files in `exclude` aren't deployed, but the pre-check lists two kinds of them**: those the server doesn't have yet, and those whose copy in the package differs from the last deploy's, which usually means developers changed it and the server's copy may need the same change. The last deploy's hashes are kept in that deploy's backup manifest, so the first deploy has nothing to compare with.
- **The pre-check resolves every assembly reference after the deploy the way the runtime does**: the strong-named references of every assembly in bin (a service's directory for a service) and the versioned type names in the environment config, through the binding redirects and the GAC. Such problems don't stop the site from starting; they fail only when that code runs, so the home page check misses them.
  - **If this deploy breaks a reference that resolved before, or new code references a version that doesn't match bin**, aca lists them and deploys to no server. Usually a NuGet package was upgraded without its binding redirects: add them to the project's config and let the package carry the environment config, and aca syncs the redirects over; add `-f` once you're sure it's fine.
  - **If new code references an assembly found neither in bin nor in the GAC**, aca only warns: it may be an unused dependency, or a file missing from the publish output.
- **The pre-check also verifies the server meets the runtime requirements this deploy brings**: when either of the first two below is unmet, aca lists it and deploys to no server. Install or adjust things on the server and deploy again, or add `-f` once you're sure it's fine.
  - **.NET Framework version**: the target framework the changed assemblies were built for, and newly written `targetFramework` or `startup` `sku` values in the config, are newer than what the server has.
  - **Bitness**: a changed assembly loads only in a 64-bit process while the site's app pool is 32-bit, or the other way round. For a service, the executable decides, and AnyCPU with "Prefer 32-bit" runs in a 32-bit process too; when the executable's bitness changes, the assemblies already there are checked again.
  - **A missing .NET Core shared framework only gets a warning**: a framework the package's `runtimeconfig.json` asks for can't be found on the server under its roll-forward rule. Where the host looks and which version it accepts also depend on environment variables (`DOTNET_ROOT`, `DOTNET_ROLL_FORWARD` and others) that aca can't fully see, so it doesn't block.

#### Environment config

The environment config is a site's `web.config` or a service's `<executable>.exe.config`: the server keeps its own, so aca refuses a package with one at its root; list it in `exclude` and it is never overwritten as a whole. With `overwriteConfig`, aca deploys it like any other file.

- **The `web.config` of ASP.NET Core is generated at publish**, so aca deploys it whole like any other file: settings added to the server's copy, such as `environmentVariables`, are overwritten; keep per-server values in `appsettings.<environment>.json` or in the server's environment variables. When an environment config deployed whole differs from the server's copy, the pre-check says so.
- **The parts of the environment config that the build decides follow the package**: when the package carries the environment config (it is in `exclude`, so it isn't deployed itself), aca merges the parts below into the server's copy, leaving connection strings, `appSettings` and everything else, and every byte outside the changes, as they were.
  - **Merged entry by entry**: assembly binding redirects (`runtime/assemblyBinding`), the `system.codedom` compilers, Entity Framework `providers` and `compilation` `assemblies`. An entry in the package replaces the server's entry for the same thing; entries only on the server are kept.
  - **Replaced with the package's**: `startup`.
  - **Value only**: `targetFramework` on `compilation` and `httpRuntime`.
  - **The pre-check lists every change**; the server's copy goes into this deploy's backup, so `aca rollback` restores it too. If someone edits the file after the pre-check, aca fails before stopping the site.
  - **When it doesn't sync**: if the server's section has elements the package's lacks (such as `probing`), a section appears more than once, its config section is kept in another file with `configSource`, or the file isn't UTF-8, aca leaves that section alone and prints a `WARN` line.
  - **Sections, `appSettings` keys and connection strings new in the package's copy are not merged**: their values depend on the environment, so the pre-check only lists the names missing from the server's copy. When the server's copy keeps `appSettings` or connection strings in another file (`configSource`, `file`), those two are not compared.

#### Home page check and load balancer

- **The home page check** requests the site's `/` on the server itself; a 5xx or no connection that differs from the status before the deploy fails that server; files are not rolled back automatically. The pre-check prints the home page status before the deploy.
  - **An http binding comes first**; a redirect to one of the site's own https bindings is followed to that binding, without validating the certificate. A site without an http binding is checked over an https binding.
  - **A redirect to another site** (such as a separate site that only redirects) leaves just the redirect's status code, which says nothing about whether the application started.
- **aca deploys the servers one at a time** and stops at the first failure; servers already deployed are not rolled back automatically.
- **For a site with `clb`, aca takes each server out of the load balancer before deploying to it**: it sets the server's weight in the CLB default server group to 0, so the CLB sends it no requests while the site is stopped; once the server deploys successfully, aca restores the weight and moves on to the next one.
  - **aca only takes a server out while another server in the default server group is taking traffic** (weight above 0, every enabled health check normal): when every other server has weight 0, aca reports an error and stops right away; when some have weight but their health checks haven't recovered yet, it waits up to 5 minutes.
  - **aca leaves a server whose weight is already 0 as it is**, and deploys to it as usual.
  - **A server that fails after its site was stopped stays out of the load balancer**: the CLB health check may not probe this site, so putting it back could send users to a site that didn't start or was broken by the deploy. A server that fails before its site is stopped (say, disk space ran out again) is put back.
  - **Only the default server group is handled**: for a site whose traffic goes through a VServer group via forwarding rules, taking servers out of the default server group does nothing.
  - **Weights only affect new connections**: layer-7 (HTTP/HTTPS) listeners open a new connection to the server for every request, so they are not affected; connections already established through layer-4 (TCP/UDP) listeners stay on the server and break when its site stops.
  - **Only one `deploy` or `rollback` runs on a CLB at a time**: for a site with `clb`, aca holds the lease (below) on the CLB as well as on the site, so deploying another site on the same CLB fails until the run is over.

#### Leases and locks

- **Only one `deploy` or `rollback` runs on a site or service at a time**: aca holds a lease for the whole run, and the other one fails right away, naming who holds it, on which machine and since when.
  - The lease is an object under `<oss.prefix>lease/` on OSS, renewed every 30 seconds while held; it expires 3 minutes after aca is killed, so there is nothing to unlock by hand, and aca stops before the next server once it has gone nearly 2 minutes without a successful renewal.
  - **It only works between aca installs configured with the same bucket and `oss.prefix`**: that is where the lease lives, and an aca pointed at another bucket cannot see it, so both would deploy at once.
  - **The lease covers the aca run, not a script already handed to Cloud Assistant**: once aca is killed, the script still runs to the end on the server (up to 30 minutes for a deploy) while the lease expires after 3; check with `aca status` before touching that site again.
  - **`--check` takes no lease**: the pre-check changes nothing on the servers.
- **The server has a lock of its own**: only one script at a time can change a given site or service on a given server; the other one reports `Another aca operation is modifying this site or service`.
  - The lock is an exclusive handle on `<root>.aca-lock` next to the directory, released when the script ends or is killed; the file staying around doesn't mean anyone holds it.

#### Windows services

Services use the same commands and the same backup and rollback machinery as sites; what differs is stopping and starting:

- **aca waits for the service to really stop and to really start**, up to 120 seconds each, then reports an error rather than letting Cloud Assistant kill the whole script.
- **When other services depend on it and are running, aca leaves it alone**: stopping it would stop them too, and aca would start only it again afterwards — deploy such a service by hand.
- **Only services that are running or stopped are deployed**: from `Paused` and the like a service cannot be stopped and started back into the same state, so aca reports an error instead.
- **The state check** looks every 3 seconds, up to 3 times, after the start: if the service is not back in the state it was in before the deploy (most likely it crashed on startup), that server counts as failed; files are not rolled back automatically.
- **`--from-stage` on a service is an error**: services have no staging.

#### After a failed deploy

Whether you undo this deploy or fix it and deploy again, first run `aca rollback <site> --check`:

- if `undo` marks this deploy (the deploy ID is its start time in UTC), roll back first;
- if it marks an earlier deploy, no server got this one and there is nothing to roll back.

> [!WARNING]
> If you deploy again without rolling back first, the servers that got this deploy back up its files, so a rollback afterwards only takes them back to this deploy, not to the version before it.

**When the output has `WARN: <instance> stays out of CLB`**, that server was left out of the load balancer, and neither a rollback nor a new deploy puts it back: once its sites work, put it back with `aca clb restore <site> <instance>`.

### `aca rollback`

On each server, aca restores the files a deploy overwrote, deletes the files and directories it added, restarts the site or service, then deletes the backup it used. Without a deploy ID it rolls back the latest deploy only; rolling back again undoes the one before it.

- **`--check` lists the backups each server still has**, newest first: the deploy ID, how many files it would restore and delete, and its size, followed by that deploy's line in the deploy log (time, outcome, `-m` note). `undo` marks the ones this rollback would undo, `keep` the ones it leaves alone; a server with nothing to undo is marked `skipped`, most likely because those deploys never reached it.
- **Given a deploy ID, aca undoes that deploy and every deploy after it in one go**, back to the version before that deploy. Backups stack on top of each other, so one in the middle can't be undone alone; each server stops only once, and the versions in between are never started.
- **The version before the oldest backup is as far back as it goes**; anything earlier takes redeploying an older build. If a server has already pruned a backup the rollback needs, aca reports an error and rolls back no server.
- **If a service that was running doesn't come back up**, the version rolled back to doesn't start either: aca reports an error, the service stays stopped on that server, and the remaining servers are left alone. Look into that server first: the backups it used are already gone, so rolling back again skips it and only takes the other servers to the same version.
- **For a site with `clb`, aca takes each server out of the load balancer before rolling it back**, just as for a deploy, and rolls back servers already left out first; when taking out the next one would leave no server taking traffic, aca reports an error and stops: put the rolled-back server back with `aca clb restore`, then roll back again.

### `aca clb`

Run `aca clb <site>` to list the weight of each server of the site in the default server group of its CLB, with the original weight noted for any server aca took out and hasn't put back; run `aca clb restore <site> <instance>` to set that server's weight back to the original. `restore` takes the same lease as a deploy, so it fails while the site is being deployed: the server may be stopped right then.

- **The original weight is recorded on this machine under `~/.aca/clb/`**: aca records it before taking a server out and deletes it once the server is back. On another machine, or for a server aca didn't take out, there is no record, so give the weight with `--weight`.

### `aca certs`

On every server of the configured sites, aca does a TLS handshake on the server itself for each HTTPS binding of every running site and lists the certificate actually served with the days it has left, failed handshakes and the soonest to expire first; sites missing from the config are checked too, stopped sites are not.

- **Exits non-zero** if a certificate is expired, expires within 30 days, doesn't cover the binding's host name (`*.a.com` doesn't cover `x.y.a.com`) or the handshake fails, so it can run as a scheduled task.
- **It reports what the handshake returns, not the IIS configuration**: once the certificate of an SNI binding is deleted, http.sys serves the certificate of the non-SNI binding on the same port instead, or drops the connection if there is none, while IIS still shows the old certificate.

### `aca certs replace`

On the same servers, aca switches every HTTPS binding that uses a certificate with the same subject name (e.g. `*.a.com`) to this certificate; the old certificates stay on the servers.

- **`--from-cloud <certificate ID>` takes the certificate from Certificate Management Service**: `aca certs cloud` lists the IDs, aca downloads the PEM and builds the PFX on this machine with a password of its own, so no `--password-file`.
- **It switches http.sys binding entries, not sites**: non-SNI bindings share one IP:port entry, so switching one of those sites switches them all; `--check` lists the sites on each entry.
- **aca switches the servers one at a time**, with a handshake on the server itself for each HTTPS binding of the running sites before and after: every binding that served a certificate with that name must serve the new one afterwards, and one whose host name matched or whose chain the server trusted must still do so; otherwise that server switches back to the old certificates and aca stops there, leaving servers already switched as they are.
- **Only one `certs replace` at a time can switch certificates on a server**; the lock is an exclusive handle on `%ProgramData%\aca-certs.aca-lock`.
- **A certificate that is not valid now is refused**, and so is one that does not expire later than the one it replaces, as it is most likely the wrong file; to switch back, pass the old certificate's thumbprint instead of a PFX and add `-f`.
- **Entries carrying http.sys settings beyond the IIS defaults** (client certificate negotiation, revocation checks and the like) are left alone: switching would drop those settings, so switch them by hand.
- **The PFX is encrypted with a one-time key**, reaches the servers through OSS and is deleted once all servers are done: a private key can't go into RunCommand, whose content shows up in the Cloud Assistant invocation history. The PFX password is read from `--password-file` and, like the decryption key, does stay in that history.
- **Windows Server 2016 and earlier can't open AES-encrypted PFX files** (OpenSSL 3's default) and report a wrong password instead; re-export with `openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1`.

## Polling failures and timeouts

- **When aca reports `Polling Cloud Assistant results failed` or `Timed out waiting for Cloud Assistant results`**, the script may still be running on the server; run `aca status` before deciding whether to roll back.
- **If Cloud Assistant kills the script at its 30-minute limit**, no log entry is written, the site and its app pool or the service may be left stopped, and files may be half overwritten. Run `aca rollback <site> --check`: if this server would roll back this deploy, roll back; otherwise its files are untouched, so start it again with:

  ```sh
  aca run <instance> "Start-WebAppPool (Get-Website '<site>').applicationPool; Start-Website '<site>'"
  aca run <instance> "Start-Service '<service>'"   # for a service
  ```

- **For a site with `clb`, in both cases above the server being worked on stays out of the load balancer**, and the output has `WARN: <instance> stays out of CLB`; see "After a failed deploy". If aca itself is stopped halfway (Ctrl+C, for example), the server stays out too, just without that WARN line; put it back with `aca clb restore` all the same.

## Disclaimer

> [!CAUTION]
> aca stops and overwrites production sites. Get it working on a test site first, run `--check` before every deploy, and keep the AccessKey safe.

This software is provided "as is" under the MIT license, without warranty of any kind; see [LICENSE](LICENSE).
