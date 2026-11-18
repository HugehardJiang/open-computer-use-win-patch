#!/usr/bin/env node
import { execFileSync, spawn } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, "..");
const PATCH_SRC_DIR = path.join(REPO_ROOT, "patch");
const SKILL_SRC_FILE = path.join(REPO_ROOT, "skills", "open-computer-use-win-patch", "SKILL.md");
const README_SRC_FILE = path.join(REPO_ROOT, "README.md");

const UTF8_BOM = Buffer.from([0xef, 0xbb, 0xbf]);

function printHelp() {
  console.log(`
open-computer-use-win-patch installer & doctor

Usage:
  node scripts/install.mjs [options]
  npx -y github:HugehardJiang/open-computer-use-win-patch [options]

Options:
  --client <target>     auto (default) | antigravity | cursor | windsurf | claude-desktop | all
  --mcp-config <path>   Explicit MCP config JSON path to wire (repeatable)
  --dest <path>         Custom patch install directory
  --skip-upstream       Do not run 'npm.cmd install -g open-computer-use' if missing
  --no-overlay          Disable visual cursor & edge marquee in patch-config.json
  --no-skill            Skip deploying SKILL.md to ~/.gemini/config/skills/
  --doctor              Run 3-stage verification only without reinstalling
  --uninstall           Revert MCP config back to upstream open-computer-use
  --purge               Used with --uninstall to also delete patch & skill files
  -h, --help            Show this help message
`.trim());
}

function parseArgs(argv) {
  const opts = {
    client: "auto",
    mcpConfigs: [],
    dest: "",
    skipUpstream: false,
    noOverlay: false,
    noSkill: false,
    doctor: false,
    uninstall: false,
    purge: false,
    help: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      opts.help = true;
    } else if (arg === "--doctor") {
      opts.doctor = true;
    } else if (arg === "--uninstall") {
      opts.uninstall = true;
    } else if (arg === "--purge") {
      opts.purge = true;
    } else if (arg === "--skip-upstream") {
      opts.skipUpstream = true;
    } else if (arg === "--no-overlay") {
      opts.noOverlay = true;
    } else if (arg === "--no-skill") {
      opts.noSkill = true;
    } else if (arg === "--client") {
      opts.client = (argv[++i] || "auto").toLowerCase();
    } else if (arg.startsWith("--client=")) {
      opts.client = arg.slice("--client=".length).toLowerCase();
    } else if (arg === "--dest") {
      opts.dest = argv[++i] || "";
    } else if (arg.startsWith("--dest=")) {
      opts.dest = arg.slice("--dest=".length);
    } else if (arg === "--mcp-config") {
      const val = argv[++i];
      if (val) opts.mcpConfigs.push(path.resolve(val));
    } else if (arg.startsWith("--mcp-config=")) {
      const val = arg.slice("--mcp-config=".length);
      if (val) opts.mcpConfigs.push(path.resolve(val));
    } else {
      throw new Error(`Unknown option: ${arg}`);
    }
  }

  const allowedClients = new Set([
    "auto",
    "antigravity",
    "cursor",
    "windsurf",
    "claude-desktop",
    "all",
  ]);
  if (!allowedClients.has(opts.client)) {
    throw new Error(`Invalid --client '${opts.client}'. Expected: ${[...allowedClients].join(", ")}`);
  }
  return opts;
}

function resolveDefaultDest(clientMode) {
  const home = os.homedir();
  const geminiDir = path.join(home, ".gemini");
  if (clientMode === "antigravity" || (clientMode === "auto" && existsSync(geminiDir))) {
    return path.join(geminiDir, "config", "patches", "open-computer-use");
  }
  return path.join(home, ".open-computer-use-win-patch");
}

function locateUpstreamRoot() {
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
    // Fall through to null.
  }

  return null;
}

function ensureUpstreamInstalled(skipInstall) {
  let root = locateUpstreamRoot();
  if (root) return root;
  if (skipInstall) return null;

  console.log("[1/5] Global 'open-computer-use' not found. Installing via npm.cmd install -g open-computer-use ...");
  const comspec = process.env.ComSpec || "cmd.exe";
  execFileSync(comspec, ["/c", "npm.cmd", "install", "-g", "open-computer-use"], {
    stdio: "inherit",
    windowsHide: true,
  });
  root = locateUpstreamRoot();
  if (!root) {
    throw new Error("Installed 'open-computer-use', but could not locate bin/open-computer-use globally.");
  }
  return root;
}

