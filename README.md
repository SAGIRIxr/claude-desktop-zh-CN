# Claude Desktop 简体中文语言包

给 Claude Desktop (Windows) 加上简体中文界面。

**不改 `app.asar`，不打补丁，不注入脚本。** 只往应用目录放一个 `zh-CN.json`，再把配置里的
`locale` 改成 `zh-CN`。

> 非官方项目，与 Anthropic 无关。翻译共 473 条，覆盖菜单、托盘、对话框与设置界面。

---

## 一键安装

1. 下载本仓库（右上角 **Code → Download ZIP**），解压
2. **双击 `install.bat`**
3. 弹出 UAC 时点「是」

卸载：双击 `uninstall.bat`。

就这些。脚本会自动定位安装位置、关闭应用、写入语言包、改配置、还原权限并重启 Claude。

> 安装过程会关闭 Claude Desktop，请先保存正在进行的对话。

---

## 原理

Claude Desktop 自带完整的 i18n 系统（`resources/` 下已有 `en-US.json`、`ja-JP.json`、
`de-DE.json` 等 11 个语言包），只是没发布中文。反编译主进程 bundle 后，相关逻辑是这样的：

```js
// 语言包目录：打包后就是 process.resourcesPath
function 语言包目录() {
  return app.isPackaged ? process.resourcesPath : path.resolve(__dirname, "../../resources/i18n");
}

// 可用语言列表：扫描目录，凡是 xx-XX 命名的 .json 都算数
function 可用语言() {
  return fs.readdirSync(语言包目录())
    .filter(n => /[a-z]{2}-[A-Z]{2}/.test(n))
    .map(n => n.replace(/\.json$/, ""))
    .reduce((acc, k) => (acc[k] = true, acc), {});
}

// 加载：直接按文件名读取
function 加载(locale) {
  return createIntl({
    locale,
    messages: JSON.parse(fs.readFileSync(path.join(语言包目录(), `${locale}.json`), "utf8")),
  });
}

// 启动时读 config.json 的 locale，缺省则按系统语言匹配
loadLocale(store.get("locale", 按系统语言挑一个()));
```

三个关键结论：

1. **没有硬编码的语言白名单。** 可用语言完全由目录扫描决定，`zh-CN.json` 天然合法。
2. **语言由 `%APPDATA%\Claude\config.json` 的 `locale` 字段决定**，应用内没有语言选择 UI
   （`en-US.json` 里没有任何 "Language" 相关字符串）。
3. 主进程和渲染进程共用同一份语言包（渲染层通过 `DesktopIntl.getInitialLocale` IPC 拿），
   所以一个文件就能覆盖菜单、托盘、对话框和界面。

因此这个"插件"要做的只有两件事：放文件 + 改一行配置。

---

## 命令行安装

`install.bat` 只是个启动器，等价于：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

脚本会：

1. 定位安装位置（MSIX 包或传统 Electron 安装都支持）
2. 关闭 Claude Desktop —— **必须关掉**，否则退出时会把 `config.json` 写回去覆盖掉改动
3. 若目录不可写则请求 UAC 提权，临时取得所有权（见下方风险说明）
4. 写入 `zh-CN.json`，并校验能被 `JSON.parse` 解析
5. 备份 `config.json` 到 `config.json.bak-zhcn`，把 `locale` 改成 `zh-CN`
6. **还原目录的所有权和 ACL**
7. 重新启动 Claude Desktop

卸载：

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

删除 `zh-CN.json`，并从备份恢复原来的 `locale`。

### 排错

提权后的操作跑在一个独立的 UAC 窗口里，退出时会立刻关闭。脚本会把这一段的全部输出写到
`%TEMP%\claude-zhcn-install-<时间戳>.log`，并在返回父进程后原样打印出来 —— 所以失败时直接看
终端里 `--- elevated step ---` 那一段就够了，日志路径也会在提权前打印。

---

## 风险与限制

**读之前先了解这几条，都是真实存在的代价：**

- **需要管理员权限，且要临时改 `C:\Program Files\WindowsApps` 的权限。**
  该目录属主是 `NT AUTHORITY\SYSTEM`，连 Administrators 组默认也只有只读。脚本用
  `takeown` + `icacls` 临时授权，操作完成后在 `finally` 块里还原属主和 ACL。
  但凡不愿意动系统目录权限的，就别装。

- **应用更新后会失效。** MSIX 更新会创建新的版本目录
  （`Claude_<版本>_x64__pzs8sxrjxfjjc`），`zh-CN.json` 不会跟过去。届时界面会**自动回退到
  英文**（`loadLocale` 失败时 fallback 到 en-US，不会崩），重新跑一次 `install.ps1` 即可。

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
