#!/usr/bin/env python3
"""
LoL Game Relay — SENDER (macOS) — TERMINAL VERSION
====================================================
• Watches for the League of Legends GAME process
• Captures all launch args + env vars
• Sends them over TCP to the Windows receiver (Wise.exe compatible)
• Kills the local game process
• Fully terminal-based with colored output
• Reads account name, rank, and profile icon from League Client (LCU)

Dependencies:  pip3 install psutil
Run:           python3 lol_sender_terminal.py
"""

import base64
import json
import os
import signal
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
import psutil

# ── ANSI Colors ───────────────────────────────────────────────────────────────
RESET   = "\033[0m"
BOLD    = "\033[1m"
RED     = "\033[91m"
GREEN   = "\033[92m"
YELLOW  = "\033[93m"
CYAN    = "\033[96m"
GOLD    = "\033[33m"
SUBTLE  = "\033[90m"
WHITE   = "\033[97m"

# ── Defaults ──────────────────────────────────────────────────────────────────
DEFAULT_RECEIVER_IP   = "192.168.1.XXX"
DEFAULT_RECEIVER_PORT = 54321
POLL_INTERVAL         = 1.0
DDRAGON_VER           = "14.3.1"

GAME_KEYWORDS    = ["leagueoflegends", "league of legends"]
EXCLUDE_KEYWORDS = ["leagueclient", "leagueclientux", "riotclientservices",
                    "riotclientux", "patcher", "crashhandler"]

MIN_ARGS             = 5
CMDLINE_WAIT_TIMEOUT = 10.0
CMDLINE_POLL         = 0.3

LOCKFILE_PATHS = [
    "~/Library/Application Support/Riot Games/League of Legends/lockfile",
    "~/Library/Application Support/Riot Games/League of Legends (PBE)/lockfile",
    "~/Library/Application Support/Riot Games/Riot Client/Config/lockfile",
    "/Applications/League of Legends.app/Contents/LoL/lockfile",
]

# ── Globals ───────────────────────────────────────────────────────────────────
_watching  = False
_seen_pids = set()
_transfers = 0
_lock      = threading.Lock()
_stop      = threading.Event()

_receiver_ip   = DEFAULT_RECEIVER_IP
_receiver_port = DEFAULT_RECEIVER_PORT

_lcu_online   = False
_lcu_summoner = ""
_cached_profile = None

# ── Logging ───────────────────────────────────────────────────────────────────

def log(msg, color="", bold=False):
    ts    = time.strftime("%H:%M:%S")
    style = (BOLD if bold else "") + color
    print(f"{SUBTLE}[{ts}]{RESET}  {style}{msg}{RESET}", flush=True)


def banner():
    print(flush=True)
    print(f"{GOLD}{BOLD}{'='*56}{RESET}")
    print(f"{GOLD}{BOLD}  ⚡  LoL RELAY  ·  SENDER  [macOS]  —  TERMINAL{RESET}")
    print(f"{GOLD}{BOLD}{'='*56}{RESET}")
    print(f"{SUBTLE}  Host: {socket.gethostname()}{RESET}")
    print(flush=True)


def print_status(label, color):
    print(f"\r{color}{BOLD}  ● STATUS: {label}{RESET}          ", flush=True)

# ── LCU (League Client — name, rank, icon) ───────────────────────────────────

def _extract_flag(text, prefix):
    idx = text.find(prefix)
    if idx == -1:
        return None
    start = idx + len(prefix)
    end = text.find(" ", start)
    val = text[start:] if end == -1 else text[start:end]
    return val.strip("\"'")


def _collect_lockfile_paths():
    paths = []
    seen = set()
    base = Path.home() / "Library/Application Support/Riot Games"
    for pattern in LOCKFILE_PATHS:
        p = Path(os.path.expanduser(pattern))
        if p.exists() and str(p) not in seen:
            seen.add(str(p))
            paths.append(p)
    if base.is_dir():
        for child in base.iterdir():
            if not child.is_dir():
                continue
            for sub in (child / "lockfile", child / "Config/lockfile"):
                if sub.exists() and str(sub) not in seen:
                    seen.add(str(sub))
                    paths.append(sub)
    return paths


def _parse_lockfile(path):
    try:
        parts = path.read_text(encoding="utf-8", errors="ignore").strip().split(":")
        if len(parts) < 5:
            return None
        port = int(parts[2])
        token = parts[3]
        if port > 0 and token:
            return port, token
    except (OSError, ValueError):
        pass
    return None