function ensureUtf8BomBuffer(buf) {
  if (buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) {
    return buf;
  }
  return Buffer.concat([UTF8_BOM, buf]);
}

function hasUtf8Bom(filePath) {
  const buf = readFileSync(filePath);
  return buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf;
}

function mergePatchConfig(templatePath, targetPath, disableOverlay) {
  const tpl = JSON.parse(readFileSync(templatePath, "utf8"));
  let current = {};
  let preservedExisting = false;

  if (existsSync(targetPath)) {
    try {
      const parsed = JSON.parse(readFileSync(targetPath, "utf8"));
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        current = parsed;
        preservedExisting = true;
      }
    } catch {
      writeFileSync(`${targetPath}.broken.bak`, readFileSync(targetPath));
    }
  }

  const merged = {
    ...tpl,
    ...current,
    appAliases: {
      ...(tpl.appAliases || {}),
      ...(current.appAliases || {}),
    },
  };
  if (disableOverlay) {
    merged.enableVisualOverlay = false;
  }

  writeFileSync(targetPath, `${JSON.stringify(merged, null, 2)}\n`, "utf8");
  return { preservedExisting };
}

function deployPatchFiles(destDir, disableOverlay) {
  mkdirSync(destDir, { recursive: true });
  copyFileSync(
    path.join(PATCH_SRC_DIR, "mcp-patch-proxy.mjs"),
    path.join(destDir, "mcp-patch-proxy.mjs")
  );
  for (const psFile of ["win32-bridge.ps1", "overlay-ui.ps1"]) {
    const raw = readFileSync(path.join(PATCH_SRC_DIR, psFile));
    writeFileSync(path.join(destDir, psFile), ensureUtf8BomBuffer(raw));
  }
  if (existsSync(README_SRC_FILE)) {
    copyFileSync(README_SRC_FILE, path.join(destDir, "README.md"));
  }
  return mergePatchConfig(
    path.join(PATCH_SRC_DIR, "patch-config.json"),
    path.join(destDir, "patch-config.json"),
    disableOverlay
  );
}

