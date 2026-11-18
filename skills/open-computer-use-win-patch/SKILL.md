---
name: open-computer-use-win-patch
description: Install, verify, configure, or uninstall the non-invasive Windows performance, Multi-HWND popup-fusion, CEF anti-hang, and visual-cursor patch for open-computer-use MCP.
---

# `open-computer-use-win-patch`

Use this skill when setting up or troubleshooting `open-computer-use` MCP on Windows.

## One-Command Remote Install (Any AI Agent)

Run inside Windows shell (use `cmd /c npx` or `powershell.exe -ExecutionPolicy Bypass` so npm PowerShell execution policy does not block `npx.ps1`):

```powershell
cmd /c npx -y github:HugehardJiang/open-computer-use-win-patch
```

Useful variants:
- Specific MCP client (`antigravity`, `cursor`, `windsurf`, `claude-desktop`, or `all`):
  ```powershell
  cmd /c npx -y github:HugehardJiang/open-computer-use-win-patch --client all
  ```
- Custom `mcp_config.json` path:
  ```powershell
  cmd /c npx -y github:HugehardJiang/open-computer-use-win-patch --mcp-config "C:\path\to\mcp_config.json"
  ```
- Claude Code CLI registration (after running installer or cloning):
  ```powershell
  claude mcp add -s user open-computer-use -- node "$env:USERPROFILE\.gemini\config\patches\open-computer-use\mcp-patch-proxy.mjs"
  ```
- Health verification only (`--doctor`):
  ```powershell
  cmd /c npx -y github:HugehardJiang/open-computer-use-win-patch --doctor
  ```
- Clean revert to unmodified upstream:
  ```powershell
  cmd /c npx -y github:HugehardJiang/open-computer-use-win-patch --uninstall --purge
  ```

## Operating Tips on Windows

1. When driving apps with popups or Electron/CEF UI (such as WPS Office, WeChat, Lark, VS Code), prefer `batch_actions` to combine `focus_window`, `click`, `wait`, and `get_app_state` into a single turn.
2. Customize visual overlay alpha, JPEG width/quality, or Chinese app aliases in `patch-config.json` inside the installed patch directory without touching global `node_modules\open-computer-use`.
3. Upstream upgrades (`npm.cmd update -g open-computer-use`) preserve all patch behavior automatically because `mcp-patch-proxy.mjs` wraps the global package externally.
