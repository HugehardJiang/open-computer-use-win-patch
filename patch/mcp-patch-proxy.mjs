#!/usr/bin/env node
import { execFileSync, spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PATCH_VERSION = "win-patch.4";
const PATCH_CONFIG_PATH = path.join(HERE, "patch-config.json");
const BRIDGE_SCRIPT_PATH = path.join(HERE, "win32-bridge.ps1");
const OVERLAY_SCRIPT_PATH = path.join(HERE, "overlay-ui.ps1");

const DEFAULT_CONFIG = {
  enableLaunchAppTool: true,
  autoLaunchOnAppNotFound: true,
  autoLaunchWaitMs: 8000,
  enableFocusWindowTool: true,
  autoRestoreMinimizedOnSnapshot: true,
  fixOccludedWindowScreenshots: true,
  enableGlobalPointerFallback: true,
  autoFocusBeforeGlobalInput: true,
  enableVisualOverlay: true,
  overlayIdleHideMs: 4500,
  overlayMaxAlpha: 96,
  enableFastNativeBridge: true,
  enableBatchActionsTool: true,
  maxScreenshotWidth: 1280,
  screenshotJpegQuality: 82,
  overlayClickLeadMs: 75,
  appAliases: {
    wps: "WPS Office",
    "wps office": "WPS Office",
    "文字": "WPS Office",
    "记事本": "notepad.exe",
    "计算器": "calc.exe",
    "画图": "mspaint.exe",
    "资源管理器": "explorer.exe",
  },
};

function loadPatchConfig() {
  try {
    const raw = readFileSync(PATCH_CONFIG_PATH, "utf8");
    const parsed = JSON.parse(raw);
    return {
      ...DEFAULT_CONFIG,
      ...parsed,
      appAliases: { ...DEFAULT_CONFIG.appAliases, ...(parsed.appAliases || {}) },
    };
  } catch {
    return DEFAULT_CONFIG;
  }
}

function resolveUpstreamRoot() {
  const candidates = [];
  if (process.env.OCU_UPSTREAM_ROOT) candidates.push(process.env.OCU_UPSTREAM_ROOT);
  if (process.env.APPDATA) {
    candidates.push(path.join(process.env.APPDATA, "npm", "node_modules", "open-computer-use"));
  }
  candidates.push(path.join(path.dirname(process.execPath), "node_modules", "open-computer-use"));

  for (const dir of candidates) {
    if (dir && existsSync(path.join(dir, "bin", "open-computer-use"))) {
      return dir;
    }
  }

  try {
    const comspec = process.env.ComSpec || "cmd.exe";
    const npmRoot = execFileSync(comspec, ["/c", "npm.cmd", "root", "-g"], {
      encoding: "utf8",
      windowsHide: true,
    }).trim();
    const discovered = path.join(npmRoot, "open-computer-use");
    if (existsSync(path.join(discovered, "bin", "open-computer-use"))) {
      return discovered;
    }
  } catch {
    // Fall through to descriptive error.
  }

  throw new Error(
    "Could not locate global open-computer-use installation. Run 'npm install -g open-computer-use' or set OCU_UPSTREAM_ROOT."
  );
}

class Win32Bridge {
  constructor(scriptPath) {
    this.scriptPath = scriptPath;
    this.child = null;
    this.buffer = "";
    this.nextId = 1;
    this.pending = new Map();
    this.readyPromise = null;
  }

  async ensureStarted() {
    if (this.child && !this.child.killed) {
      return this.readyPromise;
    }
    this.readyPromise = new Promise((resolve, reject) => {
      const child = spawn(
        "powershell.exe",
        ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", this.scriptPath],
        { stdio: ["pipe", "pipe", "pipe"], windowsHide: true }
      );
      this.child = child;
      this.buffer = "";
      let readySettled = false;

      child.stdout.setEncoding("utf8");
      child.stdout.on("data", chunk => {
        this.buffer += chunk;
        for (;;) {
          const idx = this.buffer.indexOf("\n");
          if (idx < 0) break;
          const line = this.buffer.slice(0, idx).trim();
          this.buffer = this.buffer.slice(idx + 1);
          if (!line) continue;
          let msg;
          try {
            msg = JSON.parse(line);
          } catch {
            continue;
          }
          if (!readySettled && msg.ready) {
            readySettled = true;
            resolve();
            continue;
          }
          if (msg.id !== undefined && this.pending.has(msg.id)) {
            const entry = this.pending.get(msg.id);
            this.pending.delete(msg.id);
            clearTimeout(entry.timer);
            entry.resolve(msg);
          }
        }
      });

      let stderrTail = "";
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", chunk => {
        stderrTail = (stderrTail + chunk).slice(-2048);
      });

      const failAll = reason => {
        if (!readySettled) {
          readySettled = true;
          reject(new Error(reason));
        }
        for (const [id, entry] of this.pending) {
          clearTimeout(entry.timer);
          entry.reject(new Error(reason));
          this.pending.delete(id);
        }
        this.child = null;
      };

      child.on("error", err => failAll(`win32-bridge error: ${err.message}`));
      child.on("exit", code => failAll(`win32-bridge exited (code=${code}): ${stderrTail.trim()}`));
    });
    return this.readyPromise;
  }

  async call(action, payload = {}, timeoutMs) {
    const effectiveTimeout = timeoutMs ?? (String(action).startsWith("fast_") ? 6_000 : 15_000);
    await this.ensureStarted();
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        this.close();
        reject(new Error(`win32-bridge action '${action}' timed out after ${effectiveTimeout}ms (worker recycled)`));
      }, effectiveTimeout);
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.child.stdin.write(`${JSON.stringify({ id, action, ...payload })}\n`);
      } catch (err) {
        clearTimeout(timer);
        this.pending.delete(id);
        this.close();
        reject(err instanceof Error ? err : new Error(String(err)));
      }
    });
  }

  close() {
    if (this.child && !this.child.killed) {
      try {
        this.child.stdin.end();
      } catch {}
      try {
        this.child.kill();
      } catch {}
    }
    this.child = null;
  }
}

