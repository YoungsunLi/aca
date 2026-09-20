<div align="center">

![aca — Aliyun Cloud Assistant CLI](.github/banner.svg)

[![npm](https://img.shields.io/npm/v/@ninesols/aca-cli?logo=npm)](https://www.npmjs.com/package/@ninesols/aca-cli)
[![node](https://img.shields.io/node/v/@ninesols/aca-cli?logo=nodedotjs)](https://nodejs.org/)
[![license](https://img.shields.io/npm/l/@ninesols/aca-cli)](LICENSE)

简体中文 | [English](README.en.md)

</div>

通过[阿里云云助手](https://help.aliyun.com/zh/ecs/user-guide/overview-10)在 Windows ECS 上执行 PowerShell、发布和回退 IIS 站点与 Windows 服务、检查和更换 SSL 证书。

- **服务器上不用装东西、不用开端口**，只需 AccessKey。
- **输出纯文本**，失败以非 0 退出码表示。
- **附带 Agent Skill**：对 Claude Code、Codex 等 Agent 说"把 MyApp 发到测试站"，它会先 `--check` 给你看结果，等你确认了再发。

## 安装

需要 Node 22.12+。

```sh
npm install -g @ninesols/aca-cli
aca skill install  # 给 Claude Code、Codex 装上 skill，升级 aca 后再跑一次
```

其他支持 Agent Skills 开放标准的 Agent 用 `npx skills add YoungsunLi/aca -g` 装，它会问装给哪些 Agent；装的是 GitHub 上最新的 skill，不一定和本机 aca 的版本一致。

## 配置

在 `~/.aca/config.json` 写一份配置，或设置环境变量 `ACA_CONFIG` 指向别的路径。

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
      "note": "正式站"
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

`sites` 的 key 是 IIS 站点名，`deploy`、`rollback`、`status` 只认这里登记的站点和下面 `services` 里登记的服务。除 `instances` 外的字段都可选：

| 字段 | 说明 |
| --- | --- |
| `instances` | 跑这个站点的服务器（别名或实例 ID），顺序即发布顺序 |
| `publish` | 本机的发布目录，`deploy` 省略路径时用它 |
| `exclude` | 包里不发布的路径（目录或文件）：服务器上自己维护的密钥、环境配置，把路径列在这里，发布就不会覆盖它们 |
| `stage` | 指向预发布站：发本站时，包必须是预发布站最近一次成功发布的同一份，预发布回退过也不算，`--skip-stage` 跳过这项要求。用 `--from-stage` 发的就是那一份；给本机路径时比对要上传的 zip，重新构建就不算同一份，两边还要用同一种输入：都给目录，或都给同一个 zip 文件 |
| `keep` | 每台服务器上为这个站点保留的备份份数，默认 5，`rollback` 最多撤得掉最近这么多次发布 |
| `clb` | 站点前面的传统型负载均衡（CLB）实例 ID：`deploy`、`rollback` 处理每台服务器前，aca 先把它摘出负载均衡，见 `aca deploy` 一节 |
| `project`<br>`note` | 只在 `aca sites`、`aca services` 里显示，方便认出是哪个站点或服务 |

`services` 的 key 是 Windows 服务名（`sc query` 列出的那个，不是显示名），字段和站点相同，但没有 `stage` 和 `clb`，另外必填 `dir`：服务器上的安装目录；aca 核对服务的可执行文件确实在这个目录里，对不上就不发。

### 凭证和权限

凭证按阿里云 SDK 的[默认凭证链](https://help.aliyun.com/zh/sdk/developer-reference/v2-manage-node-js-access-credentials)查找，和阿里云 CLI 共用：`aliyun configure` 配过就不用再配，也可以设环境变量 `ALIBABA_CLOUD_ACCESS_KEY_ID`、`ALIBABA_CLOUD_ACCESS_KEY_SECRET`，两处都配了时环境变量优先。

**RAM 权限**：`ecs:DescribeInstances`、`ecs:RunCommand`、`ecs:DescribeInvocationResults`、`oss:PutObject`、`oss:GetObject`、`oss:ListObjects`、`oss:DeleteObject`（bucket 开了版本控制时，`pull`、`diff` 和 `certs replace` 删 OSS 上中转的文件要 `oss:DeleteObjectVersion`），站点配了 `clb` 还要 `slb:DescribeLoadBalancerAttribute`、`slb:DescribeLoadBalancerListeners`、`slb:DescribeHealthStatus`、`slb:SetBackendServers`，取云端证书要 `yundun-cert:ListUserCertificateOrder`、`yundun-cert:GetUserCertificateDetail`（数字证书管理服务只支持操作级授权，资源只能写 `*`）。

> [!WARNING]
> 云助手以 SYSTEM 身份执行脚本，`ecs:RunCommand` 授权到哪些实例，持有这份 AccessKey 的人和 Agent 就是哪些实例的管理员，按实例 ID 授权，不要给 `*`。

## 约束

- **ECS 与 OSS bucket 同地域**，发布包走 OSS 内网下载。
- **服务器需装有[云助手客户端](https://help.aliyun.com/zh/ecs/user-guide/install-the-cloud-assistant-agent#775c8cd747xcj)**（2017 年 12 月以来用公共镜像创建的服务器已预装）。
- **云助手按服务器的系统代码页回传输出**，英文版等非中文 Windows 上站点名、路径和 `-m` 说明里的中文会变成问号。
- **站点目录和服务目录必须是本地盘上的普通目录**，不能是盘符根或 UNC 路径，也不要嵌套在另一个目标的目录里：备份和发布记录放在它旁边。
- **目录旁的 `<root>.bak-<时间>` 备份和 `<root>.aca-*` 文件是 aca 的状态，别手动删**：删了最新的备份，`rollback` 会跳过那次发布，恢复出一个从没发布过的混合版本。
- **发布完成后站点和应用池会被启动**，即使发布前是手动停掉的；服务相反，发布前就停着的发布后也不启动：备机上的服务常常是刻意停着的。
- **本机和服务器要在同一时区**：包里的文件时间按本地时间存，"比服务器旧"的判断靠它。
- **发布包（`--check` 也会上传）按 SHA-256 命名留在 OSS 的 `<prefix>` 下**，aca 不删，要在 bucket 上配生命周期规则按天清理，天数要长于从发预发布站到用 `--from-stage` 发正式站的间隔。

## 命令

```sh
aca instances                                   # 列出实例
aca sites                                       # 列出站点与项目、发布目录、实例的映射
aca services                                    # 列出 Windows 服务与它们在服务器上的目录
aca run web1 "Get-Website | select name,state"  # 以 SYSTEM 执行任意 PowerShell
aca pull web1 "C:\inetpub\logs\LogFiles\W3SVC1\u_ex260919.log"  # 把服务器上的文件拉到本机当前目录
aca deploy "Default Web Site" ./publish --check # 只预检查，打印将覆盖/新增的文件，不停站
aca deploy "Default Web Site" ./publish -m "release-2026-09"  # 目录或 zip；-m 写进发布记录
aca deploy "Default Web Site" --from-stage -m "release-2026-09"  # 直接发预发布站最近一次发布的那个包
aca deploy MyApp.Worker ./publish -m "release-2026-09"  # 发 Windows 服务，参数和站点一样
aca status "Default Web Site"                   # 每台服务器上最新的文件时间、服务的运行状态和最近 5 条发布/回退记录
aca diff "Default Web Site"                     # 按内容哈希比对每台服务器上的文件，列出不一样的
aca diff "Default Web Site" bin                 # 只比站点目录下的一个目录
aca certs                                       # 每台服务器上运行中站点的 https 绑定实际发出的证书
aca certs replace ./a.pfx --password-file ./pw.txt --check  # 看每台服务器会把哪些 https 绑定换成这张证书
aca certs replace ./a.pfx --password-file ./pw.txt  # 换证书
aca certs cloud                                 # 列出数字证书管理服务里没过期的证书和它们的 ID
aca certs replace --from-cloud 22863954         # 换成云端这张证书，PFX 由 aca 合成
aca rollback "Default Web Site" --check         # 每台服务器上还留着哪几次发布的备份、占多少空间、会撤掉哪几次
aca rollback "Default Web Site"                 # 回退最近一次发布
aca rollback "Default Web Site" 20260918T020100Z  # 连同之后的发布一起回退，退到这次发布之前
aca clb "Default Web Site"                      # 每台服务器在 CLB 里的权重
aca clb restore "Default Web Site" web1         # 把摘下的 web1 放回负载均衡
```

### `aca run`

aca 以 SYSTEM 身份在服务器上执行任意 PowerShell，结束后打印输出；脚本以非 0 退出（包括没被捕获的异常）时 aca 用同样的退出码退出。

- **适合查日志、看磁盘、重启应用池这类临时运维**，实例可以写配置里的别名，也可以写当前地域的任意实例 ID。
- **`-t` 指定超时秒数**，到点强杀（默认 300）。
- **PowerShell 默认出错的命令只报错不中止**，退出码仍是 0；要让任何错误都算失败，脚本开头加 `$ErrorActionPreference = 'Stop'`。
- **脚本连同 aca 加的前缀 base64 后不能超过 24 KB**（纯英文约 18 KB）；输出超过云助手上限会被截断，aca 会提示丢了多少字节，大的输出先在脚本里筛过；要看整个文件用 `aca pull`。
- **改站点文件请用 `aca deploy`**：用 `aca run` 改的东西没有备份，`aca rollback` 管不了。

### `aca pull`

aca 把服务器上的一个文件拉到本机，不受云助手输出上限的限制，适合看完整的日志（正在写的也能拉）、比对每台服务器的 `web.config`。

- **本地路径默认是当前目录下的同名文件**，给的是已有目录就放进这个目录；本机已有这个文件时 aca 报错，不覆盖。
- **文件经 OSS 中转**：服务器用 aca 这次生成的一次性密钥加密后上传，aca 下载解密后就删掉 OSS 上的这份；密钥留在云助手的执行记录里。

### `aca diff`

负载均衡后面几台服务器上的文件不一致时，表现是刷新几次好一次坏一次。`aca diff <站点或服务>` 在每台服务器上按内容算哈希，列出各台不一样的文件。

- **比的是站点目录（服务是配置里的 `dir`）下的全部文件**，`exclude` 里的路径除外：那些是服务器上自己维护的，本来就该不一样；上传目录、日志目录也列进 `exclude` 就不比了。目录联接（junction）不跟进去，隐藏文件比。
- **服务只比 `.dll` 和 `.exe`**：服务的程序集和它天天写的日志在同一个目录里。
- **每行一个不一样的文件**，后面按内容分组列出服务器（`web1,web2=<哈希前 8 位> <最后写入时间>`），没有这个文件的服务器是 `missing`；有差异时以非 0 退出。
- **差异超过 50 个时，列完前 50 个再按目录汇总**，看清楚差异落在哪几个目录，再用 `aca diff <站点> <目录或文件>` 缩小范围，比如 `aca diff "Default Web Site" bin`；这台服务器上没有这个目录就当它里面的文件全缺。
- **每台服务器要把目录整个读一遍算哈希**，几 GB 的目录要几分钟，超过 30 分钟会被云助手强杀；脚本在服务器上以 `BelowNormal` 优先级跑，抢不过 IIS 的工作进程。
- **文件清单经 OSS 中转**，和 `aca pull` 一样用一次性密钥加密，比完就删：几千个文件的清单超过云助手的输出上限。
- **只读，不占租约**：这个站点正发着时比出来的是发布到一半的样子。

### `aca deploy`

aca 在每台服务器上依次执行：下载解压 → 预检查 → 停站点或服务 → 把将被覆盖的文件备份到 `<root>.bak-<时间>` → 覆盖复制 → 启动 → 状态检查 → 删掉最近 `keep` 份以外的旧备份。

- **发布是增量的**：包里有什么就覆盖什么（`exclude` 的除外），可以只发几个改动的文件；目录里已有的上传文件、日志、环境配置不动，包里已删掉的文件也不会被清理。
- **`--from-stage` 直接发预发布站最近一次成功发布的那个包**：aca 从 OSS 取这个包，不用本机的构建，也不重新上传；包已被生命周期规则清理掉时 aca 报错，这时改用本机路径发同一份构建。
- **预检查不过**（源码痕迹、包根目录里的环境配置、疑似发错目标、磁盘不足、包里有比服务器更旧的文件）aca 就不停站直接退出。"比服务器旧"意味着拿错了旧构建，或者服务器上有人手改过；确认要覆盖就加 `-f`。
- **环境配置**指站点的 `web.config`、服务的 `<可执行文件>.exe.config`：它们在服务器上自己维护，出现在包根目录时 aca 报错，把它列进 `exclude` 就不会被覆盖。
- **首页检查**在服务器本机按站点的 http 绑定请求 `/`，5xx 或连不上、且和发布前的状态不同，就算这台服务器发布失败，文件不自动回退。预检查会打印发布前的首页状态；只有 https 绑定的站点不检查。
- **有多台服务器时，aca 发完一台再发下一台**，一台失败就停止，已发布的服务器不会自动回退。
- **站点配了 `clb` 时，aca 发每台服务器之前先把它摘出负载均衡**：CLB 默认服务器组里的权重调成 0，停站期间 CLB 不再把请求转给它；这台服务器发布成功后调回原值，再发下一台。
  - **默认服务器组里还有别的服务器在接流量**（权重不为 0，开了的健康检查都正常）aca 才摘：别的服务器权重都是 0 时直接报错停下，有权重但健康检查还没恢复时最多等 5 分钟。
  - **权重本来就是 0 的服务器，aca 不摘也不放回**，照常发布。
  - **停过站又失败的服务器留在负载均衡外**：CLB 的健康检查查的不一定是这个站点，放回去用户可能撞上没起来或发坏了的站点。预检查没过的服务器还没停站，aca 直接放回。
  - **只管默认服务器组**：站点经转发规则走虚拟服务器组时，摘默认服务器组没有用。
  - **权重只管新连接**：七层（HTTP/HTTPS）监听每个请求都新建到服务器的连接，不受影响；四层（TCP/UDP）监听上已经建立的连接会一直连到这台服务器，停站时断开。
  - **同一个 CLB 上同时只有一个 `deploy` 或 `rollback`**：站点配了 `clb` 时，aca 把 CLB 连同站点一起占进租约（见下），这一轮走完之前，同一个 CLB 上别的站点发不了。
- **同一个站点或服务同时只有一个 `deploy` 或 `rollback`**：aca 整轮持有一份租约，撞上的那个立即报错，写明是谁、在哪台机器上、从什么时候开始。
  - 租约是 OSS 上 `<oss.prefix>lease/` 下的一个对象，持有期间每 30 秒续一次，aca 被强杀后 3 分钟自动失效，不用手工解锁；快 2 分钟续不上时 aca 在动下一台服务器之前停下。
  - **只在配了同一个 bucket 和 `oss.prefix` 的 aca 之间有效**：租约就放在那里，指向别的 bucket 的 aca 看不见它，两边会同时发。
  - **租约只管 aca 这一轮，管不了已经发给云助手的脚本**：aca 被强杀后脚本还会在服务器上跑完（发布最长 30 分钟），租约却 3 分钟就失效；先用 `aca status` 看清楚再动这个站点。
  - **`--check` 不占租约**：预检查不改服务器上的任何东西。
- **服务器本机还有一把锁**：同一台服务器上的同一个站点或服务，同时只有一个脚本能改文件，撞上的那个报 `Another aca operation is modifying this site or service`。
  - 加锁的方式是独占打开目录旁的 `<root>.aca-lock`，脚本结束或被强杀都会释放锁；文件留着不代表有人在改。

#### Windows 服务

服务和站点用同一套命令和同一套备份、回退机制，区别在停和起：

- **aca 停服务、起服务都等它真的停下、起来**，各最多 120 秒，到点报错，免得整个脚本被云助手强杀。
- **有别的服务依赖它、而且在跑时，aca 不动它**：停它会连带停掉那些服务，而 aca 事后只把它自己起回来，这种服务只能手工发。
- **只发在跑的和停着的服务**：`Paused` 这类状态停了再起回不到原样，aca 报错不发。
- **状态检查**在启动后每 3 秒看一次、最多 3 次：没回到发布前的运行状态（多半是启动即崩）就算这台服务器发布失败，文件不自动回退。
- **`--from-stage` 用在服务上会报错**：服务没有预发布。

#### 发布失败后

不论是撤销这次发布还是修好重发，都先跑 `aca rollback <站点> --check`：

- 标 `undo` 的是这次发布（发布 ID 是开始时的 UTC 时间）就先回退；
- 标的是更早的发布，说明哪台服务器都没发上，不用回退。

> [!WARNING]
> 发上了这次的服务器不先回退就重发，会把这次的版本当作备份，之后回退一次只能退到这次，退不回发布前的版本。

**输出里有 `WARN: <实例> stays out of CLB` 时**，这台服务器留在了负载均衡外，回退和重发都不会放回它：确认它上面的站点正常后，用 `aca clb restore <站点> <实例>` 放回。

### `aca rollback`

aca 在每台服务器上恢复被发布覆盖的文件、删除发布新增的文件、重启站点或服务，然后删掉用过的备份。不给发布 ID 时只撤最近一次发布，再回退一次就撤更早的一次。

- **`--check` 列出每台服务器上还留着的备份**，从新到旧：发布 ID、要恢复和删除的文件数、占用空间，下一行是那次发布在发布记录里的原文（时间、结果、`-m` 说明）。标 `undo` 的是这次要撤的，标 `keep` 的留着不动；一份都不用撤的服务器标 `skipped`，它多半没参与那几次发布。
- **给出发布 ID，aca 一次撤掉那次发布和它之后的每次发布**，退到那次发布之前的版本。备份是一层层叠上去的，不能只撤中间的一次；每台服务器只停一次，中间的版本不启动。
- **最多退到最早一份备份之前**，更早的版本只能重新发旧构建；有服务器已经清理掉要用的备份时 aca 报错，哪台服务器都不回退。
- **回退前在跑的服务要是没起来**，说明退到的这一版也起不来：aca 报错，这台服务器上的服务停着，后面的服务器不再回退。先在这台服务器上查清楚：它用掉的备份已经删了，再回退一次会跳过它，只把别的服务器退到同一版。
- **站点配了 `clb` 时，aca 回退每台服务器也和发布一样先摘出负载均衡**，已经留在外面的服务器先回退；再摘一台就没有服务器接流量时 aca 报错停下，把回退好的服务器用 `aca clb restore` 放回后再回退一次。

### `aca clb`

用 `aca clb <站点>` 看站点每台服务器在 CLB 默认服务器组里的权重，aca 摘下后没放回的会注明原来的权重；用 `aca clb restore <站点> <实例>` 把这台服务器的权重调回原来的值。`restore` 和发布占同一份租约，这个站点正发着时它报错：那台服务器可能正停着站。

- **原来的权重记在本机 `~/.aca/clb/`**：aca 摘服务器之前记下，放回后删掉。换一台机器，或者服务器不是 aca 摘的，没有记录可用，要用 `--weight` 给出权重。

### `aca certs`

aca 在登记站点所在的每台服务器上，按每个运行中站点的 https 绑定在服务器本机握手，列出实际发出的证书和剩余天数，握手不上的和快到期的排在最前；没登记的站点也查，停止的站点不查。

- **退出码**：证书过期、30 天内到期、不含绑定的域名（`*.a.com` 管不到 `x.y.a.com`）或握手失败时以非 0 退出，可以放进计划任务定期跑。
- **看的是握手结果而不是 IIS 里的配置**：SNI 绑定用的证书被删掉后，http.sys 改发同端口不带 SNI 的绑定的证书，没有就断开连接，IIS 里显示的还是原来那张。

### `aca certs replace`

aca 在同一批服务器上，把正在用同名证书（按证书使用者名称，如 `*.a.com`）的 https 绑定全部换成这张证书，旧证书留在服务器上。

- **`--from-cloud <证书 ID>` 用数字证书管理服务里的证书**：ID 用 `aca certs cloud` 列，aca 取回 PEM 在本机合成 PFX，密码自己生成，不用 `--password-file`，只支持 RSA 证书。
- **换的单位是 http.sys 的绑定条目而不是站点**：不带 SNI 的绑定共用一个 IP:端口 条目，换其中一个站点就是全换，`--check` 会列出每个条目上的站点。
- **aca 换完一台再换下一台**，换前换后都在服务器本机按运行中站点的 https 绑定握手：原来发同名证书的绑定换完必须发新证书，原来域名对得上、证书链在服务器上验证得过的，换完也得一样，否则这台服务器换回旧证书，后面的服务器不再换，已换好的服务器不动。
- **同一台服务器上同时只有一个 `certs replace` 能换**，锁是独占打开 `%ProgramData%\aca-certs.aca-lock`。
- **新证书不在有效期内，aca 拒绝换**；不比被换掉的晚到期也拒绝，多半是拿错了文件，换回旧证书时把 PFX 换成旧证书的指纹，并加 `-f`。
- **条目上有 IIS 默认值以外的 http.sys 设置**（客户端证书协商、吊销检查等）时 aca 不换：换证书会把这些设置丢掉，这种条目要手工换。
- **aca 把 PFX 用一次性密钥加密后经 OSS 传到服务器**，全部服务器处理完就删掉：私钥不能写进 RunCommand，云助手的执行记录里查得到命令内容。PFX 密码从 `--password-file` 读，和解密密钥一起留在执行记录里。
- **Windows Server 2016 及更早的系统打不开 AES 加密的 PFX**（OpenSSL 3 默认就是），报的却是密码不正确，用 `openssl pkcs12 -export -legacy` 重新导出。

## 轮询失败或超时

- **aca 报 `Polling Cloud Assistant results failed` 或 `Timed out waiting for Cloud Assistant results` 时**，服务器上的脚本可能还在跑，先跑 `aca status` 看发布记录再决定是否回退。
- **某台服务器上的脚本跑满 30 分钟被云助手强杀时**，脚本来不及写发布记录，站点和应用池、服务可能停着，文件可能只覆盖了一半。先跑 `aca rollback <站点> --check`：这台服务器要撤的是这次发布就回退，否则文件没动过，手动启起来：

  ```sh
  aca run <实例> "Start-WebAppPool (Get-Website '<站点>').applicationPool; Start-Website '<站点>'"
  aca run <实例> "Start-Service '<服务名>'"   # 发的是服务
  ```

- **配了 `clb` 的站点，以上两种情况下正在处理的服务器都留在负载均衡外**，输出里有 `WARN: <实例> stays out of CLB`，处理办法见"发布失败后"。aca 被中途终止（比如 Ctrl+C）时也留在外面，只是没有这行 WARN，同样用 `aca clb restore` 放回。

## 免责声明

> [!CAUTION]
> aca 会停止并覆盖生产站点。请先在测试站跑通、每次发布前用 `--check`、保管好 AccessKey。

本软件按 MIT 协议"按原样"提供，不附带任何担保，详见 [LICENSE](LICENSE)。
