#!/usr/bin/env node
/**
 * LoL Game Relay — SENDER (macOS) — NODE.JS VERSION
 * ===================================================
 * • Watches for the League of Legends GAME process
 * • Captures all launch args + env vars
 * • Auto-detects active LAN IPs on the network and sends to all / chosen one
 * • Kills the local game process after capture
 * • Fully terminal-based with colored output
 *
 * Dependencies: ps-list  (auto-installed by the .sh launcher)
 */

"use strict";

const net        = require("net");
const os         = require("os");
const { execSync, exec } = require("child_process");
const readline   = require("readline");

// ── Lazy-load ps-list (ESM) ──────────────────────────────────────────────────
let psListFn = null;
async function psList() {
  if (!psListFn) {
    const mod = await import("ps-list");
    psListFn  = mod.default;
  }
  return psListFn();
}

// ── ANSI Colors ───────────────────────────────────────────────────────────────
const R  = "\x1b[0m";
const B  = "\x1b[1m";
const RED    = "\x1b[91m";
const GREEN  = "\x1b[92m";
const YELLOW = "\x1b[93m";
const CYAN   = "\x1b[96m";
const GOLD   = "\x1b[33m";
const SUBTLE = "\x1b[90m";
const WHITE  = "\x1b[97m";

// ── Config ────────────────────────────────────────────────────────────────────
const DEFAULT_PORT       = 54321;
const POLL_INTERVAL_MS   = 1000;
const CMDLINE_WAIT_MS    = 10_000;
const CMDLINE_POLL_MS    = 300;
const MIN_ARGS           = 5;

const GAME_KEYWORDS    = ["leagueoflegends", "league of legends", "league_of_legends"];
const EXCLUDE_KEYWORDS = ["leagueclient", "leagueclientux", "riotclientservices",
                          "riotclientux", "patcher", "crashhandler"];

// ── State ─────────────────────────────────────────────────────────────────────
let watching   = false;
let seenPids   = new Set();
let transfers  = 0;
let watchTimer = null;

// ── Logging ───────────────────────────────────────────────────────────────────
function ts() { return new Date().toTimeString().slice(0,8); }

function log(msg, color = "", bold = false) {
  const style = (bold ? B : "") + color;
  process.stdout.write(`${SUBTLE}[${ts()}]${R}  ${style}${msg}${R}\n`);
}

function banner() {
  console.log();
  console.log(`${GOLD}${B}${"=".repeat(56)}${R}`);
  console.log(`${GOLD}${B}  ⚡  LoL RELAY  ·  SENDER  [macOS]  —  NODE.JS${R}`);
  console.log(`${GOLD}${B}${"=".repeat(56)}${R}`);
  console.log(`${SUBTLE}  Host: ${os.hostname()}${R}`);
  console.log();
}

// ── Network helpers ───────────────────────────────────────────────────────────

/**
 * Returns all non-loopback IPv4 addresses on this machine.
 */
function getLocalIPs() {
  const ifaces = os.networkInterfaces();
  const ips = [];
  for (const name of Object.keys(ifaces)) {
    for (const iface of ifaces[name]) {
      if (iface.family === "IPv4" && !iface.internal) {
        ips.push({ name, address: iface.address, netmask: iface.netmask });
      }
    }
  }
  return ips;
}

/**
 * Ping-scan the /24 subnet of `localIP` and return hosts that respond.
 * Uses fping if available, otherwise falls back to sequential ping.
 * Returns an array of IP strings.
 */
async function scanSubnet(localIP) {
  const base = localIP.split(".").slice(0, 3).join(".");
  log(`Scanning ${base}.0/24 for live hosts …`, CYAN);

  // Try fping first (fast)
  try {
    execSync("which fping", { stdio: "ignore" });
    const result = execSync(
      `fping -a -g ${base}.1 ${base}.254 2>/dev/null`,
      { timeout: 8000, encoding: "utf8" }
    );
    return result.trim().split("\n").filter(Boolean).filter(ip => ip !== localIP);
  } catch (_) {/* fping not available or failed */}

  // Fallback: parallel ping sweep
  const promises = [];
  for (let i = 1; i <= 254; i++) {
    const ip = `${base}.${i}`;
    if (ip === localIP) continue;
    promises.push(new Promise(resolve => {
      exec(`ping -c 1 -W 1 ${ip}`, (err) => resolve(err ? null : ip));
    }));
  }
  const results = await Promise.all(promises);
  return results.filter(Boolean);
}

