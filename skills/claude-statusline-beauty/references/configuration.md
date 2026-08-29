# Configuration

Installation creates `<config-dir>/statusline-beauty/config.sh` — normally
`~/.claude/statusline-beauty/config.sh` — and never overwrites or removes a
line from it afterwards, so your edits survive every update. `manage.sh
update` may *append* a newly available reference block (commented out, with
its default) if the file predates that key family — see
[Staying current](#staying-current) below — but it never touches a line that
was already there.

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
| `SLB_SHOW_MONTHLY` | `1` | drops the `📅 ~$41.20/mo` segment | **highest** — scans every transcript modified this month (cached, but the first warm-up is the slowest thing here). In lite mode this only actually runs for the session's first 10 turns — past that the segment stops printing and the scan is skipped outright, `SLB_SHOW_MONTHLY` or not |
| `SLB_SHOW_GIT` | `1` | drops the whole git line | one `git status --porcelain=v2` + one `git log -1`, memoized for 5s |
| `SLB_SHOW_TOOL_COUNTS` | `1` | drops `🧩 skills / 🤖 agents / 🔌 mcp / 🔧 tools` | one `jq` pass over the session transcript and every subagent transcript |
| `SLB_SHOW_CPU` | `1` | drops the CPU bar | reads `/proc/loadavg`; `nproc` once per machine (cached). **No effect in lite mode** — that bar never renders there, so the read never happens either |
| `SLB_SHOW_RAM` | `1` | drops the RAM bar and the disk-free suffix | `free` or `/proc/meminfo`, plus `df` at most once a minute. **No effect in lite mode** — same reason |
| `SLB_CHECK_LATEST` | `1` | drops the `(LTS)` tag next to the version | a background `npm view` at most every 6 hours — **the only network call the status line makes** |
| `SLB_SHOW_FOOTER` | `1` | drops the version + `session_id` footer line | none |
| `SLB_BAR_WIDTH` | `25` | — | width of every usage bar, clamped to 10–60 |
| `SLB_LITE_MODE` | `0` | — | `1` switches to the minimal, low-color render (see below); costs nothing extra — it only changes what already-computed segments print |

Each switch gates the *work*, not just the display: turning a line off stops the
underlying commands from running at all.

## Emoji icons

Every decorative icon the status line prints (model, folder, git branch,
ahead/behind, cost/month/turns/cache/avg, skills/agents/mcp/tools counters,
fast-mode, session id) can be re-skinned with an `SLB_EMOJI_*` key — same
`config.sh`, same "parsed not sourced" rules, same env-var-wins-over-file
precedence as the switches above. The only difference: the value can be any
single non-whitespace token (an emoji, not `1`/`0`), since that's what these
keys hold.

The four usage-bar status circles (🔴🟡⚪🟢), the ⚠️ context-half warning, and
the two lite-mode bar markers (🌎🧩) are **not** on this list — they're a
separate `SLB_EMOJI_STATUS_*` namespace, see [below](#status-icons), since
they encode meaning by color/threshold rather than pure identity.

| Key | Default | Where it renders |
|---|---|---|
| `SLB_EMOJI_MODEL_OPUS` | `✨` | header / lite line 1 — Opus |
| `SLB_EMOJI_MODEL_SONNET` | `⚡️` | header / lite line 1 — Sonnet |
| `SLB_EMOJI_MODEL_OTHER` | `☄️` | header / lite line 1 — any other model |
| `SLB_EMOJI_FOLDER_NORMAL` | `📁` | header — current directory (normal mode) |
| `SLB_EMOJI_FOLDER_LITE` | `🌐` | lite line 2 — current directory |
| `SLB_EMOJI_FAST` | `🚀` | header — fast-mode indicator |
| `SLB_EMOJI_EFFORT` | `🧠` | header / lite line 1 — effort/thinking level |
| `SLB_EMOJI_SKILLS` | `🧩` | header — skills counter |
| `SLB_EMOJI_AGENTS` | `🤖` | header — agents counter |
| `SLB_EMOJI_MCP` | `🔌` | header — mcp counter |
| `SLB_EMOJI_TOOLS` | `🔧` | header — tools counter |
| `SLB_EMOJI_COST` | `🌿` | stats line — session cost |
| `SLB_EMOJI_MONTH_NORMAL` | `📅` | stats line — month-to-date cost |
| `SLB_EMOJI_MONTH_LITE` | `💲` | lite mode's trailing month-to-date line |
| `SLB_EMOJI_TURNS` | `♻️` | stats line — turn count |
| `SLB_EMOJI_COST_PER_TURN` | `💲` | stats line — cost per turn |
| `SLB_EMOJI_CACHE` | `📀` | stats line — cache hit rate |
| `SLB_EMOJI_AVG_TOKENS` | `📈` | stats line — avg tokens/turn |
| `SLB_EMOJI_GIT_BRANCH_NORMAL` | `🌐` | git line — branch (normal mode) |
| `SLB_EMOJI_GIT_BRANCH_LITE` | `🌿` | lite line 2 — branch |
| `SLB_EMOJI_AHEAD` | `↑` | git line — commits ahead |
| `SLB_EMOJI_BEHIND` | `↓` | git line — commits behind |
| `SLB_EMOJI_SESSION_ID` | `📡` | lite line 1 only — short session id |

`_NORMAL`/`_LITE` pairs exist because normal and lite mode already use a
different default icon for that field — setting one never affects the other
mode. Fields with a single key already use the same icon in both modes (or
only appear in one), so there's nothing to split.

```sh
SLB_EMOJI_MODEL_OPUS=🐉
SLB_EMOJI_COST=💵
```

All 23 keys are listed, commented out with their defaults, at the bottom of
the default `config.sh` — uncomment and edit any of them.

## Status icons

A deliberately separate key family from `SLB_EMOJI_*` above —
`SLB_EMOJI_STATUS_*` — for the icons that encode a color-coded
danger/warn/ok threshold on the usage bars, not just a decorative identity.
Same `config.sh`, same parsing rules, same env-var-wins-over-file precedence;
kept as its own namespace so it's never ambiguous which set an icon belongs
to when re-skinning.

| Key | Default | Where it renders |
|---|---|---|
| `SLB_EMOJI_STATUS_CIRCLE_RED` | `🔴` | ctx/5h/week/CPU/RAM circle at ≥75% usage (normal mode only) |
| `SLB_EMOJI_STATUS_CIRCLE_YELLOW` | `🟡` | ctx/5h/week/CPU/RAM circle at 50–74% (normal mode only) |
| `SLB_EMOJI_STATUS_CIRCLE_WHITE` | `⚪` | circle at 25–74% (normal) / ≥75% (lite ctx/5h/week) — shared between modes, same meaning |
| `SLB_EMOJI_STATUS_CIRCLE_GREEN` | `🟢` | circle under the warn threshold — shared between modes, same meaning |
| `SLB_EMOJI_STATUS_CTX_WARNING` | `⚠️` | context line — shown once usage passes 50% of the window (normal mode only) |
| `SLB_EMOJI_STATUS_LITE_CTX_MARKER` | `🌎` | lite mode only — bare marker on the ctx bar line |
| `SLB_EMOJI_STATUS_LITE_5H_MARKER` | `🧩` | lite mode only — bare marker on the 5h bar line |

`CIRCLE_RED`/`CIRCLE_YELLOW` only ever appear in normal mode's four-state
circle (lite mode's ctx/5h/week circle only has two states); CPU/RAM keep
the four-state circle in both modes.

```sh
SLB_EMOJI_STATUS_CIRCLE_RED=🟥
SLB_EMOJI_STATUS_CTX_WARNING=🚨
```

## Model name color (lite mode)

| Key | Default | Effect |
|---|---|---|
| `SLB_MODEL_COLOR_LITE` | `AF87FF` | color of the model name in lite mode's line 1 |

A hex color, `#` optional (`AF87FF` and `#AF87FF` both work). `AF87FF` is
the same purple normal mode reserves for Sonnet, re-expressed as a 24-bit
color so this key and the default share one code path. Unlike the other
keys on this page, this one ships **active** in `config.sh` rather than
commented — uncomment the alternate line instead of the default one to
make the model name the same gray as everything else in lite mode:

```sh
SLB_MODEL_COLOR_LITE=AF87FF
# SLB_MODEL_COLOR_LITE=BCBCBC   # same gray as everything else in lite mode
```

Only affects lite mode. Normal mode already colors the model name per
model (Opus rainbow, Sonnet purple, everything else cyan) and isn't
affected by this key. An invalid value (not six hex digits) falls back to
the default purple rather than an unreadable escape sequence.

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

## Resetting

Hand-edited `config.sh` into a state you don't understand any more? Or it went
missing entirely?

```bash
manage.sh reset-config
```

Backs up the current file (timestamped, under `<config-dir>/statusline-beauty/backups/`)
if one exists, then rewrites every switch back to its documented default —
including `SLB_LITE_MODE`, so this also switches back to normal mode. If
`config.sh` doesn't exist at all (deleted by hand), `manage.sh lite`/`normal`
recreate it with defaults on their own; `reset-config` is for when the file
*is* there but wrong.

## Staying current

A `config.sh` created before a key family existed (say, one from before
`SLB_EMOJI_STATUS_*` was added) just never had it — there was nothing to
show it. Rather than leaving that file permanently behind, `manage.sh
update` checks for a `# statusline-beauty-config-version:` marker at the
bottom of the file and appends whichever blocks are missing — identical
text to what a fresh install gets, which for most keys means commented
reference lines, but a couple (like the lite-mode model color) ship with
their documented default already active — then updates the marker. Every
line that was already there —
your values, your comments, your hand edits — is left completely untouched;
this only ever adds what's missing. It runs automatically on every `update`,
even when the deployed script itself is already current, so a config.sh
never quietly falls behind the docs.

## Lite mode

`SLB_LITE_MODE=1` (or `manage.sh lite`) switches to a minimal render:

```
📡 a9ccdf31 ⚡️ Sonnet 5 · 🧠 low (Thinking) $9.68 · 65 turns | 4 agents | 129 tools | 3 skills
🌐 claude-statusline-beauty  |  🌿 main  |  ± 7 files  +1569 -132  |  6d
🟢 ctx  [███░░░░░░░░░░░░░░░░░░░░░░]  15% · 145.5k/1M · 🌎
🟢 5h   [█░░░░░░░░░░░░░░░░░░░░░░░░]   6% ⟳ 42m (10:30 PM) 🧩
⚪ week [██████████████████████░░░]  89% ⟳ 7h 12m (05:00 AM)
💲~$1571.97/mo · 1675.1Mtok/mo
```

- Every color collapses to gray, except the model name, which keeps the purple
  normal mode reserves for Sonnet — no rainbow gradient anywhere, on any model.
  Configurable: [`SLB_MODEL_COLOR_LITE`](#model-name-color-lite-mode).
- Line 1: turns and, once `SLB_SHOW_TOOL_COUNTS` is on, agents/tools always
  print — even at `0`. Skills/mcp print only when non-zero.
- Line 2: branch always prints when `SLB_SHOW_GIT` is on, even outside a
  repository — `🌿 (repo not found)` instead of dropping the whole line.
- Reset countdowns on the 5h/week bars use `⟳` instead of "resets". The ctx
  bar drops its in:/out: token figures in favor of a bare `🌎` marker (shown
  only when there's session token data); the 5h bar always ends with `🧩`.
- The `📀 cache HR` and `📈 avg/turn` segments, along with `💲/turn`
  (cost-per-turn), stay dropped from anywhere in lite mode — and since
  they're never shown there, they're never *computed* there either.
- Month-to-date cost/tokens gets its own trailing line (`💲…`) — but **only
  for the session's first 10 turns**, then it stops printing — and past
  turn 10, the underlying month scan (the single heaviest operation in the
  file) is skipped outright rather than computed and discarded.
- The ctx/5h/week circles collapse to two states: 🟢 under 75%, ⚪ at 75%+.
  The CPU/RAM bars keep the normal four-state circle regardless of this
  switch — but they don't render at all in lite mode either way, and the
  underlying `sysctl`/`vm_stat`/load-average work is skipped outright rather
  than computed and discarded, so `SLB_SHOW_CPU`/`SLB_SHOW_RAM` have no
  effect (cost or otherwise) while lite mode is on.
- The footer (version + `session_id`) and its separating blank line are
  omitted entirely — output ends right after the last bar (or the month
  line, when it's showing).

Switch back with `SLB_LITE_MODE=0` or `manage.sh normal`. Everything else in
this file (which segments show, bar width) still applies on top of lite mode.

## What is never configurable

The context / 5h / weekly bars and the model + directory header always render.
They are the reason the status line exists, and they cost nothing beyond the
single `jq` pass over the JSON that Claude Code already provides on stdin.

---

[← SKILL.md](../SKILL.md) · [platform notes](platform-notes.md) · [troubleshooting](troubleshooting.md)
