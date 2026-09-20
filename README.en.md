<div align="center">

![aca — Aliyun Cloud Assistant CLI](.github/banner.svg)

[![npm](https://img.shields.io/npm/v/aca-cli?logo=npm)](https://www.npmjs.com/package/aca-cli)
[![node](https://img.shields.io/node/v/aca-cli?logo=nodedotjs)](https://nodejs.org/)
[![license](https://img.shields.io/npm/l/aca-cli)](LICENSE)

[简体中文](README.md) | English

</div>

Run PowerShell on Windows ECS instances, deploy or roll back IIS sites and Windows services, and check or replace their SSL certificates through Alibaba Cloud [Cloud Assistant](https://www.alibabacloud.com/help/en/ecs/user-guide/overview-10).

- **Nothing to install and no ports to open on the servers**, just an AccessKey.
- **Plain-text output** with non-zero exit codes on failure.
- **Comes with an Agent Skill**: tell Claude Code, Codex or another agent "deploy MyApp to the test site", and it runs `--check` first, shows you the result and deploys after you confirm.

## Install

Requires Node 22.12+.

```sh
npm install -g aca-cli
aca skill install  # the skill for Claude Code and Codex; run it again after upgrading aca
```

Other agents that support the open Agent Skills standard can install it with `npx skills add YoungsunLi/aca -g`, which asks which agents to install it for; it installs the latest skill on GitHub, which may not match your aca version.

## Configuration

Write a config at `~/.aca/config.json`, or point the `ACA_CONFIG` environment variable at another path.

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

The keys of `sites` are IIS site names; `deploy`, `rollback` and `status` only accept sites registered here and the services registered in `services` below. Every field except `instances` is optional:

| Field | Description |
| --- | --- |
| `instances` | The servers (aliases or instance IDs) hosting the site, in deploy order |
| `publish` | The publish directory on this machine, used when `deploy` is given no path |
| `exclude` | Paths in the package (directories or files) that are not deployed: list where the server keeps its own secrets and environment config, and deploys won't overwrite them |
| `stage` | Names the staging site: this site only takes the package that was the latest successful deploy on the staging site, and not once the staging site has rolled it back; `--skip-stage` skips this requirement. `--from-stage` deploys exactly that package; given a local path, aca compares the zip it would upload, so a rebuild is a different package, and both sides must use the same kind of input: both a directory, or both the same zip file |
| `keep` | How many backups of the site each server keeps, 5 by default; `rollback` can go back at most that many times |
| `clb` | ID of the Classic Load Balancer (CLB) instance in front of the site: before `deploy` or `rollback` works on each server, aca takes it out of the load balancer; see `aca deploy` |
| `project`<br>`note` | Only shown by `aca sites` and `aca services`, to help find the right site or service |

The keys of `services` are Windows service names (the ones `sc query` lists, not the display names). The fields are the same as for a site, without `stage` and `clb`, plus a required `dir`: the installation directory on the servers; aca checks that the service's executable really is inside it and refuses to deploy otherwise.

### Credentials and permissions

Credentials are resolved by the Alibaba Cloud SDK's [default credential chain](https://www.alibabacloud.com/help/en/sdk/developer-reference/v2-manage-node-js-access-credentials), shared with the Alibaba Cloud CLI: once you have run `aliyun configure` there is nothing more to set up; you can also set the environment variables `ALIBABA_CLOUD_ACCESS_KEY_ID` and `ALIBABA_CLOUD_ACCESS_KEY_SECRET`, which take precedence over `aliyun configure`.

**RAM permissions**: `ecs:DescribeInstances`, `ecs:RunCommand`, `ecs:DescribeInvocationResults`, `oss:PutObject`, `oss:GetObject`, `oss:ListObjects`, `oss:DeleteObject` (on a versioned bucket, `pull` and `certs replace` need `oss:DeleteObjectVersion` to delete the files they pass through OSS), and `slb:DescribeLoadBalancerAttribute`, `slb:DescribeLoadBalancerListeners`, `slb:DescribeHealthStatus` and `slb:SetBackendServers` for sites with `clb`.

> [!WARNING]
> Cloud Assistant runs scripts as SYSTEM: whoever holds this AccessKey, human or agent, is an administrator of every instance `ecs:RunCommand` is granted on. Grant it per instance ID, never `*`.

## Constraints

- **ECS and the OSS bucket are in the same region**; packages are downloaded over the OSS internal network.
- **Servers need the [Cloud Assistant client](https://www.alibabacloud.com/help/en/ecs/user-guide/install-the-cloud-assistant-agent#775c8cd747xcj)** (preinstalled on servers created from public images since December 2017).
- **Cloud Assistant returns output in the server's ANSI code page**: characters outside it (e.g. Chinese on English Windows) in site names, paths and `-m` notes turn into question marks, and `rollback` fails if the directory path contains any.
- **A site or service directory must be a plain directory on a local drive**, not a drive root or a UNC path, and not nested inside another target's directory: backups and the deploy log live next to it.
- **The `<root>.bak-<time>` backups and `<root>.aca-*` files next to that directory are aca's state; don't delete them by hand**: without the latest backup, `rollback` skips that deploy and restores a mix that was never deployed.
- **After a deploy the site and its app pool are started**, even if they had been stopped by hand; a service is the opposite: one stopped before the deploy is left stopped, since on a standby server a service is often stopped on purpose.
- **This machine and the servers must be in the same time zone**: file times in the package are stored as local time, and the check for files older than the copies on the server relies on them.
- **Packages (`--check` uploads too) stay in OSS under `<prefix>`, named by their SHA-256**; aca doesn't delete them; set up a lifecycle rule on the bucket to expire them, with more days than you take from deploying to the staging site to deploying production with `--from-stage`.

## Commands

```sh
aca instances                                   # list instances
aca sites                                       # list sites with their project, publish directory and instances
aca services                                    # list Windows services with their directory on the servers
aca run web1 "Get-Website | select name,state"  # run any PowerShell as SYSTEM
aca pull web1 "C:\inetpub\logs\LogFiles\W3SVC1\u_ex260919.log"  # copy a file from a server to the current directory
aca deploy "Default Web Site" ./publish --check # pre-check only: list the files to overwrite and add, the site keeps running
aca deploy "Default Web Site" ./publish -m "release-2026-09"  # directory or zip; -m goes into the deploy log
aca deploy "Default Web Site" --from-stage -m "release-2026-09"  # deploy the package the staging site last deployed
aca deploy MyApp.Worker ./publish -m "release-2026-09"  # deploy a Windows service, same options as a site
aca status "Default Web Site"                   # newest file time, a service's state + last 5 deploy/rollback entries of each server
aca certs                                       # certificates the HTTPS bindings of running sites actually serve on each server
aca certs replace ./a.pfx --password-file ./pw.txt --check  # see which HTTPS bindings each server would switch to this certificate
aca certs replace ./a.pfx --password-file ./pw.txt  # switch them
aca rollback "Default Web Site" --check         # see which deploy each server would roll back
aca rollback "Default Web Site"                 # roll back the latest deploy
aca clb "Default Web Site"                      # weight of each server in the CLB
aca clb restore "Default Web Site" web1         # put web1, taken out earlier, back into the load balancer
```

### `aca run`

aca runs any PowerShell on the server as SYSTEM and prints the output when it finishes; if the script exits non-zero (an uncaught exception included), aca exits with the same code.

- **Handy for ad-hoc operations** such as reading logs, checking disk space or restarting an app pool; the instance can be an alias from the config or any instance ID in the configured region.
- **`-t` kills the script after this many seconds** (default 300).
- **By default a failing PowerShell command only reports an error** and the exit code stays 0; start the script with `$ErrorActionPreference = 'Stop'` to make any error a failure.
- **The script plus the prefix aca adds must fit in 24 KB after base64** (about 18 KB of plain English text); output beyond the Cloud Assistant limit is cut off and aca reports how many bytes were dropped, so filter large output in the script; to read a whole file, use `aca pull`.
- **Change site files with `aca deploy`**: whatever you change with `aca run` has no backup, and `aca rollback` can't undo it.

### `aca pull`

aca copies a file from a server to this machine, free of the Cloud Assistant output limit: read a whole log (even one still being written) or compare `web.config` across servers.

- **The local path defaults to a file of the same name in the current directory**; given an existing directory, the file goes into it. If the local file already exists, aca refuses to overwrite it.
- **The file goes through OSS**: the server encrypts it with a one-time key aca generates for this pull before uploading; aca downloads and decrypts it, then deletes it from OSS. The key stays in the Cloud Assistant invocation history.

### `aca deploy`

On each server, aca runs: download and extract → pre-check → stop the site or service → back up the files about to be overwritten to `<root>.bak-<time>` → copy over → start it again → check its state → delete backups beyond the latest `keep`.

- **Deploys are incremental**: whatever is in the package gets overwritten (except `exclude`), so you can ship just a few changed files; uploads, logs and the environment config already in the directory stay untouched, and files removed from the package are not cleaned up.
- **`--from-stage` deploys the package the staging site last deployed successfully**: aca takes that package from OSS, with no local build and no new upload; once the bucket's lifecycle rule has removed it, aca reports an error, and you deploy the same build from a local path instead.
- **When the pre-check fails** (source code traces, an environment config at the package root, looks like the wrong target, not enough disk space, files older than the copies on the server), aca exits without stopping the site. Files older than the copies on the server mean an old build was picked up, or someone edited files on the server; add `-f` if you do want to overwrite them.
- **The environment config** is a site's `web.config` or a service's `<executable>.exe.config`: the server keeps its own, so aca refuses a package with one at its root; list it in `exclude` and it is never overwritten.
- **The home page check** requests `/` over the site's http binding on the server itself; a 5xx or no connection that differs from the status before the deploy fails that server; files are not rolled back automatically. The pre-check prints the home page status before the deploy; sites with only https bindings are not checked.
- **aca deploys the servers one at a time** and stops at the first failure; servers already deployed are not rolled back automatically.
- **For a site with `clb`, aca takes each server out of the load balancer before deploying to it**: it sets the server's weight in the CLB default server group to 0, so the CLB sends it no requests while the site is stopped; once the server deploys successfully, aca restores the weight and moves on to the next one.
  - **aca only takes a server out while another server in the default server group is taking traffic** (weight above 0, every enabled health check normal): when every other server has weight 0, aca reports an error and stops right away; when some have weight but their health checks haven't recovered yet, it waits up to 5 minutes.
  - **aca leaves a server whose weight is already 0 as it is**, and deploys to it as usual.
  - **A server that fails after its site was stopped stays out of the load balancer**: the CLB health check may not probe this site, so putting it back could send users to a site that didn't start or was broken by the deploy. A server that fails the pre-check hasn't stopped its site, and aca puts it back.
  - **Only the default server group is handled**: for a site whose traffic goes through a VServer group via forwarding rules, taking servers out of the default server group does nothing.
  - **Weights only affect new connections**: layer-7 (HTTP/HTTPS) listeners open a new connection to the server for every request, so they are not affected; connections already established through layer-4 (TCP/UDP) listeners stay on the server and break when its site stops.
  - **Only one `deploy` or `rollback` runs on a CLB at a time**: for a site with `clb`, aca holds the lease (below) on the CLB as well as on the site, so deploying another site on the same CLB fails until the run is over.
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

- if it would roll back this deploy (the deploy ID is its start time in UTC), roll back first;
- if it shows an earlier deploy, no server got this one and there is nothing to roll back.

> [!WARNING]
> If you deploy again without rolling back first, the servers that got this deploy back up its files, so a rollback afterwards only takes them back to this deploy, not to the version before it.

**When the output has `WARN: <instance> stays out of CLB`**, that server was left out of the load balancer, and neither a rollback nor a new deploy puts it back: once its sites work, put it back with `aca clb restore <site> <instance>`.

### `aca rollback`

aca restores the latest backup, deletes the files that deploy added, restarts the site or service, then deletes that backup; rolling back again goes to the deploy before it. If a service that was running doesn't come back up, the version rolled back to doesn't start either: aca reports an error, the service stays stopped on that server, and the remaining servers are left alone. Look into that server first: the backup it used is already gone, so running `aca rollback` again skips it and only takes the other servers to the same version. For a site with `clb`, aca takes each server out of the load balancer before rolling it back, just as for a deploy, and rolls back servers already left out first; when taking out the next one would leave no server taking traffic, aca reports an error and stops: put the rolled-back server back with `aca clb restore`, then roll back again.

### `aca clb`

Run `aca clb <site>` to list the weight of each server of the site in the default server group of its CLB, with the original weight noted for any server aca took out and hasn't put back; run `aca clb restore <site> <instance>` to set that server's weight back to the original. `restore` takes the same lease as a deploy, so it fails while the site is being deployed: the server may be stopped right then.

- **The original weight is recorded on this machine under `~/.aca/clb/`**: aca records it before taking a server out and deletes it once the server is back. On another machine, or for a server aca didn't take out, there is no record, so give the weight with `--weight`.

### `aca certs`

On every server of the configured sites, aca does a TLS handshake on the server itself for each HTTPS binding of every running site and lists the certificate actually served; sites missing from the config are checked too, stopped sites are not.

- **Exits non-zero** if a certificate is expired, expires within 30 days, doesn't cover the binding's host name (`*.a.com` doesn't cover `x.y.a.com`) or the handshake fails, so it can run as a scheduled task.
- **It reports what the handshake returns, not the IIS configuration**: once the certificate of an SNI binding is deleted, http.sys serves the certificate of the non-SNI binding on the same port instead, or drops the connection if there is none, while IIS still shows the old certificate.

### `aca certs replace`

On the same servers, aca switches every HTTPS binding that uses a certificate with the same subject name (e.g. `*.a.com`) to this certificate; the old certificates stay on the servers.

- **It switches http.sys binding entries, not sites**: non-SNI bindings share one IP:port entry, so switching one of those sites switches them all; `--check` lists the sites on each entry.
- **aca switches the servers one at a time**, with a handshake on the server itself for each HTTPS binding of the running sites before and after: every binding that served a certificate with that name must serve the new one afterwards, and one whose host name matched or whose chain the server trusted must still do so; otherwise that server switches back to the old certificates and aca stops there, leaving servers already switched as they are.
- **Only one `certs replace` at a time can switch certificates on a server**; the lock is an exclusive handle on `%ProgramData%\aca-certs.aca-lock`.
- **A certificate that is not valid now is refused**, and so is one that does not expire later than the one it replaces, as it is most likely the wrong file; to switch back, pass the old certificate's thumbprint instead of a PFX and add `-f`.
- **Entries carrying http.sys settings beyond the IIS defaults** (client certificate negotiation, revocation checks and the like) are left alone: switching would drop those settings, so switch them by hand.
- **The PFX is encrypted with a one-time key**, reaches the servers through OSS and is deleted once all servers are done: a private key can't go into RunCommand, whose content shows up in the Cloud Assistant invocation history. The PFX password is read from `--password-file` and, like the decryption key, does stay in that history.
- **Windows Server 2016 and earlier can't open AES-encrypted PFX files** (OpenSSL 3's default) and report a wrong password instead; re-export with `openssl pkcs12 -export -legacy`.

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