/**
 * Try TCP-connecting to `ip:port` to see if a receiver is listening.
 */
function probePort(ip, port) {
  return new Promise(resolve => {
    const s = new net.Socket();
    s.setTimeout(1500);
    s.once("connect",  () => { s.destroy(); resolve(true);  });
    s.once("error",    () => { s.destroy(); resolve(false); });
    s.once("timeout",  () => { s.destroy(); resolve(false); });
    s.connect(port, ip);
  });
}

/**
 * Auto-detect receiver: scan LAN and find hosts with the relay port open.
 * Returns array of IPs with the port open.
 */
async function autoDetectReceivers(port) {
  const localIPs = getLocalIPs();
  if (localIPs.length === 0) {
    log("No active network interfaces found.", RED);
    return [];
  }

  log(`Local interfaces: ${localIPs.map(i => `${i.name}(${i.address})`).join(", ")}`, SUBTLE);

  // Collect all live hosts across all subnets
  let liveHosts = [];
  for (const iface of localIPs) {
    const hosts = await scanSubnet(iface.address);
    liveHosts.push(...hosts);
  }

  // Deduplicate
  liveHosts = [...new Set(liveHosts)];
  log(`Found ${liveHosts.length} live host(s) — probing port ${port} …`, CYAN);

  // Probe port in parallel
  const probeResults = await Promise.all(
    liveHosts.map(async ip => ({ ip, open: await probePort(ip, port) }))
  );

  const receivers = probeResults.filter(r => r.open).map(r => r.ip);
  return receivers;
}

// ── Send payload ──────────────────────────────────────────────────────────────

function sendPayload(info, ip, port) {
  return new Promise(resolve => {
    const payload = Buffer.from(JSON.stringify(info), "utf8");
    const header  = Buffer.alloc(8);
    header.writeBigUInt64BE(BigInt(payload.length));

    const s = new net.Socket();
    s.setTimeout(10_000);

    s.connect(port, ip, () => {
      s.write(Buffer.concat([header, payload]), () => {
        s.end();
        resolve({ ok: true, msg: `✓  Sent ${payload.length.toLocaleString()} bytes to ${ip}:${port}` });
      });
    });

    s.on("error", err => {
      s.destroy();
      if (err.code === "ECONNREFUSED")
        resolve({ ok: false, msg: `✗  Connection refused — is the receiver running on ${ip}:${port}?` });
      else
        resolve({ ok: false, msg: `✗  Network error: ${err.message}` });
    });

    s.on("timeout", () => {
      s.destroy();
      resolve({ ok: false, msg: `✗  Timeout connecting to ${ip}:${port}` });
    });
  });
}

// ── Process helpers ───────────────────────────────────────────────────────────

function isGameProcess(proc) {
  const identity = `${(proc.name || "").toLowerCase()} ${(proc.cmd || "").toLowerCase()}`;
  if (!GAME_KEYWORDS.some(k => identity.includes(k))) return false;
  if (EXCLUDE_KEYWORDS.some(k => identity.includes(k))) return false;
  return true;
}

/**
 * Get full cmdline for a PID via `ps`.
 * ps-list often gives a truncated cmd; we use ps -p PID -o args= for the full one.
 */
function getFullCmdline(pid) {
  try {
    const raw = execSync(`ps -p ${pid} -o args=`, { encoding: "utf8", timeout: 3000 }).trim();
    if (!raw) return [];
    return raw.split(/\s+/);
  } catch (_) {
    return [];
  }
}

/**
 * Poll until cmdline has >= MIN_ARGS tokens or timeout.
 */
async function waitForFullCmdline(pid) {
  const deadline = Date.now() + CMDLINE_WAIT_MS;
  const start    = Date.now();
  while (Date.now() < deadline) {
    const args = getFullCmdline(pid);
    if (args.length >= MIN_ARGS) {
      return { args, elapsed: ((Date.now() - start) / 1000).toFixed(2) };
    }
    log(`  Waiting for args … (${args.length} so far)`, SUBTLE);
    await sleep(CMDLINE_POLL_MS);
  }
  return { args: [], elapsed: (CMDLINE_WAIT_MS / 1000).toFixed(2) };
}

