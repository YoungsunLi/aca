import { readFileSync } from 'node:fs';
import type { Config } from './config.ts';

// 脚本放在仓库顶层 ps/，src/ 和编译出的 dist/ 用同一个相对路径都能找到。
// 整行注释和行首缩进不发到服务器：RunCommand 内容 base64 后上限 24 KB，STS 类凭证签出的 URL 长度不定；
// 脚本里不用 here-string、字符串不跨行，行首的 # 只会是注释，缩进也不影响语义。
// 换行统一成 LF 也是为了这个上限：Windows 上 autocrlf 检出的是 CRLF，每行多一个字节
const read = (name: string) => readFileSync(new URL(`../ps/${name}.ps1`, import.meta.url), 'utf8').replace(/^[ \t]*#.*\r?\n/gm, '').replace(/\r\n/g, '\n').replace(/^[ \t]+/gm, '');

// 占位符连同两侧单引号整体换成 base64 解码表达式，值里的任何字符都进不了 PowerShell 语法。
// 只把单引号翻倍不够：PowerShell 把 ‘ ’ ‚ ‛ 也当单引号定界符，-m 里一对中文引号就能逃出字符串。
// 引号写成可选是为了把漏写引号的占位符也匹配到并报错，而不是原样留在脚本里运到服务器。
// libs 是只有部分脚本用的函数文件，不放进 common.ps1，免得挤占 deploy 的 24 KB
/** 站点下的应用（站点/路径）要多带 app.ps1，服务要多带 service.ps1：这些只有它们用得上，不占别的目标的 24 KB */
export const targetLibs = (cfg: Config, ...names: string[]) => [
  'target',
  ...(names.some((n) => n.includes('/')) ? ['app'] : []),
  ...(names.some((n) => Object.hasOwn(cfg.services, n)) ? ['service'] : []),
];

export function renderScript(name: string, vars: Record<string, string>, libs: string[] = []): string {
  return renderBare(name, vars, ['common', ...libs]);
}

/** 不带 common.ps1：aca run 的脚本要在 PowerShell 的默认设置下跑，比如 $ErrorActionPreference */
export function renderBare(name: string, vars: Record<string, string>, libs: string[] = []): string {
  return (libs.map(read).join('') + read(name)).replace(/'?__([A-Z0-9_]+)__'?/g, (m, key: string) => {
    if (!m.startsWith("'") || !m.endsWith("'")) throw new Error(`Placeholder ${key} in script ${name} must be written as '__${key}__'`);
    if (!Object.hasOwn(vars, key)) throw new Error(`No value for placeholder ${key} in script ${name}`);
    return `([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${Buffer.from(vars[key]).toString('base64')}')))`;
  });
}
