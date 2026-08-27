#!/bin/bash
# Resolve which Claude account profile applies to a directory.
# Usage: resolve.sh [dir]   -> prints "<profile>\t<profile-dir>\t<matched-prefix>" or nothing.
# SINGLE source of routing truth — the shim, the VS Code wrapper and claude-whoami
# all call this, so they cannot drift (the gh shim/gh-whoami drift taught us that).
MAP="${CLAUDE_ACCOUNTS_MAP:-$HOME/.config/claude-accounts/paths.map}"
PROFILES="${CLAUDE_ACCOUNTS_DIR:-$HOME/.config/claude-accounts/profiles}"
dir=${1:-$PWD}
case "$dir" in /*) ;; *) dir=$(cd "$dir" 2>/dev/null && pwd) || exit 0 ;; esac
[ -f "$MAP" ] || exit 0
best_len=0; best_name=""; best_prefix=""
# TAB-separated so project paths may contain spaces ("Apps & Games").
while IFS=$'\t' read -r prefix name state _rest || [ -n "${prefix:-}" ]; do
  case "$prefix" in ''|\#*) continue ;; esac
  [ -z "$name" ] && continue
  # A third field of "paused" keeps the rule (and its login) but stops routing,
  # so the path falls back to the globally signed-in account.
  [ "$state" = "paused" ] && continue
  case "$prefix" in "~"*) prefix="$HOME${prefix#\~}" ;; esac
  prefix="${prefix%/}"
  case "$dir/" in
    "$prefix"/*) len=${#prefix}
      if [ "$len" -gt "$best_len" ]; then best_len=$len; best_name=$name; best_prefix=$prefix; fi ;;
  esac
done < "$MAP"
[ -z "$best_name" ] && exit 0
printf '%s\t%s\t%s\n' "$best_name" "$PROFILES/$best_name" "$best_prefix"