/**
 * Collect process info (exe path, cwd, env) via proc filesystem / lsof.
 */
function collectInfo(pid, name, cmdline) {
  const info = { pid, name, cmdline, exe: "", cwd: "", environ: {}, created: Date.now() / 1000 };

  // exe
  try { info.exe = execSync(`lsof -p ${pid} -Fn | grep '^n' | head -1`, { encoding: "utf8" }).trim().slice(1); } catch (_) {}
  try { info.exe = execSync(`ps -p ${pid} -o comm=`, { encoding: "utf8" }).trim(); } catch (_) {}

  // cwd
  try { info.cwd = execSync(`lsof -p ${pid} -a -d cwd -Fn | grep '^n'`, { encoding: "utf8" }).trim().slice(1); } catch (_) {}

  // environ from /proc (Linux) or `ps eww` (macOS)
  try {
    const envRaw = execSync(`ps eww -p ${pid} -o command=`, { encoding: "utf8", timeout: 3000 });
    // ps eww appends env vars after the command, separated by spaces in KEY=VAL format
    const envPart = envRaw.slice(envRaw.indexOf(" ") + 1);
    const pairs   = envPart.match(/\b([A-Z_][A-Z0-9_]*)=([^\s]*)/g) || [];
    for (const pair of pairs) {
      const eq = pair.indexOf("=");
      info.environ[pair.slice(0, eq)] = pair.slice(eq + 1);
    }
  } catch (_) {}

  return info;
}

function killProcess(pid) {
  try {
    process.kill(pid, "SIGTERM");
    return "SIGTERM — graceful";
  } catch (e) {
    if (e.code === "EPERM") {
      try {
        execSync(`sudo kill -9 ${pid}`, { timeout: 5000 });
        return `killed via sudo kill -9 (PID ${pid})`;
      } catch (e2) {
        return `ACCESS DENIED + sudo failed: ${e2.message}  → run with sudo`;
      }
    }
    return `already gone (${e.code})`;
  }
}

// ── Capture & relay ───────────────────────────────────────────────────────────

async function captureAndRelay(proc, receivers, port) {
  const { pid, name } = proc;
  log(`Game process found:  PID=${pid}  Name=${name}`, GREEN, true);
  log(`Waiting for process to fully load args (max ${CMDLINE_WAIT_MS / 1000}s) …`, YELLOW);

  const { args, elapsed } = await waitForFullCmdline(pid);

  if (!args.length) {
    log(`⚠  Timeout waiting for args — process may have exited early.`, RED);
    return;
  }

  log(`Args ready:  ${args.length} tokens captured in ${elapsed}s`, GREEN);

  const info = collectInfo(pid, name, args);

  log("── Launch Arguments ──", GOLD, true);
  args.forEach((arg, i) => {
    log(`  [${String(i).padStart(2, "0")}]  ${arg}`, i === 0 ? GOLD : WHITE);
  });
  log(`── Environment: ${Object.keys(info.environ).length} vars captured ──`, SUBTLE);

  // Kill local process
  const killResult = killProcess(pid);
  log(`Local process killed: ${killResult}`, YELLOW);

  // Send to all detected receivers
  for (const ip of receivers) {
    log(`Sending to ${ip}:${port} …`, CYAN);
    const { ok, msg } = await sendPayload(info, ip, port);
    log(msg, ok ? GREEN : RED, true);
    if (ok) {
      transfers++;
      log(`Total transfers this session: ${transfers}`, GREEN);
    }
  }
}

// ── Watch loop ────────────────────────────────────────────────────────────────

async function watchLoop(receivers, port) {
  if (!watching) return;
  log("Watcher tick …", SUBTLE);

  try {
    const procs = await psList();
    for (const proc of procs) {
      if (!watching) break;
      if (seenPids.has(proc.pid)) continue;
      if (isGameProcess(proc)) {
        seenPids.add(proc.pid);
        captureAndRelay(proc, receivers, port).catch(e => log(`Error: ${e.message}`, RED));
      }
    }
  } catch (e) {
    log(`Watch error: ${e.message}`, RED);
  }

  if (watching) {
    watchTimer = setTimeout(() => watchLoop(receivers, port), POLL_INTERVAL_MS);
  }
}

