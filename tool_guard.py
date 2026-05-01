#!/usr/bin/env python3
"""
tool_guard.py — generic policy enforcement engine for CLI tool-guard stubs.

Each per-tool stub (e.g. scripts/tool-guard/az/wrapper.py) is a ~25-line
declaration that calls run() with the tool name, real binary path, and
an optional set of secret-bearing flags. This engine handles everything
else: config loading, classification, prompt, logging, redaction,
recursion defence, force override, dry-run, and exec.

Patterns adopted from prior art in shell-wrapper safety guards:
hard-coded real binary path (no PATH-resolution of own name), env-var
sentinel for recursion defence, /proc walk for ancestor detection,
structured per-call logging, severity tiers (block vs advise),
force-override env var.

Severity tiers:
  - deny  → log + block + exit 13. Real binary not invoked.
  - warn  → log + advise to stderr + exec. Same as allow but noisy.
  - allow → log + exec.

Default-mode for unmatched calls (set via `defaultMode` in config):
  - "deny"   → auto-deny silently (with informative stderr + log)
  - "prompt" → interactive [a/A/d/D] when stdin is a TTY; auto-deny
               otherwise. [A]/[D] also append the suggested pattern to
               the per-user `<tool>.config.local.json` so future
               calls match without re-prompting.
  - "allow"  → auto-allow (only sensible for trusted tools).

Config layering (deepest wins for defaultMode; allow/warn/deny are unioned):
  1. <repo>/.tool-guard/<tool>.config.json   (shared, committed)
  2. <repo>/.tool-guard/<tool>.config.local.json (per-user, gitignored)
  3. <repo>/.tool-guard/_defaults.json                (cross-cutting, applied last)

Each rule entry can be:
  - a plain string  → just the glob pattern, e.g. "version*"
  - an object       → {"pattern": "...", "message": "...", "claude_only": false}

`message` overrides the default deny / warn text; `claude_only: true`
makes the rule fire only when running under a Claude ancestor process
(useful for git's "warn on force-push under Claude" pattern).

Environment variables (TOOL = upper(tool_name) with '-' → '_'):
  <TOOL>_TG_REAL_BIN     override the real binary path
  (To bypass a deny in an emergency, invoke the real binary directly,
   e.g. /usr/bin/az.)
  <TOOL>_TG_DRYRUN       print classification + exit; do not exec
  <TOOL>_TG_DISABLE      disable logging (the call still runs)
  <TOOL>_TG_NONINTERACTIVE  treat stdin as non-TTY (auto-deny on prompt)
  <TOOL>_TG_CONFIG       single-file config override (replaces all
                              merged layers; for tests)
  <TOOL>_TG_LOG_DIR      override log dir (default: /tmp/tool-guard, one file per tool/day)
  _<TOOL>_TG_ACTIVE      internal recursion sentinel; do not set manually

The stub is responsible for the recursion sentinel check BEFORE
importing this engine — that way recursion path skips Python import
overhead. Engine still re-checks for safety.
"""
from __future__ import annotations

import fnmatch
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

DENY_EXIT_CODE = 13  # distinct from 0 (success), 1 (tool error), 127 (not found)
_PROC_WALK_DEPTH = 15  # /proc ancestor walk safety limit
_VALID_DEFAULT_MODES = {"deny", "allow", "warn", "prompt"}  # anything else → fall back to "deny"


# ─── Helpers ────────────────────────────────────────────────────────────


_VALID_TOOL_NAME_RE = re.compile(r'^[a-zA-Z][a-zA-Z0-9-]*$')


