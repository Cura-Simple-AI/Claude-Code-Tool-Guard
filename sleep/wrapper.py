#!/usr/bin/env python3
"""sleep tool-guard — numeric guard, self-contained (does not use the engine).

Sums all argv durations (`sleep 1 30s 2m` = 151s) and blocks if the
total exceeds SLEEP_TG_MAX seconds AND a Claude ancestor is detected.
Long sleeps under Claude block the conversation — ScheduleWakeup /
CronCreate are the right tool for waits >30s.

Env:
  SLEEP_TG_MAX        max seconds under Claude (default 30, max 300)
  SLEEP_TG_REAL_BIN   override /usr/bin/sleep
"""
# TOOL_GUARD_STUB_v1 — canonical magic line.
from __future__ import annotations

import os
import re
import sys

REAL_SLEEP = os.environ.get("SLEEP_TG_REAL_BIN", "/usr/bin/sleep")  # TG_REAL_BIN_DEFAULT

# SLEEP_TG_MAX hard-capped at 300s — without an upper bound, setting it
# to 999999 effectively disables the guard.
_HARD_MAX = 300
_max_raw = os.environ.get("SLEEP_TG_MAX", "30")
try:
    MAX_SECS = int(_max_raw)
    if MAX_SECS > _HARD_MAX:
        print(
            f"sleep-tool-guard: SLEEP_TG_MAX={MAX_SECS} exceeds hard cap {_HARD_MAX}s "
            f"— clamping to {_HARD_MAX}. Use ScheduleWakeup/CronCreate for longer waits.",
            file=sys.stderr,
        )
        MAX_SECS = _HARD_MAX
    elif MAX_SECS < 0:
        print(
            f"sleep-tool-guard: SLEEP_TG_MAX={MAX_SECS} is negative — falling back to 30s.",
            file=sys.stderr,
        )
        MAX_SECS = 30
except ValueError:
    print(
        f"sleep-tool-guard: invalid SLEEP_TG_MAX={_max_raw!r} — falling back to default 30s.",
        file=sys.stderr,
    )
    MAX_SECS = 30

_DURATION_RE = re.compile(r"^(\d+(?:\.\d+)?)([smhd]?)$")
_UNITS = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}


def parse_duration(arg: str) -> float | None:
    """Parse a single sleep duration arg like '30', '30s', '2m', '1h', '1d'.
    Returns seconds as float, or None if the arg doesn't match the format."""
    m = _DURATION_RE.match(arg.strip())
    if not m:
        return None
    return float(m.group(1)) * _UNITS[m.group(2)]


def sum_durations(args: list[str]) -> float | None:
    """Sum all parseable durations across argv. Returns None if NO arg is
    parseable (e.g. `sleep --help`); otherwise the sum of the parseable
    ones — matching GNU sleep semantics where `sleep 1 2 3` waits 6s."""
    total = 0.0
    parsed_any = False
    for a in args:
        d = parse_duration(a)
        if d is not None:
            total += d
            parsed_any = True
    return total if parsed_any else None


def is_claude_ancestor() -> bool:
    """Walk /proc upward; return True if any ancestor's cmdline starts with 'claude'."""
    try:
        pid = os.getpid()
        for _ in range(15):
            status_path = f"/proc/{pid}/status"
            if not os.path.exists(status_path):
                return False
            with open(status_path) as f:
                content = f.read()
            ppid_lines = [ln for ln in content.splitlines() if ln.startswith("PPid:")]
            if not ppid_lines:
                return False
            ppid = int(ppid_lines[0].split()[1])
            if ppid <= 1:
                return False
            try:
                with open(f"/proc/{ppid}/cmdline", "rb") as f:
                    cmdline = f.read().replace(b"\x00", b" ").decode(errors="replace").strip()
                first = cmdline.split()[0] if cmdline else ""
                if first and os.path.basename(first) == "claude":
                    return True
            except (OSError, PermissionError):
                pass
            pid = ppid
    except OSError:
        pass
    return False


def _exec_real(args: list[str]) -> int:
    """Exec the real sleep binary, with a clear error message if it's
    missing instead of an uncaught FileNotFoundError traceback."""
    if not os.path.exists(REAL_SLEEP):
        print(
            f"sleep-tool-guard: real sleep binary not found at {REAL_SLEEP}. "
            "Set SLEEP_TG_REAL_BIN to its path.",
            file=sys.stderr,
        )
        return 127
    os.execv(REAL_SLEEP, [REAL_SLEEP] + args)
    return 0  # unreachable — execv replaces the process


def main() -> int:
    args = sys.argv[1:]
    if not args:
        return _exec_real([])

    secs = sum_durations(args)
    if secs is not None and secs > MAX_SECS and is_claude_ancestor():
        joined = " ".join(args)
        print(
            f"sleep-tool-guard: ❌ blocked sleep {joined} (sums to {secs:.0f}s) under Claude (max {MAX_SECS}s).",
            file=sys.stderr,
        )
        print(
            "  Long sleeps block the entire Claude session — the user cannot talk to Claude\n"
            "  while a sleep is pending. Use ScheduleWakeup or CronCreate for waits >30s.",
            file=sys.stderr,
        )
        return 1

    return _exec_real(args)


if __name__ == "__main__":
    sys.exit(main())
