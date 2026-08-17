#!/usr/bin/env bash
# manage.sh — install, update and inspect statusline-beauty.
# https://github.com/veerapan-boo/claude-statusline-beauty  ·  MIT
#
#   manage.sh status [--json]      what is installed, what is available
#   manage.sh install [--force]    install/refresh and wire up settings.json
#   manage.sh update  [--force]    pull the latest released statusline.sh
#   manage.sh doctor               dependency + environment report
#   manage.sh uninstall [--purge]  restore the previous statusLine setting
#   manage.sh render-demo          render the status line from a fixture
#
# Exit codes: 0 ok · 1 error · 2 usage · 3 settings.json conflict (needs --force)

# ── Minimum bash, and the macOS re-exec ───────────────────────────
# Same shim as statusline.sh, and for the same reason: macOS's /bin/bash is 3.2,
# so on a stock Mac this script would refuse to install the very thing that
# would have worked once installed. Nothing above uses bash-4 syntax, so 3.2
# parses this far and we can hand the script to a newer interpreter. Arguments
# are forwarded; SLB_REEXEC stops a second pass from exec'ing again.
if [ -z "${BASH_VERSINFO[0]:-}" ] ||
   [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  if [ -z "${SLB_REEXEC:-}" ]; then
    for _b in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null)"; do
      [ -n "$_b" ] && [ -x "$_b" ] || continue
      if "$_b" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] ||
                   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }' 2>/dev/null; then
        export SLB_REEXEC=1
        exec "$_b" "$0" "$@"
      fi
    done
  fi
fi

set -uo pipefail

REPO_OWNER="veerapan-boo"
REPO_NAME="claude-statusline-beauty"
RAW_SCRIPT_PATH="skills/claude-statusline-beauty/scripts/statusline.sh"
API_BASE="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME"
RAW_BASE="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME"

# ── Locations ─────────────────────────────────────────────────────
# BASH_SOURCE resolved through symlinks: `npx skills add` installs a skill by
# symlinking its canonical checkout into the agent's skills directory, so the
# apparent path is often a link.
_self=${BASH_SOURCE[0]}
if readlink -f / >/dev/null 2>&1; then _self=$(readlink -f "$_self"); fi
SCRIPT_DIR=$(cd -- "$(dirname -- "$_self")" && pwd -P)

CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
DEST="$CONFIG_DIR/statusline-beauty"
SETTINGS="$CONFIG_DIR/settings.json"
INSTALLED_SCRIPT="$DEST/statusline.sh"
CONFIG_FILE="$DEST/config.sh"
MARKER="$DEST/.installed.json"
BACKUP_DIR="$DEST/backups"
BACKUP_KEEP=5

CACHE_DIR="${TMPDIR:-/tmp}/claude-statusline-beauty-${UID:-0}"
RELEASE_CACHE="$CACHE_DIR/release-check.cache"
RELEASE_TTL=21600   # 6h — the unauthenticated GitHub API allows 60 req/h per IP

# Minimal, network-free input for the post-download smoke render.
SMOKE_INPUT='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"cwd":"/tmp","context_window":{"used_percentage":42,"total_input_tokens":120000,"context_window_size":1000000},"rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":5}},"cost":{"total_cost_usd":0.42,"total_lines_added":10,"total_lines_removed":2},"version":"2.1.140","session_id":"smoke-test"}'

FORCE=0
JSON_OUT=0
DO_UPDATE_CHECK=1
PURGE=0

# ── Output helpers ────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[90m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; N=""; fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
err()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; }

# ── Small utilities ───────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

detect_platform() {
  case "$(uname -s 2>/dev/null)" in
    Linux*)               printf 'linux' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    Darwin*)              printf 'macos' ;;
    *)                    printf 'unknown' ;;
  esac
}
PLATFORM=$(detect_platform)

jq_hint() {
  case "$PLATFORM" in
    linux)   printf 'sudo apt install jq   (or: dnf install jq / pacman -S jq)' ;;
    windows) printf 'winget install jqlang.jq   (then open a NEW terminal — winget only updates the persistent PATH)' ;;
    macos)   printf 'brew install jq' ;;
    *)       printf 'install jq from https://jqlang.org/' ;;
  esac
}

