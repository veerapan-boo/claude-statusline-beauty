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

Not supported yet, and guarded rather than left to fail messily: the script exits
immediately with a one-line message when bash is older than 4.2.

Two independent problems:

1. The system bash is 3.2 (2007), which lacks `readarray` and
   `printf '%(fmt)T'`. Installing bash 5 via Homebrew fixes this half.
2. Several commands are used with GNU-only flags: `stat -c`, `date -d`,
   `find -printf`/`-newermt`, `df -BG`, and `free`. BSD equivalents differ.

Installing `coreutils` and `findutils` from Homebrew provides `gstat`, `gdate`
and friends, but the script does not yet prefer them.

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
