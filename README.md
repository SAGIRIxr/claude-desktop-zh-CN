# Claude Desktop 简体中文语言包

给 Claude Desktop (Windows) 加上简体中文界面。

**不改 `app.asar`，不打补丁，不注入脚本。** 用中文语言包覆盖应用自带的 `ja-JP.json`，
原文件备份在安装包外部，可随时还原。

> 非官方项目，与 Anthropic 无关。翻译共 473 条，覆盖菜单、托盘、右键菜单与各类对话框。

### 先说清楚汉化范围

这 473 条字符串全部属于**桌面外壳**，也就是 Electron 主进程负责渲染的部分：

| 会变成中文 | 不会变 |
|---|---|
| 输入框右键菜单（复制/粘贴/全选/查询） | **聊天对话区** |
| 托盘图标右键菜单 | 侧边栏、设置页 |
| 菜单栏（文件/编辑/视图/窗口/帮助） | 模型选择、账号信息 |
| 关于、检查更新、诊断报告 | 网页里的一切文字 |
| 权限请求、扩展安装、错误对话框 | |

**主界面绝大部分是 claude.ai 网页**，翻译由 Anthropic 服务端下发，本项目改不了，
而且他们没有提供简体中文。所以装完之后**主界面看起来几乎没变化是正常的**。

想立刻确认是否生效：**在输入框里点右键**。显示「复制 / 粘贴」就是成功了。

如果你期待的是整个界面变中文，那这个项目达不到，请到此为止。

---

## 一键安装

1. 下载本仓库（右上角 **Code → Download ZIP**），解压
2. **双击 `install.bat`**
3. 弹出 UAC 时点「是」
4. 手动打开 Claude Desktop，**在设置里把语言切换为「日本語」**

第 4 步不能省 —— 界面语言由 claude.ai 账号设置决定，不切换就不会加载我们的文件。

卸载：双击 `uninstall.bat`。

> 安装会关闭 Claude Desktop，请先保存正在进行的对话。
> 安装完成后**不会自动启动**应用，需要你手动打开。

### 想切回英文？

把语言切回 **English** 就行 —— `en-US.json` 完全没被改动，是原版英文。
所以装完之后，设置里的语言项等于一个**中英切换开关**，不需要卸载重装。

代价是选「日本語」时，对话内容区（claude.ai 网页部分）会变成日文。
如果你更在意这一点，可以改成覆盖英文：`install.ps1 -TargetLocale en-US`，
这样完全不用动设置，网页内容保持英文，但也就没有一键切回原版的能力了。

想先看看它打算做什么而不实际执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
```

---

## 原理

Claude Desktop 自带完整 i18n 系统（`resources/` 下有 `en-US.json`、`ja-JP.json` 等 11 个
语言包），只是没发布中文。主进程逻辑：

```js
// 语言包目录：打包后就是 process.resourcesPath
const 语言包目录 = () => app.isPackaged ? process.resourcesPath : ...;

// 按文件名读取
const 加载 = locale => createIntl({
  locale,
  messages: JSON.parse(fs.readFileSync(path.join(语言包目录(), `${locale}.json`), "utf8")),
});

