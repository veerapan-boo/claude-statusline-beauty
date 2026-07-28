# Platform notes

## How Claude Code runs the status line

`settings.json` holds a shell command, not a file path, and Claude Code runs it
in a shell with the session JSON on stdin:

```json
"statusLine": {
  "type": "command",
  "command": "bash \"$HOME/.claude/statusline-beauty/statusline.sh\"",
  "padding": 0
}
```

`$HOME` is expanded by that shell, which is why the same command string works on
every machine and every account — there is no per-user path to edit. The quotes
keep it working when the home directory contains a space, such as
`C:/Users/John Doe`.

When `CLAUDE_CONFIG_DIR` points somewhere other than `~/.claude`, the installer
writes the resolved absolute path instead, in the same quoted form.

## Linux

Supported. Everything renders.

Requirements: bash ≥ 4.2 and `jq`. Install `jq` with `apt install jq`,
`dnf install jq` or `pacman -S jq`.

`git`, `curl`/`wget` and `npm` are optional — each only disables its own segment.

## Windows

Claude Code runs status line commands **through Git Bash when Git Bash is
installed, and through PowerShell when it is not**. This status line is a bash
script, so:

- **Git Bash installed** → supported.
- **Git Bash absent** → PowerShell has no `bash`, and the status line renders
  **blank with no error**. Install Git for Windows.

Two Windows-specific behaviours are handled inside the script:

**jq is found without relying on `PATH`.** `winget` installs `jq.exe` into a
versioned Packages directory and only appends it to the *persistent* user PATH.
Any process already running — including the terminal, and Claude Code, which
inherits its environment from that terminal — keeps the stale PATH and cannot see
`jq`. The script probes the winget, Chocolatey and Scoop locations directly, so
it works even in a terminal opened before `jq` was installed.

**CRLF is stripped from jq output.** The native Windows `jq.exe` opens stdout in
text mode, so every line it emits ends CRLF. Command substitution strips only the
final line's carriage return, and every other stray `\r` reaches bash arithmetic
as `syntax error: invalid arithmetic operator`. The script normalises jq's output
once, at the top.

Known limitation: **the CPU bar does not render.** It needs `/proc/loadavg`,
which Git Bash does not provide. Set `SLB_SHOW_CPU=0` in `config.sh` to drop the
row cleanly. The RAM bar does work — Git Bash ships no `free`, but it emulates
`/proc/meminfo`, which the script falls back to.

Write paths in `settings.json` with forward slashes. Git Bash treats unquoted
backslashes as escape characters, so `C:\Users\me\script.sh` reaches the runner
with its separators stripped and fails silently.

## macOS

Supported. Everything renders, including the CPU and RAM bars.

Requirements: `jq` (`brew install jq`) and a bash ≥ 4.2 — which macOS does not
ship. `/bin/bash` is 3.2, frozen at the last GPLv2 release in 2007, and lacks
both `readarray` and `printf '%(fmt)T'`.

```sh
brew install bash jq
```

**You do not have to change `PATH`, or the `settings.json` command.** The script
re-execs itself: if the bash it was started with is too old, it looks for a newer
one at `/opt/homebrew/bin/bash` (Apple silicon), `/usr/local/bin/bash` (Intel)
and then on `PATH`, verifies the version, and hands itself over with `exec`.
stdin — the session JSON — survives the switch untouched.

This matters because Claude Code launched from the Dock inherits a minimal `PATH`
that often has no Homebrew in it at all, so `bash` resolves to 3.2 even on a
machine where `brew install bash` was run months ago. With no modern bash
anywhere, the status line prints one line naming the fix instead of a wall of
syntax errors:

```
statusline-beauty needs bash >= 4.2 (running 3.2.57(1)-release) — install one with: brew install bash
```

`git`, `curl`/`wget` and `npm` are optional — each only disables its own segment.

### BSD userland

macOS ships the BSD userland, not GNU coreutils, and the script speaks both
rather than requiring `brew install coreutils`:

| Used for | GNU | BSD / macOS |
|---|---|---|
| cache signatures | `stat -c '%s:%Y'` | `stat -f '%z:%m'` |
| monthly transcript listing | `find -printf` | `find -exec stat +` |
| free disk | `df -BG` | `df -Pk` (POSIX columns, both) |
| CPU cores | `nproc` | `sysctl -n hw.ncpu` |
| load average | `/proc/loadavg` | `sysctl -n vm.loadavg` |
| memory | `free` / `/proc/meminfo` | `sysctl -n hw.memsize` + `vm_stat` |
| bounding the `(LTS)` check | `timeout 5` | background job + watchdog |

Two things are done in bash arithmetic rather than picking a side, because
neither spelling is portable — `date -d` is GNU-only and `date -j -f` is
BSD-only:

- **ISO-8601 → epoch** (rate-limit resets, session duration)
- **epoch → UTC ISO-8601** (the month window handed to `jq`)

Both are exact, and they removed the last `date(1)` fork from the render.

`df -Pk` is worth one note: BSD `df` adds three inode columns by default, so
indexing the *Available* column from the end — which is how the script survives
volume names containing spaces — lands on `ifree` instead and reports a
plausible but entirely wrong number. `-P` pins the six-column POSIX layout on
every platform.

### RAM accounting

There is no `MemAvailable` on macOS. The script reconstructs it from `vm_stat`
as `free + inactive + speculative + purgeable` pages — the set the kernel can
hand to a new allocation without swapping, which is what `MemAvailable` means on
Linux. The page size is read from `vm_stat`'s own header rather than assumed: it
is 16K on Apple silicon and 4K on Intel.

Expect the percentage to sit higher than Activity Monitor's memory pressure
graph. They measure different things — this is "used vs installed", not pressure.

## Terminal requirements

The status line uses emoji, box-drawing characters (`█░`) and 24-bit colour.

- **Emoji rendered as tofu boxes** → the terminal font lacks them. On Linux
  install `fonts-noto-color-emoji`; Windows Terminal has them by default.
- **Bars look ragged** → the font renders `█` and `░` at different widths. Any
  monospace font with proper block-element coverage fixes it; a Nerd Font is a
  safe choice.
- **Colours look wrong or absent** → the gradient model name needs a 24-bit
  colour terminal. Terminals without it degrade to no colour rather than breaking.

---

[← SKILL.md](../SKILL.md) · [configuration](configuration.md) · [troubleshooting](troubleshooting.md)