def _env_prefix(tool_name: str) -> str:
    """az → 'AZ', tool-with-dashes → 'TOOL_WITH_DASHES'.

    Tool name must match `^[a-zA-Z][a-zA-Z0-9-]*$` so the resulting env
    var prefix is a valid POSIX env name. Invalid names (containing
    dots, slashes, leading digits, etc.) raise ValueError early —
    setting `os.environ["FOO.BAR_TG_ACTIVE"] = ...` would otherwise
    succeed in Python but be unportable / silently ignored by sub-shells."""
    if not _VALID_TOOL_NAME_RE.match(tool_name):
        raise ValueError(
            f"tool-guard: invalid tool_name {tool_name!r} — must match "
            f"[a-zA-Z][a-zA-Z0-9-]* (got '{tool_name}'). Stub is misconfigured."
        )
    return tool_name.upper().replace("-", "_")


def _env(tool_name: str, suffix: str) -> str | None:
    """Read os.environ['<PREFIX>_TG_<SUFFIX>']."""
    return os.environ.get(f"{_env_prefix(tool_name)}_TG_{suffix}")


def _is_interactive(tool_name: str) -> bool:
    """True iff stdin is a TTY AND <TOOL>_TG_NONINTERACTIVE is not set."""
    if _env(tool_name, "NONINTERACTIVE") == "1":
        return False
    try:
        return sys.stdin.isatty()
    except (OSError, ValueError):
        return False


def _is_claude_ancestor(tool_name: str | None = None) -> bool:
    """Walk /proc upward from current pid; return True if any ancestor's
    cmdline starts with `claude`. Linux-only; returns False on other OSes
    or if /proc is not readable.

    Test hook: <TOOL>_TG_FAKE_CLAUDE=1 forces True, =0 forces False —
    useful for unit testing the claude_only branch in both directions.
    """
    if tool_name is not None:
        fake = _env(tool_name, "FAKE_CLAUDE")
        if fake == "1":
            return True
        if fake == "0":
            return False
    try:
        pid = os.getpid()
        for _ in range(_PROC_WALK_DEPTH):
            status_path = f"/proc/{pid}/status"
            if not os.path.exists(status_path):
                return False
            with open(status_path) as f:
                content = f.read()
            ppid_lines = [line for line in content.splitlines() if line.startswith("PPid:")]
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


def _get_parent_cmd() -> str | None:
    """Read /proc/<ppid>/cmdline to identify the immediate caller. Linux-only."""
    try:
        with open(f"/proc/{os.getppid()}/cmdline", "rb") as f:
            return f.read().replace(b"\x00", b" ").decode(errors="replace").strip() or None
    except OSError:
        return None


# ─── Config loading + merging ───────────────────────────────────────────


def _find_guards_dir(start: Path | None = None) -> Path | None:
    """Locate the `.tool-guard/` config dir in priority order:

      1. $TOOL_GUARD_DIR — explicit override (a directory path).
      2. Walk up from `start` (default cwd) looking for `.tool-guard/`.
         Mirrors how git locates `.git/`. Up to 20 levels.
      3. ~/.config/tool-guard/ — XDG-aligned per-user fallback.
      4. ~/.tool-guard/ — legacy/simple per-user fallback.

    The fallbacks (3 and 4) matter for invocations from arbitrary cwds,
    e.g. an MCP server running az with cwd=/usr/bin — without them, the
    walk-up reaches / without finding anything and the engine falls
    back to embedded deny-all. Returns None only if no candidate exists."""
    explicit = os.environ.get("TOOL_GUARD_DIR")
    if explicit:
        p = Path(explicit)
        return p if p.is_dir() else None

    p = (start or Path.cwd()).resolve()
    for _ in range(20):
        candidate = p / ".tool-guard"
        if candidate.is_dir():
            return candidate
        if p == p.parent:
            break
        p = p.parent

    home = Path.home()
    for fallback in (home / ".config" / "tool-guard", home / ".tool-guard"):
        if fallback.is_dir():
            return fallback
    return None


