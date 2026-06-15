#!/usr/bin/env python3
"""
LoL Game Relay — SENDER (macOS) — TERMINAL VERSION
====================================================
• Watches for the League of Legends GAME process
• Captures all launch args + env vars
• Sends them over TCP to the Windows receiver
• Kills the local game process
• Fully terminal-based with colored output

Dependencies:  pip3 install psutil
Run:           python3 lol_sender_terminal.py
"""

import json
import signal
import socket
import sys
import threading
import time
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

GAME_KEYWORDS    = ["leagueoflegends", "league of legends"]
EXCLUDE_KEYWORDS = ["leagueclient", "leagueclientux", "riotclientservices",
                    "riotclientux", "patcher", "crashhandler"]

MIN_ARGS             = 5
CMDLINE_WAIT_TIMEOUT = 10.0
CMDLINE_POLL         = 0.3

# ── Globals ───────────────────────────────────────────────────────────────────
_watching  = False
_seen_pids = set()
_transfers = 0
_lock      = threading.Lock()

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

def send_info(info, ip, port):
    try:
        payload = json.dumps(info).encode("utf-8")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(10)
            s.connect((ip, port))
            s.sendall(len(payload).to_bytes(8, "big") + payload)
        return True, f"✓  Sent {len(payload):,} bytes to {ip}:{port}"
    except ConnectionRefusedError:
        return False, f"✗  Connection refused — is the receiver running on {ip}:{port}?"
    except socket.timeout:
        return False, f"✗  Timeout connecting to {ip}:{port}"
    except OSError as e:
        return False, f"✗  Network error: {e}"

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

    # Send
    log(f"Sending to {ip}:{port} …", CYAN)
    ok, msg = send_info(info, ip, port)
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
    global _watching, _seen_pids, _transfers

    banner()

    # Config
    print(f"{GOLD}── Configuration ──────────────────────────────{RESET}")
    receiver_ip   = get_input("Receiver IP  (Windows PC LAN IP)", DEFAULT_RECEIVER_IP)
    receiver_port_str = get_input("Receiver Port", str(DEFAULT_RECEIVER_PORT))
    try:
        receiver_port = int(receiver_port_str)
    except ValueError:
        print(f"{RED}Invalid port, using default {DEFAULT_RECEIVER_PORT}{RESET}")
        receiver_port = DEFAULT_RECEIVER_PORT

    print()
    log(f"Target:  {receiver_ip}:{receiver_port}", CYAN, bold=True)
    log(f"Host:    {socket.gethostname()}", CYAN)
    print()

    # Signal handler for clean Ctrl+C exit
    def _sigint(sig, frame):
        global _watching
        print()
        log("Interrupt received — stopping …", YELLOW)
        _watching = False
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
                t = threading.Thread(target=watch_loop, args=(receiver_ip, receiver_port), daemon=True)
                t.start()

        elif cmd == "q":
            _watching = False
            log("Goodbye.", SUBTLE)
            break

        elif cmd == "stop":
            if _watching:
                _watching = False
            else:
                log("Not watching.", SUBTLE)

        elif cmd == "status":
            state = f"{GREEN}WATCHING{RESET}" if _watching else f"{RED}IDLE{RESET}"
            log(f"Status: {state}  |  Transfers: {_transfers}", CYAN)

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
