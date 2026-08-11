#!/usr/bin/env bash
# statusline-beauty — a multi-line status line for Claude Code
# https://github.com/veerapan-boo/claude-statusline-beauty  ·  MIT
#
# statusline-beauty-version: 1.1.1
#
# Layout: header line + stats line (leads with bold session cost +
# month-to-date estimate) + git line (branch, ahead/behind, dirty files,
# last commit — omitted entirely outside a git repo) + 5 stacked usage-bar
# lines (context / 5h / weekly, then CPU, then RAM) + a footer carrying the
# Claude Code version and session_id
#
#   ✨ Opus  |  📁 my-project +173 -104  |  🧩 5 skills  |  🤖 2 agents  |  🔌 4 mcp  |  🔧 87 tools
#   🌿 $1.77  |  📅 ~$41.20/mo · 9.8Mtok/mo  |  ♻️ 12 turns  |  💲$0.02/turn  |  📀 cache HR 80%  |  📈 avg ~1.2k/turn
#   🌐 (worktree) feat/some-branch  |  ↑2  |  ± 3 files  |  4h
#     🟡 ctx  [████████████████░░░░░░░░░]  67% · 670k/1M in:26.8k out:127.8k  ⚠️ 500k+
#     🟢 5h   [█████░░░░░░░░░░░░░░░░░░░░]  23% · resets 3h 12m (07:45 PM)
#     ⚪ week [██████████░░░░░░░░░░░░░░░]  41%
#     ⚪ CPU  [██████░░░░░░░░░░░░░░░░░░░]  27% · load 0.80
#     ⚪ RAM  [████████░░░░░░░░░░░░░░░░░]  32% · 7.3G free/disk 133G free
#
#     Claude Code v2.1.220 (LTS)  ·  session_id: a1b2c3d4-e5f6-7890-abcd-ef1234567890
#
# Every line can be switched off — see config.sh / references/configuration.md.

# ── Platform ──────────────────────────────────────────────────────
# ONE uname call, reused by the bash shim, the jq shim, and every GNU-vs-BSD
# fork below. Everything down to the re-exec must stay bash-3.2-parseable.
case "$(uname -s 2>/dev/null)" in
  Darwin*)              _SLB_OS=macos ;;
  MINGW*|MSYS*|CYGWIN*) _SLB_OS=windows ;;
  *)                    _SLB_OS=linux ;;
esac

# ── Minimum bash, and the macOS re-exec ───────────────────────────
# Needs readarray (4.0) and printf '%(fmt)T' (4.2). macOS still ships bash 3.2 —
# frozen at the last GPLv2 release — as /bin/bash, and Claude Code launched from
# the Dock inherits a PATH that often has no Homebrew in it at all, so `bash`
# resolves to 3.2 even on a machine that HAS a modern one installed.
#
# Nothing above this point uses bash-4 syntax, so 3.2 reaches here cleanly and we
# can simply hand the script to a newer interpreter: exec preserves stdin, and
# the JSON payload has not been read yet, so the switch is invisible to the
# caller. SLB_REEXEC is the recursion stop — if the interpreter we picked turns
# out to be old too, the second pass prints the message instead of exec'ing.
_slb_bash_ok() {   # $1 = interpreter path; true when it is bash >= 4.2
  "$1" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] ||
           { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }' 2>/dev/null
}
if [ -z "${BASH_VERSINFO[0]:-}" ] ||
   [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  if [ -z "${SLB_REEXEC:-}" ]; then
    # Homebrew first (Apple silicon, then Intel), PATH last: on the broken path
    # PATH is exactly what handed us 3.2, so it is the least likely to help.
    for _b in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null)"; do
      [ -n "$_b" ] && [ -x "$_b" ] || continue
      if _slb_bash_ok "$_b"; then
        export SLB_REEXEC=1
        exec "$_b" "$0" "$@"
      fi
    done
  fi
  printf '  statusline-beauty needs bash >= 4.2 (running %s)' "${BASH_VERSION:-unknown}"
  [ "$_SLB_OS" = macos ] && printf ' — install one with: brew install bash'
  printf '\n'
  exit 0
fi

