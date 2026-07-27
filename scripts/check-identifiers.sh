#!/usr/bin/env bash
# Pre-release gate: fail if anything that could identify the maintainer or their
# machine has reached the published files.
#
# The names are read from the environment at run time and are never written down
# here — a checker that lists the words it is looking for is itself the leak.
#
#   bash scripts/check-identifiers.sh        # silence means clean
#
# Machine-specific words that cannot be derived (internal project names, host
# aliases, client names) go one per line in .pii-words, which is gitignored.

set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

# Words the repository is legitimately allowed to contain: the public GitHub
# owner and repo name appear in URLs and cannot be avoided.
ALLOW_OWNER=$(git config --get remote.origin.url 2>/dev/null |
              sed -E 's#.*[:/]([^/]+)/([^/]+?)(\.git)?$#\1#')

patterns=()
add() {
  local w=${1:-}
  [ -n "$w" ] || return 0
  # The owner name is public by definition — it is in every clone URL, the
  # LICENSE and the SKILL.md author field. Searching for it only produces noise,
  # and a noisy gate is a gate people stop reading.
  [ -n "$ALLOW_OWNER" ] && [ "${w,,}" = "${ALLOW_OWNER,,}" ] && return 0
  patterns+=("$w")
}

# Account name, hostname and home directory, taken from this machine.
me=$(id -un 2>/dev/null || printf '%s' "${USER:-}")
add "$me"
add "$(hostname 2>/dev/null)"
add "$(hostname -s 2>/dev/null)"
[ -n "${HOME:-}" ] && add "$(basename "$HOME")"

# Git identity — the local part of the address, so a rewritten commit trailer or
# a pasted log line still trips the check.
for e in "$(git config --get user.email 2>/dev/null)" "$(git config --global --get user.email 2>/dev/null)"; do
  [ -n "$e" ] || continue
  add "$e"
  add "${e%%@*}"
done

# Optional private word list.
if [ -r .pii-words ]; then
  while IFS= read -r w; do
    w=${w%$'\r'}; w=${w#"${w%%[![:space:]]*}"}
    case "$w" in ''|'#'*) continue ;; esac
    add "$w"
  done < .pii-words
fi

# Generic shapes: real home paths, email addresses, IPv4 literals.
generic='(/home/[a-z0-9._-]+|/Users/[a-z0-9._-]+|/root/)|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'

# Documented placeholders that are not anybody's real data.
allow_line='C:/Users/John Doe|users\.noreply\.github\.com|example\.(com|org)'

status=0
report() { printf '%s\n' "$1"; status=1; }

files=$(git ls-files)

for p in "${patterns[@]}"; do
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    printf '%s' "$hit" | grep -qE "$allow_line" && continue
    report "  identifier: $hit"
  done < <(printf '%s\n' "$files" | xargs -r grep -nIiF -- "$p" 2>/dev/null)
done

# This file necessarily contains the shapes it searches for, so it is excluded
# from the shape scan. It is still covered by the identifier scan above, which
# derives its terms and cannot match a pattern definition.
self=${BASH_SOURCE[0]#./}
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  printf '%s' "$hit" | grep -qE "$allow_line" && continue
  report "  shape: $hit"
done < <(printf '%s\n' "$files" | grep -v -F -x "scripts/${self##*/}" |
         xargs -r grep -nIE -- "$generic" 2>/dev/null)

# Commit metadata is published too, and a real address in the author field is
# just as exposed as one in a file.
while IFS= read -r line; do
  printf '%s' "$line" | grep -qE 'users\.noreply\.github\.com' && continue
  report "  commit identity: $line"
done < <(git log --format='%h %ae %ce' 2>/dev/null | awk '{print $1" "$2" "$3}' |
         grep -vE ' noreply@anthropic\.com' | grep -E '@' | head -20)

if [ "$status" -eq 0 ]; then
  printf 'check-identifiers: clean\n'
else
  printf '\ncheck-identifiers: FAILED — the above must not be published.\n' >&2
fi
exit "$status"
