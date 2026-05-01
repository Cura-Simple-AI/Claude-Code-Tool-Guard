# Security policy

## Reporting a vulnerability

Please report security issues privately by opening a [GitHub security
advisory](../../security/advisories/new) on this repository, or by
emailing the maintainers (see `pyproject.toml` once published, or git
log for active maintainers).

Do **not** open a public issue for security reports.

We aim to acknowledge reports within 7 days and provide a fix or
mitigation plan within 30 days for high-severity issues.

## Supported versions

| Version | Supported          |
|---------|--------------------|
| 0.1.x   | :white_check_mark: |

Pre-1.0 releases may include breaking changes between minor versions.
Once we hit 1.0, semantic versioning applies strictly.

## Threat model

`tool-guard` is a **policy guardrail**, not a sandbox.

### What it does

- Logs every wrapped CLI invocation with timestamp, argv (with secrets
  redacted), exit code, and caller info.
- Classifies invocations against an allow / warn / deny policy and
  blocks (or warns + logs) according to that policy.
- Provides an interactive prompt for unknown invocations (TTY users)
  and auto-denies for non-interactive callers.

### What it does NOT do

- **Process isolation.** A wrapped tool runs as the same user with the
  same permissions as the tool-guard. There is no chroot, no namespace,
  no syscall filter.
- **Argument tampering protection.** Once a call is allowed, the real
  binary receives the full argv. Anything the binary chooses to do
  with those args is unrestricted.
- **Shell-out protection.** A user (or AI agent) can bypass the
  tool-guard trivially by:
  - Running the real binary directly (`/usr/bin/az ...`) — the tool-guard
    only intercepts via `PATH` priority.
  - Running via `xargs`, `bash -c`, `eval`, or any subshell that
    constructs the command differently from the way the policy
    matches.
  - Using a different language binding (Python SDK, Node SDK) that
    talks to the same APIs.
  - Modifying `$PATH` to remove `/usr/local/bin/`.
- **Network-level protection.** If a wrapped tool can make HTTP calls,
  those calls are not inspected.

### Use cases it IS appropriate for

- A safety net against accidental destructive commands by humans
  (`az group delete` typed without thinking).
- A guardrail for AI agents that you've told to use the tool-guard but
  whose internal monologue you can't easily review.
- Audit logging of who-ran-what across a team's CLI usage.

### Use cases it is NOT appropriate for

- Defending against an adversarial user who has shell access on the
  same machine.
- Running untrusted code with reduced privileges. Use a real sandbox
  (Docker, gVisor, Firecracker) instead.
- Compliance-grade audit logs. The JSONL log is best-effort; see
  "Known limitations" below for failure modes.

## Known limitations

- **Recursion sentinel can be set externally.** Setting
  `_<TOOL>_TG_ACTIVE=1` in the environment causes the tool-guard to
  exec the real binary directly without consulting policy. This is
  intended for the tool-guard itself to defend against re-entry, but it
  doubles as an opt-out. Documented; not a bug.
- **`<TOOL>_TG_FORCE=1` bypasses deny.** Documented escape hatch.
  If you don't want to allow this, override the env var in your shell
  profile or container init.
- **`/proc`-based Claude detection.** The `claude_only` rule semantic
  walks `/proc/<pid>/status` and `cmdline`, which is Linux-only and
  can be spoofed by renaming the parent process. This is a heuristic,
  not a security boundary.
- **JSONL log writes are not atomic across concurrent invocations.**
  Two simultaneous tool-guard calls can interleave bytes if their
  serialised events exceed the OS pipe-buffer size (rare in practice
  for our event sizes; ~1 KB each). Multi-line entries are theoretically
  possible.
- **Log files are stored under `/tmp/tool-guard-logs/`** by default, which
  is ephemeral. For persistent audit, override `<TOOL>_TG_LOG_DIR`.

## Disclosure timeline (past advisories)

None to date.
