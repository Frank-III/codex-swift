#!/usr/bin/env python3
"""Run the real Codex application loop through a PTY after a large synthetic resume.

Usage:
  swift build -c release --product codex-swift
  python3 Scripts/large-session-pty-soak.py .build/release/codex-swift 1000
"""

import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

binary = sys.argv[1]
turns = sys.argv[2] if len(sys.argv) > 2 else "1000"
pid, descriptor = pty.fork()
if pid == 0:
    os.environ["SUPATERM_SOCKET_PATH"] = "/tmp/codex-soak-supaterm.sock"
    os.execv(binary, [binary, "--large-demo", turns])

fcntl.ioctl(descriptor, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
os.set_blocking(descriptor, False)
start = time.monotonic()
last_output = start
last_memory_sample = 0.0
output_bytes = 0
peak_rss_kib = 0
sent_at = None
query_tail = b""
received_after_send = False
seen_final_fixture = False

try:
    while time.monotonic() - start < 90:
        now = time.monotonic()
        if now - last_memory_sample > 0.05:
            last_memory_sample = now
            try:
                raw = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)]).strip()
                peak_rss_kib = max(peak_rss_kib, int(raw or b"0"))
            except (OSError, subprocess.SubprocessError, ValueError):
                pass

        readable, _, _ = select.select([descriptor], [], [], 0.02)
        if readable:
            try:
                data = os.read(descriptor, 65_536)
            except BlockingIOError:
                data = b""
            if data:
                output_bytes += len(data)
                last_output = now
                if sent_at is not None:
                    received_after_send = True
                if (b"iteration " + turns.encode()) in data:
                    seen_final_fixture = True
                combined = query_tail + data
                for _ in range(combined.count(b"\x1b[6n")):
                    os.write(descriptor, b"\x1b[40;1R")
                query_tail = combined[-4:]

        # Do not send the prompt during the CPU-heavy cold render. Wait until the final fixture marker has
        # reached the PTY and output has become quiet, then exercise the ordinary composer/submit path.
        if sent_at is None and seen_final_fixture and now - last_output > 0.4:
            startup_seconds = now - start
            os.write(descriptor, b"hello after resume\r")
            sent_at = time.monotonic()
            received_after_send = False
        elif sent_at is not None and received_after_send and now - last_output > 0.8:
            chat_seconds = now - sent_at
            print(f"startup_quiet_seconds={startup_seconds:.3f}")
            print(f"chat_completion_quiet_seconds={chat_seconds:.3f}")
            print(f"output_bytes={output_bytes}")
            print(f"peak_rss_mib={peak_rss_kib / 1024:.1f}")
            print("post_resume_output=yes")
            break
    else:
        print("timeout=yes")
        raise SystemExit(1)
finally:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