def _load_one(path: Path | None) -> dict | None:
    """Read + parse a single JSON config file. Returns None if missing,
    malformed, or not a JSON object at the top level (with a warning to
    stderr — tool-guard must not break on bad config files)."""
    if not path or not path.exists():
        return None
    try:
        # utf-8-sig silently strips a leading UTF-8 BOM (0xEF 0xBB 0xBF)
        # if present — Windows editors sometimes save JSON with one,
        # and stdlib json.load chokes on it with a cryptic error.
        with path.open("r", encoding="utf-8-sig") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"tool-guard: config load failed at {path}: {e} — ignoring this file.", file=sys.stderr)
        return None
    if not isinstance(data, dict):
        print(
            f"tool-guard: config at {path} is valid JSON but the top level is not an object "
            f"(got {type(data).__name__}) — ignoring this file.",
            file=sys.stderr,
        )
        return None
    return data


def _validate_default_mode(value) -> str:
    """Validate `defaultMode` value from config. Accepts {"deny", "allow",
    "warn", "prompt"}; anything else (including None) falls back to "deny"
    with a stderr warning. Defaulting to deny on garbage is the safer
    choice — silently auto-allowing because of a typo would be a security
    hole."""
    if value is None:
        return "deny"
    # Normalize: strip whitespace + lowercase. "DENY", " deny ", "deny\n"
    # all mean "deny" — don't make users guess at exact casing/whitespace
    # and silently fall back to deny when their config "looks fine".
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in _VALID_DEFAULT_MODES:
            return normalized
    print(
        f"tool-guard: invalid defaultMode={value!r} — must be one of "
        f"{sorted(_VALID_DEFAULT_MODES)} (case + whitespace insensitive). "
        "Falling back to 'deny'.",
        file=sys.stderr,
    )
    return "deny"


def _normalize_rules(raw) -> list[dict]:
    """Convert a mixed string/dict rule list into a uniform list of dicts.
    Each dict has at least `pattern`; optional `message`, `claude_only`.

    If `raw` is None, returns []. If `raw` is anything other than a
    list/tuple (e.g. a string accidentally written instead of an array),
    warns to stderr and returns [] — better than iterating the string
    character-by-character and producing nonsense rules."""
    if raw is None:
        return []
    if not isinstance(raw, (list, tuple)):
        print(
            f"tool-guard: rule list must be an array, got {type(raw).__name__} ({raw!r:.50}) "
            "— ignoring this section.",
            file=sys.stderr,
        )
        return []
    out: list[dict] = []
    for r in raw:
        # Reject empty / whitespace-only patterns — fnmatch("", "") returns
        # True, so an empty pattern in an allow list silently matches an
        # empty argv item (likely a bug in the config, not what was meant).
        if isinstance(r, str):
            if not r.strip():
                print(
                    f"tool-guard: skipping empty pattern in rule list "
                    "(likely a config typo).",
                    file=sys.stderr,
                )
                continue
            out.append({"pattern": r})
        elif isinstance(r, dict) and isinstance(r.get("pattern"), str):
            if not r["pattern"].strip():
                print(
                    f"tool-guard: skipping rule with empty pattern: {r!r}",
                    file=sys.stderr,
                )
                continue
            # pattern must be a string — fnmatch crashes on int/None/other.
            # Also validate claude_only is a bool — strings like "true"/"false"
            # are both truthy in Python and would silently treat the rule as
            # claude-only, which is the opposite of what users typing "false"
            # would expect. Reject with a warning so the typo is visible.
            if "claude_only" in r and not isinstance(r["claude_only"], bool):
                print(
                    f"tool-guard: rule {r['pattern']!r}: claude_only must be true/false (boolean), "
                    f"got {type(r['claude_only']).__name__} ({r['claude_only']!r}). "
                    "Treating as if claude_only were not set (rule always active).",
                    file=sys.stderr,
                )
                # Drop the field so downstream sees default behaviour
                r = {k: v for k, v in r.items() if k != "claude_only"}
            if "type" in r and r["type"] not in ("glob", "regex"):
                print(
                    f"tool-guard: rule {r['pattern']!r}: type must be 'glob' or 'regex', "
                    f"got {r['type']!r}. Falling back to 'glob' (default).",
                    file=sys.stderr,
                )
                r = {k: v for k, v in r.items() if k != "type"}
            out.append(r)
        elif isinstance(r, dict) and "pattern" in r:
            print(
                f"tool-guard: rule pattern must be a string, got "
                f"{type(r['pattern']).__name__} ({r['pattern']!r:.50}) "
                "— skipping this rule.",
                file=sys.stderr,
            )
        # else: silently skip malformed entries (don't break on bad config)
    return out


