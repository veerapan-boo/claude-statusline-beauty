# Troubleshooting

Start here:

```bash
bash ~/.claude/skills/claude-statusline-beauty/scripts/manage.sh doctor
```

`doctor` checks every dependency and system probe the status line relies on and
names the fix for each. To see the status line rendered from a fixture without
restarting Claude Code:

```bash
bash ~/.claude/skills/claude-statusline-beauty/scripts/manage.sh render-demo
```

## Nothing shows up at all

**Check the wiring first.** `manage.sh status` reports whether `settings.json`
points at this status line. If it points somewhere else, `install --force`
switches it over (and backs the old one up).

**`jq` is missing.** Without it the script cannot read the session JSON and every
field is empty. `doctor` flags this. Install it, then open a **new terminal** —
on Windows, `winget` only updates the persistent PATH, so a terminal already open
still cannot see it.

**Windows without Git Bash.** Claude Code falls back to PowerShell, which has no
`bash`, and the line renders blank with no error at all. Install Git for Windows.

**macOS with only the system bash.** Instead of a status line you get one line:

```
statusline-beauty needs bash >= 4.2 (running 3.2.57(1)-release) — install one with: brew install bash
```

`/bin/bash` is 3.2 and cannot run the script. Run `brew install bash`; nothing
else needs changing, because the script finds the Homebrew bash and re-execs
itself under it. If you see this message *after* installing it, check that
`/opt/homebrew/bin/bash` (Apple silicon) or `/usr/local/bin/bash` (Intel) exists
and is executable — those two paths are probed directly, precisely because
Claude Code launched from the Dock often has no Homebrew on its `PATH`.

**Run it by hand** to see the real error, which Claude Code swallows:

```bash
echo '{"model":{"display_name":"Claude"},"cwd":"/tmp"}' | bash ~/.claude/statusline-beauty/statusline.sh
```

## `syntax error: invalid arithmetic operator (error token is "")`

Carriage returns reaching bash arithmetic. Two sources:

- **jq output on Windows** — handled inside the script; if you see this, you are
  probably running a modified or very old copy. Reinstall with `manage.sh update --force`.
- **`config.sh` saved with CRLF** — handled too (the file is parsed, and `\r` is
  stripped). Again, reinstall if you see it.

## Status line is slow, or flickers

The status line is killed by the host when it takes too long. In order of impact:

```sh
SLB_SHOW_MONTHLY=0      # by far the biggest win
SLB_SHOW_TOOL_COUNTS=0  # skips scanning subagent transcripts
SLB_CHECK_LATEST=0      # removes the only network call
SLB_SHOW_GIT=0          # skips 2 git spawns + awk + sed every render
SLB_SHOW_RAM=0          # macOS: skips a vm_stat spawn every render
SLB_SHOW_CPU=0          # skips a load-average spawn every render
```

`SLB_SHOW_MONTHLY` scans every transcript modified this month. It is cached and
warms up over a few renders, but a machine with many long sessions pays for it.

`SLB_SHOW_RAM`/`SLB_SHOW_CPU` have no effect at all in lite mode — it never
renders those bars regardless of the switch, so the computation is skipped
outright rather than computed and discarded. Only relevant in normal mode.

The last three are individually smaller, but real: unlike the first three,
`git`/`vm_stat`/load-average genuinely can't be skipped on a cache hit — a
5-second internal cache absorbs the git spawns on rapid back-to-back renders,
but the very next render past that window (and RAM/CPU on every render, since
free memory and load are live values) still pays for them. Worth trying if
you're still on the edge after the first three.

A warm render should take well under a second:

```bash
time (echo '{"model":{"display_name":"Claude"},"cwd":"/tmp"}' | bash ~/.claude/statusline-beauty/statusline.sh >/dev/null)
```

## Emoji show as boxes, bars look ragged