def _lcu_credentials():
    for path in _collect_lockfile_paths():
        creds = _parse_lockfile(path)
        if creds:
            return creds
    for proc in psutil.process_iter(["pid", "name"]):
        try:
            name = (proc.info.get("name") or "").lower()
            if "leagueclient" not in name:
                continue
            cmd = " ".join(proc.cmdline())
            port = _extract_flag(cmd, "--app-port=") or _extract_flag(cmd, "-RiotClientPort=")
            token = _extract_flag(cmd, "--remoting-auth-token=") or _extract_flag(
                cmd, "-RiotClientAuthToken="
            )
            if port and token:
                return int(port), token
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return None


def _lcu_request(path):
    creds = _lcu_credentials()
    if not creds:
        return None
    port, token = creds
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    auth = base64.b64encode(f"riot:{token}".encode()).decode()
    req = urllib.request.Request(
        f"https://127.0.0.1:{port}{path}",
        headers={"Authorization": f"Basic {auth}"},
    )
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=4) as resp:
            return json.loads(resp.read().decode())
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError, OSError):
        return None


def _parse_rank(ranked_json):
    if not ranked_json:
        return "Unranked"
    raw = json.dumps(ranked_json)
    pos = raw.find("RANKED_SOLO_5x5")
    if pos == -1:
        return "Unranked"
    chunk = raw[pos:]
    tier = division = ""
    for key in ("tier", "division"):
        marker = f'"{key}"'
        idx = chunk.find(marker)
        if idx == -1:
            continue
        colon = chunk.find(":", idx)
        q1 = chunk.find('"', colon + 1)
        q2 = chunk.find('"', q1 + 1)
        if q1 != -1 and q2 != -1:
            val = chunk[q1 + 1:q2]
            if key == "tier":
                tier = val
            else:
                division = val
    if not tier:
        return "Unranked"
    return tier if not division else f"{tier} {division}"


def _get_local_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def build_profile():
    summoner = _lcu_request("/lol-summoner/v1/current-summoner")
    if not summoner:
        return None
    ranked = _lcu_request("/lol-ranked/v1/current-ranked-stats")
    icon_id = summoner.get("profileIconId") or 29
    game = summoner.get("gameName") or summoner.get("displayName") or "Summoner"
    tag = summoner.get("tagLine") or ""
    name = f"{game}#{tag}" if tag else game
    host_ip = _get_local_ip()
    return {
        "type": "profile",
        "name": name,
        "level": summoner.get("summonerLevel") or 0,
        "rank": _parse_rank(ranked),
        "discord": "WISEIT",
        "meta": f"macOS Sender • {host_ip}:{DEFAULT_RECEIVER_PORT}",
        "icon_url": (
            f"https://ddragon.leagueoflegends.com/cdn/{DDRAGON_VER}/"
            f"img/profileicon/{icon_id}.png"
        ),
        "platform": "darwin",
        "host_ip": host_ip,
    }


def refresh_lcu():
    global _lcu_online, _lcu_summoner, _cached_profile
    profile = build_profile()
    if profile:
        _lcu_online = True
        _lcu_summoner = profile["name"]
        _cached_profile = profile
        return True
    _lcu_online = False
    _lcu_summoner = ""
    _cached_profile = None
    return False


def lcu_loop():
    last = False
    last_sent = None
    while not _stop.is_set():
        online = refresh_lcu()
        if online != last:
            last = online
            if online:
                log(f"League Client online — {_lcu_summoner}", GREEN, bold=True)
            else:
                log("League Client offline", YELLOW)
        if online and _cached_profile:
            key = (_cached_profile.get("name"), _cached_profile.get("rank"))
            if key != last_sent:
                ok, msg = send_payload(_cached_profile, _receiver_ip, _receiver_port)
                if ok:
                    log(f"Profile synced to Windows — {_lcu_summoner} ({_cached_profile['rank']})", CYAN)
                    last_sent = key
        time.sleep(3.0)

# ── Process helpers ───────────────────────────────────────────────────────────

def is_game_process(proc):
    try:
        name     = proc.name().lower()
        exe      = proc.exe().lower()
        cmdline  = " ".join(proc.cmdline()).lower()
        identity = f"{name} {exe} {cmdline}"
        if not any(k in identity for k in GAME_KEYWORDS):
            return False
        if any(k in identity for k in EXCLUDE_KEYWORDS):
            return False
        return True
    except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
        return False