def _load_config(tool_name: str) -> dict:
    """Load and merge the layered config files for `tool_name`.

    Override priority:
      1. <TOOL>_TG_CONFIG → load that single file, ignore the layers
      2. .tool-guard/<tool>.config.json + .config.local.json + _defaults.json
      3. Restrictive embedded fallback (`defaultMode: "deny"`)
    """
    explicit = _env(tool_name, "CONFIG")
    if explicit:
        explicit_path = Path(explicit)
        if not explicit_path.exists():
            # User explicitly pointed us at a config that's not there —
            # almost certainly a typo. Warn so they don't silently fall
            # through to deny-all. (Layered configs are silently optional;
            # an explicit override is intentional.)
            print(
                f"tool-guard: {_env_prefix(tool_name)}_TG_CONFIG={explicit!r} "
                "does not exist — falling back to embedded deny-all default. "
                "Check the path for typos.",
                file=sys.stderr,
            )
        cfg = _load_one(explicit_path) or {}
        return {
            "defaultMode": _validate_default_mode(cfg.get("defaultMode")),
            "allow": _normalize_rules(cfg.get("allow", [])),
            "warn":  _normalize_rules(cfg.get("warn", [])),
            "deny":  _normalize_rules(cfg.get("deny", [])),
        }

    guards_dir = _find_guards_dir()
    if guards_dir is None:
        return {"defaultMode": "deny", "allow": [], "warn": [], "deny": []}

    shared = _load_one(guards_dir / f"{tool_name}.config.json") or {}
    local = _load_one(guards_dir / f"{tool_name}.config.local.json") or {}
    defaults = _load_one(guards_dir / "_defaults.json") or {}

    # Merge order: shared → local → defaults (so per-tool specific rules
    # match before the cross-cutting defaults; defaults serve as backstop)
    return {
        "defaultMode": _validate_default_mode(
            local.get("defaultMode") or shared.get("defaultMode")
        ),
        "allow": (
            _normalize_rules(shared.get("allow", []))
            + _normalize_rules(local.get("allow", []))
            + _normalize_rules(defaults.get("allow", []))
        ),
        "warn": (
            _normalize_rules(shared.get("warn", []))
            + _normalize_rules(local.get("warn", []))
            + _normalize_rules(defaults.get("warn", []))
        ),
        "deny": (
            _normalize_rules(shared.get("deny", []))
            + _normalize_rules(local.get("deny", []))
            + _normalize_rules(defaults.get("deny", []))
        ),
    }


def _rule_active(rule: dict, under_claude: bool) -> bool:
    """A rule with `claude_only: true` only fires when running under Claude."""
    if rule.get("claude_only") and not under_claude:
        return False
    return True


def _rule_matches(cmd: str, rule: dict) -> bool:
    """Check if `cmd` matches `rule['pattern']` using the rule's matcher.

    Supported `type` values:
      - "glob" (default) — fnmatch glob; pattern matches whole string
      - "regex" — Python re.search; pattern matches anywhere in cmd.
        Use `\\b` for word boundaries (the main reason to choose regex
        over glob — fnmatch cannot express word boundaries, so a glob
        like `*[Ff]ixes #*` matches "prefixes #1" as well as "fixes #1").

    Invalid regex patterns are caught and logged as a warning; the
    rule is treated as not-matching (safer than crashing the wrapper)."""
    matcher_type = rule.get("type", "glob")
    pattern = rule["pattern"]
    if matcher_type == "regex":
        try:
            return re.search(pattern, cmd) is not None
        except re.error as e:
            print(
                f"tool-guard: rule {pattern!r}: invalid regex ({e}) — "
                "treating as no-match. Fix the pattern.",
                file=sys.stderr,
            )
            return False
    # default: glob
    return fnmatch.fnmatch(cmd, pattern)


