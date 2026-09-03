import { readFileSync } from 'node:fs';

// 脚本放在仓库顶层 ps/，src/ 和编译出的 dist/ 用同一个相对路径都能找到
const read = (name: string) => readFileSync(new URL(`../ps/${name}.ps1`, import.meta.url), 'utf8');
const COMMON = read('common');

// 占位符连同两侧单引号整体换成 base64 解码表达式，值里的任何字符都进不了 PowerShell 语法。
// 只把单引号翻倍不够：PowerShell 把 ‘ ’ ‚ ‛ 也当单引号定界符，-m 里一对中文引号就能逃出字符串。
// 引号写成可选是为了把漏写引号的占位符也匹配到并报错，而不是原样留在脚本里运到服务器
export function renderScript(name: string, vars: Record<string, string>): string {
  return (COMMON + read(name)).replace(/'?__([A-Z_]+)__'?/g, (m, key: string) => {
    if (!m.startsWith("'") || !m.endsWith("'")) throw new Error(`Placeholder ${key} in script ${name} must be written as '__${key}__'`);
    if (!Object.hasOwn(vars, key)) throw new Error(`No value for placeholder ${key} in script ${name}`);
    return `([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${Buffer.from(vars[key]).toString('base64')}')))`;
  });
}
