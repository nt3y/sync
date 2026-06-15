#!/usr/bin/env python3
"""
LoL Game Relay — SENDER (macOS)
================================
• Watches for the League of Legends GAME process
• Captures all launch args + env vars
• Sends them over TCP to the Windows receiver
• Kills the local game process
• Dark gold GUI (tkinter — built-in on macOS)

Dependencies:  pip install psutil
Run:           python3 lol_sender_mac.py
"""

import json
import socket
import threading
import time
import tkinter as tk
from tkinter import scrolledtext
import psutil

# ── Defaults ──────────────────────────────────────────────────────────────────
DEFAULT_RECEIVER_IP   = "192.168.1.XXX"   # ← change to your Windows PC LAN IP
DEFAULT_RECEIVER_PORT = 54321
POLL_INTERVAL         = 1.0

GAME_KEYWORDS    = ["leagueoflegends", "league of legends"]
EXCLUDE_KEYWORDS = ["leagueclient", "leagueclientux", "riotclientservices",
                    "riotclientux", "patcher", "crashhandler"]

# Minimum number of cmdline args the game must have before we consider
# the process fully launched (the real game has 15-16 args)
MIN_ARGS = 5

# How long to wait for cmdline to populate (seconds)
CMDLINE_WAIT_TIMEOUT = 10.0
CMDLINE_POLL         = 0.3

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


def wait_for_full_cmdline(proc, log_cb=None):
    """
    Poll until the process cmdline has at least MIN_ARGS tokens
    (the game loads args a moment after the process spawns).
    Returns (cmdline_list, elapsed_seconds) or ([], timeout).
    """
    deadline = time.time() + CMDLINE_WAIT_TIMEOUT
    while time.time() < deadline:
        try:
            cmdline = proc.cmdline()
            if len(cmdline) >= MIN_ARGS:
                return cmdline, round(time.time() - (deadline - CMDLINE_WAIT_TIMEOUT), 2)
            if log_cb:
                log_cb(f"  Waiting for args … ({len(cmdline)} so far)", "subtle")
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
        info["cmdline"] = full_cmdline          # use the waited-for full list
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
    """Try SIGTERM, escalate to SIGKILL, fall back to `sudo kill -9` via subprocess."""
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
        # Fall back to sudo kill (works when script is run via `sudo python3 …`
        # or when the user has a passwordless sudo rule for kill)
        try:
            _sp.run(["sudo", "kill", "-9", str(proc.pid)],
                    timeout=5, check=True, capture_output=True)
            return f"killed via sudo kill -9 (PID {proc.pid})"
        except Exception as e:
            return f"ACCESS DENIED + sudo failed: {e}  → run:  sudo python3 lol_sender_mac.py"


# ── GUI ───────────────────────────────────────────────────────────────────────