def classify(argv: list[str], config: dict, under_claude: bool) -> tuple[str, dict | None]:
    """Return (decision, matched_rule_dict | None).

    decision ∈ {"deny", "warn", "allow", "prompt"} — first three come
    from rule matches; "prompt" is the defaultMode value (or whatever
    string defaultMode resolves to).

    Precedence: deny > warn > allow > defaultMode. First match within
    each category wins."""
    cmd = " ".join(argv)

    for rule in config["deny"]:
        if not _rule_active(rule, under_claude):
            continue
        if _rule_matches(cmd, rule):
            return "deny", rule
    for rule in config["warn"]:
        if not _rule_active(rule, under_claude):
            continue
        if _rule_matches(cmd, rule):
            return "warn", rule
    for rule in config["allow"]:
        if not _rule_active(rule, under_claude):
            continue
        if _rule_matches(cmd, rule):
            return "allow", rule

    return config["defaultMode"], None


# ─── Pattern derivation + redaction + logging ───────────────────────────


def derive_pattern(argv: list[str]) -> str:
    """Suggest a glob pattern to remember an unknown command.

      az logout                          → 'logout*'
      az boards work-item show --id 9    → 'boards work-item show*'
      az --version                       → '--version'
      az account get-access-token --r ?  → 'account get-access-token*'
    """
    if not argv:
        return "*"
    if argv[0].startswith("-"):
        return argv[0]
    parts: list[str] = []
    for a in argv:
        if a.startswith("-"):
            break
        parts.append(a)
    return " ".join(parts) + "*"


def redact(argv: list[str], secret_flags: set[str]) -> list[str]:
    """Replace values immediately following secret-bearing flags with <redacted>.
    Handles both `--password value` and `--password=value` forms."""
    out: list[str] = []
    skip_next = False
    for arg in argv:
        if skip_next:
            out.append("<redacted>")
            skip_next = False
            continue
        out.append(arg)
        if arg in secret_flags:
            skip_next = True
        elif "=" in arg and arg.split("=", 1)[0] in secret_flags:
            flag = arg.split("=", 1)[0]
            out[-1] = f"{flag}=<redacted>"
    return out


def _log_file(tool_name: str) -> Path:
    """Default log path is /tmp/tool-guard/<tool>_YYYYMMDD.log (one
    file per tool per day, flat layout). /tmp is ephemeral — logs are
    lost on devcontainer rebuild. Override <TOOL>_TG_LOG_DIR to point
    at a persistent dir."""
    base = Path(_env(tool_name, "LOG_DIR") or "/tmp/tool-guard")
    if base.exists() and not base.is_dir():
        # mkdir with exist_ok=True still raises FileExistsError if the
        # path is a non-directory — translate to an actionable message.
        # write_event() catches OSError, so the wrapper still works
        # (just without logging) — but the user needs to know to fix it.
        raise OSError(
            f"log path {base} exists but is a file, not a directory. "
            f"Remove it (rm {base}) or set {tool_name.upper()}_TG_LOG_DIR "
            f"to a different path."
        )
    base.mkdir(parents=True, exist_ok=True)
    return base / f"{tool_name}_{time.strftime('%Y%m%d')}.log"


def write_event(tool_name: str, event: dict) -> None:
    """Append one JSONL event to the per-tool log file. Failures are
    warnings, never fatal — logging must not break the wrapped tool."""
    if _env(tool_name, "DISABLE") == "1":
        return
    try:
        path = _log_file(tool_name)
        with path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(event, ensure_ascii=False) + "\n")
    except OSError as e:
        print(f"{tool_name}-tool-guard: log write failed: {e}", file=sys.stderr)