class VisualOverlayClient {
  constructor(scriptPath, config) {
    this.scriptPath = scriptPath;
    this.enabled = Boolean(config.enableVisualOverlay);
    this.idleHideMs = Number.isInteger(config.overlayIdleHideMs) ? config.overlayIdleHideMs : 4500;
    this.maxAlpha = Number.isInteger(config.overlayMaxAlpha) ? config.overlayMaxAlpha : 96;
    this.child = null;
    this.readyPromise = null;
    this.buffer = "";
  }

  sanitize(text) {
    return String(text || "").replace(/[\r\n\t]+/g, " ").trim();
  }

  async ensureStarted() {
    if (!this.enabled) return false;
    if (this.child && !this.child.killed) {
      return this.readyPromise;
    }
    this.readyPromise = new Promise(resolve => {
      try {
        const child = spawn(
          "powershell.exe",
          [
            "-Sta",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            this.scriptPath,
            "-IdleHideMs",
            String(this.idleHideMs),
            "-MaxAlpha",
            String(this.maxAlpha),
          ],
          { stdio: ["pipe", "pipe", "pipe"], windowsHide: true }
        );
        this.child = child;
        this.buffer = "";
        let settled = false;
        const timer = setTimeout(() => {
          if (!settled) {
            settled = true;
            resolve(false);
          }
        }, 8000);

        child.stdout.setEncoding("utf8");
        child.stdout.on("data", chunk => {
          this.buffer += chunk;
          if (!settled && this.buffer.includes("READY")) {
            settled = true;
            clearTimeout(timer);
            resolve(true);
          }
        });
        child.on("error", () => {
          this.child = null;
          if (!settled) {
            settled = true;
            clearTimeout(timer);
            resolve(false);
          }
        });
        child.on("exit", () => {
          this.child = null;
          if (!settled) {
            settled = true;
            clearTimeout(timer);
            resolve(false);
          }
        });
      } catch {
        this.child = null;
        resolve(false);
      }
    });
    return this.readyPromise;
  }

  async send(line) {
    if (!this.enabled) return;
    try {
      const ok = await this.ensureStarted();
      if (!ok || !this.child || this.child.killed) return;
      this.child.stdin.write(`${line}\n`);
    } catch {
      // Visual overlay must fail open and never disrupt MCP automation.
    }
  }

  async status(pid, label) {
    await this.send(`STATUS\t${Number(pid) || 0}\t${this.sanitize(label)}`);
  }

  async move(pid, relX, relY, label) {
    await this.send(
      `MOVE\t${Number(pid) || 0}\t${Math.round(Number(relX) || 0)}\t${Math.round(Number(relY) || 0)}\t${this.sanitize(label)}`
    );
  }

  async click(pid, relX, relY, label) {
    await this.send(
      `CLICK\t${Number(pid) || 0}\t${Math.round(Number(relX) || 0)}\t${Math.round(Number(relY) || 0)}\t${this.sanitize(label)}`
    );
  }

  hide() {
    if (!this.enabled || !this.child || this.child.killed) return;
    try {
      this.child.stdin.write("HIDE\n");
    } catch {}
  }

  close() {
    if (this.child && !this.child.killed) {
      try {
        this.child.stdin.write("EXIT\n");
        this.child.stdin.end();
      } catch {}
      try {
        this.child.kill();
      } catch {}
    }
    this.child = null;
  }
}