function recyclePatchWorkers(destDir) {
  const safeNeedle = destDir.replace(/'/g, "''").toLowerCase();
  const psCommand = [
    "$targets = @('win32-bridge.ps1', 'overlay-ui.ps1')",
    "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" -ErrorAction SilentlyContinue | ForEach-Object {",
    "  $cmd = [string]$_.CommandLine",
    "  if (-not $cmd) { return }",
    "  $low = $cmd.ToLowerInvariant()",
    `  if ($low.Contains('${safeNeedle}') -or $low.Contains('patches\\open-computer-use\\win32-bridge.ps1')) {`,
    "    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue",
    "    Write-Output $_.ProcessId",
    "  }",
    "}",
  ].join("; ");

  try {
    const out = execFileSync(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", psCommand],
      { encoding: "utf8", windowsHide: true }
    ).trim();
    return out ? out.split(/\r?\n/).filter(Boolean) : [];
  } catch {
    return [];
  }
}

function resolveClientConfigs(clientMode, explicitConfigs) {
  const home = os.homedir();
  const appData = process.env.APPDATA || path.join(home, "AppData", "Roaming");
  const geminiRoot = path.join(home, ".gemini");

  const known = {
    antigravity: path.join(geminiRoot, "config", "mcp_config.json"),
    cursor: path.join(home, ".cursor", "mcp.json"),
    windsurf: path.join(home, ".codeium", "windsurf", "mcp_config.json"),
    "claude-desktop": path.join(appData, "Claude", "claude_desktop_config.json"),
  };

  const selected = [];
  if (clientMode === "auto") {
    if (existsSync(geminiRoot) || existsSync(known.antigravity)) {
      selected.push(known.antigravity);
    }
    for (const key of ["cursor", "windsurf", "claude-desktop"]) {
      if (existsSync(known[key])) {
        selected.push(known[key]);
      }
    }
    if (selected.length === 0 && explicitConfigs.length === 0) {
      selected.push(known.antigravity);
    }
  } else if (clientMode === "all") {
    selected.push(known.antigravity);
    for (const key of ["cursor", "windsurf", "claude-desktop"]) {
      if (existsSync(known[key]) || existsSync(path.dirname(known[key]))) {
        selected.push(known[key]);
      }
    }
  } else {
    selected.push(known[clientMode]);
  }

  const deduped = new Map();
  for (const p of [...selected, ...explicitConfigs]) {
    const resolved = path.resolve(p);
    deduped.set(resolved.toLowerCase(), resolved);
  }
  return [...deduped.values()];
}

function wireMcpConfigFile(filePath, desiredEntry) {
  const existed = existsSync(filePath);
  let rawBefore = "";
  let parsed = {};

  if (existed) {
    rawBefore = readFileSync(filePath, "utf8");
    if (rawBefore.trim()) {
      parsed = JSON.parse(rawBefore);
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error(`Invalid JSON object in MCP config: ${filePath}`);
    }
  }

  if (!parsed.mcpServers || typeof parsed.mcpServers !== "object" || Array.isArray(parsed.mcpServers)) {
    parsed.mcpServers = {};
  }

  const prev = parsed.mcpServers["open-computer-use"];
  if (prev && JSON.stringify(prev) === JSON.stringify(desiredEntry)) {
    return { path: filePath, status: "unchanged" };
  }

  if (existed && rawBefore) {
    writeFileSync(`${filePath}.bak`, rawBefore, "utf8");
  }
  mkdirSync(path.dirname(filePath), { recursive: true });
  parsed.mcpServers["open-computer-use"] = desiredEntry;
  writeFileSync(filePath, `${JSON.stringify(parsed, null, 2)}\n`, "utf8");
  return { path: filePath, status: existed ? "updated" : "created" };
}

function unhookMcpConfigFile(filePath, upstreamRoot) {
  if (!existsSync(filePath)) return { path: filePath, status: "missing" };
  const rawBefore = readFileSync(filePath, "utf8");
  const parsed = rawBefore.trim() ? JSON.parse(rawBefore) : {};
  const servers = parsed?.mcpServers;
  if (!servers || typeof servers !== "object" || !servers["open-computer-use"]) {
    return { path: filePath, status: "not_configured" };
  }

  const upstreamBin = upstreamRoot ? path.join(upstreamRoot, "bin", "open-computer-use") : null;
  const restoredEntry =
    upstreamBin && existsSync(upstreamBin)
      ? { command: process.execPath, args: [upstreamBin, "mcp"] }
      : { command: "cmd.exe", args: ["/c", "npx.cmd", "-y", "open-computer-use", "mcp"] };

  if (JSON.stringify(servers["open-computer-use"]) === JSON.stringify(restoredEntry)) {
    return { path: filePath, status: "unchanged" };
  }

  writeFileSync(`${filePath}.bak`, rawBefore, "utf8");
  servers["open-computer-use"] = restoredEntry;
  writeFileSync(filePath, `${JSON.stringify(parsed, null, 2)}\n`, "utf8");
  return { path: filePath, status: "reverted" };
}

function deployAntigravitySkill(skipSkill) {
  if (skipSkill || !existsSync(SKILL_SRC_FILE)) return null;
  const geminiRoot = path.join(os.homedir(), ".gemini");
  if (!existsSync(geminiRoot)) return null;
  const target = path.join(geminiRoot, "config", "skills", "open-computer-use-win-patch", "SKILL.md");
  mkdirSync(path.dirname(target), { recursive: true });
  copyFileSync(SKILL_SRC_FILE, target);
  return target;
}

function testBridgeHandshake(bridgePath) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", bridgePath],
      { stdio: ["pipe", "pipe", "pipe"], windowsHide: true }
    );
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      try { child.kill(); } catch {}
      reject(new Error(`win32-bridge.ps1 doctor check timed out. stderr=${stderr.trim()}`));
    }, 25_000);

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", c => {
      stdout += c;
      if (stdout.includes('"ready":true')) {
        try { child.stdin.end(); } catch {}
      }
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", c => { stderr += c; });
    child.on("error", err => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("exit", code => {
      clearTimeout(timer);
      if (code !== 0 || !stdout.includes('"ready":true')) {
        reject(new Error(`win32-bridge.ps1 failed (code=${code}): stdout=${stdout.trim()} stderr=${stderr.trim()}`));
        return;
      }
      resolve(true);
    });
    child.stdin.end();
  });
}