# ─── Prompt + auto-save to local config ─────────────────────────────────


def prompt_user(tool_name: str, argv: list[str]) -> tuple[str, bool]:
    """Interactive prompt for unmatched commands. Returns (decision, persist)
    where decision ∈ {allow, deny} and persist indicates whether to write
    the suggested pattern to the local config."""
    suggested = derive_pattern(argv)
    print(
        f"\n{tool_name}-tool-guard: '{tool_name} {' '.join(argv)}' is not in the policy.\n"
        f"  Suggested pattern: '{suggested}'\n"
        f"  [a] allow once   [A] allow always (save pattern to local config)\n"
        f"  [d] deny once    [D] deny always  (save pattern to local config)",
        file=sys.stderr,
    )
    while True:
        try:
            sys.stderr.write("  Choice [a/A/d/D]: ")
            sys.stderr.flush()
            choice = input().strip()
        except (EOFError, KeyboardInterrupt):
            print(f"\n{tool_name}-tool-guard: prompt cancelled — denying.", file=sys.stderr)
            return "deny", False
        if choice == "a":
            return "allow", False
        if choice == "A":
            return "allow", True
        if choice == "d":
            return "deny", False
        if choice == "D":
            return "deny", True
        print(f"  invalid choice '{choice}' — try again.", file=sys.stderr)


def append_to_local_config(tool_name: str, pattern: str, decision: str) -> Path | None:
    """Append `pattern` to the allow or deny list in the per-user
    `.tool-guard/<tool>.config.local.json` file. Creates the file
    (and the .tool-guard/ dir at cwd if no ancestor has one) if needed.
    Returns the path written to, or None if the write failed."""
    guards_dir = _find_guards_dir()
    if guards_dir is None:
        guards_dir = Path.cwd() / ".tool-guard"
        try:
            guards_dir.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            print(f"{tool_name}-tool-guard: failed to create {guards_dir}: {e}", file=sys.stderr)
            return None

    local_path = guards_dir / f"{tool_name}.config.local.json"
    if local_path.exists():
        try:
            with local_path.open("r", encoding="utf-8") as f:
                local = json.load(f)
        except (OSError, json.JSONDecodeError):
            local = {}
    else:
        local = {
            "_comment": (
                f"Per-user {tool_name}-tool-guard overrides. Gitignored. "
                "Populated by the tool-guard's prompt-mode 'save' actions. "
                "Edit by hand to remove or generalise patterns."
            ),
        }

    key = "allow" if decision == "allow" else "deny"
    local.setdefault(key, [])
    if pattern not in local[key]:
        local[key].append(pattern)

    try:
        with local_path.open("w", encoding="utf-8") as f:
            json.dump(local, f, indent=2, ensure_ascii=False)
            f.write("\n")
    except OSError as e:
        print(f"{tool_name}-tool-guard: failed to write {local_path}: {e}", file=sys.stderr)
        return None

    return local_path


# ─── Main entry ─────────────────────────────────────────────────────────


def _build_event(
    tool_name: str,
    argv: list[str],
    secret_flags: set[str],
    decision: str,
    rule: dict | None,
    exit_code: int,
    duration_ms: int,
) -> dict:
    return {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "tool": tool_name,
        "argv": redact(argv, secret_flags),
        "cwd": os.getcwd(),
        "exit": exit_code,
        "duration_ms": duration_ms,
        "ppid": os.getppid(),
        "parent_cmd": _get_parent_cmd(),
        "user": os.environ.get("USER"),
        "claude_session": os.environ.get("CLAUDE_SESSION_ID"),
        "policy": {
            "decision": decision,
            "rule": rule.get("pattern") if rule else None,
        },
    }