# Escape a string for embedding in JSON. Used instead of jq so `status --json`
# still works on a machine that has not installed jq yet — which is exactly the
# machine most likely to need the report.
json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}
jstr() { if [ -z "${1-}" ]; then printf 'null'; else printf '"%s"' "$(json_escape "$1")"; fi; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown'; }
stamp()   { date -u +%Y%m%dT%H%M%SZ    2>/dev/null || printf '%s' "$$"; }

# A second-resolution timestamp is not unique: install --force followed by
# uninstall within the same second would silently overwrite the backup taken
# before the install — the one holding the user's original setting. Suffix on
# collision so no backup can ever clobber another.
unique_path() {
  local base=$1 n=2
  [ -e "$base" ] || { printf '%s' "$base"; return; }
  while [ -e "$base-$n" ]; do n=$((n + 1)); done
  printf '%s' "$base-$n"
}

sha256_of() {
  if   have sha256sum; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif have shasum;    then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  fi
}

# Version marker written into statusline.sh by the release process.
script_version() {
  [ -r "${1-}" ] || return 1
  local v
  v=$(grep -m1 -E '^# statusline-beauty-version:' "$1" 2>/dev/null |
      sed -E 's/^# statusline-beauty-version:[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# True when $1 is a strictly newer semver than $2. Non-numeric components are
# treated as 0, so a malformed tag can never masquerade as an upgrade.
version_gt() {
  local a=${1#v} b=${2#v}
  [ "$a" = "$b" ] && return 1
  local IFS=. ; local -a A=($a) B=($b) ; unset IFS
  local i x y
  for i in 0 1 2; do
    x=${A[i]:-0}; y=${B[i]:-0}
    x=${x%%[!0-9]*}; y=${y%%[!0-9]*}
    x=${x:-0};       y=${y:-0}
    if   (( 10#$x > 10#$y )); then return 0
    elif (( 10#$x < 10#$y )); then return 1
    fi
  done
  return 1
}

# ── HTTP ──────────────────────────────────────────────────────────
# Sets HTTP_STATUS and HTTP_BODY. Returns 1 when no transport is available or
# the request could not be made at all (offline, DNS failure, timeout).
HTTP_STATUS=""; HTTP_BODY=""
http_get() {
  local url=$1 out
  HTTP_STATUS=""; HTTP_BODY=""
  # Unauthenticated GitHub API calls are limited to 60/hour *per IP*, which a
  # shared office or VPN address burns through quickly. A token — if the user
  # already has one exported — raises that to 5000/hour. Never required.
  local -a auth=()
  local tok=${GH_TOKEN:-${GITHUB_TOKEN:-}}
  [ -n "$tok" ] && auth=(-H "Authorization: Bearer $tok")
  if have curl; then
    out=$(curl -sS -L --proto '=https' --proto-redir '=https' --max-time 20 \
               -H 'Accept: application/vnd.github+json' \
               -H 'User-Agent: statusline-beauty' \
               "${auth[@]}" \
               -w $'\n%{http_code}' "$url" 2>/dev/null) || return 1
    HTTP_STATUS=${out##*$'\n'}
    HTTP_BODY=${out%$'\n'*}
    [ -n "$HTTP_STATUS" ] || return 1
    return 0
  fi
  if have wget; then
    # wget gives no convenient status code; treat any success as 200 and any
    # failure as "unavailable" rather than guessing at 404 vs 403.
    HTTP_BODY=$(wget -qO- --timeout=20 --header='User-Agent: statusline-beauty' "$url" 2>/dev/null) || return 1
    HTTP_STATUS=200
    return 0
  fi
  return 1
}

# Pull one string field out of a JSON blob. Prefers jq; the grep fallback keeps
# the update check working before jq is installed.
json_field() {
  local body=$1 key=$2
  if have jq; then
    printf '%s' "$body" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null
  else
    printf '%s' "$body" |
      grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" |
      head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
  fi
}

# ── Release lookup ────────────────────────────────────────────────
# LATEST_SOURCE: release | main | ratelimited | unavailable
LATEST_VERSION=""; LATEST_REF=""; LATEST_SOURCE="unavailable"; LATEST_NOTE=""
resolve_latest() {
  local use_cache=${1:-1} now cached_ts rest
  printf -v now '%(%s)T' -1
  # Only a successful lookup is ever cached, and only a successful lookup is
  # honoured on read. Caching a 403 would freeze update checks for the whole TTL
  # over one transient rate limit.
  if [ "$use_cache" = 1 ] && [ -r "$RELEASE_CACHE" ]; then
    IFS='|' read -r cached_ts LATEST_VERSION LATEST_REF LATEST_SOURCE rest < "$RELEASE_CACHE"
    case "$LATEST_SOURCE" in
      release|main)
        if [ -n "$cached_ts" ] && (( now - cached_ts < RELEASE_TTL )); then
          LATEST_NOTE="cached"
          [ "$LATEST_SOURCE" = "main" ] && LATEST_NOTE="no GitHub release yet — tracking the main branch"
          return 0
        fi
        ;;
    esac
    LATEST_VERSION=""; LATEST_REF=""; LATEST_SOURCE="unavailable"
  fi

  if ! http_get "$API_BASE/releases/latest"; then
    LATEST_SOURCE="unavailable"; LATEST_NOTE="no network or no curl/wget"
    return 1
  fi

  case "$HTTP_STATUS" in
    200)
      LATEST_REF=$(json_field "$HTTP_BODY" tag_name)
      LATEST_VERSION=${LATEST_REF#v}
      if [ -n "$LATEST_REF" ]; then
        LATEST_SOURCE="release"
      else
        LATEST_SOURCE="unavailable"; LATEST_NOTE="release payload had no tag_name"
      fi
      ;;
    404)
      # No releases published yet — track the default branch by commit instead,
      # so the updater is useful from the very first push.
      if http_get "$API_BASE/commits/main" && [ "$HTTP_STATUS" = 200 ]; then
        local sha; sha=$(json_field "$HTTP_BODY" sha)
        if [ -n "$sha" ]; then
          LATEST_REF="$sha"; LATEST_VERSION="main@${sha:0:7}"; LATEST_SOURCE="main"
          LATEST_NOTE="no GitHub release yet — tracking the main branch"
        else
          LATEST_SOURCE="unavailable"; LATEST_NOTE="could not read main branch head"
        fi
      else
        LATEST_SOURCE="unavailable"; LATEST_NOTE="repository not reachable (HTTP ${HTTP_STATUS:-?})"
      fi
      ;;
    403|429)
      LATEST_SOURCE="ratelimited"
      LATEST_NOTE="GitHub API rate limit reached — try again later"
      ;;
    *)
      LATEST_SOURCE="unavailable"; LATEST_NOTE="GitHub API returned HTTP $HTTP_STATUS"
      ;;
  esac

  case "$LATEST_SOURCE" in
    release|main)
      mkdir -p -m 700 "$CACHE_DIR" 2>/dev/null &&
        printf '%s|%s|%s|%s|\n' "$now" "$LATEST_VERSION" "$LATEST_REF" "$LATEST_SOURCE" \
          > "$RELEASE_CACHE.tmp.$$" 2>/dev/null &&
        mv -f "$RELEASE_CACHE.tmp.$$" "$RELEASE_CACHE" 2>/dev/null
      ;;
  esac
  [ "$LATEST_SOURCE" = "unavailable" ] && return 1
  return 0
}

# ── Installed state ───────────────────────────────────────────────
INSTALLED_VERSION=""; INSTALLED_REF=""; INSTALLED_SOURCE=""
read_marker() {
  INSTALLED_VERSION=""; INSTALLED_REF=""; INSTALLED_SOURCE=""
  [ -r "$INSTALLED_SCRIPT" ] || return 1
  INSTALLED_VERSION=$(script_version "$INSTALLED_SCRIPT" || printf 'unknown')
  if [ -r "$MARKER" ] && have jq; then
    INSTALLED_REF=$(jq -r '.ref // ""' "$MARKER" 2>/dev/null)
    INSTALLED_SOURCE=$(jq -r '.source // ""' "$MARKER" 2>/dev/null)
  fi
  return 0
}

update_available() {
  case "$LATEST_SOURCE" in
    release) version_gt "$LATEST_VERSION" "${INSTALLED_VERSION:-0.0.0}" ;;
    main)    [ -n "$LATEST_REF" ] && [ "$LATEST_REF" != "$INSTALLED_REF" ] ;;
    *)       return 1 ;;
  esac
}

# ── Validation ────────────────────────────────────────────────────
smoke_test() {
  local out rc
  out=$(printf '%s' "$SMOKE_INPUT" |
        SLB_DEMO=1 SLB_CHECK_LATEST=0 SLB_SHOW_MONTHLY=0 SLB_SHOW_TOOL_COUNTS=0 bash "$1" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] && [ -n "$out" ]
}

# Everything a candidate statusline.sh must satisfy before it is allowed to
# replace a working one. A failure here keeps the current file in place.
validate_script() {
  local f=$1 first
  [ -s "$f" ]                              || { VALIDATE_ERR="file is empty"; return 1; }
  IFS= read -r first < "$f"
  case "$first" in '#!'*) ;; *) VALIDATE_ERR="missing shebang"; return 1 ;; esac
  grep -qE '^# statusline-beauty-version:' "$f" \
                                           || { VALIDATE_ERR="missing version marker"; return 1; }
  bash -n "$f" 2>/dev/null                 || { VALIDATE_ERR="bash syntax check failed"; return 1; }
  smoke_test "$f"                          || { VALIDATE_ERR="smoke render produced no output"; return 1; }
  return 0
}