function testOverlayHandshake(overlayPath) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "powershell.exe",
      ["-Sta", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", overlayPath],
      { stdio: ["pipe", "pipe", "pipe"], windowsHide: true }
    );
    let stdout = "";
    let stderr = "";
    let sentExit = false;
    const timer = setTimeout(() => {
      try { child.kill(); } catch {}
      reject(new Error(`overlay-ui.ps1 doctor check timed out. stdout=${stdout.trim()} stderr=${stderr.trim()}`));
    }, 15_000);

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", c => {
      stdout += c;
      if (!sentExit && stdout.includes("READY")) {
        sentExit = true;
        try {
          child.stdin.write("EXIT\n");
          child.stdin.end();
        } catch {}
      }
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", c => { stderr += c; });
    child.on("error", err => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("exit", code => {
      clearTimeout(timer);
      if (code !== 0 || !stdout.includes("READY")) {
        reject(new Error(`overlay-ui.ps1 failed (code=${code}): stdout=${stdout.trim()} stderr=${stderr.trim()}`));
        return;
      }
      resolve(true);
    });
  });
}

function testMcpProxyHandshake(proxyPath) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [proxyPath], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    let buffer = "";
    let stderr = "";
    let serverVersion = "";
    let toolNames = [];
    let phase = 1;

    const timer = setTimeout(() => {
      try { child.kill(); } catch {}
      reject(new Error(`mcp-patch-proxy.mjs doctor handshake timed out (phase=${phase}). stderr=${stderr.trim()}`));
    }, 25_000);

    const finish = err => {
      clearTimeout(timer);
      try { child.stdin.end(); } catch {}
      try { child.kill(); } catch {}
      if (err) reject(err);
      else resolve({ serverVersion, toolNames });
    };

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", chunk => {
      buffer += chunk;
      for (;;) {
        const idx = buffer.indexOf("\n");
        if (idx < 0) break;
        const line = buffer.slice(0, idx).trim();
        buffer = buffer.slice(idx + 1);
        if (!line) continue;
        let msg;
        try {
          msg = JSON.parse(line);
        } catch {
          continue;
        }
        if (msg.id === 1) {
          if (msg.error) {
            finish(new Error(`MCP initialize error: ${msg.error.message}`));
            return;
          }
          serverVersion = msg.result?.serverInfo?.version || "";
          phase = 2;
          child.stdin.write(
            `${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized", params: {} })}\n`
          );
          child.stdin.write(
            `${JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} })}\n`
          );
        } else if (msg.id === 2) {
          if (msg.error) {
            finish(new Error(`MCP tools/list error: ${msg.error.message}`));
            return;
          }
          toolNames = (msg.result?.tools || []).map(t => t?.name).filter(Boolean);
          const missing = ["get_app_state", "launch_app", "focus_window", "batch_actions"].filter(
            name => !toolNames.includes(name)
          );
          if (!serverVersion.includes("+win-patch.")) {
            finish(new Error(`Unexpected serverInfo.version '${serverVersion}' (expected '+win-patch.*')`));
            return;
          }
          if (missing.length > 0 || toolNames.length < 12) {
            finish(new Error(`MCP tools incomplete (count=${toolNames.length}, missing=${missing.join(",")})`));
            return;
          }
          finish(null);
          return;
        }
      }
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", c => { stderr += c; });
    child.on("error", finish);

    child.stdin.write(
      `${JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2024-11-05",
          capabilities: {},
          clientInfo: { name: "open-computer-use-win-patch-doctor", version: "1.0.0" },
        },
      })}\n`
    );
  });
}

