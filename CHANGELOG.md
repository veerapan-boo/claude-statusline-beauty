# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