# ── settings.json ─────────────────────────────────────────────────
desired_command() {
  if [ "$CONFIG_DIR" = "$HOME/.claude" ]; then
    # $HOME is expanded by the shell Claude Code runs the command in, and the
    # quotes keep it working when the home path contains spaces (C:/Users/John Doe).
    printf 'bash "$HOME/.claude/statusline-beauty/statusline.sh"'
  else
    printf 'bash "%s"' "$INSTALLED_SCRIPT"
  fi
}

settings_command() {
  [ -r "$SETTINGS" ] || return 1
  have jq || return 1
  jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null
}

SETTINGS_RESULT=""; SETTINGS_CONFLICT=""
wire_settings() {
  local cmd cur pad tmp prev backup created=0
  cmd=$(desired_command)
  have jq || { err "jq is required to edit settings.json — $(jq_hint)"; return 1; }

  if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    printf '{}\n' > "$SETTINGS" || { err "cannot create $SETTINGS"; return 1; }
    created=1   # nothing existed to preserve — skip the empty backup
  fi
  jq -e . "$SETTINGS" >/dev/null 2>&1 || { err "$SETTINGS is not valid JSON — fix it first"; return 1; }

  cur=$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null)
  if [ "$cur" = "$cmd" ]; then SETTINGS_RESULT="already"; return 0; fi
  if [ -n "$cur" ] && [ "$FORCE" != 1 ]; then
    SETTINGS_CONFLICT="$cur"; SETTINGS_RESULT="conflict"; return 3
  fi

  pad=$(jq -r '.statusLine.padding // 0' "$SETTINGS" 2>/dev/null)
  [[ "$pad" =~ ^[0-9]+$ ]] || pad=0
  prev=$(jq -c '.statusLine // null' "$SETTINGS" 2>/dev/null); prev=${prev:-null}

  backup=""
  if [ "$created" = 0 ]; then
    backup=$(unique_path "$SETTINGS.bak-statusline-beauty-$(stamp)")
    cp "$SETTINGS" "$backup" || { err "could not back up $SETTINGS"; return 1; }
  fi

  tmp="$SETTINGS.slb.tmp.$$"
  if jq --arg c "$cmd" --argjson p "$pad" \
        '.statusLine = {type:"command", command:$c, padding:$p}' "$SETTINGS" > "$tmp" 2>/dev/null &&
     jq -e . "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$SETTINGS" || { rm -f "$tmp"; err "could not replace $SETTINGS"; return 1; }
  else
    rm -f "$tmp"
    err "failed to rewrite $SETTINGS${backup:+ (backup kept at $backup)}"
    return 1
  fi

  PREV_STATUSLINE="$prev"
  SETTINGS_BACKUP="$backup"
  SETTINGS_RESULT="wired"
  return 0
}
PREV_STATUSLINE="null"; SETTINGS_BACKUP=""

