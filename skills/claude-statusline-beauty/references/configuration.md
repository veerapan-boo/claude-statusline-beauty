# Configuration

Installation creates `<config-dir>/statusline-beauty/config.sh` — normally
`~/.claude/statusline-beauty/config.sh` — and never overwrites it afterwards, so
your edits survive every update.

Changes apply on the **next render**. No restart is needed.

You can edit the file directly, or just tell Claude what you want — "turn off the
CPU and RAM bars", "hide my session id, I'm screen sharing", "the status line is
slow" — and the skill makes the edit for you.

## How the file is read

The file is **parsed, not sourced**. Only `KEY=VALUE` lines using a known key
take effect; everything else is ignored, and nothing in the file is ever
executed.

This matters on Windows: an editor that saves with CRLF line endings would, if
the file were sourced, set every value to `1<CR>` and break bash arithmetic
inside the status line. Parsing sidesteps that entirely.

Accepted values: `1`/`0`, `true`/`false`, `yes`/`no`, `on`/`off` (any case).
Anything unrecognised falls back to the default. Spaces around `=` are allowed.

An environment variable of the same name **overrides the file**, which is handy
for a one-off check:

```bash
SLB_SHOW_MONTHLY=0 bash ~/.claude/statusline-beauty/statusline.sh < fixture.json
```

## Switches

| Key | Default | Effect when `0` | Cost when `1` |
|---|---|---|---|
| `SLB_SHOW_MONTHLY` | `1` | drops the `📅 ~$41.20/mo` segment | **highest** — scans every transcript modified this month (cached, but the first warm-up is the slowest thing here) |
| `SLB_SHOW_GIT` | `1` | drops the whole git line | one `git status --porcelain=v2` + one `git log -1` |
| `SLB_SHOW_TOOL_COUNTS` | `1` | drops `🧩 skills / 🤖 agents / 🔌 mcp / 🔧 tools` | one `jq` pass over the session transcript and every subagent transcript |
| `SLB_SHOW_CPU` | `1` | drops the CPU bar | reads `/proc/loadavg`; `nproc` once per machine (cached) |
| `SLB_SHOW_RAM` | `1` | drops the RAM bar and the disk-free suffix | `free` or `/proc/meminfo`, plus `df` at most once a minute |
| `SLB_CHECK_LATEST` | `1` | drops the `(LTS)` tag next to the version | a background `npm view` at most every 6 hours — **the only network call the status line makes** |
| `SLB_SHOW_FOOTER` | `1` | drops the version + `session_id` footer line | none |
| `SLB_BAR_WIDTH` | `25` | — | width of every usage bar, clamped to 10–60 |
| `SLB_LITE_MODE` | `0` | — | `1` switches to the minimal, low-color render (see below); costs nothing extra — it only changes what already-computed segments print |

Each switch gates the *work*, not just the display: turning a line off stops the
underlying commands from running at all.

## Recipes

**Make it as fast and quiet as possible** — no network, no month scan, no
transcript scanning:

```sh
SLB_SHOW_MONTHLY=0
SLB_CHECK_LATEST=0
SLB_SHOW_TOOL_COUNTS=0
```

**Screen sharing or recording** — the `session_id` is a real identifier, and the
month-to-date figure discloses spending:

```sh
SLB_SHOW_FOOTER=0
SLB_SHOW_MONTHLY=0
```

**Narrow terminal** — shorter bars leave room for the suffixes:

```sh
SLB_BAR_WIDTH=14
```

**Windows** — the CPU bar cannot render under Git Bash anyway, so drop the row:

```sh
SLB_SHOW_CPU=0
```

## Lite mode

`SLB_LITE_MODE=1` (or `manage.sh lite`) switches to a minimal render:

- Every color collapses to gray, except the model name, which keeps the purple
  normal mode reserves for Sonnet — no rainbow gradient anywhere, on any model.
- The `📀 cache HR` and `📈 avg/turn` segments are dropped from the stats line.
- The skills/agents/mcp/tools counters and the `📅` month-to-date prefix lose
  their emoji (the data stays, just as plain text).
- The ctx/5h/week circles collapse to two states: 🟢 under 75%, ⚪ at 75%+.
  The CPU/RAM bars keep the normal four-state circle regardless of this switch.
- The footer (version + `session_id`) and its separating blank line are
  omitted entirely — output ends right after the last usage bar.

Switch back with `SLB_LITE_MODE=0` or `manage.sh normal`. Everything else in
this file (which segments show, bar width) still applies on top of lite mode.

## What is never configurable

The context / 5h / weekly bars and the model + directory header always render.
They are the reason the status line exists, and they cost nothing beyond the
single `jq` pass over the JSON that Claude Code already provides on stdin.

---

[← SKILL.md](../SKILL.md) · [platform notes](platform-notes.md) · [troubleshooting](troubleshooting.md)
