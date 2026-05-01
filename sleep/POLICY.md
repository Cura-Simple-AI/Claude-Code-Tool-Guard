# sleep tool guard policy — design notes

The sleep tool guard is **not pattern-matched policy** — it does its own
minimal numeric validation and does not delegate to `tool_guard.py`.

## Why a tool guard at all?

Long sleeps inside a Claude session are uniquely bad: the user cannot
talk to Claude while a sleep is pending, and Claude burns its prompt
cache while waiting. The CLI ergonomic of `sleep N` makes it easy to
write `sleep 300` "to wait for CI" in a script — the user pays for the
session staying open.

Claude has dedicated tools for waiting: `ScheduleWakeup` (resume after
N seconds), `CronCreate` (one-shot or recurring), and `Monitor` (stream
events from a background process). Any of those is strictly better
than a blocking sleep.

## What the tool guard does

For each `sleep <duration>` call:

1. Parse `<duration>` (supports `30`, `30s`, `2m`, `1h`, `1d`).
2. If the parsed duration ≤ `SLEEP_TG_MAX` (default 30s), run real
   sleep transparently.
3. Otherwise, walk `/proc` upward looking for a `claude` ancestor:
   - **Under Claude:** print an error + suggest `ScheduleWakeup` /
     `CronCreate`, exit 1. Real sleep is not invoked.
   - **Not under Claude:** run real sleep transparently. Interactive
     shells / cron jobs / CI scripts are unaffected.

Unparseable durations also pass through unchanged — better to let real
sleep error on its own terms than try to second-guess.

## Configuration

| Env var | Default | Effect |
|---------|---------|--------|
| `SLEEP_TG_MAX` | `30` | Threshold (seconds) above which the Claude-ancestor check kicks in |
| `SLEEP_TG_REAL_BIN` | `/usr/bin/sleep` | Override real binary (tests, snap installs) |
| `_SLEEP_TG_ACTIVE` | unset | Internal recursion sentinel; do not set manually |

For a deliberate long sleep, invoke `/usr/bin/sleep` directly — that
sidesteps the wrapper via PATH.

## Test

```bash
# Should succeed (under threshold)
SLEEP_TG_REAL_BIN=/bin/true python3 scripts/tool-guard/sleep/wrapper.py 5
echo $?  # → 0

# Should pass through (not under Claude — real sleep runs for 60s)
SLEEP_TG_REAL_BIN=/bin/true python3 scripts/tool-guard/sleep/wrapper.py 60
echo $?  # → 0  (real sleep is /bin/true so this returns immediately)

# Emergency bypass: invoke real sleep directly (skips the wrapper entirely)
/usr/bin/sleep 999
```

The Claude-ancestor branch is the hard one to test — it requires the
Python process to be a descendant of a process named `claude`. The
numeric-validator pattern is well-trodden and field-tested in earlier
similar tools.

## Future extensions (not implemented)

- `timeout` tool guard — same numeric guard, same Claude-ancestor logic.
- `ScheduleWakeup` suggestion that includes the converted seconds in
  the suggested CronCreate cron expression.
- Per-script allowlist (e.g. CI scripts that legitimately need long
  sleeps).