write_marker() {
  local version=$1 ref=$2 source=$3 sha prev
  sha=$(sha256_of "$INSTALLED_SCRIPT")
  prev="$PREV_STATUSLINE"
  # Keep any previously recorded statusLine: only the FIRST install saw the
  # user's original setting, and that is the one uninstall must restore.
  if [ -r "$MARKER" ] && have jq; then
    local existing; existing=$(jq -c '.prev_statusline // null' "$MARKER" 2>/dev/null)
    [ -n "$existing" ] && [ "$existing" != "null" ] && prev="$existing"
  fi
  {
    printf '{\n'
    printf '  "version": %s,\n'       "$(jstr "$version")"
    printf '  "ref": %s,\n'           "$(jstr "$ref")"
    printf '  "source": %s,\n'        "$(jstr "$source")"
    printf '  "sha256": %s,\n'        "$(jstr "$sha")"
    printf '  "installed_at": %s,\n'  "$(jstr "$(now_utc)")"
    printf '  "prev_statusline": %s\n' "${prev:-null}"
    printf '}\n'
  } > "$MARKER.tmp.$$" && mv -f "$MARKER.tmp.$$" "$MARKER"
}

write_default_config() {
  [ -e "$CONFIG_FILE" ] && return 0
  cat > "$CONFIG_FILE" <<'CFG'
# statusline-beauty configuration
#
# This file is PARSED, not sourced: only `KEY=VALUE` lines using the keys below
# take effect, and nothing here is ever executed. Values may be 1/0, true/false,
# yes/no or on/off. An environment variable of the same name overrides the file.
#
# Restart is not needed — the next status line render picks up the change.

# Month-to-date cost estimate on line 2.
# By far the most expensive switch: it scans every transcript modified this
# month. Turn it off first if renders feel slow.
SLB_SHOW_MONTHLY=1

# Git line: branch, ahead/behind, dirty file count, last commit age.
SLB_SHOW_GIT=1

# Skills / agents / mcp / tools counters on line 1.
SLB_SHOW_TOOL_COUNTS=1

# CPU bar. Reads /proc/loadavg on Linux and `sysctl vm.loadavg` on macOS. Git
# Bash on Windows provides neither, so the bar is simply absent there.
SLB_SHOW_CPU=1

# RAM bar, with free disk space appended.
SLB_SHOW_RAM=1

# "(LTS)" tag next to the Claude Code version. Costs one background `npm view`
# call at most every 6 hours. Set to 0 to keep the status line fully offline.
SLB_CHECK_LATEST=1

# Footer line with the Claude Code version and session_id.
# The session_id is a real identifier — set this to 0 when screen sharing.
SLB_SHOW_FOOTER=1

# Width of the usage bars, in characters. Clamped to 10-60.
SLB_BAR_WIDTH=25

# Lite mode: gray text + purple model name, fewer segments, no footer.
# Use `manage.sh lite` / `manage.sh normal` to flip this rather than editing
# it by hand — see the "lite mode" section of the README.
SLB_LITE_MODE=0
CFG
}

