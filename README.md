# claude-statusline-beauty

A multi-line status line for [Claude Code](https://claude.com/claude-code),
packaged as an agent skill that installs, wires up and updates itself.

```
✨ Opus 5  |  📁 my-project +173 -104  |  🧩 5 skills  |  🤖 2 agents  |  🔌 4 mcp  |  🔧 87 tools
🌿 $1.77  |  📅 ~$41.20/mo · 9.8M tok  |  ♻️ 12 turns  |  💲$0.02/turn  |  📀 cache HR 80%
🌐 main  |  ↑2  |  ± 3 files  |  4h
🟡 ctx  [████████████████░░░░░░░░░]  67% · 670k/1M in:26.8k out:127.8k  ⚠️ 500k+
🟢 5h   [█████░░░░░░░░░░░░░░░░░░░░]  23% · resets 3h 12m (07:45 PM)
⚪ week [██████████░░░░░░░░░░░░░░░]  41%
⚪ CPU  [██████░░░░░░░░░░░░░░░░░░░]  27% · load 0.80
⚪ RAM  [████████░░░░░░░░░░░░░░░░░]  32% · 7.3G free/disk 133G free

  Claude Code v2.1.220 (LTS)  ·  session_id: a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

- **Session and month-to-date cost** — live spend, plus the month so far,
  accumulated from the figure Claude Code reports rather than re-priced from
  tokens. Both the cost and the token count start from the day you install.
- **Usage bars** — context window, 5-hour and weekly rate limits with reset
  countdowns, CPU and RAM. The circle turns ⚪ / 🟡 / 🔴 as each one fills.
- **Git state** — branch, worktree marker, ahead/behind, dirty file count, last
  commit age. Hidden entirely outside a repository.
- **Session analytics** — turns, cost per turn, cache hit rate, average tokens
  per turn, skill/agent/MCP/tool counts across the session *and* its subagents.
- **Footer** — the running Claude Code version, an `(LTS)` tag when it is the
  latest published one, and the `session_id`.

Every line can be switched off.

## Install

```bash
npx skills add https://github.com/veerapan-boo/claude-statusline-beauty -g -a claude-code
```

Then, inside Claude Code:

```
/claude-statusline-beauty
```

That checks for a newer release, installs the script to
`~/.claude/statusline-beauty/`, and wires up `~/.claude/settings.json`.

<details>
<summary>What <code>-g -a claude-code</code> does, and when to drop it</summary>

Both flags remove a question the CLI would otherwise have to guess or ask:

| Flag | Effect |
|---|---|
| `-g` | install user-level, into `~/.claude/skills/`, instead of scoping the skill to whatever directory you happen to be in |
| `-a claude-code` | install for Claude Code only, rather than every agent the CLI detects on the machine |

Without them, `npx skills add` installs **into the directory you run it from** and
prompts for the agent — fine from `$HOME`, surprising from inside a project,
where the skill ends up available only in that project.

Drop `-g` on purpose if that project scoping is what you want:

```bash
npx skills add https://github.com/veerapan-boo/claude-statusline-beauty -a claude-code
```

Either way **the status line itself is installed machine-wide**, because it lives
in `~/.claude/statusline-beauty/` and is wired into `~/.claude/settings.json`.
Only the `/claude-statusline-beauty` command follows the skill's scope.

</details>

**If you already have a status line configured**, the installer stops and shows
you what is there rather than overwriting it. Re-run with `--force` — or just
tell Claude to go ahead — and your old setting is backed up first.

## Requirements

| | |
|---|---|
| bash | ≥ 4.2 |
| jq | required — `apt install jq` · `winget install jqlang.jq` · `brew install jq` |
| git, curl/wget, npm | optional; each only disables its own segment |

**You do not have to check these yourself.** `/claude-statusline-beauty` runs a
dependency scan before it installs anything, names what is missing, and prints
the exact command for your platform. Ask Claude to run it and it will — but it
asks first, because installing a system package changes your machine and may
need `sudo`. Nothing is installed behind your back.

```
> /claude-statusline-beauty
  jq is not installed — the status line cannot render without it.
  Fix: sudo apt install jq
  Want me to run that?

> yes
```

Only `jq` and bash ≥ 4.2 are hard requirements; the installer refuses to
continue without them. The rest are optional and degrade one segment each — no
`git` means no git line, no `npm` means no `(LTS)` tag.

**Linux** and **Windows with Git Bash** are supported. Windows *without* Git Bash
is not: Claude Code falls back to PowerShell, where a bash status line renders
blank. macOS is not supported yet (system bash is 3.2). See
[platform notes](skills/claude-statusline-beauty/references/platform-notes.md).

## Configure

`~/.claude/statusline-beauty/config.sh` is created on install and never
overwritten. Changes apply on the next render.

```sh
SLB_SHOW_MONTHLY=1      # month-to-date cost — the most expensive line
SLB_SHOW_GIT=1
SLB_SHOW_TOOL_COUNTS=1
SLB_SHOW_CPU=1
SLB_SHOW_RAM=1
SLB_CHECK_LATEST=1      # the only network call the status line makes
SLB_SHOW_FOOTER=1       # version + session_id — turn off when screen sharing
SLB_BAR_WIDTH=25
```

Editing that file by hand always works. But you can also just say what you want
and let Claude make the edit — the skill knows which key each part of the status
line maps to:

| Say this | What happens |
|---|---|
| "turn off the CPU and RAM bars" | `SLB_SHOW_CPU=0`, `SLB_SHOW_RAM=0` |
| "hide my session id, I'm screen sharing" | `SLB_SHOW_FOOTER=0` |
| "the status line is slow, make it faster" | `SLB_SHOW_MONTHLY=0` first, then the other scans |
| "stop it from hitting the network" | `SLB_CHECK_LATEST=0` |
| "hide how much I'm spending this month" | `SLB_SHOW_MONTHLY=0` |
| "the bars are too wide for my terminal" | `SLB_BAR_WIDTH=14` |
| "put the CPU bar back" | `SLB_SHOW_CPU=1` |

No restart — the change shows up on the next render.

Full reference: [configuration.md](skills/claude-statusline-beauty/references/configuration.md).

## Manage it directly

The skill is a thin wrapper around one script:

```bash
S=~/.claude/skills/claude-statusline-beauty/scripts/manage.sh

bash $S status          # what is installed, what is available
bash $S install         # install + wire up settings.json
bash $S update          # pull the latest release
bash $S doctor          # dependency and environment report
bash $S render-demo     # preview without restarting Claude Code
bash $S uninstall       # restore the previous statusLine setting
```

Updates are safe by construction: a downloaded script must pass a shebang check,
a version-marker check, `bash -n`, and a smoke render before it may replace a
working copy. If any check fails the download is discarded and the current
version stays. The previous five versions are kept in
`~/.claude/statusline-beauty/backups/`.

Something wrong? [troubleshooting.md](skills/claude-statusline-beauty/references/troubleshooting.md).

## Privacy

The status line prints only the **basename** of your working directory, never the
full path. The footer contains your `session_id` — set `SLB_SHOW_FOOTER=0` before
screen sharing. Caches live in a UID-scoped directory under `TMPDIR`, created
`0700`, because the month-to-date token cache stores transcript paths. It is
bucketed by month and prunes past months itself, and deleting it is safe — the
next few renders rebuild it from your transcripts.

The **cost** ledger, and the token baseline beside it, cannot be rebuilt — so
they live with the install rather than in `TMPDIR`, at
`~/.claude/statusline-beauty/cost/`. The ledger accumulates the spend figure
Claude Code reports on each render, which the CLI itself does not persist
anywhere; deleting it, or running `uninstall --purge`, loses that month's spend
for good. Deleting the `<YYYY-MM>.tokens-base` file beside it is harmless — it
just re-baselines the token figure to zero from that moment.

The only outbound network call is `npm view @anthropic-ai/claude-code version`,
at most once every 6 hours, used for the `(LTS)` tag. `SLB_CHECK_LATEST=0`
removes it. Update checks run only when you invoke the skill.

## For maintainers

Cutting a release:

1. Bump `VERSION` **and** the `# statusline-beauty-version:` header inside
   `skills/claude-statusline-beauty/scripts/statusline.sh`. The updater reads the
   header; `VERSION` is for humans.
2. Update `CHANGELOG.md`.
3. Run the checks below.
4. Tag `vX.Y.Z` and publish a GitHub release. The updater reads
   `releases/latest`; with no releases published it falls back to tracking `main`
   by commit SHA.

Pre-release checks — run them **after committing**, not before:

```bash
bash scripts/check-identifiers.sh     # must report nothing
bash -n skills/claude-statusline-beauty/scripts/statusline.sh
bash -n skills/claude-statusline-beauty/scripts/manage.sh
bash skills/claude-statusline-beauty/scripts/manage.sh render-demo
```

`check-identifiers.sh` fails the release if anything that looks like a personal
identifier — your account name, your machine's hostname, a home directory path,
an email address, an IP — has reached the published files. It reads those names
from the environment at run time rather than listing them, so the check itself
never becomes the leak. Machine-specific words such as internal project or host
names go in `.pii-words`, which is gitignored and never published.

It also scans `git log`, because the author and committer address of every
commit is published just as publicly as the files. That part can only see
commits that already exist, which is why the checks run *after* committing. The
prevention, rather than the detection, is a repo-local identity — set it once
per clone so a global `user.email` can never leak into this repository:

```bash
git config --local user.name  '<your-github-username>'
git config --local user.email '<your-github-username>@users.noreply.github.com'
```

A force-push removes a bad commit from the branch, but GitHub keeps the object
reachable by its SHA until it garbage-collects. If a real address has already
been pushed, treat deleting and recreating the repository as the only complete
remedy.

There is no rate table to maintain. Month-to-date cost accumulates the figure
Claude Code reports on stdin, so a price change on Anthropic's side needs no
release here. Resist adding one: pricing tokens yourself means a table that goes
stale silently, and it still cannot see fast mode, `inference_geo`, web-search
charges, or the API calls the CLI bills without writing them to a transcript.

When testing anything that renders a fixture, set `SLB_DEMO=1`. The ledger is
append-only and cannot be rebuilt, so a fake `total_cost_usd` reaching it is not
recoverable; `smoke_test` and `render-demo` already set it.

## License

MIT — see [LICENSE](LICENSE).