# ── Windows / Git-Bash portability shim ───────────────────────────
# jq.exe is a native Windows build: it opens stdout in text mode, so every line
# it emits ends CRLF. Command substitution strips only the FINAL line's CR, so
# every other line carries a stray \r into bash arithmetic and blows up with
# "syntax error: invalid arithmetic operator (error token is "")". Strip CR
# once here so all call sites below see clean LF. PIPESTATUS preserves jq's own
# exit status, which _sum_tokens_month's failure handling depends on.
# No-op elsewhere, so behaviour on Linux and macOS is unchanged.
case "$_SLB_OS" in
  windows)
    # Resolve jq WITHOUT relying on PATH. winget drops jq.exe in a versioned
    # Packages dir and only appends that dir to the *persistent* user PATH — any
    # process already running (the terminal, and Claude Code, which inherits its
    # environment from that terminal) keeps the stale PATH and cannot see jq.
    # The script then silently loses every jq-derived field: model name, context,
    # rate limits, cost, turns, skill/agent/tool counts. Locate it ourselves so
    # the status line survives whatever PATH it happens to be launched with.
    _JQ=$(command -v jq 2>/dev/null)
    if [ -z "$_JQ" ]; then
      for _c in \
        "$HOME"/AppData/Local/Microsoft/WinGet/Links/jq.exe \
        "$HOME"/AppData/Local/Microsoft/WinGet/Packages/jqlang.jq_*/jq.exe \
        /c/ProgramData/chocolatey/bin/jq.exe \
        "$HOME"/scoop/shims/jq.exe
      do
        [ -x "$_c" ] && { _JQ="$_c"; break; }
      done
    fi
    _JQ=${_JQ:-jq}
    jq() { command "$_JQ" "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
    ;;
esac

# ── GNU vs BSD tool shims ─────────────────────────────────────────
# macOS ships the BSD userland, where stat takes -f and a different format
# language: %z is size (GNU %s), %m is mtime (GNU %Y), %N is the name (GNU %n).
# Resolve it ONCE into variables rather than probing at each call site — a
# `stat -c` feature test would be a fork on every render, on every platform, to
# answer a question that cannot change between renders.
if [ "$_SLB_OS" = macos ]; then
  _STAT_F=-f; _FMT_MTIME='%m'; _FMT_SIG='%z:%m'; _FMT_NAMESIG='%N %z:%m'
else
  _STAT_F=-c; _FMT_MTIME='%Y'; _FMT_SIG='%s:%Y'; _FMT_NAMESIG='%n %s:%Y'
fi

# ── Portable date arithmetic ──────────────────────────────────────
# Converting an ISO-8601 timestamp to epoch has no portable tool: `date -d` is
# GNU-only and `date -j -f` is BSD-only, and bash's own printf '%(fmt)T' can
# FORMAT an epoch but not PARSE a string, and only in the local zone. Transcript
# timestamps and rate-limit resets both arrive as ISO strings, so do the
# conversion in arithmetic instead — Howard Hinnant's civil-days algorithm is
# exact for every date bash can represent, and costs no fork at all.
#
# Accepts "YYYY-MM-DDTHH:MM:SS", optionally with fractional seconds and a
# trailing Z or ±HH[:]MM. No zone suffix is read as UTC, which is what Claude
# Code writes. Prints epoch seconds; returns 1 on anything unparseable.
_iso_to_epoch() {
  local s=$1 y m d hh mm ss era yoe doy doe days adj=0
  [[ $s =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt\ ]([0-9]{2}):([0-9]{2}):([0-9]{2}) ]] || return 1
  y=$((10#${BASH_REMATCH[1]})); m=$((10#${BASH_REMATCH[2]})); d=$((10#${BASH_REMATCH[3]}))
  hh=$((10#${BASH_REMATCH[4]})); mm=$((10#${BASH_REMATCH[5]})); ss=$((10#${BASH_REMATCH[6]}))
  # A zone offset means the civil time is ahead of (+) or behind (-) UTC, so it
  # is SUBTRACTED from / ADDED to the epoch the fields would give if they were
  # already UTC. Anchored at the end so the date's own hyphens cannot match.
  if [[ $s =~ ([+-])([0-9]{2}):?([0-9]{2})$ ]]; then
    adj=$(( (10#${BASH_REMATCH[2]} * 3600) + (10#${BASH_REMATCH[3]} * 60) ))
    [ "${BASH_REMATCH[1]}" = "+" ] && adj=$(( -adj ))
  fi
  (( m <= 2 )) && (( y-- ))                      # March-based year: Feb 29 lands last
  era=$(( (y >= 0 ? y : y - 399) / 400 ))
  yoe=$(( y - era * 400 ))
  doy=$(( (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1 ))
  doe=$(( yoe * 365 + yoe/4 - yoe/100 + doy ))
  days=$(( era * 146097 + doe - 719468 ))        # 719468 = days from 0000-03-01 to 1970-01-01
  printf '%s' $(( days * 86400 + hh * 3600 + mm * 60 + ss + adj ))
}

# The inverse: epoch seconds -> "YYYY-MM-DDTHH:MM:SS.000Z", always UTC.
# Same reason for hand-rolling it — `date -u -d @N` is GNU-only, `date -u -r N`
# is BSD-only, and printf '%(fmt)T' can only render the LOCAL zone.
_epoch_to_utc_iso() {
  local z=$1 days secs era doe yoe doy mp y m d
  days=$(( z / 86400 )); secs=$(( z % 86400 ))
  (( secs < 0 )) && { secs=$(( secs + 86400 )); days=$(( days - 1 )); }
  days=$(( days + 719468 ))
  era=$(( (days >= 0 ? days : days - 146096) / 146097 ))
  doe=$(( days - era * 146097 ))
  yoe=$(( (doe - doe/1460 + doe/36524 - doe/146096) / 365 ))
  y=$(( yoe + era * 400 ))
  doy=$(( doe - (365*yoe + yoe/4 - yoe/100) ))
  mp=$(( (5*doy + 2) / 153 ))
  d=$(( doy - (153*mp + 2)/5 + 1 ))
  m=$(( mp + (mp < 10 ? 3 : -9) ))
  (( m <= 2 )) && (( y++ ))
  printf '%04d-%02d-%02dT%02d:%02d:%02d.000Z' \
    "$y" "$m" "$d" $(( secs/3600 )) $(( secs%3600/60 )) $(( secs%60 ))
}

# Epoch of LOCAL midnight on a YYYY-MM-DD day.
# Reads the civil fields as if they were UTC, then subtracts the zone offset
# printf reports FOR THAT INSTANT. Two passes: the offset can differ on the two
# sides of the boundary (a DST change), and the second pass re-reads it on the
# corrected side so the answer is right in either zone.
_local_midnight_epoch() {
  local base off secs e="" pass
  base=$(_iso_to_epoch "${1}T00:00:00") || return 1
  for pass in 1 2; do
    printf -v off '%(%z)T' "${e:-$base}" 2>/dev/null
    [[ $off =~ ^([+-])([0-9]{2})([0-9]{2})$ ]] || return 1
    secs=$(( 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60 ))
    [ "${BASH_REMATCH[1]}" = "-" ] && secs=$(( -secs ))
    e=$(( base - secs ))
  done
  printf '%s' "$e"
}

# ── User configuration ────────────────────────────────────────────
# <config-dir>/statusline-beauty/config.sh is PARSED, never sourced. A config
# saved by a Windows editor carries CRLF line endings; sourcing it would set
# every value to "1<CR>" and blow up bash arithmetic downstream — the same class
# of bug the jq shim above exists to prevent. So: only `KEY=VALUE` lines whose
# key is a known SLB_* switch are honoured, values are restricted to a safe
# character set, and nothing in the file is ever executed.
# An SLB_* variable already present in the environment wins over the file, which
# makes one-off overrides (and the installer's smoke test) possible.
_slb_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline-beauty/config.sh"
if [ -r "$_slb_cfg" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line=${_line%$'\r'}                            # tolerate CRLF
    _line=${_line#"${_line%%[![:space:]]*}"}        # strip leading blanks
    case "$_line" in ''|'#'*) continue ;; esac
    # Spaces around `=` are accepted even though a real shell would reject them —
    # this file is parsed, not sourced, and a silently-ignored line is worse than
    # a lenient one.
    [[ "$_line" =~ ^(SLB_[A-Z0-9_]+)[[:space:]]*=[[:space:]]*([A-Za-z0-9._-]+)[[:space:]]*$ ]] || continue
    _k=${BASH_REMATCH[1]}; _v=${BASH_REMATCH[2]}
    # Whitelist as a padded string so the list stays on one line — a backslash
    # continuation inside a case pattern list would smuggle blanks into the
    # patterns and silently stop matching.
    case " SLB_SHOW_MONTHLY SLB_SHOW_GIT SLB_SHOW_TOOL_COUNTS SLB_SHOW_CPU SLB_SHOW_RAM SLB_CHECK_LATEST SLB_SHOW_FOOTER SLB_BAR_WIDTH " in
      *" $_k "*) ;;
      *) continue ;;                                # unknown key — ignore
    esac
    # `${!k+set}` is true even for an empty env value, so an explicit
    # SLB_X= in the environment still beats the file.
    [ -n "${!_k+set}" ] || printf -v "$_k" '%s' "$_v"
  done < "$_slb_cfg"
fi
unset _slb_cfg _line _k _v

# Normalize a switch in place to exactly 0 or 1, falling back to its default for
# anything unrecognized. printf -v is a builtin, so this costs no subshell.
_slb_norm() {
  local _v=${!1-}
  case "$_v" in
    0|false|no|off|FALSE|False|NO|No|OFF|Off) _v=0 ;;
    1|true|yes|on|TRUE|True|YES|Yes|ON|On)    _v=1 ;;
    *)                                        _v=$2 ;;
  esac
  printf -v "$1" '%s' "$_v"
}
_slb_norm SLB_SHOW_MONTHLY    1   # month-to-date cost (scans a month of transcripts — the heaviest line)
_slb_norm SLB_SHOW_GIT        1   # git branch / ahead-behind / dirty / last commit
_slb_norm SLB_SHOW_TOOL_COUNTS 1  # skills / agents / mcp / tools counters
_slb_norm SLB_SHOW_CPU        1   # CPU bar
_slb_norm SLB_SHOW_RAM        1   # RAM bar (+ disk free)
_slb_norm SLB_CHECK_LATEST    1   # "(LTS)" tag — makes a background `npm view` network call
_slb_norm SLB_SHOW_FOOTER     1   # version + session_id footer (turn off when screen sharing)

# Bar width is a number, not a switch: reject anything non-numeric, then clamp to
# a range that still renders sensibly.
case "${SLB_BAR_WIDTH-}" in ''|*[!0-9]*) SLB_BAR_WIDTH=25 ;; esac
(( SLB_BAR_WIDTH < 10 )) && SLB_BAR_WIDTH=10
(( SLB_BAR_WIDTH > 60 )) && SLB_BAR_WIDTH=60

input=$(cat)

# ── Extract every field in ONE jq pass ────────────────────────────
# Was ~18 separate `echo | jq` spawns (~150ms). Now a single jq emits all
# fields, one per line in a fixed order, read into the array F.
# NOTE: per Claude Code docs (v2.1.132+), total_input_tokens reflects CURRENT
# context occupancy (input + cache), not a cumulative session total — we show
# it as current/max, and compute the cumulative in/out from the transcript.
readarray -t F < <(printf '%s' "$input" | jq -r '
  [ (.model.display_name // "Claude"),
    (.workspace.current_dir // .cwd // ""),
    (.workspace.git_worktree // ""),
    (.vim.mode // ""),
    (.context_window.used_percentage // 0),
    (.context_window.total_input_tokens // ""),
    (.context_window.context_window_size // ""),
    (.transcript_path // ""),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.seven_day.resets_at // ""),
    (.cost.total_cost_usd // ""),
    (.cost.total_lines_added // ""),
    (.cost.total_lines_removed // ""),
    (.effort.level // ""),
    (.thinking.enabled // ""),
    (.fast_mode // false),
    (.context_window.current_usage.cache_creation_input_tokens // ""),
    (.version // ""),
    (.session_id // "")
  ] | map(tostring) | .[]')

model=${F[0]:-Claude}
cwd=${F[1]}
worktree=${F[2]}
vim_mode=${F[3]}
ctx_pct=${F[4]:-0}
ctx_tok=${F[5]}
ctx_size=${F[6]}
transcript=${F[7]}
five_pct=${F[8]}
five_reset=${F[9]}
week_pct=${F[10]}
week_reset=${F[11]}
cost=${F[12]}
lines_add=${F[13]}
lines_del=${F[14]}
effort=${F[15]}
thinking=${F[16]}
fast_mode=${F[17]}
ctx_cache_write=${F[18]}
version=${F[19]}
session_id=${F[20]}

# On Windows, Claude Code reports native paths — a drive letter with backslashes, and
# `transcript_path` likewise. Bash does not treat `\` as a separator, so every
# path test against them fails: `[ -f "$transcript" ]` is false, so the turn
# counters, cache hit rate and per-turn cost vanish; `last_agent_skill` cannot
# stat the file, so the skill/agent/mcp/tool counts vanish; `_git_stats` cannot
# enter the directory, so the whole git line vanishes; and `${cwd##*/}` finds no
# `/` to strip, so the folder segment prints the FULL path — the one thing the
# status line promises never to do.
#
# Rewrite to the MSYS form (`C:\dir\file` -> `/c/dir/file`) in pure bash: cygpath
# would be a fork per path per render, and this runs on every platform because
# the pattern cannot match a POSIX path anyway.
# Rewrites the variable NAMED by $1, in place. Indirect expansion plus
# `printf -v` rather than a `local -n` nameref: namerefs are bash 4.3, and the
# floor this script advertises (and enforces above) is 4.2.
_to_posix_path() {
  local _p=${!1}
  case "$_p" in
    [A-Za-z]:[\\/]*)
      local _d=${_p%%:*}
      _p=${_p#?:}
      _p=${_p//\\//}
      _p="/${_d,,}${_p}"
      ;;
    *\\*) _p=${_p//\\//} ;;   # UNC or relative Windows path, no drive letter
  esac
  printf -v "$1" '%s' "$_p"
}
_to_posix_path cwd
_to_posix_path transcript

short_cwd="${cwd##*/}"

# ── Colors ────────────────────────────────────────────────────────
C_RESET='\033[0m'
C_MODEL='\033[0;36m'   # cyan
C_MODEL_SONNET='\033[1;38;5;141m' # bold light purple
C_PATH='\033[0;37m'    # white  — folder path
C_GIT='\033[0;37m'     # white
C_VIM='\033[0;35m'     # magenta
C_DIM='\033[0;90m'     # gray
C_INFO='\033[38;5;117m'  # light sky blue (#87d7ff) — resets, token info
C_BAR='\033[0;37m'     # white  — usage bar < 75%
C_YEL='\033[0;33m'     # yellow — usage bar 75-99%
C_ADD='\033[38;5;114m' # soft green  (#87d787) — theme green, used everywhere
                        # something is "good" (lines added, git ahead, LTS tag)
C_DEL='\033[38;5;210m' # soft red    (#ff8787) — theme red, used everywhere
                        # something needs attention (lines removed, git behind,
                        # usage bar at 100%, ctx threshold warning)
C_RED="$C_DEL"          # usage bar at 100%
C_WARN="$C_DEL"         # ctx threshold warning
C_VERLINE='\033[0;37m' # white  — version/session_id footer line
C_LTS="$C_ADD"          # "(LTS)" tag shown when running the latest published version
C_COST='\033[0;37m'    # white  — session cost
C_COST_HL='\033[1;38;5;220m'  # bold gold   — session cost, made to stand out
C_MONTH_HL='\033[1;38;5;39m'  # bold azure blue — month-to-date cost/tokens
C_EFRT='\033[0;37m'    # white  — effort / thinking

BAR_WIDTH=$SLB_BAR_WIDTH

# ── Cache locations ─────────────────────────────────────────────────
# Everything cached lives under one root so a stale install is easy to clear.
# The root is keyed by UID because /tmp is shared: without it the first user on
# a multi-user box owns the directory and every other user's mkdir fails,
# silently disabling all caching for them.
# Leaf dirs are created 0700 (see the mkdir call sites) — the monthly cache
# stores full transcript paths, which encode project directory names, alongside
# per-model token and cost figures. None of that should be world-readable.
SLB_CACHE_ROOT="${TMPDIR:-/tmp}/claude-statusline-beauty-${UID:-0}"
SLB_CACHE_DIR="$SLB_CACHE_ROOT/cache"

# ── "Is this the latest published version?" (LTS) check ─────────────
# A live `npm view` takes ~0.5-1s — too slow to run synchronously every
# render — so it's refreshed in the BACKGROUND at most once per TTL; this
# render just reads whatever's cached (or shows nothing yet if there's no
# cache at all). See is_latest_version() below.
LATEST_VERSION_CACHE="$SLB_CACHE_DIR/latest-version.cache"
LATEST_VERSION_TTL=21600   # 6h

# ── Month-to-date cost/token stat ───────────────────────────────────
# Rows are bucketed into a YYYY-MM subdirectory, resolved per render rather
# than once at startup so a session that outlives a month boundary agrees with
# every other session about which bucket is current. Flat, the merge below had
# to cat every cache file ever written — one per transcript per month, growing
# without bound — to use only the current month's rows.
MONTHLY_CACHE_ROOT="$SLB_CACHE_ROOT/monthly"
MONTHLY_WARMUP_BUDGET=10   # max dirty transcript files reprocessed per render
# The whole month-to-date roll-up (find + per-file merge + pricing) costs
# ~0.8s/render even fully warm, yet the figure barely moves second-to-second.
# Memoize the final output line for a short TTL so most renders skip all of it.
# Only a fully-warmed result is cached (see the write guard) so the cache never
# freezes a mid-warmup undercount.
MONTHLY_RESULT_TTL=60      # seconds to reuse the last computed month-to-date line

# ── Month-to-date COST ledger ───────────────────────────────────────
# Deliberately NOT under TMPDIR with everything else. Every other cache here is
# rebuildable by re-reading transcripts, so losing it costs a warm-up. This one
# is not rebuildable — it accumulates a counter that Claude Code hands over once
# per render and never stores — and /tmp is cleared on reboot on most systems,
# which would silently erase the month. It lives beside config.sh instead.
SLB_COST_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline-beauty/cost"

# ── Helpers ───────────────────────────────────────────────────────
# Seconds after which a held lock is presumed abandoned. Long enough that a
# slow-but-alive background pass is never robbed, short enough that a wedged
# cache heals within a couple of renders.
SLB_LOCK_STALE=120

# Try to take a mkdir-based lock; 0 on success, 1 if someone else holds it.
#
# mkdir is atomic, which is why it is the lock primitive here — but a holder
# killed between mkdir and rmdir (terminal closed, OOM, reboot mid-write)
# leaves the directory behind and the guarded work then never runs again for
# the life of the cache directory. Steal anything older than SLB_LOCK_STALE.
#
# rmdir is the arbiter when two processes both judge a lock stale: exactly one
# rmdir can succeed, and the loser reports "held" rather than racing on mkdir.
#
# The steal is not perfectly atomic — a process can judge a lock stale, have it
# stolen and recreated by someone else, and then evict that live holder. The
# re-read below closes the window observed in testing (8 racers went from 2
# winners to 1), and the residual risk is bounded and harmless: the guarded
# work is recomputing cache rows, which is idempotent and written by atomic
# rename, so two warmers duplicate effort but cannot corrupt or miscount.
_take_lock() {
  local lock=$1
  mkdir "$lock" 2>/dev/null && return 0
  local held; held=$(stat "$_STAT_F" "$_FMT_MTIME" "$lock" 2>/dev/null) || return 1
  local now; printf -v now '%(%s)T' -1
  (( now - held > SLB_LOCK_STALE )) || return 1
  [ "$(stat "$_STAT_F" "$_FMT_MTIME" "$lock" 2>/dev/null)" = "$held" ] || return 1
  rmdir "$lock" 2>/dev/null || return 1
  mkdir "$lock" 2>/dev/null
}

# Render a string with each character in a cycling rainbow (256-color).
# Used for the model name when it's Opus. Falls back gracefully on
# terminals without 256-color — the codes are simply ignored.
rainbow() {
  local s=$1 i ch out=""
  local len=${#s}
  local denom=$(( len > 1 ? len - 1 : 1 ))
  local d2=$(( 2 * denom ))
  # 24-bit truecolor 3-stop gradient computed across the whole name so colors
  # never repeat regardless of length: first char = light green, middle = light
  # blue, last = light purple.
  #   A #5fcd78 (green) → B #55a0eb (blue) → C #a56ef0 (purple)
  local Ar=95 Ag=205 Ab=120   Br=85 Bg=160 Bb=235   Cr=165 Cg=110 Cb=240
  local r g b num ln cAr cAg cAb cBr cBg cBb p2
  for (( i = 0; i < len; i++ )); do
    ch=${s:i:1}
    p2=$(( 2 * i ))                 # position t*2 in units of 1/denom (range 0..2*denom)
    if (( p2 <= denom )); then      # first half → segment A→B
      ln=$p2;            cAr=$Ar cAg=$Ag cAb=$Ab   cBr=$Br cBg=$Bg cBb=$Bb
    else                            # second half → segment B→C
      ln=$(( p2 - denom )); cAr=$Br cAg=$Bg cAb=$Bb   cBr=$Cr cBg=$Cg cBb=$Cb
    fi
    num=$(( cAr*denom + (cBr-cAr)*ln )); r=$(( (2*num + denom) / d2 ))
    num=$(( cAg*denom + (cBg-cAg)*ln )); g=$(( (2*num + denom) / d2 ))
    num=$(( cAb*denom + (cBb-cAb)*ln )); b=$(( (2*num + denom) / d2 ))
    out+="\033[38;2;${r};${g};${b}m${ch}"
  done
  printf '%b' "${out}\033[0m"
}

# Round a possibly-float percentage to an int, clamp 0..100
to_int_pct() {
  local v=$1
  [ -z "$v" ] && { echo 0; return; }
  v=$(printf '%.0f' "$v" 2>/dev/null || echo 0)
  (( v < 0 )) && v=0
  (( v > 100 )) && v=100
  echo "$v"
}

# Humanize a token count: 15500 -> 15.5k, 200000 -> 200k, 1850000 -> 1.8M
# Drops the trailing ".0" for round numbers.
humanize_tokens() {
  local n=$1
  { [ -z "$n" ] || ! [[ "$n" =~ ^[0-9]+$ ]]; } && return
  local div unit
  if   (( n >= 1000000 )); then div=1000000; unit=M
  elif (( n >= 1000 ));    then div=1000;    unit=k
  else printf '%d' "$n"; return
  fi
  local whole=$(( n / div ))
  local frac=$(( (n % div) * 10 / div ))   # one decimal digit
  if (( frac == 0 )); then printf '%d%s' "$whole" "$unit"
  else                     printf '%d.%d%s' "$whole" "$frac" "$unit"
  fi
}

# Sum input_tokens / output_tokens over every assistant message in a transcript.
# Claude Code writes one JSONL line per content block (thinking/text/tool_use)
# within a turn, usually repeating the same usage object on each — so collapse
# by requestId or totals overcount 2-3x.
#
# Take the LARGEST snapshot per request, not the first. The repeated objects are
# not always identical: a streamed response can leave an early partial line
# (`output_tokens: 1`) alongside the final one (`255`), and picking the first
# silently undercounts. Measured against `claude -p --output-format json` on a
# fresh session, first-wins was 623 output tokens short of the 1581 the CLI
# billed; max-wins matched it exactly. output_tokens only grows within a
# request, so the maximum is the final figure.
_sum_tokens() {
  jq -rs '
    [ .[] | select(.message.usage) | {rid: .requestId, u: .message.usage} ]
    | group_by(.rid) | map(max_by(.u.output_tokens // 0)) | map(.u) as $u
    | "\(($u | map(.input_tokens  // 0) | add) // 0) \(($u | map(.output_tokens // 0) | add) // 0) \(($u | map(.cache_read_input_tokens // 0) | add) // 0)"
  ' "$1" 2>/dev/null || echo "0 0 0"
}

# Like _sum_tokens() but scoped to a month, for the 📅 token figure. Emits ONE
# line: "input output cache_read cache_write_5m cache_write_1h".
#
# No per-model split: the display sums all five buckets into a single number,
# and the rate tables that were the only other consumer are gone — cost comes
# from Claude Code now, not from tokens times a price.
#
# $2/$3 bound the half-open window [since, until) as UTC ISO-8601 strings.
# Transcripts are selected by mtime, but a session started last month and
# touched this month carries LAST month's messages too — counting the whole
# file attributes them to the wrong month. Fixed-width ISO UTC sorts
# lexicographically in time order, so a plain string compare is exact here and
# costs nothing next to parsing every timestamp.
_sum_tokens_month() {
  jq -rs --arg since "${2:-}" --arg until "${3:-}" '
    [ .[] | select(.message.usage and .message.model)
      | select($since == "" or (.timestamp // "") >= $since)
      | select($until == "" or (.timestamp // "") <  $until)
      | {rid: .requestId, u: .message.usage} ]
    | group_by(.rid) | map(max_by(.u.output_tokens // 0))
    # `add` yields null for an empty array, and null minus null is a jq ERROR
    # rather than zero — so a transcript with nothing inside this month (every
    # message belongs to last month, or it has no usage yet) aborted the whole
    # filter. The caller reads a non-zero exit as "transient, retry later", so
    # those files were re-parsed on every render and never cached. `// 0` on
    # each sum keeps the empty case arithmetic.
    | { input:  ((map(.u.input_tokens // 0) | add) // 0),
        output: ((map(.u.output_tokens // 0) | add) // 0),
        cache_r:((map(.u.cache_read_input_tokens // 0) | add) // 0),
        cw_5m:  ((map(.u.cache_creation.ephemeral_5m_input_tokens // 0) | add) // 0),
        cw_1h:  ((map(.u.cache_creation.ephemeral_1h_input_tokens // 0) | add) // 0),
        cw_tot: ((map(.u.cache_creation_input_tokens // 0) | add) // 0) }
    # 5m writes: prefer the explicit breakdown field. Fall back to the
    # subtraction only when it is absent, and floor it at 0 — the top-level
    # total and the 1h breakdown do not always agree in real transcripts
    # (observed cw_tot 233348 vs cw_1h 236825 in one session), and a negative
    # count would drag the displayed token total down.
    | "\(.input) \(.output) \(.cache_r) \(if .cw_5m > 0 then .cw_5m else ([.cw_tot - .cw_1h, 0] | max) end) \(.cw_1h)"
  ' "$1" 2>/dev/null
}

# Cumulative session tokens — summed from the transcript JSONL.
# The statusline JSON only exposes the current turn, so for a running session
# total we sum input/output/cache_read over every assistant message. Result is
# CACHED keyed by the transcript's size:mtime, so the expensive jq -s only
# runs when it grows. Echoes "IN OUT CACHE_READ"; "0 0 0" when missing.
session_tokens() {
  local tp=$1
  { [ -z "$tp" ] || [ ! -f "$tp" ]; } && { echo "0 0 0"; return; }
  local sig; sig=$(stat "$_STAT_F" "$_FMT_SIG" "$tp" 2>/dev/null) || { _sum_tokens "$tp"; return; }
  local dir="$SLB_CACHE_DIR"
  local cache="$dir/${tp##*/}.cache"
  if [ -f "$cache" ]; then
    local c_sig c_in c_out c_cr
    read -r c_sig c_in c_out c_cr < "$cache"
    [ "$c_sig" = "$sig" ] && { echo "$c_in $c_out $c_cr"; return; }   # cache hit
  fi
  local s_in s_out s_cr
  read -r s_in s_out s_cr <<< "$(_sum_tokens "$tp")"
  mkdir -p -m 700 "$SLB_CACHE_ROOT" "$dir" 2>/dev/null && printf '%s %s %s %s\n' "$sig" "$s_in" "$s_out" "$s_cr" > "$cache" 2>/dev/null
  echo "$s_in $s_out $s_cr"
}

# Most recently invoked Skill or Agent (sub-agent) tool call in the transcript,
# plus session-wide counts of skill/agent/MCP/other-tool calls — surfaced on
# Line 1. Claude Code's statusline JSON has no native "active skill/agent"
# field (as of v2.1.140), so this is a transcript-mined proxy: the name
# reflects the LAST Skill/Agent tool_use call, not necessarily one still
# "running" right now. MCP tool calls are identified by the "mcp__" name
# prefix Claude Code gives every MCP-server tool.
# Echoes "TYPE NAME SKILL_N AGENT_N MCP_N TOOL_N" (TYPE "skill"/"agent"/"none";
# TOOL_N excludes Skill/Agent/MCP calls so the four counts don't overlap).
# CACHED like session_tokens().
# Accepts ONE OR MORE transcript paths ("$@"): the main session file plus every
# subagent transcript. jq -s slurps them all into one array, so the four counts
# become session-wide totals (main agent + all subagents), not just the top
# agent's. Order is irrelevant to the counts (they're sums); only the unused
# "last invoked" name depends on order, and that's no longer displayed.
_last_agent_skill() {
  jq -rs '
    [ .[] | select(.message.content != null) | .message.content[]?
      | select(.type == "tool_use") ] as $all
    | ($all | length) as $tool_total
    | ($all | map(select(.name == "Skill")) | length) as $skill_n
    | ($all | map(select(.name == "Agent")) | length) as $agent_n
    | ($all | map(select(.name | startswith("mcp__"))) | length) as $mcp_n
    | ($all | map(select(.name == "Skill" or .name == "Agent"))) as $sa
    | (if ($sa | length) == 0 then ["none", "none"] else
         ($sa[-1] | if .name == "Skill" then ["skill", (.input.skill // "?")]
                     else ["agent", (.input.subagent_type // "general-purpose")]
                     end)
       end) as $last
    | "\($last[0]) \($last[1]) \($skill_n) \($agent_n) \($mcp_n) \($tool_total - $skill_n - $agent_n - $mcp_n)"
  ' "$@" 2>/dev/null
}

last_agent_skill() {
  local tp=$1
  { [ -z "$tp" ] || [ ! -f "$tp" ]; } && { echo "none none 0 0 0 0"; return; }
  # Subagents write their own transcripts under <session-id>/subagents/ (one
  # more nesting level per subagent depth). Fold every one of them in so the
  # skill/agent/mcp/tool counts reflect the WHOLE session, not just the top
  # agent. The dir only exists once a session has actually spawned a subagent,
  # so the common (no-subagent) case pays nothing beyond the [ -d ] test.
  local sessdir="${tp%.jsonl}" subs=()
  if [ -d "$sessdir" ]; then
    readarray -t subs < <(find "$sessdir" -name 'agent-*.jsonl' 2>/dev/null)
  fi
  # The signature must change when ANY constituent file grows — otherwise a
  # running subagent's new calls would never refresh the count (the main
  # transcript doesn't change until the Agent result returns). Collapse every
  # file's size:mtime into ONE space-free token (newlines → commas) so the
  # cache-read `read -r c_sig c_val` below still splits sig from value cleanly.
  local sig; sig=$(stat "$_STAT_F" "$_FMT_SIG" "$tp" "${subs[@]}" 2>/dev/null | tr '\n' ',') \
    || { _last_agent_skill "$tp" "${subs[@]}"; return; }
  local dir="$SLB_CACHE_DIR"
  local cache="$dir/${tp##*/}.agentskill.cache"
  if [ -f "$cache" ]; then
    local c_sig c_val
    read -r c_sig c_val < "$cache"
    [ "$c_sig" = "$sig" ] && { echo "$c_val"; return; }   # cache hit
  fi
  local val; val=$(_last_agent_skill "$tp" "${subs[@]}")
  mkdir -p -m 700 "$SLB_CACHE_ROOT" "$dir" 2>/dev/null && printf '%s %s\n' "$sig" "$val" > "$cache" 2>/dev/null
  echo "$val"
}


# Month-to-date cost/token stat — scans every transcript modified since day 1
# of this month: the main session files AND every subagent transcript nested
# beneath them, which cost real money and outnumber the main ones several to
# one. Sums tokens (deduped, see _sum_tokens_month).
# Per-file sums are CACHED in a directory separate from session_tokens()'s
# cache, so only the currently-active session's file is ever reparsed. A cold
# cache is capped at MONTHLY_WARMUP_BUDGET files/render and warms up over a
# few renders instead of blocking one render for the ~2-3s a full cold scan
# of a month's transcripts can take.
#
# Tokens only — the money comes from monthly_cost(), which accumulates the
# figure Claude Code itself reports rather than pricing these tokens.
# Echoes "IN OUT CACHE_READ CACHE_WRITE_5M CACHE_WRITE_1H WARMING".

# Month-to-date cost, accumulated from the figure Claude Code hands us.
#
# `.cost.total_cost_usd` is a running total for THIS PROCESS, not for the
# session: resuming starts it over. Verified — one session reported $0.030005,
# then $0.003533 after `claude --resume` on the same session_id. So it is a
# monotonic counter with resets, and it is accumulated the way any such counter
# is: credit the increase; a decrease means a new run whose whole value is new.
#
# Reset detection is safe because a new run renders its status line at startup,
# before any API call, so the first value it reports is ~$0 — far below the
# previous run's final total. The failure needs every render of a new run to be
# missed until it passes the old total, and it under-reports rather than over.
#
# Crediting the DELTA rather than a session total is what splits a session that
# runs past midnight on the last of the month across both months.
#
# Why this instead of pricing the tokens: this figure already accounts for fast
# mode, `inference_geo`, web-search requests, subagents, and the API calls
# Claude Code bills without writing them to any transcript. Reproducing it needs
# a rate table that goes stale, and even then it cannot see the untranscribed
# calls. What it costs is history: unlike the token cache, this cannot be
# rebuilt, so a period with the status line disabled is never counted.
#
# Echoes the month's total with 8 decimals — the running sum is rewritten on
# every render, so the rounding step has to sit far below the cent the display
# shows or it would compound over thousands of renders.
monthly_cost() {
  local sid=$1 observed=$2
  # SLB_DEMO marks a canned-fixture render: the installer's smoke test and
  # `manage.sh render-demo` both do several per invocation, carrying a made-up
  # cost. That must never reach the ledger — and unlike the token cache, the
  # ledger cannot be rebuilt to undo it afterwards.
  (( ${SLB_DEMO:-0} )) && { printf '0'; return; }
  local month; printf -v month '%(%Y-%m)T' -1
  local month_dir="$SLB_COST_DIR/$month"
  mkdir -p -m 700 "$SLB_COST_DIR" "$month_dir" 2>/dev/null || { printf '0'; return; }

  # Session ids are UUIDs from Claude Code, but they land in a filename, so
  # refuse anything that is not one rather than trusting the input.
  if [[ $sid =~ ^[A-Za-z0-9._-]+$ ]] && [[ $observed =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    local last_file="$SLB_COST_DIR/$sid.last" sum_file="$month_dir/$sid.sum"
    local last=0 sum=0
    [ -f "$last_file" ] && read -r last < "$last_file" 2>/dev/null
    [ -f "$sum_file"  ] && read -r sum  < "$sum_file"  2>/dev/null
    [[ $last =~ ^[0-9]+([.][0-9]+)?$ ]] || last=0
    [[ $sum  =~ ^[0-9]+([.][0-9]+)?$ ]] || sum=0

    local new_sum
    new_sum=$(awk -v o="$observed" -v l="$last" -v s="$sum" \
      'BEGIN { printf "%.8f", s + ((o >= l) ? o - l : o) }')

    # `.last` first. Crashing between the two writes then loses the delta
    # (under-report) instead of re-crediting it on the next render
    # (over-report), and a spend figure should fail low.
    printf '%s\n' "$observed" > "$last_file.tmp.$$" && mv -f "$last_file.tmp.$$" "$last_file"
    printf '%s\n' "$new_sum"  > "$sum_file.tmp.$$"  && mv -f "$sum_file.tmp.$$"  "$sum_file"
  fi

  # Past months are KEPT — they are the only record there is, and a month's
  # worth of these files is a few kilobytes. Only the month-independent `.last`
  # markers are retired, and only when far older than any conceivable run:
  # losing one is harmless because a resumed run restarts its counter at zero,
  # which is exactly what a missing `.last` assumes.
  find "$SLB_COST_DIR" -maxdepth 1 -name '*.last' -mtime +60 -delete 2>/dev/null

  awk '{ t += $1 } END { printf "%.8f", t + 0 }' "$month_dir"/*.sum 2>/dev/null || printf '0'
}

monthly_tokens() {
  local proj_root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  [ -d "$proj_root" ] || { echo "0 0 0 0 0 0"; return; }

  # The bucket carries a cache-format suffix as well as the month, so a format
  # change retires the old bucket wholesale via the prune below instead of
  # mixing row layouts. v3 dropped the per-model column.
  local month; printf -v month '%(%Y-%m)T' -1
  local bucket="$month.v3"
  local MONTHLY_CACHE_DIR="$MONTHLY_CACHE_ROOT/$bucket"
  mkdir -p -m 700 "$SLB_CACHE_ROOT" "$MONTHLY_CACHE_ROOT" "$MONTHLY_CACHE_DIR" 2>/dev/null

  # Retire everything that is not the current bucket: past months, superseded
  # cache formats, and the flat *.cache files written before month scoping
  # existed. The listing below is already month-scoped, so those rows can never
  # match again — they would only be read and discarded, once per render,
  # forever. An unmatched glob yields a literal '*', which falls through both
  # patterns and removes nothing.
  local e n
  for e in "$MONTHLY_CACHE_ROOT"/*; do
    n=${e##*/}
    case "$n" in
      "$bucket")                        continue ;;
      [0-9][0-9][0-9][0-9]-[0-9][0-9]*) rm -rf -- "$e" 2>/dev/null ;;
      *.cache)                          rm -f  -- "$e" 2>/dev/null ;;
    esac
  done
  # Dotfiles the glob above cannot see, also from the flat layout.
  rm -f    -- "$MONTHLY_CACHE_ROOT/.result.cache" 2>/dev/null
  rmdir    -- "$MONTHLY_CACHE_ROOT/.warm.lock"    2>/dev/null

  # ── Result memo: reuse the last fully-warmed line for MONTHLY_RESULT_TTL ──
  # printf %(%s)T is a bash builtin (>=4.2) — no `date` fork on the hot path.
  local result_cache="$MONTHLY_CACHE_DIR/.result.cache"
  local now_s; printf -v now_s '%(%s)T' -1
  if [ -f "$result_cache" ]; then
    local r_ts r_line
    IFS='|' read -r r_ts r_line < "$result_cache"
    if [ -n "$r_ts" ] && (( now_s - r_ts < MONTHLY_RESULT_TTL )); then
      echo "$r_line"; return
    fi
  fi

  # No -maxdepth: subagents write their own transcripts under
  # <session-id>/subagents/, one more nesting level per subagent depth (and
  # another for workflow agents), and their tokens cost exactly as much as the
  # main agent's. Capping the walk at depth 2 silently excluded all of them —
  # measured here as 580 of 684 files, and 36% of the month's spend.
  # last_agent_skill() already folds the same files into the tool counters.
  local month_start; printf -v month_start '%(%Y-%m-01)T' -1
  # The month boundary the user means is LOCAL midnight, but transcript
  # timestamps are UTC — at +07:00 that is a seven-hour band of messages that
  # would otherwise land in the wrong month. Neither direction has a portable
  # tool (`date -d`/`-f -` are GNU-only, `date -j -f` is BSD-only), so both are
  # arithmetic now: local midnight to epoch, then that epoch back out as UTC.
  # If either fails the bounds stay empty and jq counts the whole file, which is
  # exactly the behaviour that shipped before.
  local _y=$(( 10#${month_start:0:4} )) _m=$(( 10#${month_start:5:2} ))
  local next_start
  if (( _m == 12 )); then printf -v next_start '%04d-01-01' $(( _y + 1 ))
  else                    printf -v next_start '%04d-%02d-01' "$_y" $(( _m + 1 ))
  fi
  local since="" until="" _e1="" _e2=""
  _e1=$(_local_midnight_epoch "$month_start")
  _e2=$(_local_midnight_epoch "$next_start")
  if [ -n "$_e1" ] && [ -n "$_e2" ]; then
    since=$(_epoch_to_utc_iso "$_e1")
    until=$(_epoch_to_utc_iso "$_e2")
  fi

  # `find -printf` is GNU-only — on BSD find it is not just absent but a usage
  # error, which emptied the whole listing and silently removed the 📅 segment.
  # `-exec stat +` batches the same fields into one extra process instead.
  local listing
  listing=$(find "$proj_root" -mindepth 2 -name '*.jsonl' \
              -newermt "$month_start" -exec stat "$_STAT_F" "$_FMT_NAMESIG" {} + 2>/dev/null)
  # -newermt is only a cheap pre-filter: the month is really bounded per message
  # by $since/$until inside jq, so dropping it costs walk time, never accuracy.
  # An empty listing on a find that does not understand the predicate is
  # indistinguishable from an empty listing on a quiet month, so just retry
  # without it rather than assuming which one happened.
  if [ -z "$listing" ]; then
    listing=$(find "$proj_root" -mindepth 2 -name '*.jsonl' \
                -exec stat "$_STAT_F" "$_FMT_NAMESIG" {} + 2>/dev/null)
  fi
  [ -z "$listing" ] && { echo "0 0 0 0 0 0"; return; }

  # Merge already-cached rows against the live listing with ONE cat + ONE awk
  # (a per-file bash loop over 100+ tiny cache files measured ~10x slower).
  # Emits matched 7-field cache rows as-is, plus "DIRTY path sig" once per
  # file that's new/changed since it was last cached.
  # awk on this system treats a missing file argument as FATAL (aborts before
  # even running BEGIN/END) — an unmatched glob must never be passed to it, so
  # check existence first instead of relying on nullglob-less expansion.
  local cache_files=()
  compgen -G "$MONTHLY_CACHE_DIR"/*.cache > /dev/null 2>&1 && cache_files=("$MONTHLY_CACHE_DIR"/*.cache)

  local merged
  # BSD awk (macOS system awk) hard-errors on a literal newline inside a `-v`
  # value ("newline in string"), which silently emptied the merge and pinned
  # the month at 0 tokens. Escape newlines as \n — POSIX requires -v values to
  # undergo escape processing, so both awks rebuild the same multi-line string.
  local listing_esc=${listing//$'\n'/\\n}
  merged=$(awk -v listing="$listing_esc" '
    BEGIN {
      n = split(listing, L, "\n")
      for (i = 1; i <= n; i++) {
        split(L[i], p, " "); live[p[1]] = p[2]; order[++cnt] = p[1]
      }
    }
    { path=$1; sig=$2
      # One row per transcript now that the model column is gone, so a plain
      # path key is the right dedupe. Nothing should ever write two files
      # carrying the same path, but if anything did — a leftover from an older
      # key scheme, a half-finished migration — summing both would inflate the
      # month, so the first row wins.
      if (path in live && live[path] == sig && !(path in seen)) { seen[path]=1; print }
    }
    END { for (i=1;i<=cnt;i++) if (!(order[i] in seen)) print "DIRTY " order[i] " " live[order[i]] }
  ' "${cache_files[@]}" /dev/null 2>/dev/null)

  # ONE pass over the merge output, splitting fields in the read itself. A cache
  # row is "path sig in out cache_read cw5m cw1h" (7 fields) and a DIRTY marker
  # is "DIRTY path sig" (3), so the same read handles both — the previous
  # `read ... <<< "$line"` per row cost a here-string each time, which at this
  # row count measured ~2x the whole loop.
  local sum_in=0 sum_out=0 sum_cr=0 sum_c5=0 sum_c1=0
  local budget=$MONTHLY_WARMUP_BUDGET warming=0 leftover=""
  local f1 f2 i o cr c5 c1
  while read -r f1 f2 i o cr c5 c1; do
    [ -z "$f1" ] && continue
    if [ "$f1" != DIRTY ]; then
      sum_in=$(( sum_in + i ));  sum_out=$(( sum_out + o )); sum_cr=$(( sum_cr + cr ))
      sum_c5=$(( sum_c5 + c5 )); sum_c1=$(( sum_c1 + c1 ))
      continue
    fi
    local path=$f2 sig=$i
    if (( budget <= 0 )); then warming=1; leftover+="$path $sig"$'\n'; continue; fi
    budget=$(( budget - 1 ))
    # Key the row file on the path flattened relative to the projects root, not
    # on its basename: subagent transcripts are named agent-<id>.jsonl and the
    # same id genuinely recurs across sessions (observed twice in one project),
    # so a basename key silently makes two transcripts share one cache entry.
    # Longest real path measured here is 195 chars, well inside NAME_MAX.
    local key=${path#"$proj_root"/}; key=${key//\//%}
    local cache="$MONTHLY_CACHE_DIR/$key.cache"
    local jq_out jq_status
    jq_out=$(_sum_tokens_month "$path" "$since" "$until"); jq_status=$?
    # A transient jq failure (OOM/fork pressure on a loaded box, not a data
    # problem) must NOT be read as "this file has zero usage" — that would
    # permanently bake in a wrong zero for a real file. Leave it DIRTY so a
    # later render retries it instead of writing anything now.
    (( jq_status == 0 )) || continue
    local ri ro rcr rc5 rc1
    read -r ri ro rcr rc5 rc1 <<< "$jq_out"
    # A file with no usage in this window (fresh session, aborted turn, or all
    # of its messages belong to last month) legitimately sums to nothing — jq
    # emits "null null ..." for an empty set. Normalise to zeros and still write
    # the row, or the merge could never tell "confirmed zero" from "never
    # processed" and would re-mark the file DIRTY forever.
    [[ $ri  =~ ^-?[0-9]+$ ]] || ri=0
    [[ $ro  =~ ^-?[0-9]+$ ]] || ro=0
    [[ $rcr =~ ^-?[0-9]+$ ]] || rcr=0
    [[ $rc5 =~ ^-?[0-9]+$ ]] || rc5=0
    [[ $rc1 =~ ^-?[0-9]+$ ]] || rc1=0
    sum_in=$(( sum_in + ri ));  sum_out=$(( sum_out + ro )); sum_cr=$(( sum_cr + rcr ))
    sum_c5=$(( sum_c5 + rc5 )); sum_c1=$(( sum_c1 + rc1 ))
    local out_buf="$path $sig $ri $ro $rcr $rc5 $rc1"$'\n'
    # This box runs many concurrent Claude Code sessions, each independently
    # rendering its own statusline — write via temp-file + rename (atomic on
    # the same filesystem) instead of truncate-then-append, so two processes
    # racing on the same cache file can't interleave and corrupt it.
    printf '%s' "$out_buf" > "$cache.tmp.$$" && mv -f "$cache.tmp.$$" "$cache"
  done <<< "$merged"

  # On a busy multi-agent box, background jobs mint new transcripts faster
  # than an interactive render (the only thing that drives the loop above)
  # can drain the per-render budget — the backlog then never clears and the
  # displayed month-to-date figure stays a stale undercount indefinitely.
  # Drain the rest in a DETACHED background pass (lock-guarded like
  # is_latest_version()'s refresh) so it converges within a render or two
  # without ever blocking this one.
  if [ -n "$leftover" ]; then
    local warm_lock="$MONTHLY_CACHE_DIR/.warm.lock"
    if _take_lock "$warm_lock"; then
      ( while read -r p s; do
          [ -z "$p" ] && continue
          k=${p#"$proj_root"/}; k=${k//\//%}
          c="$MONTHLY_CACHE_DIR/$k.cache"
          out=$(_sum_tokens_month "$p" "$since" "$until"); st=$?
          (( st == 0 )) || continue   # transient failure — leave DIRTY, retry later
          read -r bi bo bcr bc5 bc1 <<< "$out"
          [[ $bi  =~ ^-?[0-9]+$ ]] || bi=0
          [[ $bo  =~ ^-?[0-9]+$ ]] || bo=0
          [[ $bcr =~ ^-?[0-9]+$ ]] || bcr=0
          [[ $bc5 =~ ^-?[0-9]+$ ]] || bc5=0
          [[ $bc1 =~ ^-?[0-9]+$ ]] || bc1=0
          out_buf="$p $s $bi $bo $bcr $bc5 $bc1"$'\n'
          tmp="$c.tmp.$BASHPID"
          printf '%s' "$out_buf" > "$tmp" && mv -f "$tmp" "$c"
        done <<< "$leftover"
        rmdir "$warm_lock" 2>/dev/null
      ) >/dev/null 2>&1 & disown
    fi
  fi

  # ── Rebase to zero, so tokens describe the same span as the cost ──
  # monthly_cost() can only count what it has observed, and showing a token
  # figure that reaches back through the whole month beside a cost figure that
  # starts at install would put two different spans of time in one segment.
  # Snapshot the month's totals once and report the growth since.
  #
  # The snapshot is taken ONLY from a fully warm scan. A baseline captured
  # mid-warm-up is an undercount, and since it is never rewritten, every later
  # render would overstate the month by that gap for the rest of the month.
  local base_file="$SLB_COST_DIR/$month.tokens-base"
  local b_in=0 b_out=0 b_cr=0 b_c5=0 b_c1=0
  if [ -f "$base_file" ]; then
    read -r b_in b_out b_cr b_c5 b_c1 < "$base_file" 2>/dev/null
    [[ $b_in  =~ ^[0-9]+$ ]] || b_in=0
    [[ $b_out =~ ^[0-9]+$ ]] || b_out=0
    [[ $b_cr  =~ ^[0-9]+$ ]] || b_cr=0
    [[ $b_c5  =~ ^[0-9]+$ ]] || b_c5=0
    [[ $b_c1  =~ ^[0-9]+$ ]] || b_c1=0
  else
    # No baseline yet. Report zero regardless of warm-up state: the baseline
    # about to be written is whatever the month reads once warm, so showing the
    # raw total in the meantime would flash the whole month's history and then
    # collapse to nothing a few renders later.
    b_in=$sum_in b_out=$sum_out b_cr=$sum_cr b_c5=$sum_c5 b_c1=$sum_c1
    # Persist only from a warm scan. A baseline captured mid-warm-up is an
    # undercount, and it is never rewritten, so it would overstate every
    # remaining render of the month by that gap.
    if (( warming == 0 )) && ! (( ${SLB_DEMO:-0} )) && mkdir -p -m 700 "$SLB_COST_DIR" 2>/dev/null; then
      printf '%s %s %s %s %s\n' "$sum_in" "$sum_out" "$sum_cr" "$sum_c5" "$sum_c1" \
        > "$base_file.tmp.$$" && mv -f "$base_file.tmp.$$" "$base_file"
    fi
  fi
  # Floor each at zero: a deleted or rotated transcript can put the live total
  # below the baseline, and a negative token count is worse than a stale one.
  (( (sum_in  -= b_in ) < 0 )) && sum_in=0
  (( (sum_out -= b_out) < 0 )) && sum_out=0
  (( (sum_cr  -= b_cr ) < 0 )) && sum_cr=0
  (( (sum_c5  -= b_c5 ) < 0 )) && sum_c5=0
  (( (sum_c1  -= b_c1 ) < 0 )) && sum_c1=0

  local out_line="$sum_in $sum_out $sum_cr $sum_c5 $sum_c1 $warming"
  # Only memoize a fully-warmed line (warming==0): caching mid-warmup would pin a
  # known undercount for the whole TTL. Atomic temp+rename — many concurrent
  # sessions render into this same dir. Delimiter '|' can't appear in the line.
  if (( warming == 0 )); then
    printf '%s|%s\n' "$now_s" "$out_line" > "$result_cache.tmp.$$" 2>/dev/null \
      && mv -f "$result_cache.tmp.$$" "$result_cache" 2>/dev/null
  fi
  echo "$out_line"
}

# Circle emoji by usage: 0-25 green, 25-50 white, 50-75 yellow, 75-100 red
pct_circle() {
  local p=$1
  if   (( p >= 75 )); then printf '🔴'
  elif (( p >= 50 )); then printf '🟡'
  elif (( p >= 25 )); then printf '⚪'
  else                     printf '🟢'
  fi
}

# Pick bar color by usage: <75 white, 75-99 yellow, 100 red
bar_color() {
  local p=$1
  if   (( p >= 100 )); then printf '%s' "$C_RED"
  elif (( p >= 75 ));  then printf '%s' "$C_YEL"
  else                      printf '%s' "$C_BAR"
  fi
}

# Build a [████░░░░] bar for a given int percentage. Solid block/shade
# chars only (no eighth-block partials — those left visible gaps in some
# terminal fonts). BAR_WIDTH=25 gives 4%-per-char resolution instead.
make_bar() {
  local p=$1 i
  (( p < 0 ))   && p=0
  (( p > 100 )) && p=100
  local filled=$(( p * BAR_WIDTH / 100 ))
  (( filled > BAR_WIDTH )) && filled=$BAR_WIDTH
  (( filled == 0 && p > 0 )) && filled=1
  local empty=$(( BAR_WIDTH - filled ))
  local bar=""
  for (( i = 0; i < filled; i++ )); do bar="${bar}█"; done
  for (( i = 0; i < empty;  i++ )); do bar="${bar}░"; done
  printf '%s' "$bar"
}

# Human time until a Unix-epoch reset timestamp, with absolute clock time
time_until_reset() {
  local reset_ts=$1
  [ -z "$reset_ts" ] || [ "$reset_ts" = "null" ] && return
  # accept epoch seconds; parse ISO strings ourselves (no GNU date)
  if ! [[ "$reset_ts" =~ ^[0-9]+$ ]]; then
    reset_ts=$(_iso_to_epoch "$reset_ts") || return
  fi
  local now remaining rel clock
  printf -v now '%(%s)T' -1
  remaining=$(( reset_ts - now ))
  if   (( remaining < 0 ));     then rel="now"
  elif (( remaining < 60 ));    then rel="${remaining}s"
  elif (( remaining < 3600 ));  then rel="$(( remaining / 60 ))m"
  elif (( remaining < 86400 )); then rel="$(( remaining / 3600 ))h $(( (remaining % 3600) / 60 ))m"
  else                               rel="$(( remaining / 86400 ))d $(( (remaining % 86400) / 3600 ))h"
  fi
  # printf '%(fmt)T' renders in the LOCAL zone, which is exactly what
  # `date -d @N` did here — and it is a builtin, so the fork is gone too.
  printf -v clock '%(%I:%M %p)T' "$reset_ts" 2>/dev/null
  [ -n "$clock" ] && echo "${rel} (${clock})" || echo "$rel"
}

# True if $1 (the running version) matches the latest version on npm, per a
# cache refreshed at most every LATEST_VERSION_TTL. Never blocks: a
# stale/missing cache triggers a detached background refresh for the NEXT
# render and returns false for THIS one. A lock dir prevents piling up
# duplicate background npm calls across rapid-fire renders.
is_latest_version() {
  local cur=$1
  [ -z "$cur" ] && return 1
  local now; printf -v now '%(%s)T' -1
  local c_ts="" c_ver=""
  [ -f "$LATEST_VERSION_CACHE" ] && read -r c_ts c_ver < "$LATEST_VERSION_CACHE" 2>/dev/null
  if [ -z "$c_ts" ] || (( now - c_ts > LATEST_VERSION_TTL )); then
    local lock="${LATEST_VERSION_CACHE}.lock"
    if mkdir -p -m 700 "$SLB_CACHE_ROOT" "$(dirname "$LATEST_VERSION_CACHE")" 2>/dev/null && _take_lock "$lock"; then
      # macOS has no timeout(1) — it is coreutils' gtimeout, and only if Homebrew
      # installed it — so `timeout 5 npm view` failed outright there and the (LTS)
      # tag could never appear. Run npm in the background with a watchdog instead:
      # portable, and it still bounds a registry call that hangs. The watchdog's
      # own stdout goes to /dev/null so it never holds the $() pipe open past the
      # kill; only npm's output reaches $v.
      ( v=$( npm view @anthropic-ai/claude-code version 2>/dev/null & _np=$!
             ( sleep 5; kill -TERM "$_np" 2>/dev/null ) >/dev/null 2>&1 & _wd=$!
             wait "$_np" 2>/dev/null
             kill -TERM "$_wd" 2>/dev/null )
        printf -v _ts '%(%s)T' -1
        [ -n "$v" ] && printf '%s %s\n' "$_ts" "$v" > "$LATEST_VERSION_CACHE"
        rmdir "$lock" 2>/dev/null
      ) >/dev/null 2>&1 & disown
    fi
  fi
  [ -n "$c_ver" ] && [ "$c_ver" = "$cur" ]
}

# Emit one bar line:  🟢 label  [bar] NN%  · resets <t>  <info>  <suffix>
emit_bar() {
  local label=$1 raw_pct=$2 reset_ts=$3 info=$4 suffix=$5
  local p; p=$(to_int_pct "$raw_pct")
  local c; c=$(bar_color "$p")
  local bar; bar=$(make_bar "$p")
  local circle; circle=$(pct_circle "$p")
  printf "  %s \033[0;37m%-4s${C_RESET} ${c}[%s] %3d%%${C_RESET}" "$circle" "$label" "$bar" "$p"
  local reset_str; reset_str=$(time_until_reset "$reset_ts")
  [ -n "$reset_str" ] && printf " ${C_INFO}· resets %s${C_RESET}" "$reset_str"
  [ -n "$info" ]      && printf " ${C_INFO}· %s${C_RESET}" "$info"
  [ -n "$suffix" ]    && printf " ${C_WARN}%s${C_RESET}" "$suffix"
}

# Git branch + ahead/behind + dirty + last-commit, emitted as one
# "branch|ahead|behind|dirty|last" line. `status --porcelain=v2 --branch` gives
# branch (# branch.head), ahead/behind (# branch.ab +N -M) and one line per
# changed/untracked file in a SINGLE git call — folding the old symbolic-ref +
# rev-list×2 + status (4 spawns) into one git + one awk. Outside a repo git
# errors → empty → all-empty line (empty branch gates Line 3 off). A standalone
# function so it can run as a background producer (see the parallel block below).
_git_stats() {
  local cwd=$1 gb="" ga=0 gbh=0 gd=0 gl="" gv2
  [ -z "$cwd" ] && { printf '|0|0|0|'; return; }
  gv2=$(git -C "$cwd" status --porcelain=v2 --branch 2>/dev/null)
  if [ -n "$gv2" ]; then
    read -r gb ga gbh gd <<< "$(printf '%s\n' "$gv2" | awk '
      /^# branch.head / { head=$3 }
      /^# branch.oid /  { oid=$3 }
      /^# branch.ab /   { aa=$3; bb=$4 }
      !/^#/             { dd++ }
      END {
        sub(/^\+/,"",aa); sub(/^-/,"",bb)
        b = (head=="(detached)") ? substr(oid,1,8) : head
        printf "%s %d %d %d", b, aa+0, bb+0, dd+0
      }')"
    gl=$(git -C "$cwd" log -1 --format="%cr" 2>/dev/null \
      | sed -E 's/ ago//; s/ (hours?)/h/; s/ (minutes?)/m/; s/ (days?)/d/; s/ (weeks?)/w/; s/ (months?)/mo/')
  fi
  printf '%s|%s|%s|%s|%s' "$gb" "$ga" "$gbh" "$gd" "$gl"
}

# ── Parallel producers (D) ────────────────────────────────────────
# Launch the independent heavy work — token sums, the agent/skill scan, git
# status — concurrently so their process-spawn latencies OVERLAP instead of
# summing. The session-metadata + system-resource blocks below run in the
# foreground meanwhile (filling the wait), then one `wait` joins them. Every
# consumer has a synchronous fallback, so if the scratch dir can't be made we
# just skip parallelization — correctness never depends on it.
_par=$(mktemp -d "${TMPDIR:-/tmp}/slb-par.XXXXXX" 2>/dev/null) || _par=""
# Clean the scratch dir on EXIT rather than only at end-of-script, so a render
# the host KILLS mid-flight (statuslines get killed when slow) can't leak dirs.
[ -n "$_par" ] && trap 'rm -rf "$_par" 2>/dev/null' EXIT
# Backstop for the one case the trap can't cover: if THIS render is SIGKILLed (or
# a still-writing background producer holds a handle on Windows), a dir survives.
# Reap dirs untouched for >5min (never an active render — those live ~2s), but
# only ~1 render in 60 (cheap %S==00 gate, no fork) and DETACHED so it never
# blocks. Bounds worst-case accumulation without paying a find on every render.
printf -v _sec '%(%S)T' -1
if [ "$_sec" = "00" ]; then
  ( find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'slb-par.*' -type d -mmin +5 \
      -exec rm -rf {} + 2>/dev/null ) >/dev/null 2>&1 & disown
fi
# Each optional producer is gated here AND at its consumer below — gating only
# the consumer would still pay the full cost of the work, which defeats the
# point of the switch.
if [ -n "$_par" ]; then
  session_tokens "$transcript"   > "$_par/session"    2>/dev/null &
  (( SLB_SHOW_MONTHLY ))     && { monthly_tokens                 > "$_par/monthly"    2>/dev/null & }
  # Not gated on SLB_SHOW_MONTHLY: the ledger has to keep accumulating even
  # while the segment is hidden, or turning the display off for an afternoon
  # would erase that afternoon's spend for good. It is an awk over a handful of
  # small files, so running it unconditionally costs nothing worth saving.
  monthly_cost "$session_id" "$cost" > "$_par/monthcost" 2>/dev/null &
  (( SLB_SHOW_TOOL_COUNTS )) && { last_agent_skill "$transcript" > "$_par/agentskill" 2>/dev/null & }
  (( SLB_SHOW_GIT ))         && { _git_stats "$cwd"              > "$_par/git"        2>/dev/null & }
fi

# ── Session metadata: turns, duration, clock ──────────────────────
turns=0
duration_str=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # grep -c prints "0" AND exits 1 when there are no matches, so a `|| echo 0`
  # fallback would append a SECOND "0" and make $turns the two-line string
  # "0\n0", which then blows up every `(( turns > 0 ))` below. grep -c already
  # emits a count on its own, so just default when it produces nothing at all.
  turns=$(grep -c '"role":"assistant"' "$transcript" 2>/dev/null)
  turns=${turns:-0}
  first_ts=$(head -1 "$transcript" | grep -o '"timestamp":"[^"]*"' | cut -d'"' -f4)
  if [ -n "$first_ts" ]; then
    start_epoch=$(_iso_to_epoch "$first_ts" 2>/dev/null)
    if [ -n "$start_epoch" ]; then
      printf -v _now_epoch '%(%s)T' -1
      elapsed=$(( _now_epoch - start_epoch ))
      if   (( elapsed < 60 ));   then duration_str="${elapsed}s"
      elif (( elapsed < 3600 )); then duration_str="$(( elapsed / 60 ))m"
      else                            duration_str="$(( elapsed / 3600 ))h $(( (elapsed % 3600) / 60 ))m"
      fi
    fi
  fi
fi
printf -v clock_str '%(%H:%M)T' -1

# ── System resources (1,2,3) ──────────────────────────────────────
# Both blocks are wholly skipped when their switch is off, so a user who turns
# the bars off stops paying for free/df/nproc/awk as well.
sys_cache_dir="$SLB_CACHE_DIR"
ram_free="" ram_pct="" disk_free=""
cpu_load="" cpu_pct=""

if (( SLB_SHOW_RAM )); then
  # RAM % = (total - available) / total — "available" already accounts for
  # reclaimable cache, so this matches what most monitoring tools call "used".
  ram_total_mb="" ram_avail_mb=""
  if [ "$_SLB_OS" = macos ]; then
    # macOS has neither free(1) nor /proc/meminfo. Total comes from sysctl;
    # "available" is reconstructed from vm_stat's page counters, whose unit is
    # printed in its own header and is 16K on Apple silicon but 4K on Intel —
    # so parse the page size rather than assuming either.
    #
    # free + inactive + speculative + purgeable is the set the kernel can hand
    # to a new allocation without swapping, which is the same thing MemAvailable
    # means on Linux. Wired, active and compressed pages are the "used" side.
    read -r ram_total_mb ram_avail_mb <<< "$( {
      sysctl -n hw.memsize 2>/dev/null
      vm_stat 2>/dev/null
    } | awk '
      NR == 1                       { total = $1 }
      /page size of/                { for (i = 1; i <= NF; i++) if ($i == "of") ps = $(i+1) }
      /^Pages free:/                { f = $3 }
      /^Pages inactive:/            { n = $3 }
      /^Pages speculative:/         { s = $3 }
      /^Pages purgeable:/           { p = $3 }
      END {
        gsub(/\./, "", f); gsub(/\./, "", n); gsub(/\./, "", s); gsub(/\./, "", p)
        if (total > 0 && ps > 0)
          printf "%d %d", total/1048576, (f + n + s + p) * ps / 1048576
      }')"
  fi
  [ -z "$ram_total_mb" ] &&
    read -r ram_total_mb ram_avail_mb <<< "$(free -m 2>/dev/null | awk 'NR==2{print $2, $7}')"
  # Git Bash / MSYS ships no `free`, so the RAM bar (and the disk-free suffix
  # hanging off it) silently vanished on Windows. msys does emulate /proc/meminfo,
  # so fall back to that. It exposes MemTotal/MemFree but no MemAvailable — on
  # Windows MemFree is already Windows' "available physical memory" (it counts the
  # reclaimable standby list), so it means what MemAvailable means on Linux.
  # Prefer MemAvailable when present so this stays correct on Linux too.
  if [ -z "$ram_total_mb" ] && [ -r /proc/meminfo ]; then
    read -r ram_total_mb ram_avail_mb <<< "$(awk '
      /^MemTotal:/     { t = $2 }
      /^MemAvailable:/ { a = $2 }
      /^MemFree:/      { f = $2 }
      END { if (a == "") a = f; if (t > 0) printf "%d %d", t/1024, a/1024 }' /proc/meminfo)"
  fi
  if [ -n "$ram_total_mb" ] && [ -n "$ram_avail_mb" ] && (( ram_total_mb > 0 )); then
    # one awk emits BOTH the human "free" string and the used-% (was two awks)
    read -r ram_free ram_pct <<< "$(awk -v t="$ram_total_mb" -v a="$ram_avail_mb" \
      'BEGIN{printf "%.1fG %d", a/1024, (t-a)*100/t}')"
  fi
  # Disk-free barely moves and `df` on Windows enumerates every mounted volume —
  # memoize it for DISK_FREE_TTL so the vast majority of renders skip the df+awk
  # spawns entirely. (The Filesystem column can contain spaces — Git Bash reports
  # "C:/Program Files/Git" — which shifts $4 off Available onto Used, a silently
  # WRONG number. The trailing columns are always size used avail use% mountpoint,
  # so index avail from the END: NF=6 on Linux -> $(NF-2)==$4, NF=7 on Windows.)
  #
  # -P pins that POSIX six-column layout, which is what makes indexing from the
  # end safe: BSD df bolts three inode columns on by default, so on macOS a bare
  # `df` puts $(NF-2) on `ifree` and reported a plausible but entirely wrong
  # number. -k then gives 1K blocks everywhere; GNU's -BG is not portable.
  DISK_FREE_TTL=60
  _d_ts=""
  disk_cache="$sys_cache_dir/disk_free.cache"
  printf -v _now_s '%(%s)T' -1
  if [ -r "$disk_cache" ]; then
    read -r _d_ts disk_free < "$disk_cache"
    (( _now_s - ${_d_ts:-0} >= DISK_FREE_TTL )) && disk_free=""
  fi
  if [ -z "$disk_free" ]; then
    disk_free=$(df -Pk / 2>/dev/null | awk 'NR==2{printf "%.0fG", $(NF-2)/1048576}')
    [ -n "$disk_free" ] && { mkdir -p -m 700 "$SLB_CACHE_ROOT" "$sys_cache_dir" 2>/dev/null
      printf '%s %s\n' "$_now_s" "$disk_free" > "$disk_cache" 2>/dev/null; }
  fi
fi

if (( SLB_SHOW_CPU )); then
  # CPU core count never changes during a session, yet `nproc` is a ~70ms process
  # spawn on Windows — cache it so only the first render on a machine pays for it.
  cpu_cores=""
  nproc_cache="$sys_cache_dir/nproc.cache"
  [ -r "$nproc_cache" ] && read -r cpu_cores < "$nproc_cache"
  if ! [[ "$cpu_cores" =~ ^[0-9]+$ ]] || (( cpu_cores < 1 )); then
    # nproc is coreutils, so it is absent on macOS; hw.ncpu is the BSD spelling
    # and getconf is the POSIX one. Whichever answers first wins.
    cpu_cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)
    [[ "$cpu_cores" =~ ^[0-9]+$ ]] || cpu_cores=1
    mkdir -p -m 700 "$SLB_CACHE_ROOT" "$sys_cache_dir" 2>/dev/null && printf '%s\n' "$cpu_cores" > "$nproc_cache" 2>/dev/null
  fi
  # CPU % = 1-minute load average relative to core count (can exceed 100 when
  # overloaded; the bar itself clamps at 100 via to_int_pct). Read /proc/loadavg
  # AND compute the % in ONE awk (was `cut` + a second awk), emitting the raw
  # load too for the "· load N" suffix. Git Bash has no /proc/loadavg, so the CPU
  # bar is simply absent there.
  # Platform first, then the file test — same order as the RAM block above, and
  # it keeps the macOS path exercisable on a Linux box that does have /proc.
  if [ "$_SLB_OS" = macos ]; then
    # macOS has no /proc at all. `sysctl -n vm.loadavg` prints "{ 1.15 1.30 1.44 }";
    # stripping the braces re-splits $0, so $1 becomes the 1-minute figure.
    read -r cpu_load cpu_pct <<< "$(sysctl -n vm.loadavg 2>/dev/null |
      awk -v c="$cpu_cores" '{gsub(/[{}]/, ""); printf "%s %d", $1, $1*100/c; exit}')"
  elif [ -r /proc/loadavg ]; then
    read -r cpu_load cpu_pct <<< "$(awk -v c="$cpu_cores" '{printf "%s %d", $1, $1*100/c; exit}' /proc/loadavg)"
  fi
fi

# Join the parallel producers before consuming their outputs. Reading straight
# from the temp files below avoids a $()-subshell fork per consumer.
[ -n "$_par" ] && wait

# session_tokens — cached; bars section reuses these variables.
if [ -n "$_par" ] && [ -s "$_par/session" ]; then
  read -r sum_in sum_out sum_cache < "$_par/session"
else
  read -r sum_in sum_out sum_cache <<< "$(session_tokens "$transcript")"
fi

# Month-to-date cost/token stat (📅, Line 2) — see monthly_tokens() above.
month_fmt=""
if [ -n "$_par" ] && [ -s "$_par/monthcost" ]; then
  read -r month_dollars < "$_par/monthcost"
else
  month_dollars=$(monthly_cost "$session_id" "$cost")
fi
if (( SLB_SHOW_MONTHLY )); then
  if [ -n "$_par" ] && [ -s "$_par/monthly" ]; then
    read -r month_in month_out month_cr month_c5 month_c1 month_warming < "$_par/monthly"
  else
    read -r month_in month_out month_cr month_c5 month_c1 month_warming <<< "$(monthly_tokens)"
  fi
  # Cost and tokens come from independent sources now, so the segment shows if
  # EITHER has something. Gating on dollars alone would hide the token figure
  # for the whole of a freshly installed month, before any spend has accrued.
  month_tok_total=$(( month_in + month_out + month_cr + month_c5 + month_c1 ))
  if (( month_tok_total > 0 )) || awk -v d="${month_dollars:-0}" 'BEGIN{exit !(d>0)}' </dev/null; then
    month_cost_fmt=$(printf '%.2f' "${month_dollars:-0}")
    month_tok_h=$(humanize_tokens "$month_tok_total")
    month_warm_suffix=""; (( month_warming )) && month_warm_suffix="…"
    month_fmt="set"
  fi
fi

# ── Line 1: header — parts collected, then joined with " | " ──────
hp=()
if [[ "$model" == *[Oo]pus* ]]; then
  # Opus gets a dragon icon ✨ + a rainbow name 🌈
  hp+=("$(printf "${C_MODEL}✨ ${C_RESET}")$(rainbow "$model")")
elif [[ "$model" == *[Ss]onnet* ]]; then
  hp+=("$(printf "${C_MODEL_SONNET}⚡️ %s${C_RESET}" "$model")")
else
  hp+=("$(printf "${C_MODEL}☄️ %s${C_RESET}" "$model")")
fi
[ -n "$short_cwd" ] && hp+=("$(printf "${C_PATH}📁 %s${C_RESET}" "$short_cwd")")

# lines changed — session edit stats, appended straight onto the path entry
# (not a new hp[] item) so no " | " separator is inserted before it.
la=${lines_add:-0}; ld=${lines_del:-0}
if (( la > 0 || ld > 0 )); then
  last_idx=$(( ${#hp[@]} - 1 ))
  hp[$last_idx]+=" $(printf "${C_ADD}+%s${C_RESET} ${C_DEL}-%s${C_RESET}" "$la" "$ld")"
fi

# git branch/ahead/behind/dirty/last — produced in parallel by _git_stats (see
# the launch block above), consumed here; empty branch gates Line 3 off. Reading
# from the temp file skips a $()-fork; a synchronous call covers the no-parallel
# fallback. branch (+worktree) is emitted on its own Line 3 below, not here.
git_branch=""; git_ahead=0; git_behind=0; git_dirty=0; git_last=""
if (( SLB_SHOW_GIT )); then
  if [ -n "$_par" ] && [ -s "$_par/git" ]; then
    IFS='|' read -r git_branch git_ahead git_behind git_dirty git_last < "$_par/git"
  else
    IFS='|' read -r git_branch git_ahead git_behind git_dirty git_last <<< "$(_git_stats "$cwd")"
  fi
fi

# fast mode indicator
[ "$fast_mode" = "true" ] && hp+=("$(printf "${C_MODEL}🚀 fast${C_RESET}")")

# effort + thinking — 🧠 label, shown verbatim.
#
# This used to relabel "xhigh" as "Ultracode", which was wrong. Ultracode is a
# separate `/effort ultracode` option — "xhigh + dynamic workflow orchestration",
# session-only — so every xhigh session was mislabelled as one that fans out
# subagents. It cannot be shown correctly either: `effort.level` is documented as
# `low | medium | high | xhigh | max`, ultracode is not one of its values, and
# selecting it simply reports xhigh. Nothing in the payload distinguishes them,
# so print the level Claude Code actually reports and claim nothing more.
#
# xhigh/max still render the label (with the " (Thinking)" suffix) in the
# rainbow() gradient, icon stays plain C_EFRT — same style as the Opus model
# name. low/medium/high keep the plain C_EFRT rendering.
if [ -n "$effort" ]; then
  efrt_label="$effort"
  [ "$thinking" = "true" ] && efrt_label="$efrt_label (Thinking)"
  if [ "$effort" = "xhigh" ] || [ "$effort" = "max" ]; then
    hp+=("$(printf "${C_EFRT}🧠 ${C_RESET}")$(rainbow "$efrt_label")")
  else
    hp+=("$(printf "${C_EFRT}🧠 %s${C_RESET}" "$efrt_label")")
  fi
fi

# session-wide skill/agent/mcp/tool counts — see last_agent_skill() above.
# No longer shows the last-invoked name, just the four counts. Produced in
# parallel (see the launch block); temp-file read avoids a $()-fork, with a
# synchronous fallback when parallelization was skipped.
as_type="none"; skill_n=0; agent_n=0; mcp_n=0; tool_n=0
if (( SLB_SHOW_TOOL_COUNTS )); then
  if [ -n "$_par" ] && [ -s "$_par/agentskill" ]; then
    read -r as_type as_name skill_n agent_n mcp_n tool_n < "$_par/agentskill"
  else
    read -r as_type as_name skill_n agent_n mcp_n tool_n <<< "$(last_agent_skill "$transcript")"
  fi
fi
if [ "$as_type" != "none" ] || (( tool_n > 0 || mcp_n > 0 )); then
  hp+=("$(printf "${C_BAR}🧩 %s skills${C_RESET}" "$skill_n")")
  hp+=("$(printf "${C_BAR}🤖 %s agents${C_RESET}" "$agent_n")")
  hp+=("$(printf "${C_BAR}🔌 %s mcp${C_RESET}" "$mcp_n")")
  hp+=("$(printf "${C_BAR}🔧 %s tools${C_RESET}" "$tool_n")")
fi

# session cost — computed here, emitted on Line 2 (🌿 $0.42)
cost_fmt=""
if [ -n "$cost" ]; then
  cost_fmt=$(printf '%.2f' "$cost" 2>/dev/null || echo "$cost")
fi

# ── Line 3: git info — branch, ahead/behind, dirty, last commit ──
# Only built (and only printed) when $cwd is inside a git repo — no git repo
# means no Line 3 at all, not even a placeholder.
hp_git=()
if [ -n "$git_branch" ]; then
  if [ -n "$worktree" ]; then
    hp_git+=("$(printf "🌐 ${C_ADD}(worktree)${C_RESET} ${C_GIT}%s${C_RESET}" "$git_branch")")
  else
    hp_git+=("$(printf "${C_GIT}🌐 %s${C_RESET}" "$git_branch")")
  fi
  # #11 ahead/behind
  if (( git_ahead > 0 || git_behind > 0 )); then
    ab=""
    (( git_ahead  > 0 )) && ab="$(printf "${C_ADD}↑%d${C_RESET}" "$git_ahead")"
    if (( git_behind > 0 )); then
      ab="${ab:+$ab }$(printf "${C_DEL}↓%d${C_RESET}" "$git_behind")"
    fi
    hp_git+=("$ab")
  fi
  # #13 dirty files — yellow if dirty, dim if clean
  dirty_color="$C_DIM"; (( git_dirty > 0 )) && dirty_color="$C_YEL"
  hp_git+=("$(printf "${dirty_color}± %d files${C_RESET}" "${git_dirty:-0}")")
  # #14 last commit — absent in a repo with no commits yet, in which case the
  # segment is dropped rather than rendered as a bare "0".
  [ -n "$git_last" ] && hp_git+=("$(printf "${C_INFO}%s${C_RESET}" "$git_last")")
fi

[ -n "$vim_mode" ] && hp+=("$(printf "${C_VIM}[%s]${C_RESET}" "$vim_mode")")

# join parts with a dim pipe separator:  model | path | git | …
sep="$(printf "  ${C_DIM}|${C_RESET}  ")"
header="${hp[0]}"
for (( i = 1; i < ${#hp[@]}; i++ )); do header="${header}${sep}${hp[$i]}"; done

# session analytics (15,16,17) — uses sum_in/sum_out/sum_cache from early call
cost_per_turn=""
if [ -n "$cost" ] && (( turns > 0 )); then
  cost_per_turn=$(awk -v c="$cost" -v t="$turns" 'BEGIN{v=c/t; if(v>=0.01) printf "$%.3f",v; else printf "$%.4f",v}')
fi
cache_rate=""
total_for_cache=$(( ${sum_in:-0} + ${sum_cache:-0} ))
if (( total_for_cache > 0 && ${sum_cache:-0} > 0 )); then
  cache_rate=$(awk -v c="${sum_cache:-0}" -v t="$total_for_cache" 'BEGIN{printf "%d", c*100/t}')
fi
avg_tok=""
total_session_toks=$(( ${sum_in:-0} + ${sum_out:-0} ))
if (( turns > 0 && total_session_toks > 0 )); then
  avg_tok=$(humanize_tokens $(( total_session_toks / turns )))
fi

printf '%s\n' "$header"

# ── Line 2: combined stats ──────────────────────────────────────────
# order: total cost | month | turns | cost/turn | cache HR% | avg tok/turn
# 🌿/📅 lead the line in bold vivid colors (gold/orange) so the two cost
# figures stand out from the plain-white turn/cache/avg stats.
hp2=()
[ -n "$cost_fmt" ]      && hp2+=("$(printf "${C_COST_HL}🌿 \$%s${C_RESET}" "$cost_fmt")")
[ -n "$month_fmt" ]     && hp2+=("$(printf "${C_MONTH_HL}📅 ~\$%s/mo · %stok/mo%s${C_RESET}" "$month_cost_fmt" "$month_tok_h" "$month_warm_suffix")")
(( turns > 0 ))         && hp2+=("$(printf "${C_BAR}♻️ %d turns${C_RESET}" "$turns")")
[ -n "$cost_per_turn" ] && hp2+=("$(printf "${C_BAR}💲 %s/turn${C_RESET}" "$cost_per_turn")")
[ -n "$cache_rate" ]    && hp2+=("$(printf "${C_BAR}📀 cache HR %d%%${C_RESET}" "$cache_rate")")
[ -n "$avg_tok" ]       && hp2+=("$(printf "${C_BAR}📈 avg ~%s/turn${C_RESET}" "$avg_tok")")
if (( ${#hp2[@]} > 0 )); then
  header2="${hp2[0]}"
  for (( i = 1; i < ${#hp2[@]}; i++ )); do header2="${header2}${sep}${hp2[$i]}"; done
  printf '%s\n' "$header2"
fi

# ── Line 3: git info (branch / ahead-behind / dirty / last commit) ─
if (( ${#hp_git[@]} > 0 )); then
  header_git="${hp_git[0]}"
  for (( i = 1; i < ${#hp_git[@]}; i++ )); do header_git="${header_git}${sep}${hp_git[$i]}"; done
  printf '%s\n' "$header_git"
fi

# disk free space is tacked onto the RAM info suffix per user request.
ram_info="${ram_free} free"
[ -n "$disk_free" ] && ram_info="${ram_info}/disk ${disk_free} free"

# ── Line 4: the three usage bars, side by side on one line ─────────
# ctx info: current context tokens / max + cumulative session in/out
#   e.g.  124.1k/1M in:26.8k out:127.8k
ctx_tokens=""
if [ -n "$ctx_tok" ]; then
  if [ -n "$ctx_size" ]; then
    ctx_tokens="$(humanize_tokens "$ctx_tok")/$(humanize_tokens "$ctx_size")"
  else
    ctx_tokens="$(humanize_tokens "$ctx_tok")"
  fi
fi
# cumulative session totals — already set by early session_tokens call above
if (( ${sum_in:-0} > 0 || ${sum_out:-0} > 0 )); then
  io="in:$(humanize_tokens "$sum_in") out:$(humanize_tokens "$sum_out")"
  ctx_tokens="${ctx_tokens:+$ctx_tokens }$io"
fi
# cache write for current turn (cache_creation_input_tokens)
if [[ "$ctx_cache_write" =~ ^[0-9]+$ ]] && (( ctx_cache_write > 0 )); then
  ctx_tokens="${ctx_tokens:+$ctx_tokens }cw:$(humanize_tokens "$ctx_cache_write")"
fi
# Warn once context occupancy passes 50% of the window (e.g. 1M → 500k).
# Label shows the actual 50% threshold for the current window size.
ctx_warn=""
if [[ "$ctx_tok" =~ ^[0-9]+$ ]] && [[ "$ctx_size" =~ ^[0-9]+$ ]] && (( ctx_size > 0 )); then
  ctx_half=$(( ctx_size / 2 ))
  (( ctx_tok >= ctx_half )) && ctx_warn=" ⚠️ $(humanize_tokens "$ctx_half")+"
fi

emit_bar "ctx"  "$ctx_pct"       ""            "$ctx_tokens" "$ctx_warn"
printf '\n'
emit_bar "5h"   "${five_pct:-0}"  "$five_reset"
printf '\n'
emit_bar "week" "${week_pct:-0}"  "$week_reset"
printf '\n'

# ── RAM / CPU bars — same look as ctx/5h/week: colored circle + bar ─
# Ordered below the rate-limit bars, CPU above RAM (RAM sits at the very
# bottom) per user request.
[ -n "$cpu_pct" ] && { emit_bar "CPU" "$cpu_pct" "" "load ${cpu_load}" ""; printf '\n'; }
[ -n "$ram_pct" ] && { emit_bar "RAM" "$ram_pct" "" "$ram_info" ""; printf '\n'; }

# Trailing spacer below the week bar (Braille-blank so it isn't trimmed).
printf '⠀\n'
# Footer carries the session_id, which is a real identifier — SLB_SHOW_FOOTER=0
# drops the whole line for screen sharing or recording.
if (( SLB_SHOW_FOOTER )) && [ -n "$version" ] && [ "$version" != "null" ]; then
  ver_line="  ${C_VERLINE}Claude Code v${version}"
  (( SLB_CHECK_LATEST )) && is_latest_version "$version" &&
    ver_line="${ver_line} ${C_LTS}(LTS)${C_VERLINE}"
  [ -n "$session_id" ] && [ "$session_id" != "null" ] && ver_line="${ver_line}  ·  session_id: ${session_id}"
  printf "%b${C_RESET}\n" "$ver_line"
fi
# (parallel-producer scratch dir is removed by the EXIT trap set at creation)
