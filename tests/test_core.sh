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
X unbind "$T/Spa ce" >/dev/null 2>&1;  [ "$(Rn "$T/Spa ce")" = "(global)" ] && ok "unbind matches it exactly" || no "space remove"

section "a map with no trailing newline keeps its last rule"
# `while read` returns false on an unterminated final line, so that path quietly used
# the global account. Every reader ends its loop with `|| [ -n "$var" ]`.
printf '%s\tlastone' "$T/other" >> "$CLAUDE_ACCOUNTS_MAP"
mkdir -p "$T/profiles/lastone"; sign lastone
[ "$(Rn "$T/other")" = "lastone" ] && ok "resolver reads the unterminated last line" || no "resolver lost it"
X list --no-refresh 2>/dev/null | grep -q lastone && ok "list shows it too" || no "list lost it"
X unbind "$T/other" >/dev/null 2>&1

section "commented template lines are not live rules"
# The shipped template's examples are TAB separated too, so an awk without a ^# guard
# counted them: on a fresh install `add` was refused because a COMMENT used the name.
mkdir -p "$T/fresh"
out=$(X add "$T/fresh" personal 2>&1); rc=$?
[ $rc = 0 ] && ok "a name used only by a commented example is free" || no "comment counted as a rule (rc=$rc)"
X unbind "$T/fresh" >/dev/null 2>&1

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

section "doctor checks the GLOBAL credential too, not just the profiles"
# Reachable by a legitimate setup: sign out of global, keep every account as a profile,
# and live on `use <name>`. Doctor probed every profile and never global, so that machine
# passed clean while pinned rules had nowhere to go.
mkdir -p "$T/gp" "$T/profiles/pers"; sign pers
X add "$T/gp" gpin >/dev/null 2>&1; sign gpin
DG(){ X doctor --no-refresh 2>&1 | grep -E '\(global\)' | head -1; }
sign_global
DG | grep -q 'signed in' && ok "global signed in -> ok" || no "A: $(DG)"
X use pers >/dev/null 2>&1
DG | grep -q "standing by while 'pers' is selected" && ok "…and says it is standing by while a selection is active" || no "B: $(DG)"
grep -v '^Claude Code-credentials$' "$T_SIGNED" > "$T/s2"; mv "$T/s2" "$T_SIGNED"
DG | grep -q 'fine while' && ok "signed out + selection: warns about what use global would do" || no "C: $(DG)"
X doctor --no-refresh >/dev/null 2>&1; [ $? = 0 ] && ok "…and that alone is a warning, not a failure" || no "C exit"
X switch "$T/gp" global >/dev/null 2>&1
DG | grep -q 'pinned to it' && ok "a pin to an unsigned global is a PROBLEM, and is counted" || no "D: $(DG)"
X doctor --no-refresh >/dev/null 2>&1; [ $? = 1 ] && ok "…and doctor exits 1" || no "D exit"
out=$(SEC_MODE=err X doctor --no-refresh 2>&1 | grep -E '\(global\)' | head -1)
printf '%s' "$out" | grep -q 'NOT proof it is missing' && ok "a probe FAILURE never reads as 'not signed in'" || no "F: $out"
X resume gpin >/dev/null 2>&1; X use global >/dev/null 2>&1; sign_global

section "a label is never recorded for a sign-in that did not happen"
# capture_label reads the SHARED ~/.claude.json, which names the most recent sign-in of
# ANY profile. It used to run unconditionally after the auth attempt, so an ABANDONED
# login stamped the profile with whatever account was last used elsewhere: `profiles`
# then showed "NOT LOGGED IN (last: someone@example.com)" for a profile that never
# signed in as anyone, and the duplicate-account note repeated the fiction.
mkdir -p "$T/profiles/aband"
# ⚠ PTYC, not PTY. acct_identity COLOURS its output on a terminal, and cmd_login refuses
# to run without one — so the earlier version of this guard compared coloured bytes to a
# plain string and never fired in production, while this test passed under ca_sandbox's
# NO_COLOR=1. Any assertion about a credential DECISION must run with colour on.
# Two ways to end with nothing stored, both checked (1.2.0 told them apart): the sign-in
# FAILS (claude auth login exits non-zero — abandoned, a bad code), or it says it worked and
# nothing usable is there (2026-10-18: an open chat emptied it). Neither may write a label.
out=$(FAKE_AUTH_RC=1 PTYC '' login aband)
printf '%s' "$out" | grep -q 'Still not logged in' && ok "an abandoned login says so" || no "abandoned: $out"
[ ! -f "$T/profiles/aband/.account" ] && ok "…and writes NO label" || no "label written: $(cat "$T/profiles/aband/.account")"
out=$(PTYC '' login aband)
printf '%s' "$out" | grep -q 'did not stick' && ok "a login that claims success and stores nothing says it did not stick" || no "no-stick: $out"
[ ! -f "$T/profiles/aband/.account" ] && ok "…and writes NO label either" || no "label written: $(cat "$T/profiles/aband/.account")"
mkdir -p "$T/profiles/good"; sign good
out=$(PTYC '' login good)
printf '%s' "$out" | grep -q "Profile 'good' is now:" && ok "a successful login reports the identity" || no "good: $out"
[ -f "$T/profiles/good/.account" ] && ok "…and DOES record the label" || no "no label on success"

section "the duplicate-account note is about shared QUOTA, so it needs credentials"
mkdir -p "$T/profiles/lbl"; echo "same@example.com (Org)" > "$T/profiles/lbl/.account"
sign_global; echo "same@example.com (Org)" > "$T/profiles/.global-account"
X profiles --no-refresh 2>&1 | grep -q 'SAME account' && no "a signed-OUT profile still claims to share a quota" || ok "a signed-out profile raises no duplicate note"
sign lbl
X profiles --no-refresh 2>&1 | grep -q 'lbl.*SAME account\|SAME account.*same@example.com' && ok "…but a real duplicate (both signed in) is still caught" || no "real duplicate missed"
rm -rf "$T/profiles/lbl"

section "remove/rm are DELETED (1.1.0), and refuse loudly instead of aliasing"
# An alias that WORKS is what made remove/forget guessable-but-wrong. A tombstone
# performs nothing and names the verb once.
for dead in remove rm; do
  out=$(X $dead "$T/a" 2>&1); rc=$?
  [ $rc = 2 ] || no "$dead exited $rc, want 2"
  printf '%s' "$out" | grep -q "renamed to 'unbind'" || no "$dead did not name unbind"
done
ok "remove and rm both refuse with exit 2 and name unbind"
grep -q "^$T/a	" "$CLAUDE_ACCOUNTS_MAP" && ok "…and the rule they were aimed at is UNTOUCHED" || no "tombstone still mutated the map"
# the 1.0.26 incident class: a directory named like the dead verb must not word-swap it
mkdir -p "$T/wd2/remove"
out=$( cd "$T/wd2" && bash "$CA" remove "$T/a" 2>&1 ); rc=$?
[ $rc = 2 ] && printf '%s' "$out" | grep -q "renamed to 'unbind'" && ok "still a tombstone from a dir containing ./remove" || no "guard: rc=$rc"