# Rewrite a single KEY=VALUE line in config.sh in place, preserving every
# comment and every other key. awk over the file rather than `sed -i`: BSD and
# GNU sed take incompatible -i syntax, which is exactly the portability trap
# this repo works around everywhere else (see the GNU/BSD shims near the top
# of statusline.sh). Temp file + mv -f keeps a crash mid-write from truncating
# a config a concurrent render might be reading.
set_config_value() {
  local key=$1 value=$2
  [ -f "$CONFIG_FILE" ] || { err "not installed — run 'manage.sh install' first"; return 1; }
  awk -v k="$key" -v v="$value" '
    $0 ~ "^" k "=" { print k "=" v; done=1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp.$$" && mv -f "$CONFIG_FILE.tmp.$$" "$CONFIG_FILE"
}

cmd_lite() {
  set_config_value SLB_LITE_MODE 1 || return 1
  ok "lite mode enabled — takes effect on the next render"
  say "  ${D}back to normal any time: manage.sh normal${N}"
}

cmd_normal() {
  set_config_value SLB_LITE_MODE 0 || return 1
  ok "normal mode enabled — takes effect on the next render"
}

prune_backups() {
  [ -d "$BACKUP_DIR" ] || return 0
  local n; n=$(ls -1t "$BACKUP_DIR" 2>/dev/null | wc -l)
  (( n > BACKUP_KEEP )) || return 0
  ls -1t "$BACKUP_DIR" 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while IFS= read -r f; do
    rm -f "$BACKUP_DIR/$f" 2>/dev/null
  done
}

# Install a validated candidate over the current script, keeping a backup.
install_script_file() {
  local src=$1 label=$2
  mkdir -p "$DEST" "$BACKUP_DIR" 2>/dev/null || { err "cannot create $DEST"; return 1; }
  VALIDATE_ERR=""
  if ! validate_script "$src"; then
    err "refusing to install $label: $VALIDATE_ERR"
    return 1
  fi
  if [ -f "$INSTALLED_SCRIPT" ]; then
    cp "$INSTALLED_SCRIPT" \
       "$(unique_path "$BACKUP_DIR/statusline.sh.${INSTALLED_VERSION:-unknown}.$(stamp)")" 2>/dev/null
    prune_backups
  fi
  cp "$src" "$INSTALLED_SCRIPT.tmp.$$" && mv -f "$INSTALLED_SCRIPT.tmp.$$" "$INSTALLED_SCRIPT" || {
    rm -f "$INSTALLED_SCRIPT.tmp.$$"; err "could not write $INSTALLED_SCRIPT"; return 1; }
  chmod +x "$INSTALLED_SCRIPT" 2>/dev/null
  return 0
}

download_ref() {  # $1 = git ref -> prints temp file path
  local ref=$1 tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/slb-dl.XXXXXX" 2>/dev/null) || return 1
  if http_get "$RAW_BASE/$ref/$RAW_SCRIPT_PATH" && [ "$HTTP_STATUS" = 200 ] && [ -n "$HTTP_BODY" ]; then
    printf '%s\n' "$HTTP_BODY" > "$tmp"
    printf '%s' "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# ── Preflight ─────────────────────────────────────────────────────
WARNINGS=()
collect_warnings() {
  WARNINGS=()
  if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
     { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    local hint=""
    [ "$PLATFORM" = "macos" ] && hint=" — install one with: brew install bash"
    WARNINGS+=("bash ${BASH_VERSION:-?} is too old — statusline-beauty needs 4.2 or newer$hint")
  fi
  have jq   || WARNINGS+=("jq is not installed — the status line cannot render without it. $(jq_hint)")
  have git  || WARNINGS+=("git is not installed — the git line will be omitted")
  have curl || have wget || WARNINGS+=("neither curl nor wget found — update checks are disabled")
  if [ "$PLATFORM" = "windows" ]; then
    WARNINGS+=("Windows: Claude Code runs the status line through Git Bash, and falls back to PowerShell when Git Bash is absent — in which case a bash status line renders blank")
  fi
  # macOS carries no blanket warning any more: the status line re-execs itself
  # under a modern bash when it can find one, and every GNU-only command it used
  # has a BSD path. What is left is the one case nothing can paper over — a Mac
  # with no bash newer than the system 3.2 — and that is the bash warning above.
}

preflight() {
  local fatal=0
  if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
     { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    err "bash ${BASH_VERSION:-?} is too old — 4.2 or newer is required"; fatal=1
  fi
  if ! have jq; then
    err "jq is required. Install it with: $(jq_hint)"; fatal=1
  fi
  [ "$fatal" = 0 ]
}

# ── Commands ──────────────────────────────────────────────────────
cmd_status() {
  read_marker; local installed=$?
  resolve_latest 1 >/dev/null 2>&1
  collect_warnings

  local wired="false" cur upd="false"
  cur=$(settings_command) || cur=""
  [ "$cur" = "$(desired_command)" ] && wired="true"
  update_available && upd="true"

  if [ "$JSON_OUT" = 1 ]; then
    local conflict="null"
    [ -n "$cur" ] && [ "$wired" = "false" ] && conflict=$(jstr "$cur")
    printf '{\n'
    printf '  "installed": %s,\n'          "$([ $installed -eq 0 ] && printf true || printf false)"
    printf '  "installed_version": %s,\n'  "$(jstr "$INSTALLED_VERSION")"
    printf '  "installed_ref": %s,\n'      "$(jstr "$INSTALLED_REF")"
    printf '  "install_path": %s,\n'       "$(jstr "$INSTALLED_SCRIPT")"
    printf '  "config_dir": %s,\n'         "$(jstr "$CONFIG_DIR")"
    printf '  "config_file": %s,\n'        "$(jstr "$CONFIG_FILE")"
    printf '  "skill_dir": %s,\n'          "$(jstr "$SCRIPT_DIR")"
    printf '  "bundled_version": %s,\n'    "$(jstr "$(script_version "$SCRIPT_DIR/statusline.sh" 2>/dev/null || true)")"
    printf '  "latest_version": %s,\n'     "$(jstr "$LATEST_VERSION")"
    printf '  "latest_ref": %s,\n'         "$(jstr "$LATEST_REF")"
    printf '  "latest_source": %s,\n'      "$(jstr "$LATEST_SOURCE")"
    printf '  "latest_note": %s,\n'        "$(jstr "$LATEST_NOTE")"
    printf '  "update_available": %s,\n'   "$upd"
    printf '  "settings_path": %s,\n'      "$(jstr "$SETTINGS")"
    printf '  "settings_wired": %s,\n'     "$wired"
    printf '  "settings_conflict": %s,\n'  "$conflict"
    printf '  "platform": %s,\n'           "$(jstr "$PLATFORM")"
    printf '  "deps": {\n'
    printf '    "bash": %s,\n' "$(jstr "${BASH_VERSION%%(*}")"
    printf '    "jq": %s,\n'   "$(jstr "$(have jq   && jq --version 2>/dev/null)")"
    printf '    "git": %s,\n'  "$(jstr "$(have git  && git --version 2>/dev/null | awk '{print $3}')")"
    printf '    "curl": %s,\n' "$(jstr "$(have curl && curl --version 2>/dev/null | head -1 | awk '{print $2}')")"
    printf '    "npm": %s\n'   "$(jstr "$(have npm  && npm --version 2>/dev/null)")"
    printf '  },\n'
    printf '  "warnings": ['
    local i first=1
    for i in ${!WARNINGS[@]}; do
      [ "$first" = 1 ] && first=0 || printf ','
      printf '\n    %s' "$(jstr "${WARNINGS[$i]}")"
    done
    [ "$first" = 1 ] || printf '\n  '
    printf ']\n}\n'
    return 0
  fi

  say "${B}statusline-beauty${N}"
  if [ $installed -eq 0 ]; then
    ok "installed  ${INSTALLED_VERSION}  ($INSTALLED_SCRIPT)"
  else
    warn "not installed yet"
  fi
  case "$LATEST_SOURCE" in
    release) say "  ${D}latest release:${N} $LATEST_VERSION" ;;
    main)    say "  ${D}latest:${N} $LATEST_VERSION${LATEST_NOTE:+  ${D}($LATEST_NOTE)${N}}" ;;
    *)       say "  ${D}latest:${N} unknown${LATEST_NOTE:+  ${D}($LATEST_NOTE)${N}}" ;;
  esac
  [ "$upd" = "true" ] && warn "update available — run: manage.sh update"
  if [ "$wired" = "true" ]; then ok "settings.json is wired up"
  elif [ -n "$cur" ];      then warn "settings.json has a different status line: $cur"
  else                          warn "settings.json has no status line configured"
  fi
  local w; for w in "${WARNINGS[@]:-}"; do [ -n "$w" ] && warn "$w"; done
  return 0
}

cmd_install() {
  preflight || return 1
  read_marker || true

  local src="$SCRIPT_DIR/statusline.sh" label="bundled copy" cleanup="" dl bundled
  [ -r "$src" ] || { err "bundled statusline.sh not found next to manage.sh ($SCRIPT_DIR)"; return 1; }
  bundled=$(script_version "$src" || printf '0.0.0')

  # A fresh install should land on the newest available version, not on whatever
  # the skill checkout happens to carry.
  # When a published release is newer than the bundled copy, install that
  # instead. The `main` channel is deliberately NOT followed here: the bundled
  # copy came from this same repository, so a fresh install has nothing to gain,
  # and `update` is the explicit way to move onto an untagged main.
  if [ "$DO_UPDATE_CHECK" = 1 ] && resolve_latest 1; then
    local want=0
    [ "$LATEST_SOURCE" = "release" ] && version_gt "$LATEST_VERSION" "$bundled" && want=1
    if [ "$want" = 1 ] && dl=$(download_ref "$LATEST_REF"); then
      src="$dl"; label="release $LATEST_VERSION"; cleanup="$dl"
    fi
  fi

  install_script_file "$src" "$label" || { [ -n "$cleanup" ] && rm -f "$cleanup"; return 1; }
  [ -n "$cleanup" ] && rm -f "$cleanup"

  write_default_config

  local v; v=$(script_version "$INSTALLED_SCRIPT" || printf 'unknown')
  local ref="$v" source="bundled"
  if [ "$label" != "bundled copy" ]; then ref="$LATEST_REF"; source="$LATEST_SOURCE"; fi

  wire_settings; local rc=$?
  write_marker "$v" "$ref" "$source"

  if [ "$rc" = 3 ]; then
    say ""
    bad "settings.json already configures a different status line:"
    say "      ${B}$SETTINGS_CONFLICT${N}"
    say ""
    say "  The statusline script itself is installed at $INSTALLED_SCRIPT"
    say "  and nothing in settings.json has been changed."
    say "  To switch over (a timestamped backup is written first), run:"
    say "      ${B}manage.sh install --force${N}"
    return 3
  fi
  [ "$rc" = 0 ] || return 1

  ok "installed statusline-beauty $v ($label)"
  # No backup exists when settings.json did not exist before this install.
  [ "$SETTINGS_RESULT" = "wired" ] && ok "settings.json updated${SETTINGS_BACKUP:+  (backup: $SETTINGS_BACKUP)}"
  [ "$SETTINGS_RESULT" = "already" ] && ok "settings.json already pointed here"
  say "  ${D}config: $CONFIG_FILE${N}"
  say "  ${D}The status line appears on the next render; restart Claude Code if it does not.${N}"
  return 0
}

cmd_update() {
  preflight || return 1
  if ! read_marker; then
    err "not installed yet — run: manage.sh install"
    return 1
  fi
  local use_cache=1; [ "$FORCE" = 1 ] && use_cache=0
  if ! resolve_latest "$use_cache"; then
    warn "could not check for updates: ${LATEST_NOTE:-unknown reason}"
    say  "  Installed version $INSTALLED_VERSION left untouched."
    return 0
  fi
  if [ "$LATEST_SOURCE" = "ratelimited" ]; then
    warn "$LATEST_NOTE"
    return 0
  fi
  if ! update_available && [ "$FORCE" != 1 ]; then
    ok "already up to date ($INSTALLED_VERSION)"
    return 0
  fi

  if [ "$INSTALLED_VERSION" = "$LATEST_VERSION" ]; then
    say "  reinstalling $LATEST_VERSION (forced)"
  else
    say "  updating $INSTALLED_VERSION -> $LATEST_VERSION"
  fi
  local dl
  if ! dl=$(download_ref "$LATEST_REF"); then
    err "download failed for ref $LATEST_REF — keeping $INSTALLED_VERSION"
    return 1
  fi
  if ! install_script_file "$dl" "$LATEST_VERSION"; then
    rm -f "$dl"
    err "update aborted — $INSTALLED_VERSION is still installed and working"
    return 1
  fi
  rm -f "$dl"
  local v; v=$(script_version "$INSTALLED_SCRIPT" || printf 'unknown')
  write_marker "$v" "$LATEST_REF" "$LATEST_SOURCE"
  ok "updated to $v"
  say "  ${D}backup of the previous version is in $BACKUP_DIR${N}"
  return 0
}

cmd_doctor() {
  collect_warnings
  say "${B}statusline-beauty doctor${N}"
  say "  platform      : $PLATFORM"
  say "  bash          : ${BASH_VERSION:-unknown}"
  say "  config dir    : $CONFIG_DIR"
  say "  install path  : $INSTALLED_SCRIPT"
  say ""
  say "${B}dependencies${N}"
  have jq   && ok "jq   $(jq --version 2>/dev/null)"                       || bad "jq is missing — $(jq_hint)"
  have git  && ok "git  $(git --version 2>/dev/null | awk '{print $3}')"   || warn "git is missing — the git line will be omitted"
  have curl && ok "curl $(curl --version 2>/dev/null | head -1 | awk '{print $2}')" || \
    { have wget && ok "wget (curl not found)" || warn "no curl or wget — update checks disabled"; }
  have npm  && ok "npm  $(npm --version 2>/dev/null)"                      || warn "npm is missing — the (LTS) tag will not appear"
  say ""
  say "${B}system probes${N}"
  # Probe what each platform ACTUALLY uses. The old checks hard-coded the GNU
  # spelling, so a healthy Mac was reported as three failures.
  if [ "$PLATFORM" = "macos" ]; then
    sysctl -n vm.loadavg >/dev/null 2>&1 && ok "sysctl vm.loadavg  (CPU bar)" \
      || warn "sysctl vm.loadavg unavailable — CPU bar will not render"
    { sysctl -n hw.memsize >/dev/null 2>&1 && have vm_stat; } && ok "sysctl + vm_stat  (RAM bar)" \
      || warn "sysctl hw.memsize / vm_stat unavailable — RAM bar will not render"
    stat -f '%z' "$0" >/dev/null 2>&1 && ok "stat -f (BSD)" \
      || warn "stat -f unsupported — caching falls back to recomputation"
  else
    [ -r /proc/loadavg ] && ok "/proc/loadavg  (CPU bar)"  || warn "/proc/loadavg absent — CPU bar will not render (normal on Git Bash)"
    { have free || [ -r /proc/meminfo ]; } && ok "memory readable (RAM bar)" || warn "no free(1) and no /proc/meminfo — RAM bar will not render"
    stat -c '%s' "$0" >/dev/null 2>&1 && ok "stat -c (GNU)" || warn "stat -c unsupported — caching falls back to recomputation"
  fi
  df -Pk / >/dev/null 2>&1 && ok "df -Pk (disk free)" || warn "df -Pk unsupported — the disk-free suffix will be blank"
  # No date probe: reset times and session duration are computed in bash
  # arithmetic now, so there is no external date(1) dependency left to check.
  say ""
  say "${B}wiring${N}"
  local cur; cur=$(settings_command) || cur=""
  if [ "$cur" = "$(desired_command)" ]; then ok "settings.json points at statusline-beauty"
  elif [ -n "$cur" ];                   then warn "settings.json points elsewhere: $cur"
  else                                       warn "no statusLine configured in $SETTINGS"
  fi
  [ -r "$CONFIG_FILE" ] && ok "config: $CONFIG_FILE" || warn "no config file yet (created on install)"
  if [ ${#WARNINGS[@]} -gt 0 ]; then
    say ""
    say "${B}notes${N}"
    local w; for w in "${WARNINGS[@]}"; do warn "$w"; done
  fi
  return 0
}

cmd_uninstall() {
  if [ ! -r "$MARKER" ] && [ ! -r "$INSTALLED_SCRIPT" ]; then
    warn "nothing to uninstall"
    return 0
  fi
  have jq || { err "jq is required to restore settings.json — $(jq_hint)"; return 1; }

  local prev="null"
  [ -r "$MARKER" ] && prev=$(jq -c '.prev_statusline // null' "$MARKER" 2>/dev/null)
  prev=${prev:-null}

  if [ -f "$SETTINGS" ] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
    local backup tmp
    backup=$(unique_path "$SETTINGS.bak-statusline-beauty-$(stamp)")
    cp "$SETTINGS" "$backup" || { err "could not back up $SETTINGS"; return 1; }
    tmp="$SETTINGS.slb.tmp.$$"
    if [ "$prev" = "null" ]; then
      jq 'del(.statusLine)' "$SETTINGS" > "$tmp" 2>/dev/null
    else
      jq --argjson p "$prev" '.statusLine = $p' "$SETTINGS" > "$tmp" 2>/dev/null
    fi
    if jq -e . "$tmp" >/dev/null 2>&1; then
      mv -f "$tmp" "$SETTINGS"
      if [ "$prev" = "null" ]; then ok "removed statusLine from settings.json"
      else                          ok "restored the previous statusLine setting"
      fi
      say "  ${D}backup: $backup${N}"
    else
      rm -f "$tmp"; err "could not rewrite $SETTINGS"; return 1
    fi
  fi

  if [ "$PURGE" = 1 ]; then
    # cost/ is the month-to-date spend ledger. Unlike every other file here it
    # cannot be rebuilt — Claude Code reports that figure to the status line and
    # keeps no copy — so say what is being destroyed rather than just doing it.
    if [ -d "$DEST/cost" ]; then
      say "  ${D}this also deletes $DEST/cost — month-to-date spend, not recoverable${N}"
    fi
    rm -rf "$DEST" && ok "removed $DEST"
  else
    say "  ${D}$DEST kept (config.sh and the cost ledger) — pass --purge to delete it${N}"
  fi
  return 0
}

cmd_render_demo() {
  local target="$INSTALLED_SCRIPT"
  [ -r "$target" ] || target="$SCRIPT_DIR/statusline.sh"
  [ -r "$target" ] || { err "no statusline.sh to render"; return 1; }
  say "${D}rendering $target with a fixture (no network, no month scan)${N}"
  say ""
  printf '%s' "$SMOKE_INPUT" | SLB_DEMO=1 SLB_CHECK_LATEST=0 SLB_SHOW_MONTHLY=0 bash "$target"
  say ""
}

usage() {
  cat <<'USAGE'
manage.sh — install, update and inspect statusline-beauty.

  manage.sh status [--json]      what is installed, what is available
  manage.sh install [--force]    install/refresh and wire up settings.json
  manage.sh update  [--force]    pull the latest released statusline.sh
  manage.sh doctor               dependency + environment report
  manage.sh uninstall [--purge]  restore the previous statusLine setting
  manage.sh render-demo          render the status line from a fixture
  manage.sh lite                 switch to the minimal, low-color render
  manage.sh normal               switch back to the full render

  --force             overwrite a conflicting statusLine / bypass the check cache
  --no-update-check   install the bundled copy without contacting GitHub
  --purge             uninstall: also delete the install directory

Exit codes: 0 ok · 1 error · 2 usage · 3 settings.json conflict (needs --force)
USAGE
}

# ── Argument parsing ──────────────────────────────────────────────
CMD=""
while [ $# -gt 0 ]; do
  case "$1" in
    status|install|update|doctor|uninstall|render-demo|lite|normal) [ -z "$CMD" ] && CMD="$1" ;;
    --json)             JSON_OUT=1 ;;
    --force|-f)         FORCE=1 ;;
    --no-update-check)  DO_UPDATE_CHECK=0 ;;
    --purge)            PURGE=1 ;;
    -h|--help|help)     usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 2 ;;
  esac
  shift
done
[ -z "$CMD" ] && CMD="status"

case "$CMD" in
  status)      cmd_status ;;
  install)     cmd_install ;;
  update)      cmd_update ;;
  doctor)      cmd_doctor ;;
  uninstall)   cmd_uninstall ;;
  render-demo) cmd_render_demo ;;
  lite)        cmd_lite ;;
  normal)      cmd_normal ;;
  *)           usage; exit 2 ;;
esac