def wait_for_full_cmdline(proc):
    deadline = time.time() + CMDLINE_WAIT_TIMEOUT
    start    = time.time()
    while time.time() < deadline:
        try:
            cmdline = proc.cmdline()
            if len(cmdline) >= MIN_ARGS:
                return cmdline, round(time.time() - start, 2)
            log(f"  Waiting for args … ({len(cmdline)} so far)", SUBTLE)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            break
        time.sleep(CMDLINE_POLL)
    return [], CMDLINE_WAIT_TIMEOUT


def collect_info(proc, full_cmdline):
    info = {}
    try:
        info["pid"]     = proc.pid
        info["name"]    = proc.name()
        info["exe"]     = proc.exe()
        info["cmdline"] = full_cmdline
        info["cwd"]     = proc.cwd()
        info["created"] = proc.create_time()
        try:
            info["environ"] = proc.environ()
        except (psutil.AccessDenied, psutil.NoSuchProcess):
            info["environ"] = {}
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        pass
    return info


def kill_process(proc):
    import subprocess as _sp
    try:
        proc.terminate()
        proc.wait(timeout=5)
        return "SIGTERM — graceful"
    except psutil.TimeoutExpired:
        try:
            proc.kill()
            proc.wait(timeout=5)
            return "SIGKILL — forced"
        except Exception:
            return "already gone after SIGKILL attempt"
    except psutil.NoSuchProcess:
        return "already gone"
    except psutil.AccessDenied:
        try:
            _sp.run(["sudo", "kill", "-9", str(proc.pid)],
                    timeout=5, check=True, capture_output=True)
            return f"killed via sudo kill -9 (PID {proc.pid})"
        except Exception as e:
            return f"ACCESS DENIED + sudo failed: {e}  → run:  sudo python3 lol_sender_terminal.py"

# ── Network ───────────────────────────────────────────────────────────────────

def send_payload(payload, ip, port):
    try:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(10)
            s.connect((ip, port))
            s.sendall(len(body).to_bytes(8, "big") + body)
        return True, f"✓  Sent {len(body):,} bytes to {ip}:{port}"
    except ConnectionRefusedError:
        return False, f"✗  Connection refused — is Wise Receiver running on {ip}:{port}?"
    except socket.timeout:
        return False, f"✗  Timeout connecting to {ip}:{port}"
    except OSError as e:
        return False, f"✗  Network error: {e}"


def build_wise_game_payload(info):
    """Wise.exe (C++) expects type=game_launch + platform=darwin + cmdline."""
    payload = {
        "type": "game_launch",
        "platform": "darwin",
        "pid": info.get("pid"),
        "name": info.get("name"),
        "cmdline": info.get("cmdline", []),
    }
    profile = _cached_profile or build_profile()
    if profile:
        payload["profile"] = profile
    return payload

# ── Capture & relay ───────────────────────────────────────────────────────────

def capture_and_relay(proc, pid, name, ip, port):
    global _transfers

    log(f"Game process found:  PID={pid}  Name={name}", GREEN, bold=True)
    log(f"Waiting for process to fully load args (max {CMDLINE_WAIT_TIMEOUT}s) …", YELLOW)

    full_cmdline, elapsed = wait_for_full_cmdline(proc)

    if not full_cmdline:
        log(f"⚠  Timeout waiting for args after {CMDLINE_WAIT_TIMEOUT}s — "
            "process may have exited early or args are restricted.", RED)
        return

    log(f"Args ready:  {len(full_cmdline)} tokens captured in {elapsed}s", GREEN)

    info = collect_info(proc, full_cmdline)

    # Print args
    log("── Launch Arguments ──", GOLD, bold=True)
    for i, arg in enumerate(full_cmdline):
        color = GOLD if i == 0 else WHITE
        log(f"  [{i:02d}]  {arg}", color)

    env_count = len(info.get("environ", {}))
    log(f"── Environment: {env_count} vars captured ──", SUBTLE)

    # Kill
    kill_result = kill_process(proc)
    log(f"Local process killed: {kill_result}", YELLOW)

    # Send (Wise.exe compatible)
    wise_payload = build_wise_game_payload(info)
    if wise_payload.get("profile"):
        p = wise_payload["profile"]
        log(f"Profile attached: {p['name']} · {p['rank']}", CYAN)
    log(f"Sending to {ip}:{port} …", CYAN)
    ok, msg = send_payload(wise_payload, ip, port)
    log(msg, GREEN if ok else RED, bold=True)

    if ok:
        with _lock:
            _transfers += 1
            log(f"Total transfers this session: {_transfers}", GREEN)