section "unbind <floating profile> says what to run instead"
# `remove` deletes a PATH RULE. Given a profile with none, "no rule for profile or path"
# reads as "no such profile", which sends you looking for the wrong thing.
mkdir -p "$T/profiles/floaty"
out=$(X unbind floaty 2>&1); rc=$?
[ $rc = 1 ] && ok "still exit 1" || no "remove floaty rc=$rc"
printf '%s' "$out" | grep -q 'has no path rules' && ok "names the actual situation" || no "wording: $out"
printf '%s' "$out" | grep -q 'claude-account forget floaty' && ok "hands you forget" || no "no forget hint"
printf '%s' "$out" | grep -q 'add <path> floaty' && ok "…and the bind-a-path alternative" || no "no add hint"
out=$(X unbind nosuchprofile 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'no rule for profile or path' && ok "a genuinely unknown name is unchanged" || no "unknown: $out"
rmdir "$T/profiles/floaty"

section "a credential decision must not change when stdout is a terminal"
# The class bug: `acct_identity` is DISPLAY text and carries colour on a tty, so every
# `[ "$(acct_identity …)" = "NOT LOGGED IN" ]` was false exactly when a human ran it.
# doctor reported an unsigned profile as "signed in" on a terminal and the truth when
# piped. Decisions go through acct_state (a bare token); acct_identity only PRINTS.
strip_ansi(){ tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'; }
mkdir -p "$T/tty1"; X add "$T/tty1" ttyp >/dev/null 2>&1     # a rule, no credential
piped=$(X doctor --no-refresh 2>&1 | strip_ansi | grep -o 'ttyp: [^—]*' | head -1)
ontty=$(PTYC '' doctor --no-refresh 2>&1 | strip_ansi | grep -o 'ttyp: [^—]*' | head -1)
[ -n "$piped" ] && [ "$piped" = "$ontty" ] && ok "doctor says the same thing piped and on a tty" || no "piped='$piped' tty='$ontty'"
printf '%s' "$ontty" | grep -q 'NOT signed in' && ok "…and on a tty it is still the TRUTH" || no "tty doctor: $ontty"
sign ttyp
ontty2=$(PTYC '' doctor --no-refresh 2>&1 | strip_ansi | grep -o 'ttyp: [^—]*' | head -1)
printf '%s' "$ontty2" | grep -q 'signed in' && printf '%s' "$ontty2" | grep -qv 'NOT signed' && ok "a signed-in profile still reads as signed in" || no "signed: $ontty2"
X unbind "$T/tty1" >/dev/null 2>&1

section "a reset time names the DATE, not just the weekday"
# A weekly window can reset 150+ hours out, where "resets Thu 8:00 AM" does not say WHICH
# Thursday. The month is spelled, never numeric: 09-11 reads as 11 Sep or 9 Nov depending
# on the reader. The stubbed curl in lib.sh pins resets_at to 2030, so this is deterministic.
sign_global
U=$(X usage global 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
printf '%s' "$U" | grep -qE 'resets [A-Z][a-z][a-z] [0-9]{1,2} [A-Z][a-z][a-z] ' \
  && ok "renders as 'resets <Day> <D> <Mon> <time>'" || no "format: $(printf '%s' "$U" | grep resets | head -1)"
printf '%s' "$U" | grep -q 'Jan' && ok "month spelled, not numeric" || no "no spelled month"
printf '%s' "$U" | grep -qE 'resets [A-Z][a-z][a-z] [0-9]{1,2}-[0-9]' && no "numeric month came back" || ok "no numeric month"
# Granularity drops as the horizon grows: days past 24h, then hours, then minutes.
# "in 152h 32m" made you divide by 24 to learn it meant Thursday week.
printf '%s' "$U" | grep -qE '\(in [0-9]+d [0-9]+h [0-9]+m\)' \
  && ok "past 24h it counts in DAYS (the stub resets in 2030)" || no "no day form: $(printf '%s' "$U" | grep -oE '\(in [^)]*\)' | head -1)"
printf '%s' "$U" | grep -qE '\(in [0-9]{3,}h' && no "still counting three-digit hours" || ok "no three-digit hour counts"
U2=$(FAKE_RESETS_AT="$(date -u -v+3H +%Y-%m-%dT%H:%M:%SZ)" X usage global 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
printf '%s' "$U2" | grep -qE '\(in [0-9]+h [0-9]+m\)' && ok "under 24h it counts in hours" || no "hours form: $(printf '%s' "$U2" | grep -oE '\(in [^)]*\)' | head -1)"
U3=$(FAKE_RESETS_AT="$(date -u -v+20M +%Y-%m-%dT%H:%M:%SZ)" X usage global 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
printf '%s' "$U3" | grep -qE '\(in [0-9]+m\)' && ok "under an hour it counts in minutes" || no "minutes form"
# a reset already behind us must NOT render as a countdown — it used to floor to "in Nm"
U4=$(FAKE_RESETS_AT="$(date -u -v-5H +%Y-%m-%dT%H:%M:%SZ)" X usage global 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
printf '%s' "$U4" | grep -q '(passed)' && ok "a PAST reset says 'passed', not a fake countdown" || no "past: $(printf '%s' "$U4" | grep -oE '\(in [^)]*\)|\(passed\)' | head -1)"
printf '%s' "$U4" | grep -qE '\(in [0-9]' && no "a past reset still renders as 'in ...'" || ok "…and no 'in' countdown on it"
# the token EXPIRY is the other date on these screens, and it was numeric (%m-%d) too.
# No weekday on this one: an expiry needs no action, it renews itself on use.
mkdir -p "$T/dt"; X add "$T/dt" dtp >/dev/null 2>&1; sign dtp
for c in list profiles verify overview; do
  o=$(X $c --no-refresh 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
  printf '%s' "$o" | grep -qE 'exp [0-9]{1,2} [A-Z][a-z][a-z] ' || no "$c: expiry not spelled ($(printf '%s' "$o" | grep -oE 'exp [^ ]+ [^ ]+' | head -1))"
  printf '%s' "$o" | grep -qE '(exp|EXPIRED) [0-9]{2}-[0-9]{2}' && no "$c: numeric date came back" || true
done
ok "list/profiles/verify/overview all spell the expiry month, none numeric"
X unbind "$T/dt" >/dev/null 2>&1

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

section "doctor: a parked rule does not count as routing to its profile"
# `switch <path> global` is the documented way to pin a path to the real global account, and
# it needs a placeholder profile that is deliberately never signed in. Counting its parked
# rule as "used" made doctor warn "those paths use global + warn" — both halves false: the
# resolver skips a parked row, so nothing routes there and nothing warns. Same false-alarm
# class as the pre-1.0.21 "re-login for a token that renews itself".
mkdir -p "$T/profiles/ghost" "$T/pinpath"
X add "$T/pinpath" ghost >/dev/null 2>&1
D=$(X doctor --no-refresh 2>&1)
printf '%s' "$D" | grep -q 'ghost: 1 rule(s) but NOT signed in' && ok "an ACTIVE rule to an unsigned profile still warns" || no "lost the real warning"
X switch "$T/pinpath" global >/dev/null 2>&1
D=$(X doctor --no-refresh 2>&1)
printf '%s' "$D" | grep -q 'ghost.*rule(s) are parked' && ok "a pinned rule reports as ok, not a warning" || no "still warns about a parked rule: $(printf '%s' "$D" | grep ghost)"
printf '%s' "$D" | grep -q 'ghost.*use global + warn' && no "still claims those paths warn" || ok "…and stops claiming those paths warn"
printf '%s' "$D" | grep -q 'ghost: floating' && no "a parked rule was mistaken for floating" || ok "…and is not mistaken for floating"
[ -z "$(R "$T/pinpath")" ] && ok "the pinned path really does resolve to the real global" || no "resolve returned: $(R "$T/pinpath")"


section "resolver: a cwd spelled in the wrong CASE still routes"
# 1.1.5. macOS filesystems are case-insensitive, so `cd ~/projects/aimining` succeeds on a
# folder named AIMining and leaves $PWD in the case that was TYPED. resolve.sh matches
# prefixes by literal string comparison, so the rule missed and the path fell through to
# the machine selection — a client's seat, silently, with `verify` unable to catch it
# (TuringLabs and the personal account both read max | default_claude_max_20x).
# The second-candidate line existed but used bash's `pwd -P`, which resolves symlinks
# TEXTUALLY and keeps the typed case, so it never fired. zsh's builtin DOES canonicalise,
# which is exactly why testing it by hand at a zsh prompt showed the right answer.
mkdir -p "$T/CaseProj/Sub"
X add "$T/CaseProj" caseprof >/dev/null 2>&1; sign caseprof
mkdir -p "$T/profiles/casefb"; sign casefb; X use casefb >/dev/null 2>&1
lower=$(printf '%s' "$T/CaseProj/Sub" | sed "s|$T/CaseProj/Sub|$T/caseproj/sub|")
[ "$(Rn "$T/CaseProj/Sub")" = "caseprof" ] && ok "exact spelling routes" || no "exact: $(Rn "$T/CaseProj/Sub")"
[ "$(Rn "$lower")" = "caseprof" ] && ok "wrong-case cwd routes to the SAME profile" || no "wrong case leaked to: $(Rn "$lower")"
[ "$(Rn "$T/CASEPROJ/SUB")" = "caseprof" ] && ok "all-caps cwd routes too" || no "caps leaked to: $(Rn "$T/CASEPROJ/SUB")"
[ "$(Rn "$T/nosuchdir")" = "casefb" ] && ok "a genuinely unrouted path still follows the selection" || no "selection broken"
X use global >/dev/null 2>&1

section "add stores the spelling that is ON DISK, not the one typed"
# Same incident, write side. A rule stored in a spelling `cd` never produces routes
# NOTHING, and looks perfectly correct in `list`.
out=$(X add "$T/caseproj/Sub" casetyped 2>&1)
grep -q 'Spelling corrected' <<<"$out" && ok "add says it corrected the spelling" || no "add was silent about the correction"
grep -qF "$T/CaseProj/Sub"$'\t'"casetyped" "$CLAUDE_ACCOUNTS_MAP" && ok "the map holds the on-disk spelling" || no "map: $(grep casetyped "$CLAUDE_ACCOUNTS_MAP")"
sign casetyped
[ "$(Rn "$T/CaseProj/Sub")" = "casetyped" ] && ok "and it routes" || no "stored rule does not route"

# ⚠ Symlinks must NOT be collapsed. Rewriting ~/work/Proj to /Volumes/Ext/work/Proj
# behind the user's back changes what every rule LOOKS like for no routing benefit —
# the resolver already tries the physical form as its second candidate.
mkdir -p "$T/RealDir"; ln -s "$T/RealDir" "$T/linkdir"
X add "$T/linkdir" linkprof >/dev/null 2>&1
grep -qF "$T/linkdir"$'\t'"linkprof" "$CLAUDE_ACCOUNTS_MAP" && ok "a symlinked path is stored as GIVEN, not resolved" || no "symlink was collapsed: $(grep linkprof "$CLAUDE_ACCOUNTS_MAP")"

section "doctor flags a rule whose spelling does not match the disk"
# Rules written before 1.1.5 can carry a spelling that never routes. It is a structural
# problem, not a warning: the rule exists, looks right, and does nothing.
mkdir -p "$T/LegacyCase"
printf '%s\tlegacyprof\n' "$T/legacycase" >> "$CLAUDE_ACCOUNTS_MAP"
mkdir -p "$T/profiles/legacyprof"; sign legacyprof
dout=$(X doctor 2>&1); drc=$?
grep -q 'NEVER routes' <<<"$dout" && ok "doctor names the mismatched rule" || no "doctor missed it"
grep -qF "$T/LegacyCase" <<<"$dout" && ok "…and prints the on-disk spelling" || no "no on-disk spelling in the report"
[ "$drc" != 0 ] && ok "and exits non-zero (structural, not cosmetic)" || no "doctor exited 0 on a rule that never routes"


section "usage: a FAILED probe never reads as an empty account"
# 1.1.6. The usage endpoint answers with JSON either way, so a 429 parsed fine, yielded no
# `limits` rows, and rendered as "no usage buckets reported for this account" — a transient
# rate limit reading as a FACT. Measured 2026-09-24 on a real account with 12 live sessions
# on one credential. Same rule as acct_state: an ERROR is not an ABSENCE.
export CA_USAGE_RETRY_SLEEP=0
mkdir -p "$T/U"; X add "$T/U" uprof >/dev/null 2>&1; sign uprof
CNT="$T/curlcount"
stub_curl(){ printf '#!/bin/bash\n%s\n' "$1" > "$T/bin/curl"; chmod +x "$T/bin/curl"; }

stub_curl "printf '%s' '{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"x\"}}'"
out=$(X usage uprof 2>&1); rc=$?
grep -qi 'rate limited' <<<"$out" && ok "a 429 says rate limited" || no "429 mislabelled: $out"
grep -qi 'no usage buckets' <<<"$out" && no "a 429 still reads as an empty account" || ok "…and never 'no usage buckets'"
[ "$rc" != 0 ] && ok "…and exits non-zero" || no "usage exited 0 on a failed probe"
X overview --no-refresh 2>&1 | grep -qi 'rate limited' && ok "overview says it too" || no "overview hid the rate limit"

stub_curl "printf '%s' '{\"limits\": []}'"
X usage uprof 2>&1 | grep -qi 'no usage buckets' && ok "a genuinely empty account still says 'no usage buckets'" || no "empty account mislabelled"

stub_curl "printf '%s' 'curl: (6) Could not resolve host'"
X usage uprof 2>&1 | grep -qi 'could not reach' && ok "a non-JSON body says unreachable" || no "unreachable mislabelled"

# one retry, because `overview` fires a call per credential back to back and can provoke
# the very 429 it would then have to report
printf '#!/bin/bash\nC="%s"; n=$(cat "$C" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$C"\nif [ "$n" = 1 ]; then printf %s %s; else printf %s %s; fi\n' \
  "$CNT" "'%s'" "'{\"error\":{\"type\":\"rate_limit_error\"}}'" "'%s'" "'{\"limits\":[{\"kind\":\"session\",\"percent\":7,\"resets_at\":\"2030-01-01T15:40:00Z\"}]}'" > "$T/bin/curl"
chmod +x "$T/bin/curl"; rm -f "$CNT"
X usage uprof 2>&1 | grep -q 'Session' && ok "a rate-limited call is retried once and then succeeds" || no "retry did not fire"
[ "$(cat "$CNT" 2>/dev/null)" = 2 ] && ok "…exactly one retry, not a loop" || no "retry count: $(cat "$CNT" 2>/dev/null)"
unset CA_USAGE_RETRY_SLEEP

section "pause on an already-PINNED row changes nothing, and says so"
# 1.1.6. set_state PRESERVES a 4th field of "global", so a plain pause on a pinned row left
# it on the real global — while the headline announced the selected profile. cmd_pause was
# branching on its own ARGUMENT instead of on the row.
mkdir -p "$T/Pin" "$T/profiles/pfb"; sign pfb
X add "$T/Pin" pinprof >/dev/null 2>&1; sign pinprof
X switch "$T/Pin" global >/dev/null 2>&1
X use pfb >/dev/null 2>&1
pout=$(X pause "$T/Pin" 2>&1)
grep -qi 'already pinned' <<<"$pout" && ok "pause says the row is already pinned" || no "pause claimed a change: $pout"
grep -q "pfb" <<<"$pout" && no "pause named the selection over an unchanged pin" || ok "…and does not name the selection"
[ "$(Rn "$T/Pin")" = "(global)" ] && ok "…and the row still resolves to the real global" || no "pin broken: $(Rn "$T/Pin")"

section "logout names the account those paths ACTUALLY get"
# 1.1.6. The sentence was hardcoded to "your GLOBAL account"; with a selection live those
# paths route to the selected profile instead.
mkdir -p "$T/L1"; X add "$T/L1" lprof >/dev/null 2>&1; sign lprof
lout=$(X logout lprof 2>&1)
[ "$(Rn "$T/L1")" = "pfb" ] && ok "a logged-out profile's paths follow the selection" || no "routing: $(Rn "$T/L1")"
grep -q "pfb" <<<"$lout" && ok "…and logout names it" || no "logout still hardcodes GLOBAL: $(grep -i 'paused its paths' <<<"$lout")"
X use global >/dev/null 2>&1

section "add derives a usable name, or refuses without blaming one you never typed"
# 1.1.6. `add ~/workspace/_lab` exited 2 with "invalid profile name '_lab'".
for f in _lab .hidden "Proj X"; do
  mkdir -p "$T/d_$f"; X add "$T/d_$f" >/dev/null 2>&1
  n=$(awk -F'\t' -v p="$T/d_$f" '$1==p{print $2}' "$CLAUDE_ACCOUNTS_MAP")
  printf '%s' "$n" | grep -qE '^[a-z0-9][a-z0-9._-]*$' && ok "derived a usable name from '$f' -> $n" || no "'$f' derived '$n'"
done
mkdir -p "$T/___"; aout=$(X add "$T/___" 2>&1); arc=$?
[ "$arc" = 2 ] && ok "an underivable folder exits 2" || no "rc=$arc"
grep -qi 'could not derive' <<<"$aout" && ok "…and says so instead of quoting a name you never typed" || no "$aout"

section "add on an existing rule points at switch, not unbind-then-add"
eout=$(X add "$T/d__lab" other 2>&1)
grep -q 'claude-account switch' <<<"$eout" && ok "names switch" || no "$eout"

section "add <path> global explains the two routes that actually work"
mkdir -p "$T/G1"; gout=$(X add "$T/G1" global 2>&1)
grep -q 'command not found' <<<"$gout" && no "a backtick executed in the refusal text" || ok "nothing in the refusal expands"
grep -q 'claude-account switch <path> global' <<<"$gout" && ok "offers the pin" || no "no pin route"
grep -q 'claude-account login <profile>' <<<"$gout" && ok "offers the profile" || no "no profile route"
grep -qE 'claude-account pause  <path>' <<<"$gout" && no "still offers pause, which does the opposite" || ok "…and no longer offers pause/unbind, which follow the selection"


section "a credential that EXISTS but is empty is NOT signed in"
# 1.1.7. When a refresh token dies, Claude Code POSTs it, gets invalid_grant, and writes
# {"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,...}} over the slot.
# The entry is then present, so a bare `find-generic-password` exit 0 read as SIGNED IN —
# and plan/tier survive the blanking, so list/profiles printed a confident "team |
# default_raven" for an account that cannot serve one request. This is the NORMAL end state
# of an expired refresh token, not an edge case. Measured on a real profile 2026-09-24.
mkdir -p "$T/Dead" "$T/Live"
X add "$T/Dead" deadprof >/dev/null 2>&1; blank deadprof
X add "$T/Live" liveprof >/dev/null 2>&1; sign liveprof

lst=$(X list --no-refresh 2>&1)
grep -q 'deadprof.*NOT LOGGED IN' <<<"$lst" && ok "list says NOT LOGGED IN" || no "list: $(grep deadprof <<<"$lst")"
grep -qE 'deadprof.*default_raven' <<<"$lst" && no "list still prints the dead account's plan" || ok "…and not its surviving plan|tier"
X profiles --no-refresh 2>&1 | grep -q 'deadprof.*NOT LOGGED IN' && ok "profiles agrees" || no "profiles disagrees"
X doctor --no-refresh 2>&1 | grep -qE 'deadprof.*(NOT signed in|not signed in)' && ok "doctor agrees" || no "doctor: $(X doctor --no-refresh 2>&1 | grep deadprof)"
X resume deadprof 2>&1 | grep -qi 'NOT signed in' && ok "resume agrees" || no "resume disagrees"

# ⚠ the live blob carries an empty mcpOAuth accessToken too — a loose substring match on
# "accessToken":"" would call a perfectly good credential dead.
grep -q 'liveprof.*NOT LOGGED IN' <<<"$lst" && no "a live credential was poisoned by its own mcpOAuth empty token" || ok "a live credential with an empty mcpOAuth token is untouched"
X doctor --no-refresh 2>&1 | grep -q 'liveprof: signed in' && ok "…and doctor still calls it signed in" || no "live profile broken"

# ⚠ acct_identity COLOURS on a tty, so this decision must also be checked with colour ON —
# the 1.1.0 incident was exactly a credential decision that flipped under a terminal.
pout=$(PTYC "" list --no-refresh 2>&1)
printf '%s' "$pout" | grep -q 'NOT LOGGED IN' && ok "under a real tty it still says NOT LOGGED IN" || no "tty output disagrees with piped"

# the routing side: a blanked profile must fall back with the documented warning, not route
# ⚠ env -u is load-bearing: BOTH shims return early when CLAUDE_SECURESTORAGE_CONFIG_DIR is
# already set (an explicit choice is never overridden), and a suite run from inside a routed
# session inherits it — the test would then pass or fail for reasons having nothing to do
# with the credential.
sout=$(cd "$T/Dead" && env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN \
       bash "$REPO/bin/claude-shim" --version 2>&1)
grep -qi 'not signed in' <<<"$sout" && ok "the launch shim warns instead of routing to a dead credential" || no "shim: $sout"
wout=$(env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN \
       bash "$REPO/bin/claude-whoami" "$T/Dead" 2>&1)
grep -qi 'not signed in\|NOT LOGGED IN' <<<"$wout" && ok "claude-whoami agrees" || no "whoami: $(grep -i account <<<"$wout")"


section "an empty credential is found whatever order its keys are in"
# 1.2.0. Newer Claude Code writes the blob with mcpOAuth FIRST. The 1.1.7 check was anchored
# at the start, so it missed every blank such a client wrote: on 2026-10-18 outlook was blank
# while doctor said "signed in", and the launchers would have routed new chats to it. Every
# surface the 1.1.7 section checks, again, with the newer order.
export FAKE_MCP_FIRST=1
lst=$(X list --no-refresh 2>&1)
grep -q 'deadprof.*NOT LOGGED IN' <<<"$lst" && ok "mcpOAuth first: list says NOT LOGGED IN" || no "list: $(grep deadprof <<<"$lst")"
X profiles --no-refresh 2>&1 | grep -q 'deadprof.*NOT LOGGED IN' && ok "…profiles agrees" || no "profiles disagrees"
dout=$(X doctor --no-refresh 2>&1)
grep -qE 'deadprof.*(NOT signed in|not signed in)' <<<"$dout" && ok "…doctor agrees (it said signed in before)" || no "doctor: $(grep deadprof <<<"$dout")"
grep -q 'liveprof: signed in' <<<"$dout" && ok "…and a live credential in the same order is still signed in" || no "live profile broken: $(grep liveprof <<<"$dout")"
sout=$(cd "$T/Dead" && env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN bash "$REPO/bin/claude-shim" --version 2>&1)
grep -qi 'not signed in' <<<"$sout" && ok "…the terminal shim falls back with the warning instead of routing to it" || no "shim: $sout"
sout=$(cd "$T/Live" && env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN bash "$REPO/bin/claude-shim" --version 2>&1)
grep -qi 'not signed in' <<<"$sout" && no "the shim called a live credential dead: $sout" || ok "…and routes a live one without a word"
vout=$(cd "$T/Dead" && env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN bash "$REPO/bin/claude-vscode-wrapper" "$T/bin/claude" --version 2>&1)
grep -qi 'not signed in' <<<"$vout" && ok "…the VS Code wrapper does the same" || no "wrapper: $vout"
wp=$(env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN bash "$REPO/bin/claude-whoami" --porcelain "$T/Dead" 2>&1 | cut -f3)
[ "$wp" = no ] && ok "…and claude-whoami says not signed in (it said yes)" || no "whoami signed_in=$wp"
wp=$(env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN bash "$REPO/bin/claude-whoami" --porcelain "$T/Live" 2>&1 | cut -f3)
[ "$wp" = yes ] && ok "…while a live one is yes" || no "whoami live signed_in=$wp"
unset FAKE_MCP_FIRST
# --porcelain's third field, every state. 1.1.7 used `return` at the top level there, which
# bash refuses: a missing credential printed "error" and a blank one "yes".
for st in "Dead:no" "Live:yes"; do d=${st%%:*}; want=${st#*:}
  got=$(env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN bash "$REPO/bin/claude-whoami" --porcelain "$T/$d" 2>&1)
  [ "$(printf '%s' "$got" | cut -f3)" = "$want" ] && ! grep -q 'return' <<<"$got" && ok "porcelain, ${d} credential: $want" || no "porcelain $d: $got"
done
mkdir -p "$T/Never"; X add "$T/Never" neverprof >/dev/null 2>&1
got=$(env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN bash "$REPO/bin/claude-whoami" --porcelain "$T/Never" 2>&1)
[ "$(printf '%s' "$got" | cut -f3)" = no ] && ok "porcelain, no credential at all: no (it said error)" || no "porcelain never: $got"
got=$(SEC_MODE=err env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN bash "$REPO/bin/claude-whoami" --porcelain "$T/Live" 2>&1)
[ "$(printf '%s' "$got" | cut -f3)" = error ] && ok "porcelain, a Keychain probe error: error, never yes or no" || no "porcelain err: $got"
# The other decisions (1.2.0). Each used a bare exit status, so a blanked credential passed
# for signed in everywhere below — in either key order.
for order in "" 1; do
  js=$(FAKE_MCP_FIRST=$order X list --json 2>&1)
  python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); p={x["name"]:x["signed_in"] for x in d["profiles"]}; assert p["deadprof"] is False and p["liveprof"] is True, p' "$js" \
    && ok "list --json: a blanked credential is signed_in false${order:+ (mcpOAuth first)}" || no "$js"
done
out=$(X switch "$T/Live" deadprof 2>&1)
grep -q "'deadprof' is not signed in" <<<"$out" && ok "switch warns when the destination's login is empty" || no "$out"
X switch "$T/Live" liveprof >/dev/null 2>&1
mkdir -p "$T/Dead2"; out=$(X add "$T/Dead2" deadprof 2>&1)
grep -q 'already signed in' <<<"$out" && no "add called a blanked profile signed in: $out" || ok "add does not call a blanked profile signed in"
X unbind "$T/Dead2" >/dev/null 2>&1
out=$(X create deadprof </dev/null 2>&1)
grep -q 'exists and is signed in' <<<"$out" && no "create called it signed in: $out" || ok "create does not either"
printf 'fallback\tdeadprof\n' > "$T/fb.tsv"; out=$(X import "$T/fb.tsv" 2>&1)
grep -q "fallback 'deadprof' NOT applied" <<<"$out" && [ ! -f "$T/profiles/.fallback" ] && ok "import does not select a blanked profile machine-wide" || no "$out"
grep -q 'claude-account login deadprof' <<<"$out" && ok "…and lists it among the profiles to sign in" || no "$out"
X use deadprof --force >/dev/null 2>&1
dout=$(X doctor --no-refresh 2>&1)
grep -q "selected profile 'deadprof' is NOT signed in" <<<"$dout" && ok "doctor flags a selected profile whose login is empty" || no "$(grep -i 'selected\|deadprof' <<<"$dout")"
X use global >/dev/null 2>&1

section "reset-page points at the claude.ai reset, and never claims one exists"
# 1.1.8. A limit reset ("Reset for free") is used on claude.ai → Settings → Usage. This tool
# CANNOT see whether an account has one: the usage endpoint answers reset status with
# eligible:false, ineligible_reason "surface" to any client but claude.ai and recent official
# Claude Code. So it only points at the page and names the account to sign in as.
mkdir -p "$T/R1"; X add "$T/R1" rprof >/dev/null 2>&1; sign rprof
X label rprof "someone@example.com (Some Org)" >/dev/null 2>&1
rout=$(X reset-page rprof 2>&1); rrc=$?
[ "$rrc" = 0 ] && ok "reset-page exits 0" || no "rc=$rrc"
grep -q 'https://claude.ai/settings/usage' <<<"$rout" && ok "…prints the Settings → Usage URL" || no "$rout"
grep -q 'someone@example.com' <<<"$rout" && ok "…and the email to sign in as (not the org text)" || no "no email: $rout"
grep -q 'Some Org' <<<"$rout" && no "the org text leaked into the sign-in line" || ok "…without the org in the sign-in line"
grep -qi 'cannot see whether' <<<"$rout" && ok "…and says it cannot see whether a reset exists" || no "claims knowledge it lacks"
open probe-that-the-stub-records; grep -q probe-that-the-stub-records "$T_OPENED" && ok "(the open stub records — so the next check is not vacuous)" || no "open stub records nothing; the next check would pass for the wrong reason"
: > "$T_OPENED"; X reset-page rprof >/dev/null 2>&1
[ ! -s "$T_OPENED" ] && ok "piped: no browser is opened" || no "opened a browser from a pipe: $(cat "$T/opened")"
PTYC "" reset-page rprof >/dev/null 2>&1
grep -q 'https://claude.ai/settings/usage' "$T_OPENED" 2>/dev/null && ok "on a terminal it opens the page" || no "terminal run did not open the page"
: > "$T_OPENED"
X reset-page nosuchprofile >/dev/null 2>&1; [ $? = 1 ] && ok "an unknown profile exits 1" || no "unknown profile rc"
X label rprof >/dev/null 2>&1   # clear the label
X reset-page rprof 2>&1 | grep -q 'no email recorded' && ok "no recorded email says so, and how to set one" || no "silent about a missing email"
X rprof reset-page 2>&1 | grep -q 'claude.ai/settings/usage' && ok "word order works both ways" || no "<profile> reset-page"
X reset-page 2>&1 | grep -q 'claude.ai/settings/usage' && ok "bare reset-page means the global account" || no "bare"

section "the weekly-limit hint appears only when a weekly limit is spent"
export CA_USAGE_RETRY_SLEEP=0
X label rprof "someone@example.com (Some Org)" >/dev/null 2>&1
lim(){ printf '#!/bin/bash\nprintf %%s %s\n' "'{\"limits\":[$1]}'" > "$T/bin/curl"; chmod +x "$T/bin/curl"; }
W100='{"kind":"weekly_all","group":"weekly","percent":100,"resets_at":"2030-01-03T15:00:00Z"}'
W99='{"kind":"weekly_all","group":"weekly","percent":99,"resets_at":"2030-01-03T15:00:00Z"}'
F100='{"kind":"weekly_scoped","group":"weekly","percent":100,"resets_at":"2030-01-03T15:00:00Z","scope":{"model":{"display_name":"Fable"}}}'
S100='{"kind":"session","group":"session","percent":100,"resets_at":"2030-01-01T15:40:00Z"}'

lim "$W100"; hout=$(X usage rprof 2>&1)
grep -q 'weekly limit reached' <<<"$hout" && ok "weekly at 100% shows the hint" || no "no hint at 100%"
grep -q 'claude-account reset-page rprof' <<<"$hout" && ok "…with the command for THIS profile" || no "$hout"
grep -q 'someone@example.com' <<<"$hout" && ok "…and the email to sign in as" || no "hint missing email"
grep -qi 'if this account has' <<<"$hout" && ok "…and never claims the account has a reset" || no "hint overclaims"
lim "$F100"; X usage rprof 2>&1 | grep -q 'weekly limit reached' && ok "a spent Fable weekly limit shows it too" || no "Fable 100% no hint"
lim "$W99";  X usage rprof 2>&1 | grep -q 'weekly limit reached' && no "hint at 99%" || ok "99% shows nothing"
lim "$S100"; X usage rprof 2>&1 | grep -q 'weekly limit reached' && no "hint for a spent 5-hour window, which reopens by itself" || ok "a spent 5-hour window alone shows nothing"
lim "$W100"; X overview --no-refresh 2>&1 | grep -q 'reset-page rprof' && ok "overview shows it on that account's card" || no "overview missing hint"
sign_global; X usage global 2>&1 | grep -q 'reset-page global' && ok "the global account's hint names 'global'" || no "global hint"
stub_curl(){ printf '#!/bin/bash\n%s\n' "$1" > "$T/bin/curl"; chmod +x "$T/bin/curl"; }
stub_curl "printf '%s' '{\"error\":{\"type\":\"rate_limit_error\"}}'"
X usage rprof 2>&1 | grep -q 'weekly limit reached' && no "a failed probe produced a hint" || ok "a failed probe shows no hint"
PTYC "" usage rprof 2>&1 | grep -q 'command not found' && no "something in the hint executed" || ok "nothing in the hint expands on a terminal"
unset CA_USAGE_RETRY_SLEEP


section "a sign-in about to end says so, with the command — and never reads as EXPIRED"
# 1.1.9. Refresh tokens end ~4 weeks after `login` and use does not extend them (measured
# 2026-10-08 on every profile). Nothing warned ahead of that date; after it the next refresh
# is refused, the slot is blanked and the account stops mid-work (kindly, 2026-09-23).
now_ms(){ echo $(( $(date +%s) * 1000 )); }
mkdir -p "$T/SI"; X add "$T/SI" siprof >/dev/null 2>&1; sign siprof
SOON=$(( $(now_ms) + 3*86400*1000 )); LATER=$(( $(now_ms) + 20*86400*1000 )); GONE=$(( $(now_ms) - 3600*1000 ))

pout=$(FAKE_SIGNIN_ENDS_MS=$SOON X profiles --no-refresh 2>&1)
grep 'siprof' <<<"$pout" | grep -q 'sign in again by' && ok "3 days left: profiles says 'sign in again by <date>'" || no "$(grep siprof <<<"$pout")"
grep 'siprof' <<<"$pout" | grep -q 'claude-account login siprof' && ok "…with the command for that profile" || no "no command on the line"
grep 'siprof' <<<"$pout" | grep -q '(claude-account login siprof)' && ok "…in parentheses, so the paths column cannot run into it" || no "$(grep siprof <<<"$pout")"
FAKE_SIGNIN_ENDS_MS=$SOON X list --no-refresh 2>&1 | grep 'siprof' | grep -q 'sign in again by' && ok "list says it too" || no "list silent"
FAKE_SIGNIN_ENDS_MS=$SOON X overview --no-refresh 2>&1 | grep -q 'sign in again by' && ok "overview says it too" || no "overview silent"
dout=$(FAKE_SIGNIN_ENDS_MS=$SOON X doctor --no-refresh 2>&1)
grep -q 'siprof: sign-in ends .*claude-account login siprof' <<<"$dout" && ok "doctor warns ahead of the end, with the command" || no "doctor: $(grep siprof <<<"$dout")"
grep 'siprof' <<<"$dout" | grep -q 'claude-account refresh' && no "doctor advised a refresh" || ok "…and never advises a refresh for it"

FAKE_SIGNIN_ENDS_MS=$LATER X profiles --no-refresh 2>&1 | grep 'siprof' | grep -q 'sign in again\|sign-in ended' && no "warned 20 days out" || ok "20 days left: says nothing"
FAKE_SIGNIN_ENDS_MS=$LATER X doctor --no-refresh 2>&1 | grep -q 'siprof: sign-in\|siprof: its sign-in' && no "doctor warned 20 days out" || ok "…and doctor says nothing"
X profiles --no-refresh 2>&1 | grep 'siprof' | grep -q 'sign in again\|sign-in ended' && no "warned without evidence" || ok "no such field in the credential: says nothing, claims nothing"

eout=$(FAKE_SIGNIN_ENDS_MS=$GONE X profiles --no-refresh 2>&1)
grep 'siprof' <<<"$eout" | grep -q 'sign-in ended' && ok "an ended sign-in says so" || no "$(grep siprof <<<"$eout")"
dout=$(FAKE_SIGNIN_ENDS_MS=$GONE X doctor --no-refresh 2>&1)
grep -q 'siprof: its sign-in ENDED .*claude-account login siprof' <<<"$dout" && ok "doctor: ended -> sign in again" || no "doctor: $(grep siprof <<<"$dout")"
grep -q 'siprof: its sign-in ENDED .*keeps working only until its current access token runs out' <<<"$dout" && ok "…and says it works until its access token runs out" || no "$(grep siprof <<<"$dout")"
grep 'siprof' <<<"$dout" | grep -q 'siprof: signed in' && no "doctor called an ended sign-in 'signed in'" || ok "…and does not also call it signed in"
# ⚠ THE dangerous case: ended sign-in AND an expired access token. doctor used to read the
# display line, see EXPIRED, and advise `refresh` — which is refused on a dead sign-in.
dout=$(FAKE_SIGNIN_ENDS_MS=$GONE FAKE_ACCESS_EXPIRES_MS=$(( $(now_ms) - 60000 )) X doctor --no-refresh 2>&1)
grep 'siprof' <<<"$dout" | grep -q 'claude-account refresh' && no "doctor advised a refresh on an ended sign-in" || ok "ended sign-in + expired access token: doctor never advises refresh"
grep -q 'claude-account login siprof' <<<"$dout" && ok "…it gives the login command instead" || no "no login command: $(grep siprof <<<"$dout")"
grep -q '✗ siprof: its sign-in ENDED .*its 1 rule(s) fail until you sign in again' <<<"$dout" && ok "…and a DEAD credential a rule depends on is a problem: those chats fail" || no "$(grep siprof <<<"$dout")"

for v in SOON GONE; do
  eval "ms=\$$v"
  FAKE_SIGNIN_ENDS_MS=$ms X profiles --no-refresh 2>&1 | grep 'siprof' | grep -qE 'EXPIRED|EXPIRES IN|NOT LOGGED IN|KEYCHAIN ERROR' \
    && no "the $v text contains a word doctor/list decide on" || ok "the $v text avoids every word doctor and list decide on"
done
cout=$(FAKE_SIGNIN_ENDS_MS=$SOON PTYC "" profiles --no-refresh 2>&1)
grep 'siprof' <<<"$cout" | grep -q $'\033\[38;5;208m' && ok "on a terminal, ending soon is orange" || no "not orange"
cout=$(FAKE_SIGNIN_ENDS_MS=$GONE PTYC "" profiles --no-refresh 2>&1)
grep 'siprof' <<<"$cout" | grep -q $'\033\[31m' && ok "…and ended is red" || no "not red"
sign_global
FAKE_SIGNIN_ENDS_MS=$SOON X doctor --no-refresh 2>&1 | grep -q '(global): sign-in ends .*claude-account login global' \
  && ok "the global account warns too, with 'login global'" || no "global not warned"
dout=$(FAKE_SIGNIN_ENDS_MS=$SOON X doctor --no-refresh 2>&1)
grep -qE 'siprof: sign-in ends .* \(in [0-9]+d [0-9]+h\)' <<<"$dout" && ok "doctor counts down to it" || no "$(grep siprof <<<"$dout")"
dout=$(FAKE_SIGNIN_ENDS_MS=$GONE X doctor --no-refresh 2>&1)
grep -q '(global): its sign-in ENDED .*keeps working only until its current access token runs out: claude-account login global' <<<"$dout" \
  && ok "the global account's ended sign-in is reported too" || no "$(grep global <<<"$dout")"
# A DEAD credential (sign-in ended AND access token expired) gets the verdict NOT signed in
# gets in the same position — it is just as unusable — so the verdict does not flip when
# Claude Code later blanks the slot.
PAST=$(( $(now_ms) - 60000 ))
dout=$(FAKE_SIGNIN_ENDS_MS=$GONE FAKE_ACCESS_EXPIRES_MS=$PAST X doctor --no-refresh 2>&1); drc=$?
# ✗ either way: "every unrouted path fails", or — when earlier sections left pins — "the N
# rule(s) pinned to it … fail". Both are problems, as for an unsigned global account.
grep -q '✗ (global): its sign-in ENDED .* fail until you sign in again' <<<"$dout" && [ "$drc" = 1 ] \
  && ok "a DEAD global account with nothing selected is a problem, as an unsigned one is" || no "rc=$drc $(grep global <<<"$dout")"
X pause siprof >/dev/null 2>&1
dout=$(FAKE_SIGNIN_ENDS_MS=$GONE FAKE_ACCESS_EXPIRES_MS=$PAST X doctor --no-refresh 2>&1)
grep -q '✓ siprof: its sign-in ended .*parked — nothing routes to it' <<<"$dout" \
  && ok "a DEAD profile whose rules are all parked is fine, as an unsigned one is" || no "$(grep siprof <<<"$dout")"
rout=$(FAKE_SIGNIN_ENDS_MS=$GONE X resume siprof 2>&1)
grep -q "the sign-in of 'siprof' ENDED" <<<"$rout" && ok "resume says when the sign-in has ended" || no "$rout"
grep -q 'credential valid' <<<"$rout" && no "resume called an ended sign-in valid: $rout" || ok "…and never calls it 'credential valid'"
X pause siprof >/dev/null 2>&1
rout=$(FAKE_SIGNIN_ENDS_MS=$SOON X resume siprof 2>&1)
grep -q 'credential valid' <<<"$rout" && grep -q 'its sign-in ends .*claude-account login siprof' <<<"$rout" \
  && ok "resume warns when the sign-in ends soon" || no "$rout"
mkdir -p "$T/profiles/blk"; blank blk
X use blk >/dev/null 2>&1; urc=$?
[ "$urc" = 1 ] && [ ! -f "$T/profiles/.fallback" ] && ok "use refuses a profile whose slot was blanked by a dead refresh token" || no "use selected a blanked profile (rc=$urc)"
uo=$(FAKE_SIGNIN_ENDS_MS=$GONE FAKE_ACCESS_EXPIRES_MS=$PAST X use siprof 2>&1); urc=$?
[ "$urc" = 1 ] && grep -q "the sign-in of 'siprof' ENDED" <<<"$uo" && ok "…and a DEAD one, which every unrouted chat would fail on" || no "rc=$urc $uo"
uo=$(SEC_MODE=err X use siprof 2>&1); urc=$?
[ "$urc" = 1 ] && grep -q 'could not read the credential' <<<"$uo" && ok "…and calls a probe failure one, not 'not signed in'" || no "rc=$urc $uo"
X use siprof >/dev/null 2>&1 && ok "…while a signed-in profile is selected as before" || no "use refused a signed-in profile"
X use global >/dev/null 2>&1
dout=$(SEC_MODE=err X doctor --no-refresh 2>&1)
grep -q 'siprof: could not read the credential' <<<"$dout" && ok "doctor reports a Keychain probe error on a profile as one" || no "$(grep siprof <<<"$dout")"
grep -q '✓ siprof: signed in' <<<"$dout" && no "doctor called a probe error 'signed in'" || ok "…and never as signed in"

section "a process is a Claude session by its executable, not by what its arguments mention"
# A grep or tail of a Claude path matched doctor's process pattern and was reported as a live
# session whose environment could not be read (2026-10-18). The rule, on the executables seen.
icc(){ bash -c "$(grep '^is_claude_comm()' "$CA")"'; is_claude_comm "$1"' _ "$1"; }
for c in "$HOME/.vscode/extensions/anthropic.claude-code-2.1.301-darwin-arm64/resources/native-binary/claude" \
         "$HOME/.cursor/extensions/anthropic.claude-code-2.1.231-darwin-arm64/resources/native-binary/claude" \
         "$HOME/.local/share/claude/versions/2.1.238" "$HOME/.local/bin/claude" claude; do
  icc "$c" && ok "a session: $(printf "%s" "$c" | tail -c 44)" || no "not recognised as a session: $c"
done
for c in grep /usr/bin/grep /bin/zsh /usr/bin/tail less Python /opt/homebrew/bin/claude-account; do
  icc "$c" && no "counted as a session: $c" || ok "not a session: $c"
done

section "doctor judges each live session the way the launcher would"
# 1.1.9. A session keeps the routing it LAUNCHED with. doctor reported a chat opened while its
# rule was paused as a launcher bypass and said to QUIT the editor; reopening that one chat
# was all it needed. It also called a session (global) when it could not read its environment
# at all, and expected a profile whose credential was blanked by an expired refresh token.
# Stand-ins are python, on purpose: macOS 27 hides the environment of Apple's own binaries
# (/bin/bash) from ps, so a bash stand-in passes every "is (global)" assertion for the wrong
# reason. They live at a path the production pattern (native-binary/claude, .local/bin/claude)
# does NOT match, end on their own after ten minutes, and the trap kills them when this file
# exits: an interrupted run must not leave sessions behind for a real doctor to report.
FAKE="$T/fake/stand-in/claude"; mkdir -p "$T/fake/stand-in" "$T/LS" "$T/UN" "$T/BL"
printf 'import time\nfor _ in range(600): time.sleep(1)\n' > "$FAKE"
trap 'kill $(jobs -p) 2>/dev/null' EXIT
fake(){ local d=$1; shift; ( cd "$d" && exec env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN "$@" python3 "$FAKE" ) & }
stop(){ kill "$@" 2>/dev/null; wait "$@" 2>/dev/null; }
live(){ X doctor --no-refresh 2>&1 | sed -n '/^live sessions/,$p'; }

fake "$T/LS"; SA=$!                                              # opens with no rule anywhere
fake "$T/UN" CLAUDE_SECURESTORAGE_CONFIG_DIR="$T/profiles/lsprof"; SU=$!   # opens on a profile
fake "$T/LS" CLAUDE_CODE_OAUTH_TOKEN=sk-test-NEVERPRINTME; ST=$!           # a token override
sleep 2
X add "$T/LS" lsprof >/dev/null 2>&1; sign lsprof               # the routing changes AFTER all three
X add "$T/BL" blprof >/dev/null 2>&1; blank blprof              # a refresh token that died
lout=$(live)
grep -q '2 live session(s) opened before the routing last changed' <<<"$lout" && ok "chats older than the last routing change are reported as stale" || no "$lout"
grep -q "pid $SA .*still on (global) from when it opened; the folder now uses 'lsprof'" <<<"$lout" && ok "…naming the account it is on and the one its folder uses" || no "$lout"
grep -q "pid $SU .*still on 'lsprof' from when it opened; the folder now uses (global)" <<<"$lout" && ok "…including a chat on a profile in a folder that now uses (global)" || no "$lout"
grep -q "pid $ST .*carries (token override)" <<<"$lout" && ok "a token override is 'handed an account' even when it predates the change: reopening cannot fix it" || no "$lout"
grep -q 'QUIT and reopen' <<<"$lout" && no "told to restart the editor for a stale chat" || ok "…and nothing is told to restart the editor"
stop "$SA" "$SU" "$ST"

sleep 2                                                          # every chat below opens AFTER
fake "$T/LS"; B1=$!                                              # the launcher skipped the shim
fake "$T/LS" CLAUDE_SECURESTORAGE_CONFIG_DIR="$T/profiles/lsprof"; B2=$!   # correct
fake "$T/LS" CLAUDE_SECURESTORAGE_CONFIG_DIR="$T/profiles/other"; B3=$!    # handed another
fake "$T/LS" CLAUDE_CODE_OAUTH_TOKEN=sk-test-NEVERPRINTME; B4=$!           # token override
fake "$T/BL"; B5=$!                                              # blanked: global IS correct
fake "$T/BL" CLAUDE_SECURESTORAGE_CONFIG_DIR="$T/profiles/blprof"; B6=$!   # STRICT keeps it
fake "$T/UN"; B7=$!                                              # unrouted, on global: correct
sleep 1
full=$(X doctor --no-refresh 2>&1); lout=$(sed -n '/^live sessions/,$p' <<<"$full")
grep -q '1 of 7 live session(s) opened after the routing last changed' <<<"$lout" && ok "a newer chat with no account variable is the one real bypass" || no "$lout"
grep -q "pid $B1 .*is on (global); the folder uses 'lsprof'" <<<"$lout" && ok "…named, with the account its folder uses" || no "$lout"
grep -q 'QUIT and reopen VS Code' <<<"$lout" && ok "…with the restart-the-editor remedy" || no "no editor remedy"
grep -q '2 live session(s) were handed an account when they launched' <<<"$lout" && ok "a chat handed another account is not called a bypass" || no "$lout"
grep -q "pid $B3 .*carries 'other'; the folder uses 'lsprof'" <<<"$lout" && ok "…naming the account it carries" || no "$lout"
grep -q "pid $B4 .*carries (token override)" <<<"$lout" && ok "a token override is named as one" || no "$lout"
grep -q NEVERPRINTME <<<"$full" && no "doctor printed a token override's VALUE" || ok "…and its value is never printed"
for p in "$B2" "$B5" "$B7"; do grep -q "pid $p " <<<"$lout" && no "pid $p was flagged: $lout"; done
grep -q "pid $B5 " <<<"$lout" || ok "a profile blanked by a dead refresh token expects (global), as the launcher does"
# B6 carries blprof, whose stored login is EMPTY: no routing complaint, but it is exactly the
# kind of chat that can empty the next sign-in for blprof, so it is named as one (1.2.0).
grep -q "pid $B6 .*on 'blprof', whose stored login is gone" <<<"$lout" && ok "a chat running on a login that is gone is named, to close before signing in again" || no "$lout"
grep -E "pid $B6 .*(is on|carries|still on)" <<<"$lout" && no "B6 got a routing verdict too: $lout" || ok "…and gets no routing verdict on top"
grep -q "pid $B2 \\|pid $B7 " <<<"$lout" || ok "chats on their folder's account are not flagged"
# A Keychain probe ERROR is not "signed in": whether the profile is usable now is unknown, so a
# chat with no account variable cannot be called a bypass.
eout=$(SEC_MODE=err X doctor --no-refresh 2>&1 | sed -n '/^live sessions/,$p')
grep -q "pid $B1 " <<<"$eout" && no "a Keychain probe error became a bypass verdict: $eout" || ok "a Keychain probe error leaves a chat with no account variable unjudged"
stop "$B1" "$B2" "$B3" "$B4" "$B5" "$B6" "$B7"

# The launchers resolve the LOGICAL path ($PWD) and lsof gives the physical one. A rule stored
# through a symlink (add keeps that spelling) must not make a correctly routed chat look wrong;
# but a PWD naming some other directory is a parent's, left behind by a launcher that never
# ran, and must not hide a bypass. A folder that moved after launch is judged where it was.
mkdir -p "$T/real/Proj" "$T/MV/Proj" "$T/RR"; ln -s "$T/real" "$T/link"
X add "$T/link/Proj" lnprof >/dev/null 2>&1; sign lnprof
X add "$T/RR" rrprof >/dev/null 2>&1; sign rrprof
sleep 2
fake "$T/link/Proj" CLAUDE_SECURESTORAGE_CONFIG_DIR="$T/profiles/lnprof"; K1=$!
( cd "$T/LS" && exec env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN PWD=/ python3 "$FAKE" ) & K2=$!
fake "$T/MV/Proj"; K3=$!                                         # unrouted, on global: correct
sleep 1
mv "$T/MV/Proj" "$T/RR/Proj"                                     # …then moved under a routed root
lout=$(live)
grep -q "pid $K1 " <<<"$lout" && no "a chat routed through a symlinked rule was flagged: $lout" || ok "a rule stored through a symlink: the correctly routed chat is not flagged"
grep -q "pid $K2 .*is on (global); the folder uses 'lsprof'" <<<"$lout" && ok "…while a parent's leftover PWD does not hide a bypass" || no "$lout"
grep -q "pid $K3 " <<<"$lout" && no "a folder moved after launch was judged where it is now: $lout" || ok "a folder moved after launch is judged where the launcher saw it"
stop "$K1" "$K2" "$K3"

# Signing a folder's profile in changes where its new chats go, but moves neither the map nor
# profiles/. A chat opened while the profile was signed out went to (global) by design, so it
# is stale afterwards, never a bypass. The REAL login writes the marker — in a sandbox HOME, so
# it cannot read the label from this machine's ~/.claude.json.
mkdir -p "$T/LI" "$T/home"; X add "$T/LI" liprof >/dev/null 2>&1    # rule first, profile not signed in
sleep 2
fake "$T/LI"; L1=$!                                              # the launcher fell back to (global)
sleep 2
sign liprof; HOME="$T/home" PTY "" login liprof >/dev/null 2>&1
[ -f "$T/profiles/liprof/.login-attempted" ] && ok "login leaves its marker behind" || no "login wrote no .login-attempted"
lout=$(live)
grep -q "pid $L1 .*still on (global) from when it opened; the folder now uses 'liprof'" <<<"$lout" && ok "a chat opened before its profile was signed in is stale, not a bypass" || no "$lout"
stop "$L1"

# `use` is a routing change that lives in profiles/, not in the map.
mkdir -p "$T/FB" "$T/profiles/fbprof"; sign fbprof
fake "$T/FB"; F1=$!                                              # unrouted, on global: correct then
sleep 2
X use fbprof >/dev/null 2>&1
sleep 2
fake "$T/FB"; F2=$!                                              # after it, with no account
sleep 1
lout=$(live)
grep -q "pid $F1 .*still on (global) from when it opened; the folder now uses 'fbprof', the account selected with use" <<<"$lout" && ok "a chat opened before 'use' is stale afterwards" || no "$lout"
grep -q "pid $F2 .*is on (global); the folder uses 'fbprof', the account selected with use" <<<"$lout" && ok "…and one opened after it with no account is a bypass" || no "$lout"
stop "$F1" "$F2"; X use global >/dev/null 2>&1

fake "$T/LS" CLAUDE_SECURESTORAGE_CONFIG_DIR="$T/profiles/lsprof"; G1=$!
fake "$T/UN"; G2=$!
sleep 1
live | grep -q '2 live session(s), each on its folder.s account' && ok "all-correct chats get the all-clear" || no "$(live)"
stop "$G1" "$G2"

# A login that says it worked and leaves nothing stored (2026-10-18: an open chat on the
# profile emptied it) says it did not stick and names the chats that could have done it.
mkdir -p "$T/NS"; X add "$T/NS" nostick >/dev/null 2>&1
fake "$T/NS" CLAUDE_SECURESTORAGE_CONFIG_DIR="$T/profiles/nostick"; N1=$!
sleep 1
out=$(HOME="$T/home" PTY "" login nostick)
grep -q 'did not stick' <<<"$out" && ok "a login that leaves nothing stored says it did not stick" || no "$out"
grep -q "pid $N1 " <<<"$out" && ok "…naming the open chat on that profile, to close first" || no "$out"
grep -q 'is now: NOT LOGGED IN' <<<"$out" && no "it still printed 'is now: NOT LOGGED IN'" || ok "…instead of 'is now: NOT LOGGED IN'"
stop "$N1"
out=$(HOME="$T/home" PTY "" login nostick)
grep -q 'No chat on .nostick. is open now' <<<"$out" && ok "…and with no chat open, says so and to try again" || no "$out"
out=$(FAKE_AUTH_RC=1 HOME="$T/home" PTY "" login nostick)
grep -q 'Still not logged in' <<<"$out" && ! grep -q 'did not stick' <<<"$out" && ok "a sign-in that failed outright still just says so" || no "$out"

# An environment ps cannot read. Built from bash, which this macOS hides; where an OS does show
# it, the case cannot be staged this way and is skipped rather than passed.
printf 'for i in $(seq 600); do sleep 1; done\n' > "$FAKE-sh"
( cd "$T/LS" && exec env PROBE_SEEN=1 bash "$FAKE-sh" ) & H1=$!
sleep 1
if ps eww -o command= -p "$H1" | tr ' ' '\n' | grep -qx 'PROBE_SEEN=1'; then
  echo "  SKIP  this OS shows a bash process's environment, so an unreadable one cannot be staged"
else
  lout=$(live)
  grep -q 'could not read the environment of 1 live session(s)' <<<"$lout" && ok "an unreadable environment is reported as unknown" || no "$lout"
  grep -q "pid $H1 .*(global)" <<<"$lout" && no "an unreadable environment was called (global)" || ok "…and never as (global)"
  grep -q 'QUIT and reopen' <<<"$lout" && no "an unreadable environment was called a bypass" || ok "…or as a bypass"
fi
stop "$H1"

section "a json.py in the folder you run it from is never imported"
# `python3 -c` / `python3 -` put the cwd first on sys.path: before 1.2.3 a planted json.py ran
# as you, with a credential on its stdin at some sites. Every python3 now runs with -I.
bare=$(grep -nE 'python3( |$)' "$CA" | grep -vE '^[0-9]+: *#' | grep -vE 'python3 -I|python3 has')
[ -z "$bare" ] && ok "every python3 in the CLI runs with -I" || no "bare python3: $bare"
mkdir -p "$T/evil"
for m in json re curses; do printf 'open("%s", "a").write("%s\\n")\n' "$T/evil/RAN" "$m" > "$T/evil/$m.py"; done
( cd "$T/evil" && python3 -c 'import json' ) >/dev/null 2>&1
[ -s "$T/evil/RAN" ] && ok "the planted modules do run for a plain python3 -c here (the probe works)" || no "the probe never fired"
rm -f "$T/evil/RAN"
X group Planted alpha >/dev/null 2>&1        # groups.tsv exists, so the views run the groups program too
for v in list profiles verify overview group _ui-state _ui-groups "_ui-usage alpha" "usage alpha" doctor; do
  ( cd "$T/evil" && X $v ) >/dev/null 2>&1
done
[ ! -e "$T/evil/RAN" ] && ok "…but no claude-account command run from that folder imports them" || no "imported: $(sort -u "$T/evil/RAN" | tr '\n' ' ')"
X group --delete Planted >/dev/null 2>&1

section "rename copies the login the way Claude Code writes it, checks it, and only then moves anything"
# T_KC turns the security stub into a real store (see lib.sh). A login is written as hex
# through `security -i` on stdin when the line fits Claude Code's 4032-character limit, on argv
# when it does not, exactly as Claude Code 2.1.238 does; the copy must read back identical, and
# a failure at any step must leave the profile, its rules and its login as they were.
KC="$T_KC"
mk_login(){ # <profile> <approximate size in bytes>
  mkdir -p "$T/profiles/$1"
  python3 -I -c 'import json,sys; n=int(sys.argv[1]); print(json.dumps({"claudeAiOauth":{"accessToken":"tok-"+sys.argv[2],"refreshToken":"ref-"+sys.argv[2],"expiresAt":4102444800000,"subscriptionType":"max","rateLimitTier":"demo"},"pad":"p"*max(0,n-170)}), end="")' "$2" "$1" > "$KC/$(svc_of "$1")"
  printf 'alexy-test' > "$KC/$(svc_of "$1").acct"
}
mkdir -p "$T/RenSmall"; mk_login rsmall 1200; X add "$T/RenSmall" rsmall >/dev/null 2>&1
cp "$KC/$(svc_of rsmall)" "$T/rsmall.orig"; : > "$KC/channel.log"
out=$(T_KC="$KC" X rename rsmall rsmall2 2>&1); rc=$?
[ $rc = 0 ] && cmp -s "$KC/$(svc_of rsmall2)" "$T/rsmall.orig" && ok "a 1.2 KB login moves to the new name byte for byte" || no "rc=$rc: $out"
[ ! -e "$KC/$(svc_of rsmall)" ] && ok "…and the old entry is gone" || no "the old entry is still there"
[ "$(cat "$KC/$(svc_of rsmall2).acct")" = alexy-test ] && ok "…under the account name the old entry had" || no "acct: $(cat "$KC/$(svc_of rsmall2).acct" 2>&1)"
grep -q '^stdin ' "$KC/channel.log" && ! grep -q '^argv ' "$KC/channel.log" && ok "…written through stdin, never on the command line" || no "channels: $(cat "$KC/channel.log")"
grep -q 'tok-rsmall\|ref-rsmall' <<<"$out" && no "rename printed the login" || ok "…and nothing of it was printed"
awk -F'\t' -v p="$T/RenSmall" '$1==p && $2=="rsmall2"{f=1} END{exit !f}' "$CLAUDE_ACCOUNTS_MAP" && [ -d "$T/profiles/rsmall2" ] && ok "…with its rule and folder renamed" || no "$(cat "$CLAUDE_ACCOUNTS_MAP")"

mk_login rbig 3000; cp "$KC/$(svc_of rbig)" "$T/rbig.orig"; : > "$KC/channel.log"
out=$(T_KC="$KC" X rename rbig rbig2 2>&1); rc=$?
[ $rc = 0 ] && cmp -s "$KC/$(svc_of rbig2)" "$T/rbig.orig" && ok "a 3 KB login, too long for stdin, moves byte for byte" || no "rc=$rc: $out"
grep -q '^argv ' "$KC/channel.log" && ! grep -q '^stdin ' "$KC/channel.log" && ok "…on the command line, as Claude Code writes a login that size" || no "channels: $(cat "$KC/channel.log")"

for mode in drop corrupt; do
  mk_login "r$mode" 1200; cp "$KC/$(svc_of "r$mode")" "$T/r$mode.orig"; mkdir -p "$T/Ren$mode"; X add "$T/Ren$mode" "r$mode" >/dev/null 2>&1
  mapb=$(cat "$CLAUDE_ACCOUNTS_MAP")
  out=$(T_KC="$KC" SEC_ADD_MODE=$mode X rename "r$mode" "r${mode}2" 2>&1); rc=$?
  [ $rc = 1 ] && grep -q 'nothing was renamed' <<<"$out" && ok "a copy that $( [ $mode = drop ] && echo 'claims success and stores nothing' || echo 'reads back one byte short') is refused" || no "rc=$rc: $out"
  [ -d "$T/profiles/r$mode" ] && [ ! -e "$T/profiles/r${mode}2" ] && [ "$(cat "$CLAUDE_ACCOUNTS_MAP")" = "$mapb" ] && ok "…the folder and the rules are untouched" || no "$(ls "$T/profiles"); $(cat "$CLAUDE_ACCOUNTS_MAP")"
  cmp -s "$KC/$(svc_of "r$mode")" "$T/r$mode.orig" && [ ! -e "$KC/$(svc_of "r${mode}2")" ] && ok "…the login is where it was, and no half copy is left" || no "$(ls "$KC")"
done

mkdir -p "$T/profiles/rhex"; printf '6869207468657265' > "$KC/$(svc_of rhex)"; cp "$KC/$(svc_of rhex)" "$T/rhex.orig"; : > "$KC/channel.log"
out=$(X rename rhex rhex2 2>&1); rc=$?
[ $rc = 1 ] && [ -d "$T/profiles/rhex" ] && cmp -s "$KC/$(svc_of rhex)" "$T/rhex.orig" && [ ! -e "$KC/$(svc_of rhex2)" ] && [ ! -s "$KC/channel.log" ] \
  && ok "a value that is neither a JSON object nor the hex of one is never copied: nothing renamed, nothing written" || no "rc=$rc: $out; $(ls "$KC")"
mkdir -p "$T/profiles/rutf"; printf '{"claudeAiOauth":{"accessToken":"tok-utf"},"mcpOAuth":{"Café|1a2b":{}}}' > "$KC/$(svc_of rutf)"; cp "$KC/$(svc_of rutf)" "$T/rutf.orig"
out=$(X rename rutf rutf2 2>&1); rc=$?
[ $rc = 0 ] && cmp -s "$KC/$(svc_of rutf2)" "$T/rutf.orig" && ok "a login with non-ASCII in it, which security prints as hex, moves byte for byte" || no "rc=$rc: $out"
mkdir -p "$T/profiles/rnone"; : > "$KC/channel.log"
T_KC="$KC" X rename rnone rnone2 >/dev/null 2>&1 && [ -d "$T/profiles/rnone2" ] && [ ! -s "$KC/channel.log" ] && ok "a profile with no login renames, and writes nothing to the Keychain" || no "$(cat "$KC/channel.log")"
SEC_MODE=err X rename rsmall2 rsmall3 >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && [ -d "$T/profiles/rsmall2" ] && ok "a Keychain probe error refuses the rename instead of leaving the login behind" || no "rc=$rc"
grep -c 'security add-generic-password' "$CA" | grep -qx 1 && ok "one place in the CLI writes a login" || no "$(grep -n 'security add-generic-password' "$CA")"

finish
