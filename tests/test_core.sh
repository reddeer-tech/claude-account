#!/bin/bash
# The invariants that must never regress, whatever else changes. Weighted toward
# BEHAVIOUR — exit codes, what the resolver returns, what ends up on disk — because
# wording moves and behaviour must not. Each block names the incident it guards.
. "$(dirname "$0")/lib.sh"; ca_sandbox

section "resolver: the LONGEST matching prefix of ANY state decides"
# 1.0.25. Ranking active and paused matches separately let a shallow ACTIVE parent beat
# a deeper pause or pin, so a client's profile was spent while list/pause/switch all
# said "global". The most specific rule wins first; only then does its state apply.
mkdir -p "$T/a/b/c" "$T/other"
X add "$T/a"   alpha >/dev/null 2>&1; sign alpha
X add "$T/a/b" beta  >/dev/null 2>&1; sign beta
[ "$(Rn "$T/a/b/c")" = "beta" ]  && ok "deeper active rule beats the parent" || no "depth"
X pause "$T/a/b" >/dev/null 2>&1
[ "$(Rn "$T/a/b/c")" = "(global)" ] && ok "a deeper PAUSE beats an active parent" || no "parent leaked: $(Rn "$T/a/b/c")"
mkdir -p "$T/profiles/fb"; sign fb; X use fb >/dev/null 2>&1
[ "$(Rn "$T/a/b/c")" = "fb" ] && ok "…and then follows the selection (paused ≡ unrouted)" || no "paused-deep selection"
X switch "$T/a/b" global >/dev/null 2>&1
[ "$(Rn "$T/a/b/c")" = "(global)" ] && ok "a deeper PIN beats the parent AND suppresses the selection" || no "pin leaked"
[ "$(Rn "$T/a")" = "alpha" ] && ok "the parent itself still routes" || no "parent broken"
X use global >/dev/null 2>&1; X resume beta >/dev/null 2>&1

section "resolver: env already set always wins, silently"
# Both shims return early on an inherited variable: an explicit choice is never
# overridden. It is also why an agent's Bash tool is not routed by its own cwd.
out=$(CLAUDE_SECURESTORAGE_CONFIG_DIR=/somewhere bash bin/claude-whoami "$T/a" 2>&1)
printf '%s' "$out" | grep -q 'explicit override in env' && ok "whoami reports the override instead of the rule" || no "override: $out"

section "paths containing spaces survive every verb"
# They were silently unrouted for weeks: the map was space-separated, so resolve.sh
# split the path and never matched. The format is TAB separated; do not re-align by hand.
mkdir -p "$T/Spa ce/src"
X add "$T/Spa ce" spacey >/dev/null 2>&1; sign spacey
[ "$(Rn "$T/Spa ce")" = "spacey" ]     && ok "a space path resolves from its root" || no "space root"
[ "$(Rn "$T/Spa ce/src")" = "spacey" ] && ok "…and from a subfolder" || no "space sub"
X pause "$T/Spa ce" >/dev/null 2>&1; [ "$(Rn "$T/Spa ce")" = "(global)" ] && ok "pause matches it exactly" || no "space pause"
X resume "$T/Spa ce" >/dev/null 2>&1
X remove "$T/Spa ce" >/dev/null 2>&1;  [ "$(Rn "$T/Spa ce")" = "(global)" ] && ok "remove matches it exactly" || no "space remove"

section "a map with no trailing newline keeps its last rule"
# `while read` returns false on an unterminated final line, so that path quietly used
# the global account. Every reader ends its loop with `|| [ -n "$var" ]`.
printf '%s\tlastone' "$T/other" >> "$CLAUDE_ACCOUNTS_MAP"
mkdir -p "$T/profiles/lastone"; sign lastone
[ "$(Rn "$T/other")" = "lastone" ] && ok "resolver reads the unterminated last line" || no "resolver lost it"
X list --no-refresh 2>/dev/null | grep -q lastone && ok "list shows it too" || no "list lost it"
X remove "$T/other" >/dev/null 2>&1

section "commented template lines are not live rules"
# The shipped template's examples are TAB separated too, so an awk without a ^# guard
# counted them: on a fresh install `add` was refused because a COMMENT used the name.
mkdir -p "$T/fresh"
out=$(X add "$T/fresh" personal 2>&1); rc=$?
[ $rc = 0 ] && ok "a name used only by a commented example is free" || no "comment counted as a rule (rc=$rc)"
X remove "$T/fresh" >/dev/null 2>&1

