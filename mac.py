#!/usr/bin/env python3
"""
Wise Mac Sender — terminal or tkinter
=====================================
• Shows up in Wise (Windows) receiver scan via LAN discovery
• Sends game launch args in Wise-compatible format
• Detects League Client (LCU) on macOS
• Watches for LoL game process, kills locally, relays to receiver

Setup:  pip3 install psutil
Run:    python3 wise_sender.py
GUI:    python3 wise_sender.py --gui
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import platform
import signal
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

try:
    import psutil
except ImportError:
    print("Install dependency:  pip3 install psutil")
    sys.exit(1)

# ── Wise protocol (matches sound/wise-cpp) ───────────────────────────────────
TCP_PORT = 54321
DISCOVERY_PORT = 54322
DISCOVERY_INTERVAL = 4.0
POLL_INTERVAL = 1.0
MIN_ARGS = 5
CMDLINE_WAIT_TIMEOUT = 10.0
CMDLINE_POLL = 0.3
DDRAGON_VER = "14.3.1"

GAME_KEYWORDS = ["leagueoflegends", "league of legends"]
EXCLUDE_KEYWORDS = [
    "leagueclient", "leagueclientux", "riotclientservices",
    "riotclientux", "patcher", "crashhandler",
]

LOCKFILE_PATHS = [
    "~/Library/Application Support/Riot Games/League of Legends/lockfile",
    "~/Library/Application Support/Riot Games/League of Legends (PBE)/lockfile",
    "~/Library/Application Support/Riot Games/Riot Client/Config/lockfile",
    "/Applications/League of Legends.app/Contents/LoL/lockfile",
]

# ── Terminal colors ───────────────────────────────────────────────────────────
RESET = "\033[0m"
BOLD = "\033[1m"
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
GOLD = "\033[33m"
SUBTLE = "\033[90m"
WHITE = "\033[97m"

LogFn = Callable[[str, str, bool], None]


def default_log(msg: str, color: str = "", bold: bool = False) -> None:
    ts = time.strftime("%H:%M:%S")
    style = (BOLD if bold else "") + color
    print(f"{SUBTLE}[{ts}]{RESET}  {style}{msg}{RESET}", flush=True)


# ── Shared state ─────────────────────────────────────────────────────────────
class AppState:
    def __init__(self) -> None:
        self.hostname = socket.gethostname()
        self.local_ip = get_local_ip()
        self.my_id = f"{self.local_ip}:{TCP_PORT}"
        self.watching = False
        self.seen_pids: set[int] = set()
        self.transfers = 0
        self.receivers: Dict[str, dict] = {}
        self.selected_receiver_id: Optional[str] = None
        self.lcu_online = False
        self.lcu_summoner = ""
        self.lock = threading.Lock()
        self._stop = threading.Event()

    def selected_receiver(self) -> Optional[dict]:
        if self.selected_receiver_id and self.selected_receiver_id in self.receivers:
            return self.receivers[self.selected_receiver_id]
        if self.receivers:
            return next(iter(self.receivers.values()))
        return None


STATE = AppState()


def get_local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def json_escape(s: str) -> str:
    return json.dumps(s)[1:-1]


# ── LCU (League Client) ─────────────────────────────────────────────────────

def collect_lockfile_paths() -> List[Path]:
    paths: List[Path] = []
    seen: set[str] = set()
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


def parse_lockfile(path: Path) -> Optional[Tuple[int, str]]:
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


def lcu_credentials_from_process() -> Optional[Tuple[int, str]]:
    for proc in psutil.process_iter(["pid", "name"]):
        try:
            name = (proc.info.get("name") or "").lower()
            if "leagueclient" not in name:
                continue
            cmd = " ".join(proc.cmdline())
            port = extract_flag(cmd, "--app-port=") or extract_flag(cmd, "-RiotClientPort=")
            token = extract_flag(cmd, "--remoting-auth-token=") or extract_flag(
                cmd, "-RiotClientAuthToken="
            )
            if port and token:
                return int(port), token
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return None


def extract_flag(text: str, prefix: str) -> Optional[str]:
    idx = text.find(prefix)
    if idx == -1:
        return None
    start = idx + len(prefix)
    end = text.find(" ", start)
    val = text[start:] if end == -1 else text[start:end]
    return val.strip("\"'")


def refresh_lcu() -> bool:
    creds = None
    for path in collect_lockfile_paths():
        creds = parse_lockfile(path)
        if creds:
            break
    if not creds:
        creds = lcu_credentials_from_process()
    if not creds:
        STATE.lcu_online = False
        STATE.lcu_summoner = ""
        return False

    port, token = creds
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    auth = base64.b64encode(f"riot:{token}".encode()).decode()
    req = urllib.request.Request(
        f"https://127.0.0.1:{port}/lol-summoner/v1/current-summoner",
        headers={"Authorization": f"Basic {auth}"},
    )
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=4) as resp:
            data = json.loads(resp.read().decode())
        game = data.get("gameName") or data.get("displayName") or "Summoner"
        tag = data.get("tagLine")
        STATE.lcu_summoner = f"{game}#{tag}" if tag else game
        STATE.lcu_online = True
        return True
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError, OSError):
        STATE.lcu_online = False
        STATE.lcu_summoner = ""
        return False


def lcu_loop(log: LogFn = default_log) -> None:
    last = False
    while not STATE._stop.is_set():
        online = refresh_lcu()
        if online != last:
            last = online
            if online:
                log(f"League Client online — {STATE.lcu_summoner}", GREEN, True)
            else:
                log("League Client offline", YELLOW)
        time.sleep(2.5)


# ── LAN discovery (Wise-compatible) ─────────────────────────────────────────

def discovery_broadcast(sock: socket.socket) -> None:
    payload = json.dumps(
        {
            "type": "wise_discover",
            "id": STATE.my_id,
            "name": f"{STATE.hostname} (host)",
            "ip": STATE.local_ip,
            "port": TCP_PORT,
            "mode": "host",
            "platform": "darwin",
        },
        separators=(",", ":"),
    ).encode()
    sock.sendto(payload, ("<broadcast>", DISCOVERY_PORT))


def discovery_loop(log: LogFn = default_log) -> None:
    recv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    recv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    recv.bind(("", DISCOVERY_PORT))
    recv.settimeout(0.25)

    send = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    send.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    discovery_broadcast(send)
    log(
        f"LAN discovery active — you should appear in Wise scan as "
        f"'{STATE.hostname} (host)'",
        CYAN,
    )
    last_broadcast = time.time()

    while not STATE._stop.is_set():
        if time.time() - last_broadcast >= DISCOVERY_INTERVAL:
            discovery_broadcast(send)
            last_broadcast = time.time()
        try:
            data, _addr = recv.recvfrom(4096)
            msg = json.loads(data.decode("utf-8", errors="ignore"))
            if msg.get("type") != "wise_discover":
                continue
            device_id = msg.get("id") or ""
            if not device_id or device_id == STATE.my_id:
                continue
            mode = (msg.get("mode") or "").lower()
            if mode != "receiver":
                continue
            ip = msg.get("ip") or ""
            port = int(msg.get("port") or TCP_PORT)
            name = msg.get("name") or ip
            with STATE.lock:
                is_new = device_id not in STATE.receivers
                STATE.receivers[device_id] = {
                    "id": device_id,
                    "name": name,
                    "ip": ip,
                    "port": port,
                    "mode": mode,
                    "platform": msg.get("platform") or "",
                }
                if not STATE.selected_receiver_id:
                    STATE.selected_receiver_id = device_id
            if is_new:
                log(f"Receiver found: {name} @ {ip}:{port}", GREEN)
        except socket.timeout:
            pass
        except (json.JSONDecodeError, ValueError, OSError):
            pass

    recv.close()
    send.close()


# ── Game watch & relay ───────────────────────────────────────────────────────

def is_game_process(proc: psutil.Process) -> bool:
    try:
        name = proc.name().lower()
        exe = proc.exe().lower()
        cmdline = " ".join(proc.cmdline()).lower()
        identity = f"{name} {exe} {cmdline}"
        if not any(k in identity for k in GAME_KEYWORDS):
            return False
        if any(k in identity for k in EXCLUDE_KEYWORDS):
            return False
        return True
    except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
        return False


def wait_for_full_cmdline(proc: psutil.Process) -> Tuple[List[str], float]:
    deadline = time.time() + CMDLINE_WAIT_TIMEOUT
    start = time.time()
    while time.time() < deadline:
        try:
            cmdline = proc.cmdline()
            if len(cmdline) >= MIN_ARGS:
                return cmdline, round(time.time() - start, 2)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            break
        time.sleep(CMDLINE_POLL)
    return [], CMDLINE_WAIT_TIMEOUT


def kill_process(proc: psutil.Process) -> str:
    try:
        proc.terminate()
        proc.wait(timeout=5)
        return "SIGTERM"
    except psutil.TimeoutExpired:
        try:
            proc.kill()
            proc.wait(timeout=5)
            return "SIGKILL"
        except Exception:
            return "forced"
    except psutil.NoSuchProcess:
        return "already gone"
    except psutil.AccessDenied:
        return "access denied — try: sudo python3 wise_sender.py"


def build_wise_payload(proc: psutil.Process, cmdline: List[str]) -> dict:
    profile = None
    if STATE.lcu_online and refresh_lcu():
        try:
            creds = lcu_credentials_from_process() or parse_lockfile_from_disk()
            if creds:
                port, token = creds
                ctx = ssl.create_default_context()
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
                auth = base64.b64encode(f"riot:{token}".encode()).decode()
                req = urllib.request.Request(
                    f"https://127.0.0.1:{port}/lol-summoner/v1/current-summoner",
                    headers={"Authorization": f"Basic {auth}"},
                )
                with urllib.request.urlopen(req, context=ctx, timeout=4) as resp:
                    s = json.loads(resp.read().decode())
                icon_id = s.get("profileIconId") or 29
                game = s.get("gameName") or s.get("displayName") or "Unknown"
                tag = s.get("tagLine") or ""
                name = f"{game}#{tag}" if tag else game
                profile = {
                    "type": "profile",
                    "name": name,
                    "level": s.get("summonerLevel") or 0,
                    "rank": "Unranked",
                    "discord": "WISEIT",
                    "meta": f"macOS Sender • {STATE.local_ip}:{TCP_PORT}",
                    "icon_url": (
                        f"https://ddragon.leagueoflegends.com/cdn/{DDRAGON_VER}/"
                        f"img/profileicon/{icon_id}.png"
                    ),
                    "platform": "darwin",
                    "host_ip": STATE.local_ip,
                }
        except Exception:
            profile = None

    payload = {
        "type": "game_launch",
        "platform": "darwin",
        "pid": proc.pid,
        "name": proc.name(),
        "cmdline": cmdline,
    }
    if profile:
        payload["profile"] = profile
    return payload


def parse_lockfile_from_disk() -> Optional[Tuple[int, str]]:
    for path in collect_lockfile_paths():
        creds = parse_lockfile(path)
        if creds:
            return creds
    return lcu_credentials_from_process()


def send_wise_payload(payload: dict, ip: str, port: int) -> Tuple[bool, str]:
    try:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(12)
            s.connect((ip, port))
            s.sendall(len(body).to_bytes(8, "big") + body)
        return True, f"Sent {len(body):,} bytes → {ip}:{port}"
    except ConnectionRefusedError:
        return False, f"Connection refused — is Wise in Receiver mode on {ip}:{port}?"
    except socket.timeout:
        return False, f"Timeout connecting to {ip}:{port}"
    except OSError as e:
        return False, f"Network error: {e}"


def capture_and_relay(proc: psutil.Process, pid: int, name: str, log: LogFn) -> None:
    log(f"Game detected: PID={pid} {name}", GREEN, True)
    full_cmdline, elapsed = wait_for_full_cmdline(proc)
    if not full_cmdline:
        log(f"No args captured within {CMDLINE_WAIT_TIMEOUT}s", RED)
        return

    log(f"Captured {len(full_cmdline)} args in {elapsed}s", GREEN)
    kill_result = kill_process(proc)
    log(f"Local game stopped ({kill_result})", YELLOW)

    receiver = STATE.selected_receiver()
    if not receiver:
        log("No Wise receiver on LAN — open Wise on Windows in Receiver mode", RED, True)
        return

    ip, port = receiver["ip"], int(receiver["port"])
    payload = build_wise_payload(proc, full_cmdline)
    log(f"Relaying to {receiver['name']} ({ip}:{port}) …", CYAN)
    ok, msg = send_wise_payload(payload, ip, port)
    log(msg, GREEN if ok else RED, True)
    if ok:
        with STATE.lock:
            STATE.transfers += 1
            log(f"Session transfers: {STATE.transfers}", GREEN)


def watch_loop(log: LogFn = default_log) -> None:
    log("Watching for game launch …", YELLOW, True)
    while STATE.watching and not STATE._stop.is_set():
        receiver = STATE.selected_receiver()
        if not receiver:
            log("Waiting for a Wise receiver on the network …", SUBTLE)
        for proc in psutil.process_iter(["pid", "name"]):
            if not STATE.watching:
                break
            if proc.pid in STATE.seen_pids:
                continue
            if is_game_process(proc):
                STATE.seen_pids.add(proc.pid)
                threading.Thread(
                    target=capture_and_relay,
                    args=(proc, proc.pid, proc.name(), log),
                    daemon=True,
                ).start()
        time.sleep(POLL_INTERVAL)


# ── Terminal UI ──────────────────────────────────────────────────────────────

def print_receivers(log: LogFn = default_log) -> None:
    with STATE.lock:
        items = list(STATE.receivers.values())
        sel = STATE.selected_receiver_id
    if not items:
        log("No receivers yet — start Wise on Windows in Receiver mode", YELLOW)
        return
    log("Receivers (link to this Mac in Wise scan, args go here):", GOLD, True)
    for i, d in enumerate(items, 1):
        mark = " ← active" if d["id"] == sel else ""
        log(f"  [{i}] {d['name']}  {d['ip']}:{d['port']}{mark}", WHITE)


def banner() -> None:
    print()
    print(f"{GOLD}{BOLD}{'=' * 58}{RESET}")
    print(f"{GOLD}{BOLD}  Wise Mac Sender  ·  compatible with Wise Windows receiver{RESET}")
    print(f"{GOLD}{BOLD}{'=' * 58}{RESET}")
    print(f"{SUBTLE}  Host: {STATE.hostname}  IP: {STATE.local_ip}{RESET}")
    print(f"{SUBTLE}  Appears in Wise scan as: {STATE.hostname} (host){RESET}")
    print()


def run_terminal() -> None:
    banner()
    STATE._stop.clear()
    threading.Thread(target=discovery_loop, daemon=True).start()
    threading.Thread(target=lcu_loop, daemon=True).start()

    print(f"{GOLD}Commands:{RESET}")
    print(f"  {GREEN}s{RESET}        start watching for game")
    print(f"  {RED}stop{RESET}     stop watching")
    print(f"  {CYAN}status{RESET}   LCU + receiver status")
    print(f"  {CYAN}list{RESET}     list discovered receivers")
    print(f"  {CYAN}use N{RESET}    pick receiver #N from list")
    print(f"  {RED}q{RESET}        quit")
    print()

    def on_sigint(_s, _f):
        STATE.watching = False
        STATE._stop.set()
        print()
        log("Bye.", SUBTLE)
        sys.exit(0)

    signal.signal(signal.SIGINT, on_sigint)

    while True:
        try:
            cmd = input(f"{GOLD}>{RESET} ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            break

        if cmd == "s":
            if STATE.watching:
                log("Already watching", YELLOW)
            else:
                STATE.watching = True
                STATE.seen_pids.clear()
                threading.Thread(target=watch_loop, daemon=True).start()

        elif cmd == "stop":
            STATE.watching = False
            log("Watcher stopped", SUBTLE)

        elif cmd == "status":
            lcu = f"{GREEN}online{RESET} ({STATE.lcu_summoner})" if STATE.lcu_online else f"{RED}offline{RESET}"
            watch = f"{GREEN}watching{RESET}" if STATE.watching else f"{RED}idle{RESET}"
            rcv = STATE.selected_receiver()
            rcv_txt = f"{rcv['name']} @ {rcv['ip']}" if rcv else "none yet"
            print(f"  LCU: {lcu}  |  Watcher: {watch}  |  Target: {rcv_txt}  |  Sends: {STATE.transfers}")

        elif cmd in ("list", "receivers"):
            print_receivers()

        elif cmd.startswith("use "):
            try:
                idx = int(cmd.split()[1]) - 1
                with STATE.lock:
                    items = list(STATE.receivers.values())
                if 0 <= idx < len(items):
                    STATE.selected_receiver_id = items[idx]["id"]
                    log(f"Active receiver: {items[idx]['name']}", GREEN)
                else:
                    log("Invalid number — run 'list' first", RED)
            except (IndexError, ValueError):
                log("Usage: use 1", YELLOW)

        elif cmd == "q":
            STATE.watching = False
            STATE._stop.set()
            log("Bye.", SUBTLE)
            break

        elif cmd == "help":
            log("s | stop | status | list | use N | q", SUBTLE)

        elif cmd:
            log("Unknown command — type help", SUBTLE)


# ── Tkinter GUI ──────────────────────────────────────────────────────────────

def run_gui() -> None:
    import tkinter as tk
    from tkinter import scrolledtext, ttk

    STATE._stop.clear()
    root = tk.Tk()
    root.title("Wise Mac Sender")
    root.geometry("620x480")
    root.configure(bg="#1a1a1a")

    def gui_log(msg: str, _color: str = "", _bold: bool = False) -> None:
        def append() -> None:
            log_box.configure(state="normal")
            log_box.insert("end", f"[{time.strftime('%H:%M:%S')}] {msg}\n")
            log_box.see("end")
            log_box.configure(state="disabled")

        root.after(0, append)

    def refresh_status() -> None:
        lcu_lbl.configure(
            text=f"League Client: {'Online — ' + STATE.lcu_summoner if STATE.lcu_online else 'Offline'}"
        )
        watch_lbl.configure(text=f"Watcher: {'Running' if STATE.watching else 'Stopped'}")
        scan_lbl.configure(text=f"Scan name: {STATE.hostname} (host)  ·  IP: {STATE.local_ip}")
        rcv = STATE.selected_receiver()
        target_lbl.configure(text=f"Receiver: {rcv['name'] + ' @ ' + rcv['ip'] if rcv else 'Waiting…'}")
        recv_list.delete(0, "end")
        with STATE.lock:
            for d in STATE.receivers.values():
                mark = " *" if d["id"] == STATE.selected_receiver_id else ""
                recv_list.insert("end", f"{d['name']}  ({d['ip']}){mark}")
        root.after(1500, refresh_status)

    def start_watch() -> None:
        if not STATE.watching:
            STATE.watching = True
            STATE.seen_pids.clear()
            threading.Thread(target=watch_loop, args=(gui_log,), daemon=True).start()
            gui_log("Watcher started")

    def stop_watch() -> None:
        STATE.watching = False
        gui_log("Watcher stopped")

    def on_pick(_evt=None) -> None:
        sel = recv_list.curselection()
        if not sel:
            return
        with STATE.lock:
            items = list(STATE.receivers.values())
        if sel[0] < len(items):
            STATE.selected_receiver_id = items[sel[0]]["id"]
            gui_log(f"Selected receiver: {items[sel[0]]['name']}")

    def on_close() -> None:
        STATE.watching = False
        STATE._stop.set()
        root.destroy()

    frm = ttk.Frame(root, padding=10)
    frm.pack(fill="both", expand=True)

    scan_lbl = ttk.Label(frm, text="", font=("Helvetica", 10, "bold"))
    scan_lbl.pack(anchor="w")
    lcu_lbl = ttk.Label(frm, text="League Client: …")
    lcu_lbl.pack(anchor="w", pady=(4, 0))
    watch_lbl = ttk.Label(frm, text="Watcher: Stopped")
    watch_lbl.pack(anchor="w")
    target_lbl = ttk.Label(frm, text="Receiver: …")
    target_lbl.pack(anchor="w", pady=(0, 8))

    ttk.Label(frm, text="Wise receivers on LAN (Windows app in Receiver mode):").pack(anchor="w")
    recv_list = tk.Listbox(frm, height=4, bg="#111", fg="#ddd", selectbackground="#333")
    recv_list.pack(fill="x", pady=4)
    recv_list.bind("<<ListboxSelect>>", on_pick)

    btn_row = ttk.Frame(frm)
    btn_row.pack(fill="x", pady=6)
    ttk.Button(btn_row, text="Start watch", command=start_watch).pack(side="left", padx=(0, 6))
    ttk.Button(btn_row, text="Stop", command=stop_watch).pack(side="left")

    log_box = scrolledtext.ScrolledText(frm, height=14, bg="#0d0d0d", fg="#ccc", font=("Menlo", 10))
    log_box.pack(fill="both", expand=True, pady=(8, 0))
    log_box.configure(state="disabled")

    threading.Thread(target=discovery_loop, args=(gui_log,), daemon=True).start()
    threading.Thread(target=lcu_loop, args=(gui_log,), daemon=True).start()
    gui_log("Discovery started — you appear in Wise Windows scan")
    refresh_status()
    root.protocol("WM_WINDOW_CLOSE", on_close)
    root.mainloop()


def main() -> None:
    if platform.system() != "Darwin":
        print("This script is for macOS (League Client + game paths).")

    parser = argparse.ArgumentParser(description="Wise Mac Sender")
    parser.add_argument("--gui", action="store_true", help="Open classic tkinter window")
    args = parser.parse_args()

    if args.gui:
        run_gui()
    else:
        run_terminal()


if __name__ == "__main__":
    main()
