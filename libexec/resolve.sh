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

best_len=0; best_name=""; best_prefix=""; p_len=0; p_why=""
# TAB-separated so project paths may contain spaces ("Apps & Games").
match_dir(){ # <absolute dir> — fills best_* (longest ACTIVE match) and p_* (longest PAUSED match)
  local d="$1" prefix name state why _rest len
  best_len=0; best_name=""; best_prefix=""; p_len=0; p_why=""
  while IFS=$'\t' read -r prefix name state why _rest || [ -n "${prefix:-}" ]; do
    case "$prefix" in ''|\#*) continue ;; esac
    [ -z "$name" ] && continue
    case "$prefix" in "~"*) prefix="$HOME${prefix#\~}" ;; esac
    prefix="${prefix%/}"
    case "$d/" in
      "$prefix"/*) len=${#prefix}
        # A third field of "paused" keeps the rule (and its login) but stops routing.
        # Its FOURTH field decides, below, whether the fallback applies ("" = plain
        # pause) or is suppressed ("global" = an explicit pin via `switch <x> global`).
        if [ "$state" = "paused" ]; then
          if [ "$len" -gt "$p_len" ]; then p_len=$len; p_why="${why:-}"; fi
        else
          if [ "$len" -gt "$best_len" ]; then best_len=$len; best_name=$name; best_prefix=$prefix; fi
        fi ;;
    esac
  done < "$MAP"
}

match_dir "$dir"
via=""
if [ -z "$best_name" ] && [ "$p_len" -eq 0 ]; then
  # NO rule of any kind covers this dir. It may be a LINKED GIT WORKTREE of a routed
  # repo (`git worktree add`, showrunner, …): the worktree lives outside every rule's
  # prefix, so without this step that work would silently bill the global account.
  # Walk up to the nearest .git; a FILE there marks a linked worktree and names the
  # main repo's gitdir — derive the main path and match ONCE more with it. Pin and
  # fallback semantics carry over because the same match_dir fills the same globals.
  wt="$dir"; hops=0
  while [ -n "$wt" ] && [ "$wt" != "/" ] && [ "$hops" -lt 64 ]; do
    [ -e "$wt/.git" ] && break
    wt="${wt%/*}"; hops=$((hops+1))
  done
  if [ -n "$wt" ] && [ "$wt" != "/" ] && [ -f "$wt/.git" ]; then
    g=""; IFS= read -r g < "$wt/.git" 2>/dev/null || true
    case "$g" in gitdir:*) g="${g#gitdir:}"; g="${g# }" ;; *) g="" ;; esac
    case "$g" in ""|/*) ;; *) g="$wt/$g" ;; esac         # relative gitdir → from the worktree
    case "$g" in
      */.git/worktrees/*)
        main="${g%/.git/worktrees/*}"
        main=$(cd "$main" 2>/dev/null && pwd) || main=""
        if [ -n "$main" ]; then
          match_dir "$main"
          [ -n "$best_name" ] && via=" (worktree)"
        fi ;;
    esac
  fi
fi

if [ -n "$best_name" ]; then
  printf '%s\t%s\t%s\n' "$best_name" "$PROFILES/$best_name" "$best_prefix$via"
  exit 0
fi
# `switch <x> global` is an explicit choice of the real global account, so it suppresses
# the fallback; a plain pause behaves as if unrouted.
[ "$p_len" -gt 0 ] && [ "$p_why" = "global" ] && exit 0
# Machine-wide fallback: one profile name in $PROFILES/.fallback. Regex-gated and NOT
# dir-checked — the Keychain entry is keyed on the dir PATH STRING and the shims
# mkdir -p it, so a hand-deleted dir must not silently revert the machine to the
# global account. Junk content means "unset" here; doctor is the loud surface for it.
fb=""
[ -f "$PROFILES/.fallback" ] && IFS= read -r fb < "$PROFILES/.fallback"
case "$fb" in
  global|none) exit 0 ;;
esac
[[ "$fb" =~ ^[a-z0-9][a-z0-9._-]{0,38}$ ]] || exit 0
printf '%s\t%s\t%s\n' "$fb" "$PROFILES/$fb" "(fallback)"