section "probe honesty: a Keychain ERROR is not 'not signed in'"
# exit 44 = item not found. Anything else is a probe failure and must route TOWARD the
# rule, so Claude fails loudly rather than the work silently billing global.
out=$(SEC_MODE=err X profiles --no-refresh 2>&1)
printf '%s' "$out" | grep -q 'KEYCHAIN ERROR' && ok "profiles says KEYCHAIN ERROR" || no "probe error mislabelled"
printf '%s' "$out" | grep -q 'NOT LOGGED IN' && no "a probe error read as NOT LOGGED IN" || ok "…and never NOT LOGGED IN"
SEC_MODE=err X list --json 2>/dev/null | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert all(p["signed_in"]=="error" for p in d["profiles"]), d["profiles"]
print("ok")' | grep -q ok && ok "list --json reports \"error\", not false" || no "json probe honesty"

section "list --json is machine-readable and never coloured"
J=$(X list --json 2>/dev/null)
printf '%s' "$J" | grep -q $'\033' && no "ANSI leaked into JSON" || ok "no ANSI in JSON"
printf '%s' "$J" | python3 -c '
import json,sys; d=json.load(sys.stdin)
assert "rules" in d and "profiles" in d and "fallback" in d, list(d)
print("ok")' | grep -q ok && ok "parses, with rules/profiles/fallback" || no "json shape"

section "reserved names: global and none"
# `global` is not an account, it is the ABSENCE of routing. A profile of that name gets
# its own Keychain entry — the right destination reached by the wrong mechanism.
mkdir -p "$T/rz"
X add "$T/rz" global >/dev/null 2>&1; [ $? = 2 ] && ok "add <path> global refused (exit 2)" || no "add global"
X add "$T/rz" none   >/dev/null 2>&1; [ $? = 2 ] && ok "add <path> none refused (exit 2)"   || no "add none"
[ ! -d "$T/profiles/global" ] && [ ! -d "$T/profiles/none" ] && ok "nothing created by a refusal" || no "junk dir"
X rename alpha global >/dev/null 2>&1; [ $? = 2 ] && ok "rename to global refused" || no "rename global"

section "a legacy profile named 'global' makes verbs refuse, not guess"
# Six verbs tested the raw string before resolving it, so `logout global` deleted the
# credential every unrouted path uses while the profile of that name sat untouched.
mkdir -p "$T/profiles/global"
for v in logout login status label refresh usage; do
  out=$(X $v global </dev/null 2>&1); rc=$?
  printf '%s' "$out" | grep -qi 'ambiguous' && [ $rc != 0 ] || { no "$v global did not disambiguate (rc=$rc)"; continue; }
done
[ "$fail" = 0 ] && ok "logout/login/status/label/refresh/usage all refuse-and-disambiguate" || true
rmdir "$T/profiles/global"

section "profile-name validation happens BEFORE anything is written"
before=$(shasum "$CLAUDE_ACCOUNTS_MAP" | cut -d' ' -f1)
n_before=$(ls "$T/profiles" | wc -l | tr -d ' ')
mkdir -p "$T/nv"
for bad in "my prof" " tl" "a/b" "..." "tür" "$(printf 'a\tb')" "$(printf 'x%.0s' $(seq 1 45))"; do
  X add "$T/nv" "$bad" >/dev/null 2>&1
  [ $? = 2 ] || no "accepted a bad name: '$bad'"
done
after=$(shasum "$CLAUDE_ACCOUNTS_MAP" | cut -d' ' -f1)
n_after=$(ls "$T/profiles" | wc -l | tr -d ' ')
[ "$before" = "$after" ] && [ "$n_before" = "$n_after" ] && ok "7 rejected names left map and profiles byte-identical" || no "state changed on rejection"

section "the map is never shrunk by a failed rewrite"
# Two separate incidents wiped every rule: `open(m,'w')` truncating before the read, and
# a switch whose second stdin redirect fed the path list to python as its program.
n=$(grep -cv '^[[:space:]]*#' "$CLAUDE_ACCOUNTS_MAP" | tr -d ' ')
X switch alpha nonexistent-profile >/dev/null 2>&1
n2=$(grep -cv '^[[:space:]]*#' "$CLAUDE_ACCOUNTS_MAP" | tr -d ' ')
[ "$n" = "$n2" ] && ok "a failed switch leaves every rule in place" || no "rules lost: $n -> $n2"