class UpstreamMcpClient {
  constructor(binPath, env) {
    this.child = spawn(process.execPath, [binPath, "mcp"], {
      stdio: ["pipe", "pipe", "pipe"],
      env,
      windowsHide: true,
    });
    this.buffer = "";
    this.nextId = 1;
    this.pending = new Map();

    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", chunk => {
      this.buffer += chunk;
      for (;;) {
        const idx = this.buffer.indexOf("\n");
        if (idx < 0) break;
        const line = this.buffer.slice(0, idx).trim();
        this.buffer = this.buffer.slice(idx + 1);
        if (!line) continue;
        let msg;
        try {
          msg = JSON.parse(line);
        } catch {
          continue;
        }
        if (msg.id !== undefined && msg.id !== null && this.pending.has(msg.id)) {
          const entry = this.pending.get(msg.id);
          this.pending.delete(msg.id);
          entry.resolve(msg);
        } else if (msg.id === undefined) {
          // Forward upstream notifications verbatim.
          process.stdout.write(`${JSON.stringify(msg)}\n`);
        }
      }
    });

    this.child.stderr.on("data", chunk => process.stderr.write(chunk));
    this.child.on("exit", code => {
      for (const [, entry] of this.pending) {
        entry.reject(new Error(`Upstream open-computer-use exited with code ${code}`));
      }
      this.pending.clear();
    });
  }

  request(method, params) {
    const id = `__up_${this.nextId++}`;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      const payload = { jsonrpc: "2.0", id, method };
      if (params !== undefined) payload.params = params;
      this.child.stdin.write(`${JSON.stringify(payload)}\n`);
    });
  }

  notify(method, params) {
    const payload = { jsonrpc: "2.0", method };
    if (params !== undefined) payload.params = params;
    this.child.stdin.write(`${JSON.stringify(payload)}\n`);
  }

  close() {
    if (this.child && !this.child.killed) {
      try {
        this.child.stdin.end();
      } catch {}
      try {
        this.child.kill();
      } catch {}
    }
  }
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function parseListAppsEntries(text) {
  const entries = [];
  for (const rawLine of String(text || "").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || !line.includes(" -- ")) continue;
    const sepIdx = line.indexOf(" -- ");
    const appName = line.slice(0, sepIdx).trim();
    const pidMatch = /\[[^\]]*?\bpid=(\d+)\b/i.exec(line);
    const winMatch = /\bwindow=([^\]]+)\]/i.exec(line);
    entries.push({
      raw: line,
      app: appName,
      pid: pidMatch ? Number.parseInt(pidMatch[1], 10) : null,
      window: winMatch ? winMatch[1].trim() : "",
    });
  }
  return entries;
}

function extractTextFromResult(response) {
  const content = response?.result?.content;
  if (!Array.isArray(content)) return "";
  return content
    .filter(item => item && item.type === "text" && typeof item.text === "string")
    .map(item => item.text)
    .join("\n");
}

function matchAppEntry(entries, queries) {
  const cleanQueries = queries
    .filter(Boolean)
    .map(q => path.basename(String(q), path.extname(String(q))).toLowerCase())
    .filter(q => q.length >= 2);
  for (const entry of entries) {
    const appLower = entry.app.toLowerCase();
    const winLower = entry.window.toLowerCase();
    for (const q of cleanQueries) {
      if (appLower === q || appLower.includes(q) || q.includes(appLower) || winLower.includes(q)) {
        return entry;
      }
    }
  }
  return null;
}

function parseAxStateText(text) {
  const pidMatch = /\(pid\s+(\d+)\)/.exec(text);
  const pid = pidMatch ? Number.parseInt(pidMatch[1], 10) : null;
  const appHeaderMatch = /^App=([^\s(]+)/m.exec(text);
  const parsedAppName = appHeaderMatch ? appHeaderMatch[1].trim() : null;
  const elements = new Map();
  const lineRe = /^\s*(\d+)\s+(\S+)\s*(.*?)\s+Frame:\s*\{x:\s*(-?\d+),\s*y:\s*(-?\d+),\s*width:\s*(\d+),\s*height:\s*(\d+)\}/;
  for (const rawLine of String(text || "").split(/\r?\n/)) {
    const m = lineRe.exec(rawLine);
    if (!m) continue;
    const index = m[1];
    const role = m[2];
    const middle = m[3].replace(/\s*Secondary Actions:.*$/, "").replace(/\s*Value:.*$/, "").trim();
    const label = middle || role;
    const x = Number.parseInt(m[4], 10);
    const y = Number.parseInt(m[5], 10);
    const w = Number.parseInt(m[6], 10);
    const h = Number.parseInt(m[7], 10);
    elements.set(index, {
      index,
      role,
      label,
      cx: Math.round(x + w / 2),
      cy: Math.round(y + h / 2),
    });
  }
  return { pid, parsedAppName, elements };
}

function buildPatchTools(existingNames, config) {
  const extras = [];
  if (config.enableLaunchAppTool && !existingNames.has("launch_app")) {
    extras.push({
      name: "launch_app",
      description:
        "Launch a Windows desktop application by name, alias, Start Menu/Desktop shortcut, App Paths, or executable path and wait for its window to appear in list_apps.",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        properties: {
          app: {
            type: "string",
            description: "App name, Chinese alias, shortcut name, or executable path (e.g. 'WPS Office', 'wps', 'notepad')",
          },
          args: {
            type: "array",
            items: { type: "string" },
            description: "Optional command-line arguments",
          },
          wait_ms: {
            type: "integer",
            minimum: 500,
            maximum: 30000,
            description: "Max wait time in ms for the app window to appear",
          },
        },
        required: ["app"],
      },
    });
  }
  if (config.enableFocusWindowTool && !existingNames.has("focus_window")) {
    extras.push({
      name: "focus_window",
      description:
        "Bring a running Windows app window to the foreground (restoring it if minimized).",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        properties: {
          app: {
            type: "string",
            description: "App name from list_apps or window/process name",
          },
          pid: {
            type: "integer",
            description: "Optional target PID",
          },
        },
      },
    });
  }
  if (config.enableBatchActionsTool && !existingNames.has("batch_actions")) {
    extras.push({
      name: "batch_actions",
      description:
        "Execute multiple Computer Use steps sequentially in a single tool call to eliminate multi-turn latency. Stops on the first error.",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        properties: {
          steps: {
            type: "array",
            minItems: 1,
            maxItems: 20,
            items: {
              type: "object",
              additionalProperties: false,
              properties: {
                tool: {
                  type: "string",
                  enum: [
                    "launch_app",
                    "focus_window",
                    "get_app_state",
                    "click",
                    "type_text",
                    "press_key",
                    "set_value",
                    "scroll",
                    "drag",
                    "wait",
                  ],
                },
                args: { type: "object" },
              },
              required: ["tool"],
            },
          },
        },
        required: ["steps"],
      },
    });
  }
  return extras;
}

