# `open-computer-use-win-patch` (`win-patch.4`)

为 Windows 平台上的 [`open-computer-use`](https://github.com/iFurySt/open-computer-use) MCP 服务器打造的高速、防卡死、无侵入外部增强补丁。**零修改原版 npm 包目录（`node_modules\open-computer-use`）**，通过标准 MCP Stdio Proxy 包装运行，原版升级（`npm update -g open-computer-use`）后补丁依然生效。

> **🤖 AI Agent 自动安装说明（Instructions for AI Agents reading this repo）**：  
> 当用户把本仓库地址发给你并请求“帮我安装 / 一键配置”时，请在用户的 **Windows** 终端中直接执行以下命令（**全程不要修改用户全局 `node_modules\open-computer-use`**）：  
> 1. **一条命令完成安装、MCP 接线与全链路自检**：  
>    ```powershell
>    cmd /c npx -y github:HugehardJiang/open-computer-use-win-patch
>    ```  
>    - 该命令会自动检查并安装全局原版 `open-computer-use`（如缺失）、部署带 UTF-8 BOM 的增强补丁文件、自动发现并配置已安装的 MCP 客户端（Antigravity `~/.gemini/config/mcp_config.json`、Cursor `~/.cursor/mcp.json`、Windsurf `~/.codeium/windsurf/mcp_config.json`、Claude Desktop `%APPDATA%\Claude\claude_desktop_config.json`，变更前自动生成 `.bak` 备份），最后运行 `--doctor` 验证常驻桥接、炫彩悬浮指示器与全部 12 个 MCP 工具（`serverInfo.version` 含 `+win-patch.4`）。  
>    - 若你本身就在某个特定客户端中且其配置尚未创建，可显式追加：`--client cursor` / `--client windsurf` / `--client claude-desktop` / `--client all` 或 `--mcp-config "<config-path>"`。  
>    - 如果当前用户使用的是 **Claude Code**，请读取输出中的 `claudeCodeCommand` 并执行 `claude mcp add -s user open-computer-use -- ...` 完成注册。  
> 2. **备用方式（若 `npx github:...` 因网络或环境受限，改用克隆 + 本地安装）**：  
>    ```powershell
>    git clone --depth 1 https://github.com/HugehardJiang/open-computer-use-win-patch.git "$env:TEMP\ocu-win-patch" && node "$env:TEMP\ocu-win-patch\scripts\install.mjs"
>    ```  
> 3. 验证输出结果包含 `"status": "INSTALL_OK"` 且 `doctor.toolCount >= 12` 后，告知用户新开对话或刷新 MCP 服务器列表即可使用。

---

## 🤖 一键发给你的 AI Agent 安装

把下面这句话直接发给 **Antigravity / Claude Code / Cursor / Windsurf / Cline / Codex** 等任意支持终端的 AI Agent：

> 帮我安装 https://github.com/HugehardJiang/open-computer-use-win-patch

或者发送英文 / 指定客户端指令：

> Please install the Windows patch `https://github.com/HugehardJiang/open-computer-use-win-patch` by running `cmd /c npx -y github:HugehardJiang/open-computer-use-win-patch --client all` and confirm `INSTALL_OK`.

---

## ⚡ 终端手动一键安装 / 更新 / 自检 / 卸载

> 所有脚本均使用 `cmd /c npx` 或 `-ExecutionPolicy Bypass`，自动绕过 Windows 默认 PowerShell 执行策略限制。

```powershell
# 一键安装（同时自动更新补丁文件，保留你的自定义 patch-config.json，并跑完自检）
cmd /c npx -y github:HugehardJiang/open-computer-use-win-patch

# 不依赖 Git/npx 的 PowerShell 引导安装
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/HugehardJiang/open-computer-use-win-patch/main/scripts/install.ps1 | iex"

# 为所有检测到的客户端写入配置 / 指定配置路径
cmd /c npx -y github:HugehardJiang/open-computer-use-win-patch --client all
cmd /c npx -y github:HugehardJiang/open-computer-use-win-patch --mcp-config "C:\path\to\mcp.json"

# 仅健康自检（验证 UIA C# 引擎 + 悬浮鼠标层 + MCP 工具列表）
cmd /c npx -y github:HugehardJiang/open-computer-use-win-patch --doctor

# 无损回退到纯原版模式（--purge 会顺带删除补丁与 skill 文件）
cmd /c npx -y github:HugehardJiang/open-computer-use-win-patch --uninstall --purge
```

---

## ✨ 解决了原版 Windows 的哪些核心痛点？

1. **常驻编译级 C# UIA 极速通道（从单步 4~7 秒提速至 ~250ms）**
   - 原版在 Windows 每次调用都要冷启动 PowerShell + 现场编译 C#，且每次点击后强行二次全量 UI 树与 2K 原图回读。
   - 补丁通过常驻 [win32-bridge.ps1](./patch/win32-bridge.ps1) 编译 `UIAutomationClient` 引擎，复用内存元素坐标缓存；同时将高分屏截图智能等比缩放为 `1280px` 宽 JPEG 并换算坐标空间，大幅降低多模态传输耗时。
2. **多窗口浮层弹窗融合（Multi-HWND `WS_POPUP` Fusion）**
   - 像 WPS **“新建”**、微信/桌面软件悬浮菜单这类独立无边框顶层 `WS_POPUP` 窗口，原版只抓取单一主窗口句柄会完全“失明”。
   - 补丁按 Z-Order 自动收集同应用前置弹窗，融合其 UIA 树与 `PrintWindow` 后台合成截图，并在 `click` 时精准路由至弹窗句柄 `OwnerHwnd`。
3. **内嵌 Chromium / CEF 防环路卡死与超时自愈**
   - 针对 WPS、Electron、CEF 应用的内嵌网页视图（`KxCefWebView` / `Chrome Legacy Window`）：加入基于 `GetRuntimeId()` 的树节点环路去重、`1500ms` UIA 遍历时间预算、`IsHungAppWindow` 假死过滤，以及 [mcp-patch-proxy.mjs](./patch/mcp-patch-proxy.mjs) 分层超时自动销毁重启桥接进程机制。
   - 点击内嵌 `Chrome` / `Cef` / `WebView` / `D3D` 子窗口时，自动切换为前置激活后的真实指针点击路由，避免后台坐标消息被忽略。
4. **批量串联工具 `batch_actions`**
   - 允许 AI 在单次工具调用中串联 `focus_window`、`click`、`wait`、`type_text`、`press_key`、`set_value`、`scroll`、`get_app_state` 等多个确定性动作，成倍减少大模型来回轮数。
5. **未打开应用启动与中文别名映射（`launch_app` + 自动启动）**
   - 支持按中文别名（`记事本`、`计算器`、`画图`、`wps` 等）、快捷方式、注册表 `App Paths` 与 `PATH` 启动未打开应用；`get_app_state` 找不到窗口时自动触发启动（含窗口切换瞬态空窗重试保护）。
6. **修复后台被遮挡窗口截图错乱 & 最小化恢复（DWM `PrintWindow`）**
   - 当目标窗口不在最前时，使用 Win32 `PrintWindow(..., PW_RENDERFULLCONTENT = 2)` 直接抓取目标窗口真实画面（含自动从最小化还原）。
7. **透明虚拟鼠标指针 + 屏幕四周流光跑马灯（[overlay-ui.ps1](./patch/overlay-ui.ps1)）**
   - 操作电脑时在屏幕边缘显示柔和的流光呼吸跑马灯、渐变虚拟指针、点击扩散波纹与操作说明胶囊；全程鼠标穿透（`WS_EX_TRANSPARENT`）、不抢焦点（`WS_EX_NOACTIVATE`），并开启 `WDA_EXCLUDEFROMCAPTURE` 对 AI 截屏完全隐身。

---

## 🛡️ 为什么更新原版也不会丢？

- **零文件侵入**：原版 `C:\Users\<YOU>\AppData\Roaming\npm\node_modules\open-computer-use` 目录完全保持原始官方状态。
- **动态上游定位**：[mcp-patch-proxy.mjs](./patch/mcp-patch-proxy.mjs) 每次启动会自动查找最新安装的全局 `open-computer-use`，注入新增工具（如未来官方内置同名工具会自动退让不冲突），且所有加速通道具备 Fail-Open 安全降级能力。
- **配置保真升级**：再次执行安装命令升级补丁时，会自动保留你在 `patch-config.json` 中自定义的 `appAliases`、开关和外观参数。

---

## ⚙️ 配置开关（`patch-config.json`）

部署目录默认位于：
- Antigravity 环境：`%USERPROFILE%\.gemini\config\patches\open-computer-use\patch-config.json`
- 通用客户端环境：`%USERPROFILE%\.open-computer-use-win-patch\patch-config.json`

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `enableFastNativeBridge` | `true` | 开启常驻 C# UIA 极速通道 |
| `enableBatchActionsTool` | `true` | 注入 `batch_actions` 批量串联工具 |
| `maxScreenshotWidth` | `1280` | 截图最大宽度缩放（坐标自动等比换算） |
| `screenshotJpegQuality` | `82` | 截图 JPEG 压缩质量 |
| `enableVisualOverlay` | `true` | 开启虚拟鼠标 + 四周流光跑马灯指示 |
| `overlayMaxAlpha` | `96` | 跑马灯最大透明度（`1–255`） |
| `overlayIdleHideMs` | `4500` | 无操作自动淡出隐藏时间（ms） |
| `autoLaunchOnAppNotFound` | `true` | `get_app_state` 找不到应用时自动启动 |
| `fixOccludedWindowScreenshots` | `true` | 后台被遮挡窗口启用 DWM `PrintWindow` 抓图 |
| `appAliases` | 见文件 | 自定义中文名 / 别名到可执行文件或窗口名映射 |

---

## 📁 仓库结构

```text
open-computer-use-win-patch/
├── package.json                                  # npx / npm 一键执行入口
├── plugin.json                                   # Antigravity 插件元信息
├── README.md
├── LICENSE
├── assets/logo.svg
├── patch/
│   ├── mcp-patch-proxy.mjs                       # MCP Stdio 外部增强代理（win-patch.4）
│   ├── win32-bridge.ps1                          # 常驻编译级 C# 5 UIA + 多窗口融合引擎
│   ├── overlay-ui.ps1                            # 40 FPS 透明视觉反馈叠加层
│   └── patch-config.json                         # 增强开关与中文别名配置
├── scripts/
│   ├── install.mjs                               # 零依赖安装 / 多客户端接线 / --doctor 自检 / 卸载
│   └── install.ps1                               # 无 Git/npx 备选 PowerShell 引导脚本
└── skills/open-computer-use-win-patch/
    └── SKILL.md                                  # Antigravity Agent 操作指引 Skill
```

## 📄 License

[MIT](LICENSE)