// 启动时从 electron-store 读 locale
加载(store.get("locale", 按系统语言挑一个()));
```

看到这里很容易得出「新增一个 `zh-CN.json` 再把 config 改成 `zh-CN`」的结论 ——
**这条路走不通**，实测会在启动约 30 秒后被打回英文。

原因在 IPC 层。`DesktopIntl` 接口把 `requestLocaleChange` 暴露给渲染进程，
并且主进程**自己从不调用它**；而 origin 白名单是：

```js
origin === "https://claude.ai"  || origin === "https://preview.claude.ai" ||
origin === "https://claude.com" || origin === "https://preview.claude.com"
```

也就是说 —— **语言的真正决定者是 claude.ai 网页端（你账号的语言设置）。**
网页加载完成后会把账号语言下推给外壳，`store.set("locale", ...)` 覆盖本地配置。
`config.json` 只是缓存，不是开关。

所以：

1. `zh-CN` 永远不会被请求，因为 claude.ai 的语言列表里没有简体中文
2. 唯一可行的办法是**覆盖一个 claude.ai 确实会请求的语言文件**

默认选 `ja-JP`，因为它把「语言设置」变成了中英切换开关：

| 覆盖目标 | 账号语言选 | 桌面外壳 | 网页内容 | 能否一键切回原版 |
|---|---|---|---|---|
| **`ja-JP`（默认）** | 日本語 | 中文 | 日文 | **能**，切回 English 即可 |
| `en-US` | English | 中文 | 英文 | 不能，需卸载 |

用 `-TargetLocale` 指定其他语言也可以，脚本会在安装完成后提示你该切换到哪一项。

---

## 命令行安装

`install.bat` 只是个启动器，等价于：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

脚本会：

1. 定位安装位置（MSIX 包或传统 Electron 安装都支持）
2. 关闭 Claude Desktop —— 必须关掉，否则退出时会覆盖掉配置改动
3. 若目录不可写则请求 UAC 提权，临时取得所有权（见下方风险说明）
4. 把原始 `ja-JP.json` 备份到 `%LOCALAPPDATA%\claude-desktop-zh-CN\`
5. 用中文语言包覆盖它，并校验能被 `JSON.parse` 解析、条目数正常
6. **还原目录的所有权和 ACL**（先 `/setowner` 再 `/remove:g`，顺序不能反）

可用参数：

| 参数 | 说明 |
|---|---|
| `-DryRun` | 只打印计划，不做任何改动 |
| `-TargetLocale <locale>` | 覆盖哪个语言文件，默认 `ja-JP` |
| `-Restart` | 完成后自动启动应用，默认不启动 |
| `-Uninstall` | 还原 |

卸载：

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

从 `%LOCALAPPDATA%\claude-desktop-zh-CN\` 还原原始语言文件。备份放在安装包外部，
所以即使应用更新过也还在。

### 排错

提权后的操作跑在一个独立的 UAC 窗口里，退出时会立刻关闭。脚本会把这一段的全部输出写到
`%TEMP%\claude-zhcn-install-<时间戳>.log`，并在返回父进程后原样打印出来 —— 所以失败时直接看
终端里 `--- 提权步骤输出 ---` 那一段就够了，日志路径也会在提权前打印。

日志里会记录每次调用 `takeown` / `icacls` 的**实际参数串和退出码**，
路径引号、权限失败之类的问题一眼可见。

---

## 风险与限制

**读之前先了解这几条，都是真实存在的代价：**

- **会覆盖应用自带的 `ja-JP.json`。** 这是一个 Anthropic 签名包内的文件。原文件在覆盖前
  备份到 `%LOCALAPPDATA%\claude-desktop-zh-CN\ja-JP.json.orig`，卸载即还原。
  这比「只新增文件」的做法侵入性更强，但那种做法**根本不生效**（原因见上文）。
  副作用是日语用户装了这个就没日语可用了 —— 如果你需要日语，改用 `-TargetLocale` 挑一个
  你不用的语言。

- **需要管理员权限，且要临时改 `C:\Program Files\WindowsApps` 的权限。**
  该目录属主是 `NT AUTHORITY\SYSTEM`，连 Administrators 组默认也只有只读。脚本用
  `takeown` + `icacls` 临时授权，操作完成后在 `finally` 块里还原属主和 ACL。
  还原属主需要 `SeRestorePrivilege`——提权令牌持有它但默认禁用，脚本会显式启用，
  否则 `icacls /setowner` 会以「拒绝访问」失败、把目录属主留在 `BUILTIN\Administrators`。
  但凡不愿意动系统目录权限的，就别装。

- **应用更新后会失效。** MSIX 更新会创建新的版本目录
  （`Claude_<版本>_x64__pzs8sxrjxfjjc`），修改不会跟过去，界面回到英文。
  重新跑一次 `install.ps1` 即可（备份在包外，不受影响）。

- **对话内容区不会变中文。** 那部分是 claude.ai 网页，翻译由服务端下发，
  而 Anthropic 没有提供简体中文。本项目只能汉化桌面外壳。

- **MSIX 包完整性。** 这个包是 `SignatureKind: Developer` 的侧载包。脚本只**新增**文件，
  不修改任何已签名文件，是风险最低的改法；但 Windows 若触发包修复，新增文件仍可能被清掉。

- **非官方翻译。** 术语是我按上下文定的，Anthropic 官方若发布中文包，用词大概率不一致。

- 目前只做了 Windows。macOS/Linux 原理相同（同样是 `process.resourcesPath`），
  但 `install.ps1` 没有对应实现。

---

## 翻译约定

- **保留不译**：`Claude`、`Cowork`、`Claude Code`、`Artifact`、`MCP`、`Pro` / `Max`、
  产品内配置键名（`secureVmFeaturesEnabled`、`claude_desktop_config.json` 等）
- **统一译法**：Extension → 扩展，Skill → 技能，Session → 会话，Usage → 用量，
  Plan → 方案，Maker devices → 创客设备，Buddy → 伙伴设备，Bypass Permissions → 跳过权限
- **ICU 语法必须原样保留**：`{name}` 占位符、`{count, plural, one {…} other {…}}`
  复数块、`<code>` / `<a>` 富文本标签
- **中文里不要出现半角单引号 `'`** —— ICU MessageFormat 用它做转义起始符，落单会让整条消息
  解析异常。需要引号时用中文引号 `“”`