async function main() {
  const config = loadPatchConfig();
  const upstreamRoot = resolveUpstreamRoot();
  const upstreamBin = path.join(upstreamRoot, "bin", "open-computer-use");

  const upstreamEnv = { ...process.env };
  if (config.enableGlobalPointerFallback) {
    upstreamEnv.OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS = "1";
  }
  upstreamEnv.OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH = "1";
  upstreamEnv.OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS = "1";
  upstreamEnv.OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK = "1";

  const upstream = new UpstreamMcpClient(upstreamBin, upstreamEnv);
  const bridge = new Win32Bridge(BRIDGE_SCRIPT_PATH);
  const overlay = new VisualOverlayClient(OVERLAY_SCRIPT_PATH, config);
  const axCache = new Map();
  const upstreamPrimed = new Set();

  if (config.enableFastNativeBridge) {
    void bridge.ensureStarted().catch(() => {});
  }

  function cacheAxStateFromResponse(appKey, response, scale = 1.0) {
    const text = extractTextFromResult(response);
    if (!text) return;
    const parsed = parseAxStateText(text);
    if (!parsed.pid && parsed.elements.size === 0) return;
    const keys = new Set();
    if (appKey) keys.add(String(appKey).trim().toLowerCase());
    if (parsed.parsedAppName) keys.add(parsed.parsedAppName.toLowerCase());
    for (const k of keys) {
      const prev = axCache.get(k);
      axCache.set(k, {
        pid: parsed.pid || prev?.pid || 0,
        scale: scale || prev?.scale || 1.0,
        elements: parsed.elements.size > 0 ? parsed.elements : (prev?.elements || new Map()),
      });
    }
  }

  function resolveCachedTarget(appKey, elementIndex, fallbackX, fallbackY) {
    const entry = appKey ? axCache.get(String(appKey).trim().toLowerCase()) : null;
    const pid = entry?.pid || 0;
    const scale = entry?.scale || 1.0;
    if (elementIndex !== undefined && elementIndex !== null && entry?.elements?.has(String(elementIndex))) {
      const el = entry.elements.get(String(elementIndex));
      return {
        pid,
        x: Math.round(el.cx / scale),
        y: Math.round(el.cy / scale),
        label: el.label,
      };
    }
    if (typeof fallbackX === "number" && typeof fallbackY === "number") {
      return {
        pid,
        x: Math.round(fallbackX / scale),
        y: Math.round(fallbackY / scale),
        label: `(${Math.round(fallbackX)}, ${Math.round(fallbackY)})`,
      };
    }
    return {
      pid,
      x: null,
      y: null,
      label: elementIndex !== undefined ? `#${elementIndex}` : (appKey || ""),
    };
  }

  async function ensureUpstreamPrimed(appName) {
    const key = String(appName || "").trim().toLowerCase();
    if (!key || upstreamPrimed.has(key)) return;
    try {
      await upstream.request("tools/call", {
        name: "get_app_state",
        arguments: { app: appName, include_ax: false, include_screenshot: false },
      });
      upstreamPrimed.add(key);
    } catch {}
  }

  async function listLiveApps() {
    if (config.enableFastNativeBridge) {
      try {
        const fast = await bridge.call("fast_list_apps", { excludePid: process.pid });
        if (fast?.ok) {
          return parseListAppsEntries(fast.text || "");
        }
      } catch {}
    }
    const res = await upstream.request("tools/call", { name: "list_apps", arguments: {} });
    return parseListAppsEntries(extractTextFromResult(res));
  }

  async function resolvePidForApp(appQuery) {
    if (!appQuery) return null;
    const entries = await listLiveApps();
    const alias = config.appAliases?.[String(appQuery).trim().toLowerCase()];
    const matched = matchAppEntry(entries, [appQuery, alias]);
    return matched?.pid ?? null;
  }

  async function launchAppAndWait(appQuery, argsList, waitMs) {
    const beforeEntries = await listLiveApps();
    const beforePids = new Set(beforeEntries.map(e => e.pid).filter(Boolean));
    const alias = config.appAliases?.[String(appQuery || "").trim().toLowerCase()];

    const existing = matchAppEntry(beforeEntries, [appQuery, alias]);
    if (existing) {
      return {
        ok: true,
        alreadyRunning: true,
        entry: existing,
        launched: existing.app,
        method: "already_running",
      };
    }

    const launchRes = await bridge.call("launch_app", {
      app: appQuery,
      args: argsList || [],
      aliases: config.appAliases || {},
    });
    if (!launchRes.ok) {
      return { ok: false, error: launchRes.error || `Failed to launch '${appQuery}'` };
    }

    const maxWait = Number.isInteger(waitMs) ? waitMs : config.autoLaunchWaitMs;
    const deadline = Date.now() + Math.max(1000, maxWait);
    const launchedBase = launchRes.launched ? path.basename(launchRes.launched, path.extname(launchRes.launched)) : "";

    while (Date.now() < deadline) {
      await sleep(500);
      const nowEntries = await listLiveApps();
      const matched = matchAppEntry(nowEntries, [appQuery, alias, launchedBase]);
      if (matched) {
        return { ok: true, alreadyRunning: false, entry: matched, ...launchRes };
      }
      const newWindow = nowEntries.find(e => e.pid && !beforePids.has(e.pid));
      if (newWindow) {
        return { ok: true, alreadyRunning: false, entry: newWindow, ...launchRes };
      }
    }

    return {
      ok: true,
      alreadyRunning: false,
      timedOutWaitingWindow: true,
      entry: null,
      ...launchRes,
    };
  }

  async function enhanceScreenshotResult(upstreamRes, includeScreenshot) {
    if (!config.fixOccludedWindowScreenshots || includeScreenshot === false) {
      return { res: upstreamRes, restored: false };
    }
    if (!upstreamRes?.result || upstreamRes.result.isError || !Array.isArray(upstreamRes.result.content)) {
      return { res: upstreamRes, restored: false };
    }
    const text = extractTextFromResult(upstreamRes);
    const pidMatch = /\(pid\s+(\d+)\)/.exec(text);
    if (!pidMatch) {
      return { res: upstreamRes, restored: false };
    }
    const pid = Number.parseInt(pidMatch[1], 10);
    if (!Number.isInteger(pid) || pid <= 0) {
      return { res: upstreamRes, restored: false };
    }

    try {
      const cap = await bridge.call("capture_window", {
        pid,
        restoreIfMinimized: Boolean(config.autoRestoreMinimizedOnSnapshot),
      });
      if (!cap?.ok || cap.alreadyForeground || !cap.data) {
        return { res: upstreamRes, restored: Boolean(cap?.restored) };
      }

      const content = upstreamRes.result.content.map(item => ({ ...item }));
      const imgIdx = content.findIndex(item => item && item.type === "image");
      if (imgIdx >= 0) {
        content[imgIdx] = {
          ...content[imgIdx],
          mimeType: "image/png",
          data: cap.data,
        };
      } else {
        for (const item of content) {
          if (item && item.type === "text" && typeof item.text === "string") {
            item.text = item.text
              .replace(/\r?\n?Screenshot unavailable\. Restore a visible, non-minimized[^\n]*/g, "")
              .trimEnd();
          }
        }
        content.push({ type: "image", mimeType: "image/png", data: cap.data });
      }
      return {
        res: { ...upstreamRes, result: { ...upstreamRes.result, content } },
        restored: Boolean(cap.restored),
      };
    } catch {
      return { res: upstreamRes, restored: false };
    }
  }

  async function executeToolCall(toolName, rawArgs) {
    const args = { ...(rawArgs || {}) };
    const leadMs = Number.isInteger(config.overlayClickLeadMs) ? Math.max(0, config.overlayClickLeadMs) : 75;

    if (toolName === "batch_actions" && config.enableBatchActionsTool) {
      const steps = Array.isArray(args.steps) ? args.steps : [];
      if (steps.length === 0) {
        return { result: { content: [{ type: "text", text: "batch_actions requires at least 1 step." }], isError: true } };
      }
      const logs = [];
      let lastImage = null;
      for (let i = 0; i < steps.length; i += 1) {
        const step = steps[i] || {};
        if (step.tool === "wait") {
          const waitMs = Math.min(10000, Math.max(0, Number(step.args?.ms ?? 300)));
          await overlay.status(0, `AI 等待: ${waitMs}ms`);
          await sleep(waitMs);
          logs.push(`[${i + 1}] wait ${waitMs}ms`);
          continue;
        }
        const stepRes = await executeToolCall(step.tool, step.args || {});
        if (stepRes.error) {
          logs.push(`[${i + 1}] ${step.tool} ERROR: ${stepRes.error.message}`);
          return { result: { content: [{ type: "text", text: logs.join("\n") }], isError: true } };
        }
        const txt = extractTextFromResult(stepRes);
        const firstLine = txt.split(/\r?\n/)[0] || "OK";
        const img = Array.isArray(stepRes.result?.content)
          ? stepRes.result.content.find(c => c && c.type === "image")
          : null;
        if (img) lastImage = img;
        if (stepRes.result?.isError) {
          logs.push(`[${i + 1}] ${step.tool} FAILED: ${txt}`);
          return { result: { content: [{ type: "text", text: logs.join("\n") }], isError: true } };
        }
        if (step.tool === "get_app_state") {
          logs.push(`[${i + 1}] get_app_state:\n${txt}`);
        } else {
          logs.push(`[${i + 1}] ${step.tool}: ${firstLine}`);
        }
      }
      const content = [{ type: "text", text: logs.join("\n") }];
      if (lastImage) content.push(lastImage);
      return { result: { content, isError: false } };
    }

    if (toolName === "list_apps" && config.enableFastNativeBridge) {
      try {
        const fast = await bridge.call("fast_list_apps", { excludePid: process.pid });
        if (fast?.ok) {
          return {
            result: {
              content: [{ type: "text", text: fast.text || "No running top-level apps found." }],
              isError: false,
            },
          };
        }
      } catch {}
    }

    if (toolName === "launch_app" && config.enableLaunchAppTool) {
      await overlay.status(0, `AI 启动: ${args.app}`);
      const res = await launchAppAndWait(args.app, args.args, args.wait_ms);
      if (!res.ok) {
        return { result: { content: [{ type: "text", text: res.error }], isError: true } };
      }
      const summary = res.alreadyRunning
        ? `App '${args.app}' is already running: ${res.entry.raw}`
        : res.entry
          ? `Launched '${args.app}' (${res.method}: ${res.launched}). Active window: ${res.entry.raw}`
          : `Launched '${args.app}' (${res.method}: ${res.launched}), but no visible window appeared in list_apps within timeout.`;
      return { result: { content: [{ type: "text", text: summary }], isError: false } };
    }

    if (toolName === "focus_window" && config.enableFocusWindowTool) {
      const targetPid = Number.isInteger(args.pid) && args.pid > 0 ? args.pid : await resolvePidForApp(args.app);
      await overlay.status(targetPid || 0, `AI 激活窗口: ${args.app || targetPid}`);
      const focusRes = await bridge.call("focus_window", { pid: targetPid || 0, app: args.app || "" });
      return {
        result: {
          content: [
            {
              type: "text",
              text: focusRes.ok
                ? `Focused window pid=${focusRes.pid} (hwnd=${focusRes.hwnd}, isForeground=${focusRes.isForeground}).`
                : focusRes.error || "Failed to focus window.",
            },
          ],
          isError: !focusRes.ok,
        },
      };
    }

    if (toolName === "get_app_state") {
      const allowAutoLaunch = args.auto_launch !== false && config.autoLaunchOnAppNotFound;
      const cleanArgs = { ...args };
      delete cleanArgs.auto_launch;

      const appCacheKey = String(cleanArgs.app || "").trim().toLowerCase();
      const cachedPid = axCache.get(appCacheKey)?.pid || 0;
      await overlay.status(cachedPid, `AI 观察: ${cleanArgs.app}`);

      if (config.enableFastNativeBridge) {
        try {
          const fastPayload = {
            app: cleanArgs.app,
            aliases: config.appAliases || {},
            includeAx: cleanArgs.include_ax !== false,
            includeScreenshot: cleanArgs.include_screenshot !== false,
            maxNodes: cleanArgs.max_tree_nodes || 600,
            maxDepth: cleanArgs.max_tree_depth || 48,
            textLimit: cleanArgs.text_limit === "max" ? 0 : (cleanArgs.text_limit || 500),
            maxScreenshotWidth: config.maxScreenshotWidth || 1280,
            jpegQuality: config.screenshotJpegQuality || 82,
            restoreIfMinimized: Boolean(config.autoRestoreMinimizedOnSnapshot),
          };
          let fast = await bridge.call("fast_get_app_state", fastPayload);
          if (fast?.notFound && appCacheKey && axCache.has(appCacheKey)) {
            for (let retry = 0; retry < 4 && fast?.notFound; retry += 1) {
              await sleep(650);
              fast = await bridge.call("fast_get_app_state", fastPayload);
            }
          }
          if (fast?.notFound && allowAutoLaunch && cleanArgs.app) {
            const launched = await launchAppAndWait(cleanArgs.app, [], config.autoLaunchWaitMs);
            if (launched.ok && launched.entry?.app) {
              fast = await bridge.call("fast_get_app_state", { ...fastPayload, app: launched.entry.app });
            } else if (!launched.ok) {
              return {
                result: {
                  content: [{ type: "text", text: `appNotFound("${cleanArgs.app}")\n[Patch auto-launch failed]: ${launched.error}` }],
                  isError: true,
                },
              };
            }
          }
          if (fast?.ok) {
            const content = [{ type: "text", text: fast.text }];
            if (fast.imageData) {
              content.push({ type: "image", mimeType: fast.mimeType || "image/jpeg", data: fast.imageData });
            }
            const resObj = { result: { content, isError: false } };
            cacheAxStateFromResponse(cleanArgs.app, resObj, fast.scale || 1.0);
            if (appCacheKey) upstreamPrimed.delete(appCacheKey);
            return resObj;
          }
        } catch {
          // Fall through to upstream path cleanly.
        }
      }

      let up = await upstream.request("tools/call", { name: "get_app_state", arguments: cleanArgs });
      let errText = up.error?.message || extractTextFromResult(up);
      let isNotFound = Boolean((up.error || up.result?.isError) && /appNotFound/i.test(errText));

      if (isNotFound && appCacheKey && axCache.has(appCacheKey)) {
        for (let retry = 0; retry < 4 && isNotFound; retry += 1) {
          await sleep(650);
          up = await upstream.request("tools/call", { name: "get_app_state", arguments: cleanArgs });
          errText = up.error?.message || extractTextFromResult(up);
          isNotFound = Boolean((up.error || up.result?.isError) && /appNotFound/i.test(errText));
        }
      }

      if (isNotFound && allowAutoLaunch && cleanArgs.app) {
        const launched = await launchAppAndWait(cleanArgs.app, [], config.autoLaunchWaitMs);
        if (launched.ok && launched.entry?.app) {
          up = await upstream.request("tools/call", {
            name: "get_app_state",
            arguments: { ...cleanArgs, app: launched.entry.app },
          });
        } else if (!launched.ok) {
          return {
            result: {
              content: [{ type: "text", text: `${errText}\n[Patch auto-launch failed]: ${launched.error}` }],
              isError: true,
            },
          };
        }
      }

      const firstPass = await enhanceScreenshotResult(up, cleanArgs.include_screenshot);
      if (firstPass.restored) {
        const refreshed = await upstream.request("tools/call", { name: "get_app_state", arguments: cleanArgs });
        const secondPass = await enhanceScreenshotResult(refreshed, cleanArgs.include_screenshot);
        up = secondPass.res;
      } else {
        up = firstPass.res;
      }
      if (!up.error && !up.result?.isError && appCacheKey) {
        upstreamPrimed.add(appCacheKey);
      }
      cacheAxStateFromResponse(cleanArgs.app, up, 1.0);
      return up;
    }

    if (toolName === "click") {
      const tgt = resolveCachedTarget(args.app, args.element_index, args.x, args.y);
      if (tgt.x !== null && tgt.y !== null) {
        await overlay.click(tgt.pid, tgt.x, tgt.y, `AI 点击: ${tgt.label}`);
        if (leadMs > 0) await sleep(leadMs);
      } else {
        await overlay.status(tgt.pid, `AI 点击: ${tgt.label}`);
      }
      if (config.enableFastNativeBridge) {
        try {
          const fast = await bridge.call("fast_click", {
            app: args.app,
            elementIndex: args.element_index ?? "",
            x: args.x ?? null,
            y: args.y ?? null,
            mouseButton: args.mouse_button || "left",
            clickCount: args.click_count || 1,
            clickMethod: args.click_method || "auto",
          });
          if (fast?.ok) {
            return { result: { content: [{ type: "text", text: fast.text }], isError: false } };
          }
          if (fast?.error && !fast.fallback) {
            return { result: { content: [{ type: "text", text: fast.error }], isError: true } };
          }
        } catch {}
      }
    } else if (toolName === "set_value") {
      const tgt = resolveCachedTarget(args.app, args.element_index);
      const valPreview = String(args.value || "").slice(0, 12);
      if (tgt.x !== null && tgt.y !== null) {
        await overlay.click(tgt.pid, tgt.x, tgt.y, `AI 填写: ${valPreview}`);
        if (leadMs > 0) await sleep(leadMs);
      } else {
        await overlay.status(tgt.pid, `AI 填写: ${valPreview}`);
      }
      if (config.enableFastNativeBridge) {
        try {
          const fast = await bridge.call("fast_set_value", {
            app: args.app,
            elementIndex: args.element_index ?? "",
            value: args.value ?? "",
          });
          if (fast?.ok) {
            return { result: { content: [{ type: "text", text: fast.text }], isError: false } };
          }
        } catch {}
      }
    } else if (toolName === "type_text") {
      const pid = axCache.get(String(args.app || "").trim().toLowerCase())?.pid || 0;
      await overlay.status(pid, `AI 输入: ${String(args.text || "").slice(0, 12)}`);
      if (config.enableFastNativeBridge) {
        try {
          const fast = await bridge.call("fast_type_text", {
            app: args.app,
            text: args.text ?? "",
            keyMethod: args.key_method || "auto",
          });
          if (fast?.ok) {
            return { result: { content: [{ type: "text", text: fast.text }], isError: false } };
          }
          if (fast?.error && !fast.fallback) {
            return { result: { content: [{ type: "text", text: fast.error }], isError: true } };
          }
        } catch {}
      }
    } else if (toolName === "press_key") {
      const pid = axCache.get(String(args.app || "").trim().toLowerCase())?.pid || 0;
      await overlay.status(pid, `AI 按键: ${args.key}`);
      if (config.enableFastNativeBridge) {
        try {
          const fast = await bridge.call("fast_press_key", {
            app: args.app,
            key: args.key ?? "",
            keyMethod: args.key_method || "auto",
          });
          if (fast?.ok) {
            return { result: { content: [{ type: "text", text: fast.text }], isError: false } };
          }
          if (fast?.error && !fast.fallback) {
            return { result: { content: [{ type: "text", text: fast.error }], isError: true } };
          }
        } catch {}
      }
    } else if (toolName === "scroll") {
      const tgt = resolveCachedTarget(args.app, args.element_index);
      if (tgt.x !== null && tgt.y !== null) {
        await overlay.move(tgt.pid, tgt.x, tgt.y, `AI 滚动: ${args.direction}`);
      } else {
        await overlay.status(tgt.pid, `AI 滚动: ${args.direction}`);
      }
      if (config.enableFastNativeBridge) {
        try {
          const fast = await bridge.call("fast_scroll", {
            app: args.app,
            elementIndex: args.element_index ?? "",
            direction: args.direction || "down",
            pages: args.pages ?? 1,
          });
          if (fast?.ok) {
            return { result: { content: [{ type: "text", text: fast.text }], isError: false } };
          }
        } catch {}
      }
    } else if (toolName === "drag") {
      const cached = axCache.get(String(args.app || "").trim().toLowerCase());
      const pid = cached?.pid || 0;
      const scale = cached?.scale || 1.0;
      const fx = Math.round(Number(args.from_x) / scale);
      const fy = Math.round(Number(args.from_y) / scale);
      const tx = Math.round(Number(args.to_x) / scale);
      const ty = Math.round(Number(args.to_y) / scale);
      await overlay.move(pid, fx, fy, "AI 拖拽起点");
      await sleep(90);
      await overlay.click(pid, tx, ty, "AI 拖拽终点");
      if (scale < 0.999) {
        args.from_x = fx;
        args.from_y = fy;
        args.to_x = tx;
        args.to_y = ty;
      }
    } else if (toolName === "perform_secondary_action") {
      const tgt = resolveCachedTarget(args.app, args.element_index);
      if (tgt.x !== null && tgt.y !== null) {
        await overlay.click(tgt.pid, tgt.x, tgt.y, `AI 操作: ${tgt.label}`);
        if (leadMs > 0) await sleep(leadMs);
      } else {
        await overlay.status(tgt.pid, `AI 操作: ${tgt.label}`);
      }
    }

    if (
      config.autoFocusBeforeGlobalInput &&
      ((toolName === "click" && args.click_method === "global") ||
        (toolName === "press_key" && args.key_method === "global"))
    ) {
      try {
        const pid = await resolvePidForApp(args.app);
        if (pid) {
          await bridge.call("focus_window", { pid, app: args.app });
          await sleep(80);
        }
      } catch {}
    }

    if (args.app && toolName !== "list_apps") {
      const cachedScale = axCache.get(String(args.app).trim().toLowerCase())?.scale || 1.0;
      if (toolName === "click" && cachedScale < 0.999 && typeof args.x === "number" && typeof args.y === "number") {
        args.x = Math.round(args.x / cachedScale);
        args.y = Math.round(args.y / cachedScale);
      }
      await ensureUpstreamPrimed(args.app);
    }

    const up = await upstream.request("tools/call", { name: toolName, arguments: args });
    cacheAxStateFromResponse(args.app, up, 1.0);
    return up;
  }

  async function handleRequest(req) {
    const { id, method, params = {} } = req;

    if (method === "initialize") {
      const up = await upstream.request(method, params);
      if (up.result) {
        const ver = up.result.serverInfo?.version || "1.0.0";
        up.result.serverInfo = {
          ...(up.result.serverInfo || { name: "open-computer-use" }),
          version: `${ver}+${PATCH_VERSION}`,
        };
        const patchNote =
          "\n\n[Windows Compatibility & Speed Patch Active] Includes resident compiled C# fast-path (`list_apps`, `get_app_state` with scaled JPEG + pruned UIA tree, fast `click`/`type_text`/`press_key`/`set_value`/`scroll` without redundant post-action snapshots), `batch_actions`, `launch_app` (with auto-launch on `get_app_state`), `focus_window`, background DWM `PrintWindow` screenshot capture, and the Windows visual virtual-cursor + edge-marquee overlay.";
        up.result.instructions = `${up.result.instructions || ""}${patchNote}`;
      }
      return { jsonrpc: "2.0", id, ...(up.error ? { error: up.error } : { result: up.result }) };
    }

    if (method === "tools/list") {
      const up = await upstream.request(method, params);
      if (up.result && Array.isArray(up.result.tools)) {
        const tools = up.result.tools.map(t => {
          if (t?.name === "get_app_state" && t.inputSchema?.properties && config.autoLaunchOnAppNotFound) {
            return {
              ...t,
              inputSchema: {
                ...t.inputSchema,
                properties: {
                  ...t.inputSchema.properties,
                  auto_launch: {
                    type: "boolean",
                    default: true,
                    description: "Patch option: auto-launch the Windows app if not currently open.",
                  },
                },
              },
            };
          }
          return t;
        });
        const existingNames = new Set(tools.map(t => t?.name).filter(Boolean));
        tools.push(...buildPatchTools(existingNames, config));
        up.result.tools = tools;
      }
      return { jsonrpc: "2.0", id, ...(up.error ? { error: up.error } : { result: up.result }) };
    }

    if (method === "tools/call") {
      const res = await executeToolCall(params.name, params.arguments || {});
      return { jsonrpc: "2.0", id, ...(res.error ? { error: res.error } : { result: res.result }) };
    }

    const up = await upstream.request(method, params);
    return { jsonrpc: "2.0", id, ...(up.error ? { error: up.error } : { result: up.result }) };
  }

  let stdinBuffer = "";
  let queue = Promise.resolve();

  process.stdin.setEncoding("utf8");
  process.stdin.on("data", chunk => {
    stdinBuffer += chunk;
    for (;;) {
      const idx = stdinBuffer.indexOf("\n");
      if (idx < 0) break;
      const line = stdinBuffer.slice(0, idx).trim();
      stdinBuffer = stdinBuffer.slice(idx + 1);
      if (!line) continue;

      let req;
      try {
        req = JSON.parse(line);
      } catch {
        process.stdout.write(
          `${JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } })}\n`
        );
        continue;
      }

      if (req.id === undefined) {
        if (req.method === "notifications/turn-ended") {
          overlay.hide();
        }
        upstream.notify(req.method, req.params);
        continue;
      }

      queue = queue
        .then(() => handleRequest(req))
        .then(res => {
          process.stdout.write(`${JSON.stringify(res)}\n`);
        })
        .catch(err => {
          process.stdout.write(
            `${JSON.stringify({
              jsonrpc: "2.0",
              id: req.id,
              error: { code: -32603, message: err instanceof Error ? err.message : String(err) },
            })}\n`
          );
        });
    }
  });

  const shutdown = () => {
    overlay.close();
    bridge.close();
    upstream.close();
  };

  process.stdin.on("end", () => {
    void queue.finally(() => {
      shutdown();
      process.exit(0);
    });
  });
  for (const sig of ["SIGINT", "SIGTERM"]) {
    process.on(sig, () => {
      shutdown();
      process.exit(0);
    });
  }
}

main().catch(err => {
  console.error(`open-computer-use patch proxy failed: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
