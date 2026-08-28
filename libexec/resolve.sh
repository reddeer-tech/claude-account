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

best_len=0; best_name=""; best_prefix=""; best_state=""; best_why=""
# TAB-separated so project paths may contain spaces ("Apps & Games").
# ⚠️ ONE ranking across every state. The LONGEST matching prefix decides, whatever its
# state; only then does its state say what happens (active → route; paused+global →
# pinned to the real global; paused → as if unrouted, so the fallback may apply).
# Tracking active and paused matches separately — as this file once did — let a shallow
# ACTIVE parent beat a deeper pause and even a deeper explicit pin, spending the parent
# profile while pause/switch/list all claimed "your GLOBAL account".
match_dir(){ # <absolute dir> — fills best_* with the longest match of ANY state
  local d="$1" prefix name state why _rest len
  best_len=0; best_name=""; best_prefix=""; best_state=""; best_why=""
  while IFS=$'\t' read -r prefix name state why _rest || [ -n "${prefix:-}" ]; do
    case "$prefix" in ''|\#*) continue ;; esac
    [ -z "$name" ] && continue
    case "$prefix" in "~"*) prefix="$HOME${prefix#\~}" ;; esac
    prefix="${prefix%/}"
    case "$d/" in
      "$prefix"/*) len=${#prefix}
        if [ "$len" -gt "$best_len" ]; then
          best_len=$len; best_name=$name; best_prefix=$prefix
          best_state="${state:-}"; best_why="${why:-}"
        fi ;;
    esac
  done < "$MAP"
}

# A symlinked cwd never string-matches a rule stored in physical spelling (and vice
# versa) — try the physical form as a second candidate before the worktree walk.
dirP=$(cd "$dir" 2>/dev/null && pwd -P) || dirP="$dir"
match_dir "$dir"
[ -z "$best_name" ] && [ "$dirP" != "$dir" ] && match_dir "$dirP"
via=""
if [ -z "$best_name" ]; then
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
  [ ! -f "${wt:-/}/.git" ] && [ "$dirP" != "$dir" ] && { wt="$dirP"; hops=0
    while [ -n "$wt" ] && [ "$wt" != "/" ] && [ "$hops" -lt 64 ]; do
      [ -e "$wt/.git" ] && break; wt="${wt%/*}"; hops=$((hops+1)); done; }
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

if [ -n "$best_name" ] && [ "$best_state" != "paused" ]; then
  printf '%s\t%s\t%s\n' "$best_name" "$PROFILES/$best_name" "$best_prefix$via"
  exit 0
fi
# The longest match is PAUSED (or nothing matched). `switch <x> global` is an explicit
# choice of the real global account, so it suppresses the fallback; a plain pause
# behaves as if unrouted.
[ "$best_state" = "paused" ] && [ "$best_why" = "global" ] && exit 0
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