def _print_deny_message(
    tool_name: str,
    argv: list[str],
    rule: dict | None,
    *,
    auto_deny_no_match: bool = False,
) -> None:
    """Render the deny message to stderr, using the rule's custom message
    if present; otherwise a default message. `auto_deny_no_match=True`
    indicates this was a non-TTY auto-deny while `defaultMode: "prompt"`
    (a different from the rule-matched-deny case). When `rule` is None
    we're in `defaultMode: "deny"` + no allow match — show the clearer
    no-rule phrasing."""
    if auto_deny_no_match:
        print(
            f"{tool_name}-tool-guard: ❌ no policy match for '{tool_name} {' '.join(argv)}'"
            " and stdin is not a TTY → denying.\n"
            f"  Suggested pattern: '{derive_pattern(argv)}'\n"
            f"  Add to .tool-guard/{tool_name}.config.json (shared, committed) or\n"
            f"  .tool-guard/{tool_name}.config.local.json (per-user, gitignored).",
            file=sys.stderr,
        )
        return

    if rule is None:
        # defaultMode="deny" + no allow rule matched — clearer than "<unknown>"
        print(
            f"{tool_name}-tool-guard: ❌ no allow rule matched '{tool_name} {' '.join(argv)}' "
            "and defaultMode is 'deny' → blocked.\n"
            f"  Suggested allow pattern: '{derive_pattern(argv)}'\n"
            f"  Add to .tool-guard/{tool_name}.config.json (shared, committed) or\n"
            f"  .tool-guard/{tool_name}.config.local.json (per-user, gitignored).",
            file=sys.stderr,
        )
        return

    pattern = rule.get("pattern", "<unknown>")
    custom = rule.get("message")
    print(f"{tool_name}-tool-guard: ❌ blocked by policy rule '{pattern}'.", file=sys.stderr)
    if custom:
        for line in custom.splitlines():
            print(f"  {line}", file=sys.stderr)
    print(
        f"  To allow this command: edit .tool-guard/{tool_name}.config.json (shared)\n"
        f"  or .tool-guard/{tool_name}.config.local.json (per-user, gitignored).",
        file=sys.stderr,
    )


def _print_warn_message(tool_name: str, argv: list[str], rule: dict | None) -> None:
    """Render a warn-tier advisory message to stderr (call still proceeds).
    `rule=None` means defaultMode="warn" — show a generic notice instead of
    the misleading 'matched warn rule <unknown>' phrasing."""
    if rule is None:
        print(
            f"{tool_name}-tool-guard: ⚠ no rule matched '{tool_name} {' '.join(argv)}' "
            "and defaultMode is 'warn' → proceeding with notice.",
            file=sys.stderr,
        )
        return
    pattern = rule.get("pattern", "<unknown>")
    custom = rule.get("message")
    print(f"{tool_name}-tool-guard: ⚠ matched warn rule '{pattern}'.", file=sys.stderr)
    if custom:
        for line in custom.splitlines():
            print(f"  {line}", file=sys.stderr)