function startWatching(receivers, port) {
  if (watching) { log("Already watching!", YELLOW); return; }
  watching  = true;
  seenPids  = new Set();
  log("Watcher started — waiting for game …", YELLOW, true);
  watchLoop(receivers, port);
}

function stopWatching() {
  watching = false;
  if (watchTimer) { clearTimeout(watchTimer); watchTimer = null; }
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function ask(rl, prompt, def) {
  return new Promise(resolve => {
    rl.question(`${CYAN}${prompt}${R} [${SUBTLE}${def}${R}]: `, ans => {
      resolve(ans.trim() || def);
    });
  });
}

// ── Main ──────────────────────────────────────────────────────────────────────
async function main() {
  banner();

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

  // Port config
  console.log(`${GOLD}── Configuration ──────────────────────────────${R}`);
  const portStr = await ask(rl, "Receiver Port", String(DEFAULT_PORT));
  const port    = parseInt(portStr, 10) || DEFAULT_PORT;
  console.log();

  // Auto-detect receivers
  log("Auto-detecting receiver(s) on LAN …", CYAN, true);
  let receivers = await autoDetectReceivers(port);

  if (receivers.length === 0) {
    log("No receivers auto-detected. Enter IP manually.", YELLOW);
    const manualIP = await ask(rl, "Receiver IP", "192.168.1.XXX");
    receivers = [manualIP];
  } else {
    log(`Auto-detected ${receivers.length} receiver(s): ${receivers.join(", ")}`, GREEN, true);
    const confirm = await ask(rl, `Use these? (y/n)`, "y");
    if (confirm.toLowerCase() !== "y") {
      const manualIP = await ask(rl, "Receiver IP", receivers[0]);
      receivers = [manualIP];
    }
  }

  console.log();
  log(`Target(s): ${receivers.join(", ")}  Port: ${port}`, CYAN, true);
  log(`Host:      ${os.hostname()}`, CYAN);
  console.log();

  // Command loop
  console.log(`${GOLD}── Commands ────────────────────────────────────${R}`);
  console.log(`  ${GREEN}s${R}      → Start watching`);
  console.log(`  ${RED}stop${R}   → Stop watching`);
  console.log(`  ${CYAN}status${R} → Show status`);
  console.log(`  ${RED}q${R}      → Quit`);
  console.log(`  ${SUBTLE}Press Ctrl+C at any time to exit${R}`);
  console.log();

  process.on("SIGINT", () => {
    console.log();
    log("Interrupt received — stopping …", YELLOW);
    stopWatching();
    rl.close();
    process.exit(0);
  });

  const prompt = () => {
    rl.question(`${GOLD}>${R} `, async cmd => {
      cmd = cmd.trim().toLowerCase();

      if (cmd === "s") {
        startWatching(receivers, port);
      } else if (cmd === "stop") {
        if (watching) { stopWatching(); log("Watcher stopped.", SUBTLE); }
        else           { log("Not watching.", SUBTLE); }
      } else if (cmd === "status") {
        const state = watching
          ? `${GREEN}WATCHING${R}`
          : `${RED}IDLE${R}`;
        log(`Status: ${state}  |  Transfers: ${transfers}  |  Targets: ${receivers.join(", ")}`, CYAN);
      } else if (cmd === "q") {
        stopWatching();
        log("Goodbye.", SUBTLE);
        rl.close();
        return;
      } else if (cmd === "help") {
        console.log(`  ${GREEN}s${R}      — start watching`);
        console.log(`  ${RED}stop${R}   — stop watching`);
        console.log(`  ${CYAN}status${R} — show current status`);
        console.log(`  ${RED}q${R}      — quit`);
      } else if (cmd !== "") {
        log(`Unknown command '${cmd}'. Type 'help' for commands.`, SUBTLE);
      }

      prompt();
    });
  };

  prompt();
}

main().catch(e => { console.error(e); process.exit(1); });
