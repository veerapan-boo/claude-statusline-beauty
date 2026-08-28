# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.1] - 2026-08-29

### Fixed
- **`monthly_tokens()` forked `mkdir`, `rm`, and `rmdir` on every single
  render**, completely bypassing the 60-second result memo added in 1.6.0
  — they ran before the memo check, not after, so the memo only ever saved
  the expensive transcript-scanning work, not these three. One of the two
  (`rm -f .result.cache`, `rmdir .warm.lock`) was a one-time migration
  cleanup from a pre-bucketing cache layout that, on any already-migrated
  machine, is a permanent no-op that still forked forever. `monthly_cost()`
  had the same unconditional `mkdir` shape. All four (plus five smaller
  cache-write `mkdir`s elsewhere in the file) now check `[ -d ]`/`[ -e ]`
  first — bash builtins, no fork — and only shell out when something
  actually needs creating or removing. Measured 2 fewer forks per render in
  the warm steady state (confirmed via fork-counting, not just timing —
  wall-clock noise at this scale otherwise swallows a 2-fork difference).
  Output is unchanged; this is pure overhead removal.

## [1.6.0] - 2026-08-29

### Changed
- **Cut per-render process-spawn overhead**, measured ~35% less CPU time in
  the warm-cache steady state (a git repo + an active transcript — the
  realistic case). Five independent fixes, none of which change what's
  displayed:
  - Total RAM (`sysctl -n hw.memsize`) is now cached forever, same pattern
    already used for CPU core count — it never changes on a running
    machine, only `vm_stat` (genuinely live) still runs every render.
  - `_git_stats()` — the one subsystem with zero caching, 2 `git` spawns +
    `awk` + `sed` on literally every render — now has a 5-second TTL memo
    per directory. Claude Code re-renders the status line very frequently
    (after most tool calls), often faster than a human could plausibly
    change a working tree, so this eliminates the repeat spawns for
    back-to-back renders while staying effectively live. See
    [troubleshooting.md](skills/claude-statusline-beauty/references/troubleshooting.md#if-the-git-line-specifically-looks-stale)
    for the (intentional) staleness trade-off.
  - The month-to-date ledger's stale-marker cleanup (a `find -delete`) ran
    on **every single render** regardless of any `SLB_SHOW_*` flag, for
    housekeeping that only ever needs to happen occasionally — now
    rate-limited to once a day.
  - Session turn-count and first-timestamp extraction were 4 separate forks
    (`grep`, `head`, `grep`, `cut`) over the same transcript file; now one
    `awk` pass.
  - `input=$(cat)` (reading stdin) replaced with a builtin `read` — one
    fewer guaranteed fork on every render.
- `manage.sh doctor` now reports an actual render time in milliseconds
  (`EPOCHREALTIME`-based, no extra process spawn on bash 5+), so "is it
  fast" is a number instead of a guess.
- `references/troubleshooting.md`'s "slow, or flickers" list now also
  mentions `SLB_SHOW_GIT`/`SLB_SHOW_RAM`/`SLB_SHOW_CPU` — real, previously
  undocumented per-render costs (smaller than the top three, but real).

## [1.5.0] - 2026-08-29

### Added
- **`manage.sh update` now keeps `config.sh` itself current, not just the
  script.** A file created before `SLB_EMOJI_*`/`SLB_EMOJI_STATUS_*` existed
  had no way to show them — you had to go find the docs to even know they
  were there. `update` now tracks a `# statusline-beauty-config-version:`
  marker at the bottom of `config.sh` and appends whichever reference blocks
  (commented out, with their defaults — identical text to a fresh install)
  the file predates, then advances the marker. Every existing line — your
  values, your comments, your hand edits — is left completely untouched;
  this only ever adds what's missing. Runs automatically on every `update`,
  even when the deployed script is already current, same as the existing
  skill-package self-sync. Full reference:
  [configuration.md#staying-current](skills/claude-statusline-beauty/references/configuration.md#staying-current).

  **Same one-time bootstrap caveat as the skill-package self-sync**: this
  only works once the *currently running* `manage.sh` already has the code
  for it. On a checkout that predates this release, one `update` brings in
  the new `manage.sh` (and thus the new logic) but doesn't apply it in that
  same run; a second `update` right after does.

## [1.4.0] - 2026-08-29

### Added
- **The remaining hardcoded icons are now configurable too**, via a new
  `SLB_EMOJI_STATUS_*` key family — deliberately separate from `SLB_EMOJI_*`
  since these encode a color-coded danger/warn/ok threshold on the usage
  bars rather than pure decoration: the four circle states
  (`CIRCLE_RED`/`CIRCLE_YELLOW`/`CIRCLE_WHITE`/`CIRCLE_GREEN`), the
  context-half `CTX_WARNING`, and lite mode's two bar markers
  (`LITE_CTX_MARKER`/`LITE_5H_MARKER`). Same `config.sh`, same parsing and
  env-var-wins-over-file rules as every other `SLB_EMOJI_*` key. With this,
  no icon in the status line is hardcoded and unconfigurable any more — only
  `SLB_SHOW_*` visibility and the bar fill/empty characters (`█`/`░`) are
  not. Full reference:
  [configuration.md#status-icons](skills/claude-statusline-beauty/references/configuration.md#status-icons).

## [1.3.0] - 2026-08-29

### Added
- **Every decorative emoji icon is now configurable** via a new `SLB_EMOJI_*`
  key family — model, folder, git branch, ahead/behind, cost/month/turns/
  cache/avg tokens, skills/agents/mcp/tools counters, fast-mode, and lite
  mode's session-id, 23 keys in all. Same `config.sh`, same "parsed not
  sourced" rules, same env-var-wins-over-file precedence as the existing
  `SLB_SHOW_*` switches — the only difference is the value can be any single
  non-whitespace token (an emoji) instead of `1`/`0`. All keys are listed,
  commented out with their defaults, at the bottom of the default
  `config.sh`. Fields whose default icon already differs between normal and
  lite mode (folder, git branch, month-to-date) get independent `_NORMAL`/
  `_LITE` keys, so tuning one mode never moves the other. The four
  usage-bar status circles and the context-half warning stay fixed — they
  encode meaning by color/threshold, not identity. Full reference:
  [configuration.md#emoji-icons](skills/claude-statusline-beauty/references/configuration.md#emoji-icons).

### Fixed
- **Lite mode's model icon was hardcoded to ⚡️** regardless of whether the
  session was actually running Opus, Sonnet, or something else. It now picks
  the icon by model type the same way normal mode does, so an
  `SLB_EMOJI_MODEL_OPUS` override (or the default ✨/☄️) takes effect there
  too.

## [1.2.4] - 2026-08-18

### Added
- **`manage.sh update` now syncs the skill package itself, not just the
  deployed script.** Previously `update` only ever refreshed
  `~/.claude/statusline-beauty/statusline.sh` — the skill package
  (`SKILL.md`, this `manage.sh`, `references/*.md`, installed by `npx
  skills add`) was invisible to it, so a fully-updated deployed script could
  coexist with an old `manage.sh` that didn't know about newer commands.
  `status --json` gains `bundled_version` (the package's own embedded
  version) and `skill_package_stale` (true when it's behind the latest
  release); `update` checks this and, when true, downloads and validates
  `SKILL.md`/`manage.sh`/`references/*.md` from the same release and
  atomically replaces them — including replacing the currently-running
  `manage.sh`, which is safe because the process already has the old file
  open and finishes this invocation on it; only the *next* invocation sees
  the new one. Replacement resolves through symlinks rather than breaking
  them, in case the install is a symlinked canonical checkout rather than
  a plain copy.

  **One-time bootstrap required**: this only works once the *currently
  running* `manage.sh` already has this self-sync code — a checkout on an
  older version has no way to fetch code it doesn't contain. Anyone
  currently behind this release needs one manual re-run of the install
  command; every `update` after that self-syncs on its own.

## [1.2.3] - 2026-08-18

### Fixed
- **`manage.sh update` reported "already up to date" against a stale cached
  release check**, up to 6 hours old — a `status`/`install` run earlier in
  that window would freeze `update`'s idea of "latest" until the cache
  expired, even after a new release had actually been published. `update`
  now always hits the GitHub API live and never reads the cache; `status`
  and `install` are unchanged and still cache for up to 6h, since they run
  far more often and don't carry the same expectation of freshness.
  `--force` keeps its other meaning: reinstalling even when already current.

## [1.2.2] - 2026-08-18

### Fixed
- **`manage.sh reset-config` reset `SLB_LITE_MODE` back to normal**, silently
  bouncing a user out of lite mode as a side effect of fixing an unrelated
  switch. Mode is now read before the reset and carried over — every other
  switch still goes back to its documented default, but lite/normal is
  treated as a deliberate ongoing choice, not stray config to reset.

### Documentation
- **Restructured README.md into a basic/advanced split.** Install, the two
  render modes, and a plain-language "just tell Claude what you want" table
  now come first, in simple terms. Everything else — full switch tables, the
  Configure section, `manage.sh` internals, privacy details, maintainer
  notes — moved below a `## Advanced` divider so first-time readers aren't
  hit with config internals before they've even installed it.

## [1.2.1] - 2026-08-18

### Changed
- **Lite mode redesigned to two header lines instead of two-and-a-half.**
  Line 1 is now `session_id` + model + effort/thinking + session cost + turns
  + agents/tools (always shown once `SLB_SHOW_TOOL_COUNTS` is on, even at `0`)
  + skills/mcp (shown only when non-zero). Line 2 is folder + git — branch
  always prints when `SLB_SHOW_GIT` is on, even outside a repository, where
  it now shows `🌿 (repo not found)` instead of dropping the whole line.
  Reset countdowns on the 5h/week bars use `⟳` instead of "resets"; the ctx
  bar drops its in:/out: token numbers for a bare `🌎` marker (shown only
  with session token data), and the 5h bar always ends with `🧩`. Month-to-date
  cost/tokens moved to its own trailing `💲…` line — shown only for the
  session's first 10 turns, then it stops printing. Normal mode is untouched.

### Added
- **`manage.sh reset-config`.** Backs up the current `config.sh` (timestamped,
  under `backups/`) if one exists, then rewrites every switch back to its
  documented default — the escape hatch for a config hand-edited into an
  unrecognizable state. Distinct from the auto-recreate in the fix below:
  that one only fires when the file is missing entirely; this one is for when
  it's present but wrong, so it always backs up first rather than overwriting
  silently.

### Fixed
- **`manage.sh lite`/`normal` failed with "not installed" if `config.sh` had
  been deleted by hand**, even though the status line script itself was still
  installed and working. `set_config_value()` now recreates `config.sh` with
  defaults before applying the switch, instead of requiring a full reinstall
  to get one file back.

### Documentation
- Added an **Example prompts** table to README.md and SKILL.md (right after
  the install instructions) spelling out what four common requests actually
  do under the hood: first install, plain update, "update and change mode" —
  including why that second one can silently fall back to guessing if the
  skill checkout is stale — and switching mode alone.

## [1.2.0] - 2026-08-17

### Added
- **Lite mode (`SLB_LITE_MODE`).** A minimal-decoration, three-line render:
  Line 1 is `session_id` (first 8 chars) + folder + branch/worktree + dirty
  file count and lines-changed + last-commit age (ahead/behind dropped —
  `📡 a9ccdf31  💻 my-project  |  🌿 main  |  ± 7 files  +1569 -132  |  6d`);
  Line 2 is model + effort/thinking + plain-text skills/agents/mcp/tools
  counters (no emoji on the counters); Line 3 is session cost + month-to-date
  + turns + cost/turn (`📀 cache HR`, `📈 avg/turn` and the per-turn `cw:`
  cache-write figure stay dropped). Every color collapses to a brighter
  256-color gray (`38;5;250`, not the darker `C_DIM` normal mode uses)
  except the model name, which keeps the purple normal mode reserves for
  Sonnet (no rainbow gradient anywhere, ⚡️ marks every model). The ctx/5h/week
  circles collapse to a two-state green (under 75%) / white (75%+) pair, with
  🌎/🧩 markers added to the ctx line's in/out token breakdown. CPU and RAM
  bars are not rendered at all in lite mode. The version/session_id footer
  (plus its separating blank line) is omitted entirely, so output ends right
  after the last bar. Normal mode is unchanged — verified byte-for-byte
  identical against the same fixture before and after this change. Switch
  with `manage.sh lite` / `manage.sh normal`, or set `SLB_LITE_MODE=1` in
  `config.sh` directly.

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