async function runDoctor(destDir) {
  const upstreamRoot = locateUpstreamRoot();
  if (!upstreamRoot) {
    throw new Error("Global 'open-computer-use' package not found. Run installer without --skip-upstream.");
  }

  let upstreamVer = "unknown";
  try {
    upstreamVer = JSON.parse(readFileSync(path.join(upstreamRoot, "package.json"), "utf8")).version || "unknown";
  } catch {}

  const required = ["mcp-patch-proxy.mjs", "win32-bridge.ps1", "overlay-ui.ps1", "patch-config.json"];
  for (const f of required) {
    const p = path.join(destDir, f);
    if (!existsSync(p)) {
      throw new Error(`Missing patch file: ${p}`);
    }
  }
  for (const ps of ["win32-bridge.ps1", "overlay-ui.ps1"]) {
    const p = path.join(destDir, ps);
    if (!hasUtf8Bom(p)) {
      throw new Error(`PowerShell file missing UTF-8 BOM: ${p}`);
    }
  }

  await testBridgeHandshake(path.join(destDir, "win32-bridge.ps1"));
  await testOverlayHandshake(path.join(destDir, "overlay-ui.ps1"));
  const mcp = await testMcpProxyHandshake(path.join(destDir, "mcp-patch-proxy.mjs"));

  return {
    upstreamRoot,
    upstreamVer,
    serverVersion: mcp.serverVersion,
    toolCount: mcp.toolNames.length,
    toolNames: mcp.toolNames,
  };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    printHelp();
    return;
  }
  if (process.platform !== "win32") {
    throw new Error("open-computer-use-win-patch only targets Windows hosts.");
  }

  const destDir = opts.dest ? path.resolve(opts.dest) : resolveDefaultDest(opts.client);
  const configTargets = resolveClientConfigs(opts.client, opts.mcpConfigs);

  if (opts.uninstall) {
    const upstreamRoot = locateUpstreamRoot();
    const recycled = recyclePatchWorkers(destDir);
    const reverted = configTargets.map(cfg => unhookMcpConfigFile(cfg, upstreamRoot));
    let purged = false;
    if (opts.purge) {
      rmSync(destDir, { recursive: true, force: true });
      const skillDir = path.join(os.homedir(), ".gemini", "config", "skills", "open-computer-use-win-patch");
      if (existsSync(skillDir)) {
        rmSync(skillDir, { recursive: true, force: true });
      }
      purged = true;
    }
    console.log(
      JSON.stringify(
        {
          status: "UNINSTALL_OK",
          destDir,
          purged,
          recycledPids: recycled,
          mcpConfigs: reverted,
        },
        null,
        2
      )
    );
    return;
  }

  if (!opts.doctor) {
    ensureUpstreamInstalled(opts.skipUpstream);
    console.log(`[2/5] Deploying patch files to ${destDir} ...`);
    const cfgMerge = deployPatchFiles(destDir, opts.noOverlay);
    console.log(`[3/5] Recycling any active bridge workers ...`);
    const recycledPids = recyclePatchWorkers(destDir);

    console.log(`[4/5] Wiring MCP client configs ...`);
    const desiredEntry = {
      command: process.execPath,
      args: [path.join(destDir, "mcp-patch-proxy.mjs")],
    };
    const mcpResults = configTargets.map(cfg => wireMcpConfigFile(cfg, desiredEntry));
    const skillPath = deployAntigravitySkill(opts.noSkill);

    console.log(`[5/5] Running doctor self-tests ...`);
    const diag = await runDoctor(destDir);

    console.log(
      JSON.stringify(
        {
          status: "INSTALL_OK",
          destDir,
          preservedUserPatchConfig: cfgMerge.preservedExisting,
          recycledPids,
          mcpConfigs: mcpResults,
          installedSkill: skillPath,
          claudeCodeCommand: `claude mcp add -s user open-computer-use -- "${process.execPath}" "${path.join(destDir, "mcp-patch-proxy.mjs")}"`,
          doctor: diag,
        },
        null,
        2
      )
    );
    return;
  }

  const diag = await runDoctor(destDir);
  console.log(
    JSON.stringify(
      {
        status: "DOCTOR_OK",
        destDir,
        doctor: diag,
      },
      null,
      2
    )
  );
}

main().catch(err => {
  console.error(`[ERROR] ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