class SenderApp(tk.Tk):
    BG        = "#0d0f14"
    PANEL     = "#13161e"
    BORDER    = "#1e2230"
    ACCENT    = "#c89b3c"
    GREEN     = "#3cffa0"
    RED       = "#ff4d6d"
    YELLOW    = "#f0e060"
    CYAN      = "#38c8e8"
    TEXT      = "#dce1ec"
    SUBTLE    = "#4a5068"
    FONT_MONO = ("Menlo", 11)
    FONT_UI   = ("Helvetica Neue", 12)
    FONT_BIG  = ("Helvetica Neue", 17, "bold")

    def __init__(self):
        super().__init__()
        self.title("LoL Relay  ·  SENDER  [macOS]")
        self.geometry("860x700")
        self.configure(bg=self.BG)
        self.resizable(True, True)

        self._watching    = False
        self._thread      = None
        self._seen_pids   = set()
        self._transfers   = 0

        self._build_ui()

    # ── Build ─────────────────────────────────────────────────────────────────

    def _build_ui(self):
        # Title bar
        top = tk.Frame(self, bg=self.BG)
        top.pack(fill="x", padx=22, pady=(18, 2))

        tk.Label(top, text="⚡  LoL RELAY", font=self.FONT_BIG,
                 bg=self.BG, fg=self.ACCENT).pack(side="left")
        tk.Label(top, text="SENDER — macOS", font=("Helvetica Neue", 11),
                 bg=self.BG, fg=self.SUBTLE).pack(side="left", padx=10)

        # Status pill (right side)
        self._dot = tk.Label(top, text="●", font=("Helvetica Neue", 20),
                             bg=self.BG, fg=self.RED)
        self._dot.pack(side="right")
        self._slbl = tk.Label(top, text="IDLE", font=("Helvetica Neue", 11, "bold"),
                              bg=self.BG, fg=self.RED)
        self._slbl.pack(side="right", padx=(0, 6))

        # Gold divider
        tk.Frame(self, bg=self.ACCENT, height=1).pack(fill="x", padx=22, pady=6)

        # ── Connection bar
        cbar = tk.Frame(self, bg=self.PANEL, height=58)
        cbar.pack(fill="x", padx=22, pady=(0, 6))
        cbar.pack_propagate(False)

        self._hostname = socket.gethostname()
        tk.Label(cbar, text=f"  THIS PC:  {self._hostname}",
                 bg=self.PANEL, fg=self.CYAN,
                 font=("Helvetica Neue", 11, "bold")).pack(side="left", padx=(10, 20), pady=14)

        tk.Label(cbar, text="→  Receiver IP:",
                 bg=self.PANEL, fg=self.SUBTLE, font=self.FONT_UI).pack(side="left")
        self._ip_var = tk.StringVar(value=DEFAULT_RECEIVER_IP)
        tk.Entry(cbar, textvariable=self._ip_var, width=17,
                 bg="#1a1d28", fg=self.TEXT, insertbackground=self.ACCENT,
                 relief="flat", font=self.FONT_MONO, bd=5
                 ).pack(side="left", padx=(4, 16), pady=14)

        tk.Label(cbar, text="Port:", bg=self.PANEL, fg=self.SUBTLE,
                 font=self.FONT_UI).pack(side="left")
        self._port_var = tk.StringVar(value=str(DEFAULT_RECEIVER_PORT))
        tk.Entry(cbar, textvariable=self._port_var, width=7,
                 bg="#1a1d28", fg=self.TEXT, insertbackground=self.ACCENT,
                 relief="flat", font=self.FONT_MONO, bd=5
                 ).pack(side="left", padx=(4, 20), pady=14)

        self._tlbl = tk.Label(cbar, text="Transfers: 0",
                              bg=self.PANEL, fg=self.GREEN,
                              font=("Helvetica Neue", 11, "bold"))
        self._tlbl.pack(side="right", padx=16)

        # ── Buttons
        brow = tk.Frame(self, bg=self.BG)
        brow.pack(fill="x", padx=22, pady=(6, 8))

        self._btn_start = tk.Button(
            brow, text="▶  START WATCHING", command=self._start,
            bg=self.GREEN, fg="#0a0c11",
            font=("Helvetica Neue", 12, "bold"),
            relief="flat", padx=20, pady=9, cursor="hand2")
        self._btn_start.pack(side="left", padx=(0, 10))

        self._btn_stop = tk.Button(
            brow, text="■  STOP", command=self._stop,
            bg=self.SUBTLE, fg=self.TEXT,
            font=("Helvetica Neue", 12, "bold"),
            relief="flat", padx=20, pady=9, cursor="hand2",
            state="disabled")
        self._btn_stop.pack(side="left", padx=(0, 10))

        tk.Button(brow, text="🗑  CLEAR", command=self._clear,
                  bg=self.PANEL, fg=self.SUBTLE,
                  font=("Helvetica Neue", 11),
                  relief="flat", padx=14, pady=9, cursor="hand2"
                  ).pack(side="left")

        # ── Log
        lf = tk.Frame(self, bg=self.PANEL)
        lf.pack(fill="both", expand=True, padx=22, pady=(0, 20))

        tk.Label(lf, text="  ACTIVITY LOG", bg=self.PANEL, fg=self.SUBTLE,
                 font=("Helvetica Neue", 10, "bold")).pack(anchor="w", pady=(8, 2))

        self._log = scrolledtext.ScrolledText(
            lf, bg="#080a0f", fg=self.TEXT,
            font=self.FONT_MONO, relief="flat",
            insertbackground=self.ACCENT, wrap="word",
            state="disabled", bd=0)
        self._log.pack(fill="both", expand=True, padx=8, pady=(0, 8))

        for tag, color in [("accent", self.ACCENT), ("green", self.GREEN),
                            ("red", self.RED), ("yellow", self.YELLOW),
                            ("cyan", self.CYAN), ("subtle", self.SUBTLE)]:
            self._log.tag_config(tag, foreground=color)

        self._log_line(f"Sender ready on  {self._hostname}", "accent")
        self._log_line("Set Receiver IP above, then press START WATCHING.", "subtle")

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _log_line(self, text, tag=""):
        ts = time.strftime("%H:%M:%S")
        self._log.config(state="normal")
        self._log.insert("end", f"[{ts}]  ", "subtle")
        self._log.insert("end", text + "\n", tag)
        self._log.config(state="disabled")
        self._log.see("end")

    def _clear(self):
        self._log.config(state="normal")
        self._log.delete("1.0", "end")
        self._log.config(state="disabled")

    def _set_status(self, label, color):
        self._slbl.config(text=label, fg=color)
        self._dot.config(fg=color)

    # ── Control ───────────────────────────────────────────────────────────────

    def _start(self):
        self._watching = True
        self._seen_pids.clear()
        self._btn_start.config(state="disabled")
        self._btn_stop.config(state="normal")
        self._set_status("WATCHING", self.YELLOW)
        self._log_line("Watcher started — waiting for game …", "yellow")
        self._thread = threading.Thread(target=self._watch_loop, daemon=True)
        self._thread.start()

    def _stop(self):
        self._watching = False
        self._btn_start.config(state="normal")
        self._btn_stop.config(state="disabled")
        self._set_status("IDLE", self.RED)
        self._log_line("Watcher stopped.", "subtle")

    # ── Watch loop ────────────────────────────────────────────────────────────

    def _watch_loop(self):
        while self._watching:
            for proc in psutil.process_iter(["pid", "name"]):
                if not self._watching:
                    break
                if proc.pid in self._seen_pids:
                    continue
                if is_game_process(proc):
                    self._seen_pids.add(proc.pid)
                    # Hand off to a dedicated thread so the wait doesn't block scanning
                    pid_snap  = proc.pid
                    name_snap = proc.name()
                    threading.Thread(
                        target=self._capture_and_relay,
                        args=(proc, pid_snap, name_snap),
                        daemon=True
                    ).start()
            time.sleep(POLL_INTERVAL)

    def _capture_and_relay(self, proc, pid, name):
        """Background thread: wait for full args → capture → kill → send."""
        self.after(0, lambda: self._set_status("GAME DETECTED!", self.GREEN))
        self.after(0, lambda: self._log_line(
            f"Game process found:  PID={pid}  Name={name}", "green"))
        self.after(0, lambda: self._log_line(
            f"Waiting for process to fully load args (max {CMDLINE_WAIT_TIMEOUT}s) …", "yellow"))

        # ── Wait until cmdline is fully populated ──
        def _log_cb(msg, tag):
            self.after(0, lambda m=msg, t=tag: self._log_line(m, t))

        full_cmdline, elapsed = wait_for_full_cmdline(proc, _log_cb)

        if not full_cmdline:
            self.after(0, lambda: self._log_line(
                f"⚠  Timeout waiting for args after {CMDLINE_WAIT_TIMEOUT}s — "
                "process may have exited early or args are restricted.", "red"))
            self.after(0, lambda: self._set_status("WATCHING", self.YELLOW))
            return

        self.after(0, lambda n=len(full_cmdline), e=elapsed:
                   self._log_line(f"Args ready:  {n} tokens captured in {e}s", "green"))

        # ── Collect full info ──
        info = collect_info(proc, full_cmdline)

        # Print args to GUI log
        self.after(0, lambda: self._log_line("── Launch Arguments ──", "accent"))
        for i, arg in enumerate(full_cmdline):
            tag = "accent" if i == 0 else ""
            self.after(0, lambda i=i, a=arg, t=tag:
                       self._log_line(f"  [{i:02d}]  {a}", t))
        env = info.get("environ", {})
        self.after(0, lambda n=len(env):
                   self._log_line(f"── Environment: {n} vars captured ──", "subtle"))

        # ── Kill local process ──
        kill_result = kill_process(proc)
        self.after(0, lambda r=kill_result:
                   self._log_line(f"Local process killed: {r}", "yellow"))

        # ── Send to Windows ──
        self.after(0, lambda: self._set_status("SENDING…", self.ACCENT))
        self.after(0, lambda: self._log_line(
            f"Sending to {self._ip_var.get()} …", "cyan"))

        ok, msg = self._send(info)
        self.after(0, lambda m=msg, s=ok: self._log_line(m, "green" if s else "red"))
        if ok:
            self._transfers += 1
            self.after(0, lambda: self._tlbl.config(
                text=f"Transfers: {self._transfers}"))
        self.after(0, lambda: self._set_status("WATCHING", self.YELLOW))

    # ── Network ───────────────────────────────────────────────────────────────

    def _send(self, info):
        ip = self._ip_var.get().strip()
        try:
            port = int(self._port_var.get().strip())
        except ValueError:
            return False, "Invalid port."
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


if __name__ == "__main__":
    app = SenderApp()
    app.mainloop()