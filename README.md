<div align="center">

# aca — Aliyun Cloud Assistant CLI

[![npm](https://img.shields.io/npm/v/aca-cli?logo=npm)](https://www.npmjs.com/package/aca-cli)
[![node](https://img.shields.io/node/v/aca-cli?logo=nodedotjs)](https://nodejs.org/)
[![license](https://img.shields.io/npm/l/aca-cli)](LICENSE)

简体中文 | [English](README.en.md)

</div>

通过[阿里云云助手](https://help.aliyun.com/zh/ecs/user-guide/overview-10)在 Windows ECS 上执行 PowerShell、发布和回退 IIS 站点、检查和更换 SSL 证书。

- **服务器上不用装东西、不用开端口**，只需 AccessKey。
- **输出纯文本**，失败以非 0 退出码表示。
- **附带 Agent Skill**：对 Claude Code、Codex 等 Agent 说"把 MyApp 发到测试站"，它会先 `--check` 给你看结果，等你确认了再发。

## 安装

需要 Node 22.12+。

```sh
npm install -g aca-cli
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
      "note": "正式站"
    },
    "Default Web Site TEST": { "instances": ["web1"], "publish": "D:\\Publish\\MyApp", "exclude": ["web.config", "bin/Res"] }
  }
}
```

`sites` 的 key 是 IIS 站点名，`deploy` 只认这里登记的站点。除 `instances` 外的字段都可选：

| 字段 | 说明 |
| --- | --- |
| `instances` | 跑这个站点的服务器（别名或实例 ID），顺序即发布顺序 |
| `publish` | 本机的发布目录，`deploy` 省略路径时用它 |
| `exclude` | 包里不发布的路径（目录或文件）：服务器上自己维护的密钥、环境配置，把路径列在这里，发布就不会覆盖它们 |
| `stage` | 指向预发布站：发本站时，包必须是预发布站最近一次成功发布的同一份（按内容哈希，重新构建就不算同一份），预发布回退过也不算，`--skip-stage` 跳过这项要求。两边要用同一种输入：都给目录，或都给同一个 zip 文件 |
| `keep` | 每台服务器上为这个站点保留的备份份数，默认 5，`rollback` 最多连退这么多次 |
| `project`<br>`note` | 只在 `aca sites` 里显示，方便认出是哪个站点 |

### 凭证和权限

凭证按阿里云 SDK 的[默认凭证链](https://help.aliyun.com/zh/sdk/developer-reference/v2-manage-node-js-access-credentials)查找，和阿里云 CLI 共用：`aliyun configure` 配过就不用再配，也可以设环境变量 `ALIBABA_CLOUD_ACCESS_KEY_ID`、`ALIBABA_CLOUD_ACCESS_KEY_SECRET`，两处都配了时环境变量优先。

**RAM 权限**：`ecs:DescribeInstances`、`ecs:RunCommand`、`ecs:DescribeInvocationResults`、`oss:PutObject`、`oss:GetObject`，`certs replace` 删上传的 PFX 还要 `oss:DeleteObject`（bucket 开了版本控制是 `oss:DeleteObjectVersion`）。

> [!WARNING]
> 云助手以 SYSTEM 身份执行脚本，`ecs:RunCommand` 授权到哪些实例，持有这份 AccessKey 的人和 Agent 就是哪些实例的管理员，按实例 ID 授权，不要给 `*`。

## 约束

- **ECS 与 OSS bucket 同地域**，发布包走 OSS 内网下载。
- **服务器需装有[云助手客户端](https://help.aliyun.com/zh/ecs/user-guide/install-the-cloud-assistant-agent#775c8cd747xcj)**（2017 年 12 月以来用公共镜像创建的服务器已预装）。
- **云助手按服务器的系统代码页回传输出**，英文版等非中文 Windows 上站点名、路径和 `-m` 说明里的中文会变成问号，站点目录路径含中文时 `rollback` 会因此失败。
- **站点目录必须是本地盘上的普通目录**，不能是盘符根或 UNC 路径，也不要嵌套在另一个站点目录里：备份和发布记录放在它旁边。
- **站点目录旁的 `<root>.bak-<时间>` 备份和 `<root>.aca-*` 文件是 aca 的状态，别手动删**：删了最新的备份，`rollback` 会跳过那次发布，恢复出一个从没发布过的混合版本。
- **发布完成后站点和应用池会被启动**，即使发布前是手动停掉的。
- **本机和服务器要在同一时区**：包里的文件时间按本地时间存，"比服务器旧"的判断靠它。
- **发布包（`--check` 也会上传）留在 OSS 的 `<prefix><站点>/` 下**，aca 不删，要在 bucket 上配生命周期规则按天清理。

## 命令

```sh
aca instances                                   # 列出实例
aca sites                                       # 列出站点与项目、发布目录、实例的映射
aca run web1 "Get-Website | select name,state"  # 以 SYSTEM 执行任意 PowerShell
aca deploy "Default Web Site" ./publish --check # 只预检查，打印将覆盖/新增的文件，不停站
aca deploy "Default Web Site" ./publish -m "release-2026-09"  # 目录或 zip；-m 写进发布记录
aca status "Default Web Site"                   # 每台服务器上最新的文件时间和最近 5 条发布/回退记录
aca certs                                       # 每台服务器上运行中站点的 https 绑定实际发出的证书
aca certs replace ./a.pfx --password-file ./pw.txt --check  # 看每台服务器会把哪些 https 绑定换成这张证书
aca certs replace ./a.pfx --password-file ./pw.txt  # 换证书
aca rollback "Default Web Site" --check         # 看每台服务器会撤掉哪次发布
aca rollback "Default Web Site"                 # 回退最近一次发布
```

### `aca run`

aca 以 SYSTEM 身份在服务器上执行任意 PowerShell，结束后打印输出；脚本以非 0 退出（包括没被捕获的异常）时 aca 用同样的退出码退出。

- **适合查日志、看磁盘、重启应用池这类临时运维**，实例可以写配置里的别名，也可以写当前地域的任意实例 ID。
- **`-t` 指定超时秒数**，到点强杀（默认 300）。
- **PowerShell 默认出错的命令只报错不中止**，退出码仍是 0；要让任何错误都算失败，脚本开头加 `$ErrorActionPreference = 'Stop'`。
- **脚本连同 aca 加的前缀 base64 后不能超过 24 KB**（纯英文约 18 KB）；输出超过云助手上限会被截断，aca 会提示丢了多少字节，大的输出先在脚本里筛过。
- **改站点文件请用 `aca deploy`**：用 `aca run` 改的东西没有备份，`aca rollback` 管不了。

### `aca deploy`

aca 在每台服务器上依次执行：下载解压 → 预检查 → 停站 → 把将被覆盖的文件备份到 `<root>.bak-<时间>` → 覆盖复制 → 启站 → 首页检查 → 删掉最近 `keep` 份以外的旧备份。

- **发布是增量的**：包里有什么就覆盖什么（`exclude` 的除外），可以只发几个改动的文件；站点里已有的上传文件、日志、`web.config` 不动，包里已删掉的文件也不会被清理。
- **预检查不过**（源码痕迹、包根目录的 `web.config`、疑似发错站点、磁盘不足、包里有比服务器更旧的文件）aca 就不停站直接退出。"比服务器旧"意味着拿错了旧构建，或者服务器上有人手改过；确认要覆盖就加 `-f`。
- **首页检查**在服务器本机按站点的 http 绑定请求 `/`，5xx 或连不上、且和发布前的状态不同，就算这台服务器发布失败，文件不自动回退。预检查会打印发布前的首页状态；只有 https 绑定的站点不检查。
- **站点有多台服务器时，aca 发完一台再发下一台**，一台失败就停止，已发布的服务器不会自动回退。
- **同一台服务器上的同一站点同时只有一个 `deploy` 或 `rollback` 能改文件**，撞上的那个报 `Another aca operation is modifying this site`。
  - 加锁的方式是独占打开站点目录旁的 `<root>.aca-lock`，脚本结束或被强杀都会释放锁；文件留着不代表有人在改。
  - **锁是每台服务器各管各的**：两个人同时发同一个跑在多台服务器上的站点，可能各自发到不同服务器上，事后用 `aca status` 核对每台服务器的版本。

#### 发布失败后

不论是撤销这次发布还是修好重发，都先跑 `aca rollback <站点> --check`：

- 显示要撤的是这次发布（发布 ID 是开始时的 UTC 时间）就先回退；
- 显示的是更早的发布，说明哪台服务器都没发上，不用回退。

> [!WARNING]
> 发上了这次的服务器不先回退就重发，会把这次的版本当作备份，之后回退一次只能退到这次，退不回发布前的版本。

### `aca rollback`

aca 恢复最近一次备份、删除那次新增的文件、重启站点，然后删掉这个备份；再回退一次就退到更早一次发布。

### `aca certs`

aca 在登记站点所在的每台服务器上，按每个运行中站点的 https 绑定在服务器本机握手，列出实际发出的证书；没登记的站点也查，停止的站点不查。

- **退出码**：证书过期、30 天内到期、不含绑定的域名（`*.a.com` 管不到 `x.y.a.com`）或握手失败时以非 0 退出，可以放进计划任务定期跑。
- **看的是握手结果而不是 IIS 里的配置**：SNI 绑定用的证书被删掉后，http.sys 改发同端口不带 SNI 的绑定的证书，没有就断开连接，IIS 里显示的还是原来那张。

### `aca certs replace`

aca 在同一批服务器上，把正在用同名证书（按证书使用者名称，如 `*.a.com`）的 https 绑定全部换成这张证书，旧证书留在服务器上。

- **换的单位是 http.sys 的绑定条目而不是站点**：不带 SNI 的绑定共用一个 IP:端口 条目，换其中一个站点就是全换，`--check` 会列出每个条目上的站点。
- **aca 换完一台再换下一台**，换前换后都在服务器本机按运行中站点的 https 绑定握手：原来发同名证书的绑定换完必须发新证书，原来域名对得上、证书链在服务器上验证得过的，换完也得一样，否则这台服务器换回旧证书，后面的服务器不再换，已换好的服务器不动。
- **同一台服务器上同时只有一个 `certs replace` 能换**，锁是独占打开 `%ProgramData%\aca-certs.aca-lock`。
- **新证书不在有效期内，aca 拒绝换**；不比被换掉的晚到期也拒绝，多半是拿错了文件，换回旧证书时把 PFX 换成旧证书的指纹，并加 `-f`。
- **条目上有 IIS 默认值以外的 http.sys 设置**（客户端证书协商、吊销检查等）时 aca 不换：换证书会把这些设置丢掉，这种条目要手工换。
- **aca 把 PFX 用一次性密钥加密后经 OSS 传到服务器**，全部服务器处理完就删掉：私钥不能写进 RunCommand，云助手的执行记录里查得到命令内容。PFX 密码从 `--password-file` 读，和解密密钥一起留在执行记录里。
- **Windows Server 2016 及更早的系统打不开 AES 加密的 PFX**（OpenSSL 3 默认就是），报的却是密码不正确，用 `openssl pkcs12 -export -legacy` 重新导出。

## 轮询失败或超时

- **aca 报 `Polling Cloud Assistant results failed` 或 `Timed out waiting for Cloud Assistant results` 时**，服务器上的脚本可能还在跑，先跑 `aca status` 看发布记录再决定是否回退。
- **某台服务器上的脚本跑满 30 分钟被云助手强杀时**，脚本来不及写发布记录，站点和应用池可能停着，文件可能只覆盖了一半。先跑 `aca rollback <站点> --check`：这台服务器要撤的是这次发布就回退，否则文件没动过，手动启站：

  ```sh
  aca run <实例> "Start-WebAppPool (Get-Website '<站点>').applicationPool; Start-Website '<站点>'"
  ```

## 免责声明

> [!CAUTION]
> aca 会停止并覆盖生产站点。请先在测试站跑通、每次发布前用 `--check`、保管好 AccessKey。

本软件按 MIT 协议"按原样"提供，不附带任何担保，详见 [LICENSE](LICENSE)。