# ── Watch loop ────────────────────────────────────────────────────────────────

def watch_loop(ip, port):
    global _watching, _seen_pids
    log("Watcher started — waiting for game …", YELLOW, bold=True)
    print_status("WATCHING", YELLOW)

    while _watching:
        for proc in psutil.process_iter(["pid", "name"]):
            if not _watching:
                break
            if proc.pid in _seen_pids:
                continue
            if is_game_process(proc):
                _seen_pids.add(proc.pid)
                pid_snap  = proc.pid
                name_snap = proc.name()
                threading.Thread(
                    target=capture_and_relay,
                    args=(proc, pid_snap, name_snap, ip, port),
                    daemon=True
                ).start()
        time.sleep(POLL_INTERVAL)

    log("Watcher stopped.", SUBTLE)
    print_status("IDLE", RED)

# ── Main ──────────────────────────────────────────────────────────────────────

def get_input(prompt, default):
    try:
        val = input(f"{CYAN}{prompt}{RESET} [{SUBTLE}{default}{RESET}]: ").strip()
        return val if val else default
    except EOFError:
        return default


def main():
    global _watching, _seen_pids, _transfers, _receiver_ip, _receiver_port

    banner()

    # Config
    print(f"{GOLD}── Configuration ──────────────────────────────{RESET}")
    _receiver_ip = get_input("Receiver IP  (Windows PC LAN IP)", DEFAULT_RECEIVER_IP)
    receiver_port_str = get_input("Receiver Port", str(DEFAULT_RECEIVER_PORT))
    try:
        _receiver_port = int(receiver_port_str)
    except ValueError:
        print(f"{RED}Invalid port, using default {DEFAULT_RECEIVER_PORT}{RESET}")
        _receiver_port = DEFAULT_RECEIVER_PORT

    print()
    log(f"Target:  {_receiver_ip}:{_receiver_port}", CYAN, bold=True)
    log(f"Host:    {socket.gethostname()}", CYAN)
    log("Wise.exe: set Windows app to Receiver mode", SUBTLE)
    print()

    _stop.clear()
    threading.Thread(target=lcu_loop, daemon=True).start()

    # Signal handler for clean Ctrl+C exit
    def _sigint(sig, frame):
        global _watching
        print()
        log("Interrupt received — stopping …", YELLOW)
        _watching = False
        _stop.set()
        sys.exit(0)

    signal.signal(signal.SIGINT, _sigint)

    # Interactive command loop
    print(f"{GOLD}── Commands ────────────────────────────────────{RESET}")
    print(f"  {GREEN}s{RESET} → Start watching")
    print(f"  {RED}q{RESET} → Quit")
    print(f"  {SUBTLE}Press Ctrl+C at any time to exit{RESET}")
    print()

    while True:
        try:
            cmd = input(f"{GOLD}>{RESET} ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            break

        if cmd == "s":
            if _watching:
                log("Already watching!", YELLOW)
            else:
                _watching  = True
                _seen_pids = set()
                t = threading.Thread(
                    target=watch_loop,
                    args=(_receiver_ip, _receiver_port),
                    daemon=True,
                )
                t.start()

        elif cmd == "q":
            _watching = False
            _stop.set()
            log("Goodbye.", SUBTLE)
            break

        elif cmd == "stop":
            if _watching:
                _watching = False
            else:
                log("Not watching.", SUBTLE)

        elif cmd == "status":
            state = f"{GREEN}WATCHING{RESET}" if _watching else f"{RED}IDLE{RESET}"
            lcu = (
                f"{GREEN}{_lcu_summoner}{RESET}"
                if _lcu_online
                else f"{RED}offline{RESET}"
            )
            log(f"Status: {state}  |  LCU: {lcu}  |  Transfers: {_transfers}", CYAN)

        elif cmd == "help":
            print(f"  {GREEN}s{RESET}      — start watching")
            print(f"  {RED}stop{RESET}   — stop watching")
            print(f"  {CYAN}status{RESET} — show current status")
            print(f"  {RED}q{RESET}      — quit")

        elif cmd == "":
            pass  # ignore empty

        else:
            log(f"Unknown command '{cmd}'. Type 'help' for commands.", SUBTLE)


if __name__ == "__main__":
    main()
