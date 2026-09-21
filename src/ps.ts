import { readFileSync } from 'node:fs';

// 脚本放在仓库顶层 ps/，src/ 和编译出的 dist/ 用同一个相对路径都能找到。
// 整行注释不发到服务器：RunCommand 内容 base64 后上限 24 KB，STS 类凭证签出的 URL 长度不定；
// 脚本里不用 here-string，行首的 # 只会是注释。
// 换行统一成 LF 也是为了这个上限：Windows 上 autocrlf 检出的是 CRLF，每行多一个字节
const read = (name: string) => readFileSync(new URL(`../ps/${name}.ps1`, import.meta.url), 'utf8').replace(/^[ \t]*#.*\r?\n/gm, '').replace(/\r\n/g, '\n');
const COMMON = read('common');

// 占位符连同两侧单引号整体换成 base64 解码表达式，值里的任何字符都进不了 PowerShell 语法。
// 只把单引号翻倍不够：PowerShell 把 ‘ ’ ‚ ‛ 也当单引号定界符，-m 里一对中文引号就能逃出字符串。
// 引号写成可选是为了把漏写引号的占位符也匹配到并报错，而不是原样留在脚本里运到服务器。
// libs 是只有部分脚本用的函数文件，不放进 common.ps1，免得挤占 deploy 的 24 KB
export function renderScript(name: string, vars: Record<string, string>, libs: string[] = []): string {
  return (COMMON + libs.map(read).join('') + read(name)).replace(/'?__([A-Z0-9_]+)__'?/g, (m, key: string) => {
    if (!m.startsWith("'") || !m.endsWith("'")) throw new Error(`Placeholder ${key} in script ${name} must be written as '__${key}__'`);
    if (!Object.hasOwn(vars, key)) throw new Error(`No value for placeholder ${key} in script ${name}`);
    return `([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${Buffer.from(vars[key]).toString('base64')}')))`;
  });
}
