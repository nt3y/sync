#!/usr/bin/env python3
"""
LoL Game Relay — RECEIVER (Windows)
=====================================
• Listens on TCP for game info from the Mac Sender
• Parses the launch args
• Launches the League of Legends GAME directly with those args
• Shows a dark GUI with connection status and activity log

Dependencies:  pip install psutil   (psutil used only for process monitoring)
Run:           python lol_receiver_windows.py

League of Legends game exe on Windows is typically:
  C:\\Riot Games\\League of Legends\\Game\\League of Legends.exe
  (edit GAME_EXE below if your path differs)
"""

import json
import os
import socket
import subprocess
import threading
import time
import tkinter as tk
from tkinter import scrolledtext, filedialog

# ── Configuration ─────────────────────────────────────────────────────────────
LISTEN_PORT = 54321

# Default path — edit if your install is in a different location
DEFAULT_GAME_EXE = r"C:\Riot Games\League of Legends\Game\League of Legends.exe"


# ── GUI ───────────────────────────────────────────────────────────────────────

class ReceiverApp(tk.Tk):
    BG        = "#0d0f14"
    PANEL     = "#13161e"
    ACCENT    = "#c89b3c"
    GREEN     = "#3cffa0"
    RED       = "#ff4d6d"
    YELLOW    = "#f0e060"
    CYAN      = "#38c8e8"
    TEXT      = "#dce1ec"
    SUBTLE    = "#4a5068"
    FONT_MONO = ("Consolas", 11)
    FONT_UI   = ("Segoe UI", 12)
    FONT_BIG  = ("Segoe UI", 17, "bold")

    def __init__(self):
        super().__init__()
        self.title("LoL Relay  ·  RECEIVER  [Windows]")
        self.geometry("880x720")
        self.configure(bg=self.BG)
        self.resizable(True, True)

        self._listening   = False
        self._server_sock = None
        self._clients     = 0
        self._launches    = 0
        self._connected_mac = None

        self._build_ui()

    # ── Build UI ──────────────────────────────────────────────────────────────

    def _build_ui(self):
        # Title
        top = tk.Frame(self, bg=self.BG)
        top.pack(fill="x", padx=22, pady=(18, 2))

        tk.Label(top, text="⚡  LoL RELAY", font=self.FONT_BIG,
                 bg=self.BG, fg=self.ACCENT).pack(side="left")
        tk.Label(top, text="RECEIVER — Windows", font=("Segoe UI", 11),
                 bg=self.BG, fg=self.SUBTLE).pack(side="left", padx=10)

        self._dot = tk.Label(top, text="●", font=("Segoe UI", 20),
                             bg=self.BG, fg=self.RED)
        self._dot.pack(side="right")
        self._slbl = tk.Label(top, text="OFFLINE", font=("Segoe UI", 11, "bold"),
                              bg=self.BG, fg=self.RED)
        self._slbl.pack(side="right", padx=(0, 6))

        tk.Frame(self, bg=self.ACCENT, height=1).pack(fill="x", padx=22, pady=6)

        # ── Info bar
        ibar = tk.Frame(self, bg=self.PANEL, height=58)
        ibar.pack(fill="x", padx=22, pady=(0, 6))
        ibar.pack_propagate(False)

        self._hostname = socket.gethostname()
        tk.Label(ibar, text=f"  THIS PC:  {self._hostname}",
                 bg=self.PANEL, fg=self.CYAN,
                 font=("Segoe UI", 11, "bold")).pack(side="left", padx=(10, 24), pady=14)

        tk.Label(ibar, text="Listen Port:", bg=self.PANEL, fg=self.SUBTLE,
                 font=self.FONT_UI).pack(side="left")
        self._port_var = tk.StringVar(value=str(LISTEN_PORT))
        tk.Entry(ibar, textvariable=self._port_var, width=7,
                 bg="#1a1d28", fg=self.TEXT, insertbackground=self.ACCENT,
                 relief="flat", font=self.FONT_MONO, bd=5
                 ).pack(side="left", padx=(4, 24), pady=14)

        self._mac_lbl = tk.Label(ibar, text="Mac sender:  waiting…",
                                 bg=self.PANEL, fg=self.SUBTLE,
                                 font=("Segoe UI", 11))
        self._mac_lbl.pack(side="left")

        self._launch_lbl = tk.Label(ibar, text="Launches: 0",
                                    bg=self.PANEL, fg=self.GREEN,
                                    font=("Segoe UI", 11, "bold"))
        self._launch_lbl.pack(side="right", padx=16)

        # ── EXE path row
        epath = tk.Frame(self, bg=self.BG)
        epath.pack(fill="x", padx=22, pady=(2, 6))

        tk.Label(epath, text="Game EXE:", bg=self.BG, fg=self.SUBTLE,
                 font=self.FONT_UI).pack(side="left")
        self._exe_var = tk.StringVar(value=DEFAULT_GAME_EXE)
        tk.Entry(epath, textvariable=self._exe_var, width=62,
                 bg="#1a1d28", fg=self.TEXT, insertbackground=self.ACCENT,
                 relief="flat", font=self.FONT_MONO, bd=5
                 ).pack(side="left", padx=(6, 8), ipady=4)
        tk.Button(epath, text="Browse…", command=self._browse_exe,
                  bg=self.PANEL, fg=self.SUBTLE, relief="flat",
                  font=("Segoe UI", 10), padx=8, pady=4, cursor="hand2"
                  ).pack(side="left")

        # ── Buttons
        brow = tk.Frame(self, bg=self.BG)
        brow.pack(fill="x", padx=22, pady=(4, 8))

        self._btn_start = tk.Button(
            brow, text="▶  START LISTENING", command=self._start,
            bg=self.GREEN, fg="#0a0c11",
            font=("Segoe UI", 12, "bold"),
            relief="flat", padx=20, pady=9, cursor="hand2")
        self._btn_start.pack(side="left", padx=(0, 10))

        self._btn_stop = tk.Button(
            brow, text="■  STOP", command=self._stop,
            bg=self.SUBTLE, fg=self.TEXT,
            font=("Segoe UI", 12, "bold"),
            relief="flat", padx=20, pady=9, cursor="hand2",
            state="disabled")
        self._btn_stop.pack(side="left", padx=(0, 10))

        tk.Button(brow, text="🗑  CLEAR", command=self._clear,
                  bg=self.PANEL, fg=self.SUBTLE,
                  font=("Segoe UI", 11),
                  relief="flat", padx=14, pady=9, cursor="hand2"
                  ).pack(side="left")

        # ── Log
        lf = tk.Frame(self, bg=self.PANEL)
        lf.pack(fill="both", expand=True, padx=22, pady=(0, 20))

        tk.Label(lf, text="  ACTIVITY LOG", bg=self.PANEL, fg=self.SUBTLE,
                 font=("Segoe UI", 10, "bold")).pack(anchor="w", pady=(8, 2))

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

        self._log_line(f"Receiver ready on  {self._hostname}", "accent")
        my_ip = self._get_local_ip()
        self._log_line(f"Local IP: {my_ip}  — give this to the Mac sender", "cyan")
        self._log_line("Set the port, check the Game EXE path, then press START.", "subtle")

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _get_local_ip(self):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(("8.8.8.8", 80))
                return s.getsockname()[0]
        except Exception:
            return socket.gethostbyname(socket.gethostname())

    def _browse_exe(self):
        path = filedialog.askopenfilename(
            title="Select League of Legends.exe",
            filetypes=[("Executable", "*.exe"), ("All files", "*.*")])
        if path:
            self._exe_var.set(path)

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

    # ── Server control ────────────────────────────────────────────────────────

    def _start(self):
        try:
            port = int(self._port_var.get().strip())
        except ValueError:
            self._log_line("Invalid port number.", "red")
            return
        self._listening = True
        self._btn_start.config(state="disabled")
        self._btn_stop.config(state="normal")
        self._set_status("LISTENING", self.YELLOW)
        self._log_line(f"TCP server started on port {port}", "yellow")
        threading.Thread(target=self._server_loop, args=(port,), daemon=True).start()

    def _stop(self):
        self._listening = False
        if self._server_sock:
            try:
                self._server_sock.close()
            except Exception:
                pass
        self._btn_start.config(state="normal")
        self._btn_stop.config(state="disabled")
        self._set_status("OFFLINE", self.RED)
        self._log_line("Server stopped.", "subtle")
        self._mac_lbl.config(text="Mac sender:  waiting…", fg=self.SUBTLE)

    # ── Server loop ───────────────────────────────────────────────────────────

    def _server_loop(self, port):
        try:
            self._server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self._server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self._server_sock.bind(("0.0.0.0", port))
            self._server_sock.listen(5)
            self._server_sock.settimeout(1.0)
        except OSError as e:
            self.after(0, lambda: self._log_line(f"Cannot bind to port {port}: {e}", "red"))
            self.after(0, self._stop)
            return

        while self._listening:
            try:
                conn, addr = self._server_sock.accept()
                client_ip = addr[0]
                self.after(0, lambda ip=client_ip: self._on_connect(ip))
                threading.Thread(target=self._handle_client,
                                 args=(conn, client_ip), daemon=True).start()
            except socket.timeout:
                continue
            except OSError:
                break

    def _on_connect(self, ip):
        self._set_status("CONNECTED!", self.GREEN)
        self._log_line(f"Mac sender connected from  {ip}", "green")
        self._mac_lbl.config(text=f"Mac sender:  {ip}", fg=self.GREEN)

    def _handle_client(self, conn, addr):
        try:
            with conn:
                # Read 8-byte length prefix
                raw_len = self._recv_exactly(conn, 8)
                if not raw_len:
                    return
                data_len = int.from_bytes(raw_len, "big")

                self.after(0, lambda: self._log_line(
                    f"Receiving {data_len:,} bytes of game data …", "cyan"))

                raw_data = self._recv_exactly(conn, data_len)
                if not raw_data:
                    self.after(0, lambda: self._log_line("Incomplete data received.", "red"))
                    return

                info = json.loads(raw_data.decode("utf-8"))
                self.after(0, lambda i=info: self._on_data_received(i))

        except Exception as e:
            self.after(0, lambda: self._log_line(f"Client error: {e}", "red"))
        finally:
            self.after(0, lambda: self._set_status("LISTENING", self.YELLOW))
            self.after(0, lambda: self._mac_lbl.config(
                text="Mac sender:  waiting…", fg=self.SUBTLE))

    @staticmethod
    def _recv_exactly(sock, n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                return None
            buf += chunk
        return buf

    # ── Process received data ─────────────────────────────────────────────────

    def _on_data_received(self, info):
        self._log_line("── Received Game Info ──", "accent")
        cmdline = info.get("cmdline", [])
        self._log_line(f"  Original EXE:  {info.get('exe', 'N/A')}", "")
        MAC_ONLY = ("-UseMetal", "-SkipBuild")
        for i, arg in enumerate(cmdline):
            if i == 0:
                continue
            tag = "subtle" if any(arg.startswith(s) for s in MAC_ONLY) else ""
            self._log_line(f"  [{i:02d}]  {arg}", tag)

        env  = info.get("environ", {})
        self._log_line(f"  ENV VARS received: {len(env)}", "subtle")
        self._log_line("────────────────────────", "subtle")

        # Launch game in background thread
        threading.Thread(
            target=self._launch_game, args=(cmdline, info), daemon=True).start()

    # ── Mac → Windows argument translator ────────────────────────────────────

    def _translate_args(self, mac_cmdline, win_exe):
        """
        Convert the Mac process cmdline into a Windows-compatible argument list.

        Mac format  (separate tokens):
            [0] /Applications/.../LeagueofLegends   ← exe, skip
            [1] 162.249.72.5 7180 TOKEN PLAYERID    ← server string (one token on Mac)
            [2] -Product=LoL
            ...
            [N] -GameBaseDir=/Applications/League of Legends.app/Contents/LoL
            ...
            [N] -UseMetal=1:1                        ← Mac-only, drop
            [N] -RiotClientPort=XXXXX                ← Mac port,  replace with Windows
            [N] -RiotClientAuthToken=XXXXX           ← Mac token, replace with Windows

        Windows format (what the game actually wants):
            [0] "C:/Riot Games/.../League of Legends.exe"
            [1] "162.249.72.5 7180 TOKEN PLAYERID"  ← quoted single string
            [2] "-Product=LoL"
            ...
            each flag is its own quoted argument
            -GameBaseDir must point to the Windows install dir
            -RiotClientPort / -RiotClientAuthToken come from the local Windows client
        """

        # ── Strip exe (index 0) and Mac-only flags ────────────────────────────
        MAC_DROP = {"-UseMetal=1:1", "-UseMetal=1:0", "-UseMetal=0:0",
                    "-SkipBuild"}
        MAC_DROP_PREFIXES = ("-RiotClientPort=", "-RiotClientAuthToken=")

        # ── Derive Windows GameBaseDir from the exe path ──────────────────────
        # win_exe = C:\Riot Games\League of Legends\Game\League of Legends.exe
        # GameBaseDir = C:\Riot Games\League of Legends   (one level up from \Game)
        game_dir   = os.path.dirname(win_exe)               # …\Game
        base_dir   = os.path.dirname(game_dir)              # …\League of Legends
        # Use forward slashes — LoL on Windows accepts either
        win_base_dir = base_dir.replace("\\", "/")

        # ── Fetch RiotClientPort + RiotClientAuthToken from running client ─────
        win_port, win_token = self._get_windows_client_credentials()

        # ── Build translated list ─────────────────────────────────────────────
        translated = []
        for i, arg in enumerate(mac_cmdline):
            if i == 0:
                continue  # skip Mac exe path

            # Drop Mac-only flags (exact match)
            if arg in MAC_DROP:
                self.after(0, lambda a=arg: self._log_line(
                    f"  [TRANSLATOR] Dropped Mac flag: {a}", "subtle"))
                continue

            # Drop Mac RiotClient credentials (will be re-added below)
            if any(arg.startswith(p) for p in MAC_DROP_PREFIXES):
                self.after(0, lambda a=arg: self._log_line(
                    f"  [TRANSLATOR] Replaced Mac credential: {a}", "subtle"))
                continue

            # Replace Mac GameBaseDir with Windows path
            if arg.startswith("-GameBaseDir="):
                new_arg = f"-GameBaseDir={win_base_dir}"
                self.after(0, lambda old=arg, new=new_arg: self._log_line(
                    f"  [TRANSLATOR] {old}  →  {new}", "yellow"))
                translated.append(new_arg)
                continue

            translated.append(arg)

        # ── Append Windows RiotClient credentials ─────────────────────────────
        if win_port and win_token:
            translated.append(f"-RiotClientPort={win_port}")
            translated.append(f"-RiotClientAuthToken={win_token}")
            self.after(0, lambda p=win_port: self._log_line(
                f"  [TRANSLATOR] Injected Windows RiotClientPort={p}", "green"))
            self.after(0, lambda t=win_token: self._log_line(
                f"  [TRANSLATOR] Injected Windows RiotClientAuthToken={t}", "green"))
        else:
            self.after(0, lambda: self._log_line(
                "  [TRANSLATOR] WARNING: Could not find Windows RiotClient credentials.\n"
                "               Make sure the League Client is running on this PC.", "red"))

        return translated

    def _get_windows_client_credentials(self):
        """
        Read RiotClientPort and RiotClientAuthToken from the running
        LeagueClient process on Windows by inspecting its command line.
        Returns (port_str, token_str) or (None, None).
        """
        try:
            import psutil
            for proc in psutil.process_iter(["name", "cmdline"]):
                name = (proc.info.get("name") or "").lower()
                if "leagueclient" not in name:
                    continue
                cmdline = proc.info.get("cmdline") or []
                cmd_str = " ".join(cmdline)
                port  = self._extract_flag(cmd_str, "--app-port=") or \
                        self._extract_flag(cmd_str, "-RiotClientPort=")
                token = self._extract_flag(cmd_str, "--remoting-auth-token=") or \
                        self._extract_flag(cmd_str, "-RiotClientAuthToken=")
                if port and token:
                    return port, token
        except Exception as e:
            self.after(0, lambda: self._log_line(
                f"  [TRANSLATOR] psutil scan error: {e}", "subtle"))
        return None, None

    @staticmethod
    def _extract_flag(text, prefix):
        """Extract value after a flag prefix in a command-line string."""
        idx = text.find(prefix)
        if idx == -1:
            return None
        start = idx + len(prefix)
        # Value ends at next space or end of string; strip surrounding quotes
        end = text.find(" ", start)
        value = text[start:end] if end != -1 else text[start:]
        return value.strip('"').strip("'").strip()

    # ── Launch ────────────────────────────────────────────────────────────────

    def _launch_game(self, original_cmdline, info):
        exe = self._exe_var.get().strip()

        if not os.path.isfile(exe):
            self.after(0, lambda: self._log_line(
                f"Game EXE not found: {exe}", "red"))
            self.after(0, lambda: self._log_line(
                "Please set the correct path in the EXE field above.", "yellow"))
            return

        # Translate Mac args → Windows args
        self.after(0, lambda: self._log_line("── Translating Mac → Windows args ──", "accent"))
        win_args = self._translate_args(original_cmdline, exe)

        # subprocess.Popen list = each element becomes one properly-quoted argument
        # This matches Windows format:
        #   "exe" "server_string" "-flag1" "-flag2" ...
        full_cmd = [exe] + win_args

        # Log the final translated command
        self.after(0, lambda: self._log_line("── Final Windows Command ──", "accent"))
        for i, a in enumerate(full_cmd):
            tag = "accent" if i == 0 else ("green" if i == 1 else "")
            self.after(0, lambda idx=i, arg=a, t=tag: self._log_line(
                f"  [{idx:02d}]  {arg}", t))

        self.after(0, lambda: self._log_line("Launching game …", "yellow"))

        try:
            proc = subprocess.Popen(
                full_cmd,
                cwd=os.path.dirname(exe),
                creationflags=subprocess.CREATE_NEW_PROCESS_GROUP
                              if os.name == "nt" else 0
            )
            self._launches += 1
            self.after(0, lambda pid=proc.pid: self._log_line(
                f"✓  Game launched!  PID={pid}", "green"))
            self.after(0, lambda: self._launch_lbl.config(
                text=f"Launches: {self._launches}"))
        except FileNotFoundError:
            self.after(0, lambda: self._log_line(
                f"✗  EXE not found: {exe}", "red"))
        except PermissionError:
            self.after(0, lambda: self._log_line(
                "✗  Permission denied — run as Administrator.", "red"))
        except Exception as e:
            self.after(0, lambda: self._log_line(f"✗  Launch error: {e}", "red"))


if __name__ == "__main__":
    app = ReceiverApp()
    app.mainloop()
