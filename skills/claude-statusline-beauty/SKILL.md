---
name: claude-statusline-beauty
description: Install, update and troubleshoot the statusline-beauty status line for Claude Code — a multi-line status bar showing model, session and month-to-date cost, git state, and context / 5h / weekly / CPU / RAM usage bars. Trigger on /claude-statusline-beauty, or whenever the user asks to install, update, configure, disable, or fix their Claude Code status line, or asks why the status line is blank, slow, or showing broken characters.
version: 1.3.0
author: veerapan-boo
license: MIT
tags: [claude-code, statusline, installer, updater, self-update, linux, macos, windows, git-bash]
---

# statusline-beauty

A multi-line status line for Claude Code, packaged so it installs and updates itself.

```
✨ Opus 5  |  📁 my-project +173 -104  |  🧩 5 skills  |  🤖 2 agents  |  🔌 4 mcp  |  🔧 87 tools
🌿 $1.77  |  📅 ~$41.20/mo · 9.8Mtok/mo  |  ♻️ 12 turns  |  💲$0.02/turn  |  📀 cache HR 80%
🌐 main  |  ↑2  |  ± 3 files  |  4h
  🟡 ctx  [████████████████░░░░░░░░░]  67% · 670k/1M in:26.8k out:127.8k  ⚠️ 500k+
  🟢 5h   [█████░░░░░░░░░░░░░░░░░░░░]  23% · resets 3h 12m (07:45 PM)
  ⚪ week [██████████░░░░░░░░░░░░░░░]  41%
  ⚪ CPU  [██████░░░░░░░░░░░░░░░░░░░]  27% · load 0.80
  ⚪ RAM  [████████░░░░░░░░░░░░░░░░░]  32% · 7.3G free/disk 133G free

  Claude Code v2.1.220 (LTS)  ·  session_id: a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

All the real work lives in `scripts/manage.sh`. Do not hand-edit `settings.json`
or copy the script around manually — the script handles backups, validation and
rollback that ad-hoc edits would skip.

## Example prompts

Four different requests map onto different subcommands — don't collapse them
into one mental model, each has a different effect:

| The user says | Run | Notes |
|---|---|---|
| `/claude-statusline-beauty` with nothing installed | `manage.sh install` | Checks the latest GitHub release first, so a fresh install lands on the newest version, not whatever this skill checkout happens to bundle. |
| "update the status line" | `manage.sh update` | Pulls the **latest published release only** — never `main` directly (see Platform support / maintainer notes for why). Overwrites the installed script; `config.sh` and `settings.json` are untouched, so existing switches (including `SLB_LITE_MODE`) survive. **Also syncs the skill package itself** (this SKILL.md, this manage.sh, references/*.md) whenever `skill_package_stale` is true — one command, both halves. |
| "update and switch to lite mode" | `manage.sh update` then `manage.sh lite` | Two sequential steps, not one atomic command. Step 1 now syncs the skill package too (see above), so step 2 knows about `lite` as long as the skill package it's running from HAS this self-sync capability at all. If it doesn't — a checkout old enough to predate this feature entirely — `update` can't fetch code it has no way to run; tell the user to re-run `npx skills add` once to bootstrap onto a version that can self-sync from then on. |
| "switch to lite mode" / "back to normal" | `manage.sh lite` / `manage.sh normal` | Only touches `SLB_LITE_MODE` in `config.sh`, in place. No download, no restart. Recreates `config.sh` with defaults first if it was deleted — don't tell the user to reinstall for this. |

## Procedure

Run everything from this skill's directory. `$SKILL_DIR` below is the directory
containing this `SKILL.md`.

### 1. Read the current state

```bash
bash "$SKILL_DIR/scripts/manage.sh" status --json
```

The JSON tells you everything needed to decide what to do:

| Field | Meaning |
|---|---|
| `installed` | whether `statusline.sh` is present in the user's config dir |
| `installed_version` / `latest_version` | semver strings, or `main@<sha>` when no release exists yet |
| `latest_source` | `release`, `main`, `ratelimited`, or `unavailable` |
| `update_available` | true when a newer version can be pulled |
| `bundled_version` | the version embedded in **this skill package's own copy** of statusline.sh — i.e. how current *this SKILL.md and this manage.sh* are, not the deployed script |
| `skill_package_stale` | true when `bundled_version` is behind `latest_version`. `manage.sh update` fixes this too — it syncs SKILL.md/manage.sh/references, not just the deployed script — unless the currently-running skill package predates that self-sync capability entirely, in which case it needs one manual `npx skills add` to bootstrap (see step 3) |
| `settings_wired` | true when `settings.json` already points at this status line |
| `settings_conflict` | the *other* command currently configured, or `null` |
| `warnings[]` | missing `jq`, old bash, Windows/PowerShell caveat, and so on |

### 2. Clear blocking dependencies

`warnings[]` already carries the exact fix command for the user's platform — use
it verbatim rather than composing your own.

| Warning | Blocking? | What to do |
|---|---|---|
| `jq is not installed` | **yes** — `install` exits 1 | offer to run the command from the warning |
| bash < 4.2 | **yes** — cannot be fixed from here | say so and stop; the warning already carries `brew install bash` on macOS |
| `git` / `curl` / `npm` missing | no | mention once, keep going |
| Windows without Git Bash | no, but the bar renders blank | say Git for Windows is required |

**Offer, ask, then run.** Installing a system package changes the user's machine
and usually needs `sudo`, so it is their call:

> `jq` is not installed — the status line cannot render without it.
> Fix: `sudo apt install jq`. Want me to run that?

Only after they agree, run it, then re-run `status --json` and confirm the
warning is gone before continuing. Never run a package manager unprompted, and
never invent an install command for a platform the warning did not name.

On Windows, `winget` updates only the persistent PATH, so `jq` stays invisible
to the session that installed it. Tell the user to open a new terminal, and
treat a still-missing `jq` right after a successful `winget install` as expected
rather than as a failure.

### 3. Act on it

- **Not installed** → `bash "$SKILL_DIR/scripts/manage.sh" install`
- **Installed, `update_available: true`** → `bash "$SKILL_DIR/scripts/manage.sh" update`
- **Installed and current** → say so and stop. Do not reinstall.
- **`skill_package_stale: true`** (regardless of the above) → run
  `manage.sh update` — it syncs the skill package (this SKILL.md, this
  manage.sh, references/*.md) as part of the same command, not just the
  deployed script. If `skill_package_stale` is STILL true immediately after
  a successful `update`, the running skill package predates the self-sync
  feature entirely — code that isn't there can't fetch its own replacement.
  That specific case needs one manual bootstrap:
  ```
  npx skills add https://github.com/veerapan-boo/claude-statusline-beauty -g -a claude-code
  ```
  After that one-time re-install, every future `update` self-syncs on its
  own. This was a real source of confusion before the self-sync existed:
  "I ran update but nothing changed" meant the deployed *script* updated
  fine while the *skill package* — the thing actually answering
  `/claude-statusline-beauty` requests — stayed old. Re-check
  `skill_package_stale` after running `update` rather than assuming it's
  fixed; report which case applies.

`install` checks for a newer release first, so a fresh install lands on the
latest version rather than whatever this checkout happens to carry.

### 4. Handle a settings.json conflict

If `settings_conflict` is not `null`, the user already has a different status
line configured. `install` exits with code **3**, changes nothing, and prints the
existing command.

**Show the user the conflicting command and ask before overriding.** Only after
they agree, run:

```bash
bash "$SKILL_DIR/scripts/manage.sh" install --force
```

Never pass `--force` unprompted. The old setting is backed up two ways (a
timestamped `settings.json.bak-statusline-beauty-*` and `prev_statusline` inside
`.installed.json`), and `uninstall` restores it — but it is still the user's
call, not yours.

### 5. Report

- State the installed version and whether `settings.json` was changed.
- Repeat any non-blocking `warnings[]` left over from step 2, with the fix.
- Tell the user it appears on the next render, and to restart Claude Code if it
  does not.

## Arguments

`/claude-statusline-beauty <arg>` maps directly onto a subcommand:

| Arg | Command |
|---|---|
| *(none)* | `status --json`, then install or update as above |
| `status` | `manage.sh status` |
| `update` | `manage.sh update` — always checks GitHub live, never a cached result. Add `--force` to reinstall even when already on the latest version |
| `doctor` | `manage.sh doctor` — dependency and environment report |
| `uninstall` | `manage.sh uninstall` (add `--purge` to delete the install dir too) |
| `demo` | `manage.sh render-demo` — render from a fixture without restarting |
| `lite` | `manage.sh lite` — switch to the minimal, low-color render |
| `normal` | `manage.sh normal` — switch back to the full render |
| `reset-config` | `manage.sh reset-config` — back up the current `config.sh` and restore every switch to its documented default |

## Changing a setting

Installation writes `<config-dir>/statusline-beauty/config.sh` — normally
`~/.claude/statusline-beauty/config.sh` — once, and never overwrites it. Every
switch lives there.

When the user asks to turn part of the status line off (or back on):

1. **Edit the existing line in place.** The file already contains every key with
   its default and a comment explaining it. Change the value; do not rewrite the
   file, append a duplicate key, or drop the comments.
2. Values are `1` or `0`. `true/false`, `yes/no`, `on/off` also parse; anything
   else silently falls back to the default, so stick to `1`/`0`.
3. **Do not restart Claude Code and do not reinstall.** The next render picks the
   change up. Say that.
4. If the file does not exist and nothing is installed at all (`status --json`
   shows `installed: false`), run the install procedure above. If the script
   **is** installed but `config.sh` alone is missing (deleted by hand), any
   `manage.sh lite`/`normal`/config-editing request recreates it with defaults
   first — no reinstall needed for that.

Map the request onto a key:

| The user says | Set |
|---|---|
| hide the CPU / RAM bar | `SLB_SHOW_CPU=0` / `SLB_SHOW_RAM=0` |
| it is slow, speed it up | `SLB_SHOW_MONTHLY=0` first — it is by far the heaviest. Then `SLB_SHOW_TOOL_COUNTS=0`, then `SLB_CHECK_LATEST=0` |
| screen sharing / recording / hide my session id | `SLB_SHOW_FOOTER=0`, and offer `SLB_SHOW_MONTHLY=0` because the monthly figure discloses spending |
| no network calls | `SLB_CHECK_LATEST=0` — the only one there is |
| hide the git line | `SLB_SHOW_GIT=0` |
| hide the skills / agents / mcp / tools counters | `SLB_SHOW_TOOL_COUNTS=0` |
| bars are too wide / my terminal is narrow | `SLB_BAR_WIDTH=14` (clamped 10–60) |
| minimal colors, fewer segments, no footer | `manage.sh lite` (sets `SLB_LITE_MODE=1`) |
| "reset my config" / "undo everything, I messed it up" | `manage.sh reset-config` — backs up the current file, restores every default |

The context / 5h / weekly bars and the model + directory header are **not**
configurable for *visibility* — that always renders. If the user asks to
remove those, say so rather than inventing a key — an unknown key in
`config.sh` is ignored silently, which would look like the request worked
when it did not. Their **icons**, however, are configurable — see below.

### Changing an emoji icon

When the user asks to re-skin an icon ("change my Opus icon to 🐉", "make the
git branch emoji a leaf"), edit or add the matching `SLB_EMOJI_*` line in
`config.sh` — same file, same "edit in place, don't rewrite the whole file"
rule as the switches above. Unlike the switches, the value is any single
non-whitespace token (the emoji itself), not `1`/`0`.

Full key list with defaults and where each renders:
[references/configuration.md](references/configuration.md#emoji-icons). All
of them are also listed commented-out at the bottom of the default
`config.sh`, so uncommenting is enough if the user just wants to see what's
available.

A few keys are mode-specific (`_NORMAL` / `_LITE` suffix) because normal and
lite mode already show a different default icon for that field — e.g.
`SLB_EMOJI_GIT_BRANCH_NORMAL` vs `SLB_EMOJI_GIT_BRANCH_LITE`. If the user
doesn't say which mode, ask, or set both if they clearly mean "everywhere."

Each switch gates the underlying work, not just the display, so turning a line
off is a real speedup. Full table with costs:
[references/configuration.md](references/configuration.md).

To show the user the result immediately instead of waiting for the next render:

```bash
bash "$SKILL_DIR/scripts/manage.sh" render-demo
```

It reads their `config.sh`, so the change is visible — except for
`SLB_SHOW_MONTHLY` and `SLB_CHECK_LATEST`, which the demo forces off so it stays
fast and offline. Those two only show up in the live status line.

## Platform support

| Platform | Status |
|---|---|
| Linux | supported |
| macOS | supported — needs `brew install bash jq`; the script re-execs itself under the Homebrew bash |
| Windows (Git Bash) | supported — the CPU bar is absent, since Git Bash has no `/proc/loadavg` |
| Windows (no Git Bash) | **not supported** — Claude Code falls back to PowerShell and a bash status line renders blank |

Requirements: bash ≥ 4.2 and `jq`. `git`, `curl`/`wget` and `npm` are optional
and only disable individual segments when missing.

See [references/platform-notes.md](references/platform-notes.md) for details, and
[references/troubleshooting.md](references/troubleshooting.md) when something
renders wrong.

## Installing on another machine

```bash
npx skills add https://github.com/veerapan-boo/claude-statusline-beauty -g -a claude-code
```

Then run `/claude-statusline-beauty` in Claude Code.

`-g` installs user-level into `~/.claude/skills/` rather than scoping the skill
to the current directory, and `-a claude-code` targets Claude Code rather than
every agent the CLI detects. Both are optional; without them the CLI installs
into the directory it was run from and prompts for the agent. The status line
itself is machine-wide regardless — only this skill's availability follows that
scope.
