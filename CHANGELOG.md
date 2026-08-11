# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.1] - 2026-08-12

### Added
- **Troubleshooting: "I installed/updated but the bar still shows the old
  thing."** Two things that look like bugs but are not. First, no restart is
  ever needed — `settings.json` stores a path and Claude Code runs that script
  fresh on every render, so a new version is live as soon as `manage.sh`
  finishes writing it; what you are waiting for is the next render, which
  activity triggers. Second, a counter that looks one step behind is usually
  correct as of the last tool call: the skills/agents/mcp/tools cache is keyed
  on the `size:mtime` signature of the session and subagent transcripts, not on
  a timer, so it recomputes exactly when a transcript grows. The section also
  records where the cache lives, since the previous advice to "restart Claude
  Code" sent people down the wrong path.

### Fixed
- **macOS: month-to-date token figure was pinned at 0.** BSD awk (the macOS
  system awk) hard-errors on a literal newline inside a `-v` value
  ("newline in string"), and the error was swallowed by `2>/dev/null` — so the
  cache merge in `monthly_tokens()` silently produced nothing, every render
  summed the month to zero, and the all-zero result was memoized and baked into
  the `tokens-base` baseline. Newlines in the listing are now escaped as `\n`
  before the `-v` assignment; POSIX requires `-v` values to undergo escape
  processing, so both gawk and BSD awk rebuild the same multi-line string.
  GNU awk accepts literal newlines, which is why Linux never showed this.
  After updating, delete `<config-dir>/statusline-beauty/cost/<YYYY-MM>.tokens-base`
  once if it was captured as all zeros — the next warm scan rewrites it correctly.

## [1.1.0] - 2026-07-28

### Added
- **macOS support.** Previously the installer refused outright, on two grounds:
  the system bash is 3.2, and the script used GNU-only tools throughout. Both
  are addressed.

  **bash.** `/bin/bash` is 3.2 and cannot run this script. It now re-execs
  itself under a newer bash — `/opt/homebrew/bin/bash`, `/usr/local/bin/bash`,
  then `PATH`, each version-checked before use — so neither `settings.json` nor
  `PATH` needs editing. `exec` preserves stdin, so the session JSON survives the
  switch. This also fixes the case that would otherwise be silent: Claude Code
  launched from the Dock inherits a minimal `PATH` with no Homebrew in it, so
  `bash` resolves to 3.2 even on a machine that has bash 5 installed. With no
  modern bash anywhere, the one-line message now names the fix
  (`brew install bash`) instead of just the problem.

  **BSD userland.** Every GNU-only call gained a BSD path: `stat -c` → `stat -f`,
  `nproc` → `sysctl -n hw.ncpu`, `/proc/loadavg` → `sysctl -n vm.loadavg`,
  `free` / `/proc/meminfo` → `sysctl -n hw.memsize` + `vm_stat` (page size read
  from its header — 16K on Apple silicon, 4K on Intel), and `timeout 5 npm view`
  → a background job with a watchdog, since macOS ships no `timeout(1)` and the
  `(LTS)` tag could never appear without one.

### Changed
- The month-to-date token figure reads `72.3Mtok/mo` instead of `72.3M tok`, so
  both halves of the `📅` segment carry their own unit.
- **`date(1)` is gone from the render path.** ISO-8601 → epoch and epoch → UTC
  ISO-8601 are computed in bash arithmetic, because neither direction is
  portable: `date -d` is GNU-only and `date -j -f` is BSD-only. Verified against
  GNU `date` over 300 random timestamps plus leap-year, century and zone-offset
  edge cases, and the month window matched across four timezones spanning DST
  changes. Side effect: one fewer fork per render.
- **`find -printf` → `find -exec stat +`** for the month-to-date transcript
  listing. `-printf` is GNU-only, and on BSD find it is a usage error that
  emptied the listing and would have removed the `📅` segment entirely. The
  file signature changes from fractional to whole-second mtime, so the monthly
  token cache re-warms once after upgrading (the `…` suffix marks it).
- **`df -BG` → `df -Pk`.** `-BG` is GNU-only, and a bare `df` on macOS adds
  three inode columns — enough to shift the Available column the script reads
  onto `ifree` and report a plausible but entirely wrong disk-free figure. `-P`
  pins the six-column POSIX layout everywhere.
- `doctor` probes what each platform actually uses, instead of hard-coding the
  GNU spelling and reporting a healthy Mac as three failures.