def run(
    *,
    tool_name: str,
    real_bin: str,
    secret_flags: set[str] | frozenset[str] = frozenset(),
) -> int:
    """Engine entry point. Called from per-tool stub. Returns exit code.

    The stub is responsible for the FAST recursion-sentinel check before
    importing this module; the engine re-checks for safety when a stub
    forgets, but the slow path (full Python import + this function call)
    is then taken on each recursive hop.
    """
    secret_flags = frozenset(secret_flags)

    # Late recursion guard (in case the stub forgot or env-var was added
    # after the stub ran). On a hot recursion path the stub's own check
    # is preferred — this is a safety net, not the primary defence.
    sentinel = f"_{_env_prefix(tool_name)}_TG_ACTIVE"
    real_bin_override = _env(tool_name, "REAL_BIN")
    if real_bin_override:
        real_bin = real_bin_override
    if os.environ.get(sentinel) and os.environ.get(sentinel) != "1":
        # Sentinel set to anything other than our own '1' marker — assume
        # we're nested inside another invocation and exec real bin.
        os.execv(real_bin, [real_bin] + sys.argv[1:])
    os.environ[sentinel] = "1"

    if not (os.path.isfile(real_bin) and os.access(real_bin, os.X_OK)):
        # Combined check covers:
        #   missing path / directory / non-executable file / broken symlink.
        # subprocess.run on any of these raises an uncaught OSError;
        # better to fail early with a clear message + 127.
        if not os.path.exists(real_bin):
            reason = "not found"
        elif os.path.isdir(real_bin):
            reason = "is a directory, not an executable"
        elif not os.access(real_bin, os.X_OK):
            reason = "is not executable (permissions)"
        else:
            reason = "is not a regular file"
        print(
            f"{tool_name}-tool-guard: real binary at {real_bin} {reason}. "
            f"Set {_env_prefix(tool_name)}_TG_REAL_BIN to its path.",
            file=sys.stderr,
        )
        return 127

    argv = sys.argv[1:]
    config = _load_config(tool_name)
    under_claude = _is_claude_ancestor(tool_name)
    decision, matched_rule = classify(argv, config, under_claude)

    # Dry-run: print classification, exit. Do not prompt or log.
    if _env(tool_name, "DRYRUN") == "1":
        rule_str = (
            f'rule="{matched_rule["pattern"]}"' if matched_rule else "rule=<defaultMode>"
        )
        outcome = {
            "allow": "would log + run real binary",
            "warn":  "would warn + log + run real binary",
            "deny":  f"would block (exit {DENY_EXIT_CODE}) without running real binary",
            "prompt": (
                f"would prompt user (TTY) or auto-deny (non-TTY); "
                f"suggested pattern: '{derive_pattern(argv)}'"
            ),
        }.get(decision, f"unknown decision: {decision}")
        print(
            f"DRYRUN: classify={decision} {rule_str} under_claude={under_claude} — {outcome}",
            file=sys.stderr,
        )
        return 0

    # Prompt path: defaultMode resolved to "prompt" (or any unknown value).
    if decision == "prompt":
        if not _is_interactive(tool_name):
            event = _build_event(
                tool_name, argv, secret_flags,
                decision="deny",
                rule={"pattern": "<no-match,non-interactive>"},
                exit_code=DENY_EXIT_CODE,
                duration_ms=0,
            )
            write_event(tool_name, event)
            _print_deny_message(tool_name, argv, None, auto_deny_no_match=True)
            return DENY_EXIT_CODE

        prompted_decision, persist = prompt_user(tool_name, argv)
        if persist:
            saved = append_to_local_config(tool_name, derive_pattern(argv), prompted_decision)
            if saved:
                print(
                    f"{tool_name}-tool-guard: ✓ saved '{derive_pattern(argv)}' → {saved} ({prompted_decision})",
                    file=sys.stderr,
                )
        decision = prompted_decision
        matched_rule = {"pattern": "<prompted>"}

    if decision == "deny":
        event = _build_event(
            tool_name, argv, secret_flags,
            decision="deny",
            rule=matched_rule,
            exit_code=DENY_EXIT_CODE,
            duration_ms=0,
        )
        write_event(tool_name, event)
        _print_deny_message(tool_name, argv, matched_rule)
        return DENY_EXIT_CODE

    if decision == "warn":
        _print_warn_message(tool_name, argv, matched_rule)
        # Fall through to exec — warn is "noisy allow"

    start = time.time()
    proc = subprocess.run([real_bin] + argv)  # stdin/stdout/stderr inherited
    duration_ms = int((time.time() - start) * 1000)

    event = _build_event(
        tool_name, argv, secret_flags,
        decision=decision,
        rule=matched_rule,
        exit_code=proc.returncode,
        duration_ms=duration_ms,
    )
    write_event(tool_name, event)

    return proc.returncode