---

## 维护

```powershell
node tools\validate.js    # 校验 zh-CN.json
node tools\sync.js        # 与当前已安装版本对比，列出新增/删除/变更的字符串
node tools\sync.js --write  # 同步键集，新键先用英文占位
```

`validate.js` 检查的项目：

- 键集与 `en-US.json` 完全一致（473 条）
- 花括号配平
- 占位符不丢失、不臆造
- `plural` / `select` 块保留，且有 `other` 分支
- 单引号成对（ICU 转义）
- `<code>` / `<a>` 标签数量与类型一致
- 漏翻检测（值里没有中文字符，且原文并非纯符号/单位/品牌名）

Claude Desktop 升级后的维护流程：

```powershell
node tools\sync.js            # 看有哪些字符串变了
node tools\sync.js --write    # 同步键集
# 翻译 sync 标出来的新键
node tools\validate.js        # 校验
powershell -ExecutionPolicy Bypass -File .\install.ps1   # 重新安装
```

---

## 目录结构

```
claude-desktop-zh-CN/
├─ install.bat        一键安装（双击）
├─ uninstall.bat      一键卸载（双击）
├─ install.ps1        实际逻辑，支持 -Uninstall / -NoRestart / -Locale
├─ uninstall.ps1      卸载的简易入口
├─ src/
│  ├─ zh-CN.json      简体中文语言包（473 条）
│  └─ en-US.json      原文，供 diff 与校验用
└─ tools/
   ├─ validate.js     结构校验
   └─ sync.js         版本同步
```

翻译基于 Claude Desktop `1.24012.9.0`。

### 关于编码的两个坑

改这两个文件时注意，都是实测踩过的：

- **`.bat` 必须纯 ASCII。** cmd.exe 用「运行前」的控制台代码页解析批处理文件，
  即使开头写了 `chcp 65001`，文件里的 UTF-8 中文字节仍会被拆坏，导致命令解析直接失败
  （实测报错 `'包' is not recognized as an internal or external command`）。
  所以中文提示全部放在 `.ps1` 里。
- **`install.ps1` 必须存为 UTF-8 带 BOM。** Windows PowerShell 5.1 在没有 BOM 时按 ANSI
  读取脚本，中文会变成 `涓枃娴嬭瘯` 这样的乱码。编辑后请确认 BOM 还在。

---

## 免责声明

本项目为非官方的社区汉化包，与 Anthropic 无从属、认可或支持关系。
Claude 和 Anthropic 是 Anthropic PBC 的商标。

`src/en-US.json` 为从已安装的 Claude Desktop 中提取的原始英文界面字符串，
仅作为 `validate.js` / `sync.js` 的 diff 基准收录，版权归 Anthropic PBC 所有，
不在本仓库 MIT 许可范围内。详见 [LICENSE](LICENSE)。

安装过程涉及修改系统目录权限，请自行评估风险。作者不对任何后果负责。