A font problem, not a script problem. See
[platform-notes.md](platform-notes.md#terminal-requirements).

## The CPU bar is missing

Expected on Windows: Git Bash provides no `/proc/loadavg`. Set `SLB_SHOW_CPU=0`
to drop the row cleanly instead of leaving a gap.

On macOS the bar comes from `sysctl -n vm.loadavg` instead, so it should be
there; if it is not, run that command by hand — `doctor` probes the same thing.

## The git line is missing

It is omitted by design outside a git repository. Inside one, check that `git` is
installed (`doctor` reports it) and that `SLB_SHOW_GIT` is not `0`.

## The month-to-date figure looks wrong

The **cost** and the **token count** in that segment come from two different
places, and they go wrong for different reasons.

**The cost** is accumulated from `cost.total_cost_usd`, which Claude Code hands
the status line on every render. It is Claude Code's own estimate — the docs say
it "may differ from your actual bill" — but it already accounts for fast mode,
`inference_geo`, web-search charges and subagents, so nothing here re-prices
anything. It is low when:

- The status line was installed part-way through the month. **It only counts
  what it has seen**, starting from its first render, and there is no way to
  recover earlier spend — Claude Code does not store that number anywhere.
- The status line was disabled, erroring, or the ledger was deleted for a while.
- You use a second `CLAUDE_CONFIG_DIR`; each keeps its own ledger.

**The token count** is recomputed from the transcripts under
`~/.claude/projects/`, covering main sessions *and* every subagent transcript
nested under them, counting only messages timestamped inside the current month.
It then subtracts a baseline taken the first time the status line saw this month
fully warm, so it reports growth since install rather than the whole month —
otherwise it would describe a longer span than the cost beside it. It is low
only while the cache is still warming, shown by a trailing `…`.

To re-baseline (zero the figure again), delete
`~/.claude/statusline-beauty/cost/<YYYY-MM>.tokens-base`.

The session cost (`🌿`) comes straight from Claude Code and is authoritative.

Two directories, with very different consequences:

| | Safe to delete? |
|---|---|
| `${TMPDIR:-/tmp}/claude-statusline-beauty-<uid>/` — token cache | **Yes.** Rebuilds from your transcripts over the next few renders. Past months prune themselves. |
| `~/.claude/statusline-beauty/cost/` — cost ledger | **No.** That month's spend is gone for good. `uninstall --purge` removes it too. |

A machine that uses subagents heavily has many more transcripts than sessions,
so the first render after an upgrade can sit on `…` for a while as the token
cache warms. That is expected; the background pass converges within a render or
two and nothing blocks on it.

## Update says "rate limit reached"

Unauthenticated GitHub API calls are limited to 60/hour **per IP**, which a
shared office or VPN address burns through quickly. Either wait, or export a
token you already have:

```bash
export GITHUB_TOKEN=ghp_...
```

The check result is cached for 6 hours; `manage.sh update --force` bypasses the
cache.

## I installed/updated but the bar still shows the old thing

**No restart is needed.** `settings.json` stores a *path*, and Claude Code runs
that script fresh on every render — so a new version is live the moment
`manage.sh` finishes writing it. What you are waiting for is the next render,
not a reload.

Claude Code renders on activity, so the quickest way to force one is simply to
do something: send a message, or let a tool call complete. Sitting idle looking
at a stale bar can look like the update failed when nothing is wrong.

The same applies to `config.sh` edits — change a value, act once, and the next
render reflects it.

### If a *counter* specifically looks stale

The skills / agents / mcp / tools counters are cached, but **not on a timer** —
the cache key is the `size:mtime` signature of the session transcript plus every
subagent transcript under it. The count is therefore recomputed exactly when a
transcript grows, which in practice means *the next time a tool runs*. Between
tool calls the number is intentionally frozen, because recounting an unchanged
file on every render is pure waste.

So a counter that looks one step behind is usually correct-as-of-the-last-tool-call
rather than broken. Run any tool and it catches up. (`SLB_SHOW_TOOL_COUNTS=0`
turns the whole segment, and its cost, off.)

### If the *git line* specifically looks stale

Branch, ahead/behind and dirty-file count are memoized for 5 seconds per
directory — `git status`/`git log` are the one part of the render with no
cheap "did anything change" signal to key a cache on, so a short flat TTL
stands in for one instead. A file saved inside that 5-second window won't
bump the dirty count until the render after it. This is deliberate — it
trades an imperceptible amount of staleness for skipping 2 `git` spawns on
every rapid re-render Claude Code triggers back-to-back — not a bug.

Caches live under `${TMPDIR:-/tmp}/claude-statusline-beauty-$UID/cache/` and are
safe to delete; they rebuild on the next render.

## An update broke it

It should not be possible: a downloaded script must pass a shebang check, a
version-marker check, `bash -n`, and a smoke render before it is allowed to
replace a working copy. If any of those fail, the download is discarded and the
current version stays.

If something still went wrong, the previous versions are kept:

```bash
ls ~/.claude/statusline-beauty/backups/
cp ~/.claude/statusline-beauty/backups/statusline.sh.<version>.<stamp> \
   ~/.claude/statusline-beauty/statusline.sh
```

## Undo everything

```bash
bash ~/.claude/skills/claude-statusline-beauty/scripts/manage.sh uninstall
```

This restores the `statusLine` setting that was there before the first install
(recorded in `.installed.json`), after backing up the current `settings.json`.
Add `--purge` to also delete `~/.claude/statusline-beauty/`, including your
`config.sh`.

---

[← SKILL.md](../SKILL.md) · [configuration](configuration.md) · [platform notes](platform-notes.md)