### Fixed
- **`🧠 xhigh` was mislabelled `Ultracode`.** They are not the same thing:
  Ultracode is a separate `/effort ultracode` option — "xhigh + dynamic workflow
  orchestration", session-only — so every plain xhigh session was reported as
  one that fans out subagents. Nor can it be shown correctly: Claude Code
  documents `effort.level` as `low | medium | high | xhigh | max`, ultracode is
  not one of its values, and selecting it just reports `xhigh`. The effort level
  is now printed verbatim; xhigh and max keep their gradient styling.
- `_to_posix_path` used a `local -n` nameref, which is bash **4.3**, while the
  script advertises and enforces 4.2. Rewritten with indirect expansion and
  `printf -v`.

## [1.0.1] - 2026-07-28

### Fixed
- **Windows: most of the status line was missing.** Claude Code reports native
  paths there — `cwd` and `transcript_path` arrive with a drive letter and backslashes. Bash does
  not treat `\` as a separator, so every path test against them failed silently
  and took a segment with it:

  | Segment | Why it disappeared |
  |---|---|
  | `🧩 skills` `🤖 agents` `🔌 mcp` `🔧 tools` | the transcript could not be stat'd |
  | `♻️ turns` `💲/turn` `📀 cache HR` `📈 avg` | `[ -f "$transcript" ]` was false |
  | `in:`/`out:` on the context bar | session token sums returned zero |
  | the whole `🌐` git line | `_git_stats` could not enter the directory |
  | `📁` | `${cwd##*/}` found no `/`, so it printed the **full path** — the one thing the status line promises never to do |

  Paths are now rewritten to the MSYS form (`C:\dir\file` → `/c/dir/file`) in pure
  bash, with no `cygpath` fork. Linux is untouched: the pattern cannot match a
  POSIX path.

## [1.0.0] - 2026-07-28

First public release.

### Added
- Multi-line status line: model + effort header, session and month-to-date cost,
  git line, and stacked context / 5h / weekly / CPU / RAM usage bars.
- **Month-to-date cost accumulated from Claude Code itself.** The status line
  receives `cost.total_cost_usd` on stdin every render; that figure is tracked
  per session and summed for the month. Nothing is re-priced from tokens, so
  there is no rate table to go stale, and fast mode, `inference_geo`,
  web-search charges and subagent usage are all included because Claude Code
  includes them. Measured against `claude -p --output-format json` across three
  fresh sessions: **exact to the cent**.

  That figure is a counter for the current *process*, not the session — resuming
  restarts it — so it is accumulated as a counter-with-resets, and the increase
  is credited to whichever month the render happens in. A session running past
  midnight on the last of the month splits across both.

  **It counts from installation onward.** Claude Code does not persist the
  number anywhere, so there is no earlier history to recover.
- **Month-to-date tokens** summed from the transcripts under
  `~/.claude/projects/`, including every subagent transcript nested beneath a
  session — on a machine that uses agents heavily those outnumber the main
  sessions several to one. Only messages timestamped inside the current month
  count, with the boundary taken as local midnight converted to UTC. A baseline
  snapshot taken at install keeps this figure describing the same span as the
  cost beside it.
- `manage.sh` with `status`, `install`, `update`, `doctor`, `uninstall` and
  `render-demo`. Updates are validated (shebang, version marker, `bash -n`,
  smoke render) before replacing a working copy, and the previous five versions
  are retained.
- Self-update from GitHub releases, falling back to tracking the `main` branch
  by commit SHA when no release has been published. Honours
  `GITHUB_TOKEN`/`GH_TOKEN`.
- `config.sh` with eight `SLB_*` switches that gate the underlying work, not
  just the display. The file is parsed rather than sourced, so a CRLF-saved
  config cannot break bash arithmetic and nothing in it is ever executed.
- `settings.json` wiring that backs up the previous `statusLine`, preserves any
  existing `padding`, and refuses to overwrite a different status line without
  `--force`.
- Windows/Git Bash support: `jq` located without relying on `PATH`, and CRLF
  stripped from jq output.

### Performance
- Per-transcript token sums are cached by `size:mtime`, so only files that grew
  are re-read. A cold cache is drained a few files per render plus a detached
  background pass, rather than blocking one render on a full scan.
- The month's roll-up is memoised for 60 seconds. Warm render: **83 ms**, or
  **40 ms** on the common path where the memo hits.
- Background refreshers take a `mkdir` lock that is stolen after 120 s, so a
  process killed mid-flight cannot wedge them permanently.

### Security
- Cache directories are UID-scoped and created `0700`. The month-to-date cache
  stores transcript paths, which should not be world-readable on a shared
  machine.
- The cost ledger lives in the install directory rather than `TMPDIR`, because
  it cannot be rebuilt and `/tmp` is cleared on reboot on most systems.
- The status line prints only the basename of the working directory, never the
  full path.