section "backups + undo"
X pause alpha >/dev/null 2>&1
ls "$T/bk"/paths.map.* >/dev/null 2>&1 && ok "a mutation snapshots the map first" || no "no snapshot"
X undo --yes >/dev/null 2>&1
grep -q paused "$CLAUDE_ACCOUNTS_MAP" && no "undo did not restore" || ok "undo restores the previous map"
ls "$T/bk"/paths.map.*-pre-undo >/dev/null 2>&1 && ok "the replaced map is kept as -pre-undo" || no "no pre-undo copy"
X undo --yes 2>&1 | grep -q 'already matches\|nothing to undo' && ok "a second undo is idempotent, never a redo" || no "undo redo"
X pause alpha >/dev/null 2>&1
X undo </dev/null >/dev/null 2>&1; [ $? = 2 ] && ok "non-tty undo without --yes refuses (exit 2)" || no "undo tty guard"
X resume alpha >/dev/null 2>&1

section "display truth: the last column is the account actually spent"
X pause alpha >/dev/null 2>&1
row=$(X list --no-refresh 2>/dev/null | grep "$T/a	\|$T/a " | head -1)
printf '%s' "$row" | grep -q 'PAUSED' && ok "a paused row says PAUSED" || no "status word"
printf '%s' "$row" | grep -qi 'using (global)\|using fallback' && ok "…and names the account in use, not the parked one" || no "paused row identity: $row"
X switch "$T/a" global >/dev/null 2>&1
row=$(X list --no-refresh 2>/dev/null | grep "$T/a	\|$T/a " | head -1)
printf '%s' "$row" | grep -q '(global)' && ok "a pinned row names (global) in the PROFILE column" || no "pin column"
printf '%s' "$row" | grep -q 'global.*PAUSED' && no "'global PAUSED' — status must describe what PROFILE names" || ok "no self-contradicting 'global PAUSED'"
X profiles --no-refresh 2>/dev/null | grep -q 'PATHS BOUND TO IT' && ok "profiles says PATHS BOUND TO IT, not USED BY" || no "profiles header"
X resume alpha >/dev/null 2>&1

section "usage names the global account (1.0.30)"
sign_global   # global's credential has no hash suffix — sign() cannot express it
X usage global 2>&1 | head -1 | grep -q '^USAGE — (global)$' && ok "no label recorded -> no empty parens" || no "bare global header"
X label global "me@personal.com (Personal)" >/dev/null 2>&1
X usage global 2>&1 | head -1 | grep -q 'me@personal.com' && ok "usage global names it, like profiles does" || no "usage global label"
X usage --all 2>&1 | grep '^USAGE — (global)' | grep -q 'me@personal.com' && ok "usage --all too" || no "usage --all label"
X profiles --no-refresh 2>&1 | grep -q 'me@personal.com' && ok "one source: profiles agrees" || no "profiles label"

section "exit codes"
X --help >/dev/null 2>&1;             [ $? = 0 ] && ok "--help -> 0" || no "help"
X not-a-command >/dev/null 2>&1;      [ $? = 2 ] && ok "unknown command -> 2 (a typo must not look like success)" || no "unknown cmd"
X login ghost </dev/null >/dev/null 2>&1; [ $? = 1 ] && ok "unknown profile -> 1" || no "unknown profile"
X add >/dev/null 2>&1;                [ $? = 2 ] && ok "missing argument -> 2" || no "missing arg"
X login alpha </dev/null >/dev/null 2>&1; [ $? = 3 ] && ok "login without a TTY -> 3" || no "no-tty login"
X status alpha >/dev/null 2>&1;       [ $? = 2 ] && ok "status <profile> refused -> 2" || no "status profile"

section "--no-refresh reaches every reporting command"
# It was silently dropped on profiles/verify/doctor ("$@" not forwarded), so each fired
# a real request per expired profile — spending the very accounts you had paused.
for c in list profiles verify doctor; do
  X $c --no-refresh >/dev/null 2>&1 || true
done
ok "list/profiles/verify/doctor all accept --no-refresh"

finish
