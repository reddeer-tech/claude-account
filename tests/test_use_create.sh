#!/bin/bash
# `use` / `create` / login-offer / floating profiles / doctor version gate (1.0.27+).
# The interaction matrix: every verb that can touch the machine-wide selection is
# crossed with every other one, because the bugs in this area were always about two
# commands disagreeing — not one command being wrong on its own.
. "$(dirname "$0")/lib.sh"; ca_sandbox

mkdir -p "$T/proj/A" "$T/proj/B" "$T/elsewhere"
X add "$T/proj/A" alpha >/dev/null 2>&1
X add "$T/proj/B" beta  >/dev/null 2>&1
sign alpha

section "use: set / show / -q / clear"
out=$(X use ghost 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'unknown profile' && ok "use <unknown> refuses (exit 1)" || no "unknown rc=$rc"
mkdir -p "$T/profiles/tl"; sign tl
out=$(X use tl 2>&1); rc=$?
[ $rc = 0 ] && printf '%s' "$out" | grep -q "Now using 'tl' for every path with no rule" && ok "use tl sets" || no "use tl rc=$rc :: $out"
[ "$(cat "$T/profiles/.fallback")" = "tl" ] && ok ".fallback holds tl" || no ".fallback content"
[ "$(X use -q)" = "tl" ] && ok "use -q prints just the name" || no "use -q"
X use 2>&1 | grep -q '^using : tl' && ok "bare use shows the selection" || no "bare use"
[ "$(Rn "$T/elsewhere")" = "tl" ] && ok "unrouted path resolves to tl" || no "resolver"
[ "$(R "$T/elsewhere" | cut -f3)" = "(fallback)" ] && ok "resolver token '(fallback)' kept (load-bearing)" || no "resolver token"
[ "$(X fallback -q)" = "tl" ] && ok "fallback alias: same command" || no "alias -q"
out=$(X use global 2>&1); rc=$?
[ $rc = 0 ] && printf '%s' "$out" | grep -q "Back on your GLOBAL account (was 'tl')" && ok "use global clears" || no "use global rc=$rc"
[ ! -f "$T/profiles/.fallback" ] && ok ".fallback removed" || no ".fallback still there"
X use -q >/dev/null 2>&1; [ $? = 1 ] && [ -z "$(X use -q 2>/dev/null)" ] && ok "use -q when unset: empty + exit 1" || no "-q unset"
out=$(X use global 2>&1); rc=$?
[ $rc = 0 ] && printf '%s' "$out" | grep -q 'Nothing was selected' && ok "use global idempotent (exit 0)" || no "idempotent rc=$rc"
X use tl >/dev/null 2>&1
out=$(X fallback global 2>&1); rc=$?
[ $rc = 0 ] && printf '%s' "$out" | grep -q 'Back on your GLOBAL' && ok "BEHAVIOUR CHANGE 1.0.27: fallback global clears (was exit 2)" || no "fallback global rc=$rc"
X use tl >/dev/null 2>&1
out=$(X fallback none 2>&1); rc=$?
[ $rc = 0 ] && printf '%s' "$out" | grep -q 'Back on your GLOBAL' && ok "fallback none still clears" || no "fallback none rc=$rc"
out=$(X use "$T/proj/A" 2>&1); rc=$?
[ $rc = 2 ] && printf '%s' "$out" | grep -q 'profile NAME, not a path' && ok "use <path> refused (exit 2)" || no "use path rc=$rc"
out=$(X use beta 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'not signed in' && ok "unsigned profile refused without --force" || no "unsigned rc=$rc"
X use beta --force >/dev/null 2>&1 && [ "$(X use -q)" = "beta" ] && ok "--force overrides" || no "--force"
X use global >/dev/null 2>&1

section "use: ambiguity guards (a legacy profile literally named global / none)"
mkdir -p "$T/profiles/global"
out=$(X use global 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'ambiguous' && ok "legacy 'global' profile -> refuse + disambiguate" || no "global-ambig rc=$rc"
rmdir "$T/profiles/global"
mkdir -p "$T/profiles/none"
out=$(X use none 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q "'none' is ambiguous" && ok "legacy 'none' profile -> refuse" || no "none-ambig rc=$rc"
rmdir "$T/profiles/none"

section "use: calm banner + doctor (no nag, age informational)"
X use tl >/dev/null 2>&1
X list --no-refresh 2>/dev/null | grep -q "using 'tl' for every path with no rule" && ok "banner: calm wording" || no "banner"
X list --no-refresh 2>/dev/null | grep -q 'fallback active' && no "old ⚠ banner still present" || ok "old ⚠ banner gone"
touch -t "$(date -v-5d +%Y%m%d%H%M)" "$T/profiles/.fallback"
X list --no-refresh 2>/dev/null | grep -q 'set 5d ago' && ok "banner keeps the age" || no "banner age"
D=$(X doctor --no-refresh 2>&1)
printf '%s' "$D" | grep -q "using 'tl' for every unrouted path (set 5d ago)" && ok "doctor: one calm line with age" || no "doctor line"
printf '%s' "$D" | grep -q 'has the global quota reset' && no "3-day nag still fires" || ok "3-day nag removed"
echo junk-name/ > "$T/profiles/.fallback"
X use 2>&1 | grep -q 'IGNORED' && ok "junk .fallback still says IGNORED" || no "junk"
rm -f "$T/profiles/.fallback"

section "use × pause / switch-pin / resume (the matrix core)"
X use tl >/dev/null 2>&1
X pause alpha >/dev/null 2>&1
[ "$(Rn "$T/proj/A")" = "tl" ] && ok "paused path follows the selection (paused ≡ unrouted)" || no "paused follows"
X switch "$T/proj/A" global >/dev/null 2>&1
[ "$(Rn "$T/proj/A")" = "(global)" ] && ok "switch <x> global pins to the REAL global (selection suppressed)" || no "pin"
X resume alpha >/dev/null 2>&1
[ "$(Rn "$T/proj/A")" = "alpha" ] && ok "resume returns the path to its own profile" || no "resume"
mkdir -p "$T/profiles/kindly2"; sign kindly2
X pause alpha >/dev/null 2>&1
out=$(X use kindly2 2>&1)
printf '%s' "$out" | grep -q "These PAUSED paths now bill 'kindly2'" && ok "setting names the paused paths it captures" || no "paused enumeration"
X resume alpha >/dev/null 2>&1; X use global >/dev/null 2>&1

section "use × logout / rename / forget / export-import / undo"
X use tl >/dev/null 2>&1
out=$(X logout tl 2>&1)
[ ! -f "$T/profiles/.fallback" ] && ok "logout of the selected profile clears the selection loudly" || no "logout clear"
printf '%s' "$out" | grep -q 'claude-account use tl' && ok "logout prints the restore pair with 'use'" || no "logout hint: $out"
sign tl; X use tl >/dev/null 2>&1
X rename tl tl9 >/dev/null 2>&1; sign tl9   # the stub cannot move a credential the way a real rename does
[ "$(X use -q)" = "tl9" ] && ok "rename repoints the selection" || no "rename repoint"
out=$(X forget tl9 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -qi 'fallback\|selected' && ok "forget of the selected profile refuses" || no "forget rc=$rc"
X export > "$T/exp.tsv" 2>/dev/null
grep -q "fallback	tl9" "$T/exp.tsv" && ok "export carries the selection" || no "export"
X use global >/dev/null 2>&1
X import "$T/exp.tsv" >/dev/null 2>&1
[ "$(X use -q)" = "tl9" ] && ok "import restores the selection" || no "import"
X pause alpha >/dev/null 2>&1
X undo --yes >/dev/null 2>&1
[ "$(X use -q)" = "tl9" ] && ok "undo restores the MAP only — the selection survives (documented gap)" || no "undo touched selection"
X resume alpha >/dev/null 2>&1; X use global >/dev/null 2>&1; X rename tl9 tl >/dev/null 2>&1

section "create: floating profiles"
out=$(X create work </dev/null 2>&1); rc=$?
[ $rc = 3 ] && ok "non-TTY: exit 3 (sign-in deferred)" || no "create rc=$rc"
[ -d "$T/profiles/work" ] && ok "profile dir WAS created (the one exit-3 with a side effect)" || no "no dir"
printf '%s' "$out" | grep -q "Created floating profile 'work'" && ok "says floating, no path bound" || no "wording"
printf '%s' "$out" | grep -q 'claude-account login work' && ok "hands you the deferred login command" || no "deferred cmd"
out=$(X create work </dev/null 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'already exists (not signed in)' && ok "existing unsigned -> exit 1, hints login" || no "exists-unsigned rc=$rc"
sign work
out=$(X create work </dev/null 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'use work' && ok "existing signed -> exit 1, hints use/add" || no "exists-signed rc=$rc"
X create global </dev/null >/dev/null 2>&1; [ $? = 2 ] && ok "create global refused (reserved)" || no "reserved global"
X create none   </dev/null >/dev/null 2>&1; [ $? = 2 ] && ok "create none refused (reserved)"   || no "reserved none"
X create "bad name" </dev/null >/dev/null 2>&1; [ $? = 2 ] && ok "invalid name refused" || no "invalid"
out=$(X create "$T/proj/A" </dev/null 2>&1); rc=$?
[ $rc = 2 ] && printf '%s' "$out" | grep -q 'add <path> <name>' && ok "path-shaped arg -> exit 2, points at add" || no "path-shaped rc=$rc"
out=$(X create switch </dev/null 2>&1)
printf '%s' "$out" | grep -q 'also a claude-account COMMAND' && ok "verb-shadow name warns" || no "verb shadow"
rm -rf "$T/profiles/switch"
D=$(X doctor --no-refresh 2>&1)
printf '%s' "$D" | grep -q 'work: signed in, floating' && ok "doctor: a signed floating profile is ok, not an orphan warning" || no "doctor floating"
printf '%s' "$D" | grep -q 'orphan' && no "the word orphan survives somewhere in doctor" || ok "no more 'orphan' in doctor"
X profiles --no-refresh 2>/dev/null | grep -q 'floating (no path)' && ok "profiles: floating wording" || no "profiles floating"
X use work >/dev/null 2>&1 && [ "$(X use -q)" = "work" ] && ok "create -> use chain works" || no "create->use"
X use global >/dev/null 2>&1

section "add × floating profiles"
mkdir -p "$T/proj/Work"
out=$(X add "$T/proj/Work" work 2>&1); rc=$?
[ $rc = 0 ] && printf '%s' "$out" | grep -q "Binding to EXISTING floating profile 'work'" && ok "explicit bind to floating: loud, allowed" || no "explicit bind rc=$rc"
X create acme </dev/null >/dev/null 2>&1
mkdir -p "$T/proj/acme"
out=$(X add "$T/proj/acme" 2>&1); rc=$?
[ $rc = 0 ] && printf '%s' "$out" | grep -q "Binding to EXISTING floating profile 'acme'" && ok "DERIVED name matching a floating profile: binds loudly" || no "derived floating rc=$rc"
mkdir -p "$T/proj2/acme"
out=$(X add "$T/proj2/acme" 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'already used' && ok "derived name colliding with a MAP-USED profile still refused" || no "derived used rc=$rc"

section "login: unknown-name offer / flag passthrough"
out=$(X login ghost </dev/null 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'create it first:.*create ghost' && ok "unknown name non-TTY: refuse + create hint" || no "login ghost rc=$rc"
[ ! -d "$T/profiles/ghost" ] && ok "nothing created on refusal" || no "ghost dir appeared"
out=$(X login "$T/proj/A" </dev/null 2>&1); rc=$?
[ $rc = 3 ] && printf '%s' "$out" | grep -q 'login alpha' && ok "path arg unchanged (resolves the rule, exit 3 non-TTY)" || no "login path rc=$rc"
out=$(X login work --email a@b.c --sso </dev/null 2>&1); rc=$?
[ $rc = 3 ] && printf '%s' "$out" | grep -q -- '--email a@b.c --sso' && ok "flags round-trip in the deferred command" || no "flags rc=$rc"
X login work --bogus </dev/null >/dev/null 2>&1; [ $? = 2 ] && ok "unknown flag refused (exit 2)" || no "bogus flag"
X login work --email </dev/null >/dev/null 2>&1; [ $? = 2 ] && ok "--email without a value refused" || no "email novalue"

section "dispatch: word order + the 1.0.26 command-vs-directory guard"
X tl use >/dev/null 2>&1
[ "$(X use -q)" = "tl" ] && ok "profile-first: 'tl use' selects tl" || no "tl use"
mkdir -p "$T/wd/use" "$T/wd/create"
( cd "$T/wd" && bash "$CA" use global >/dev/null 2>&1 )
[ ! -f "$T/profiles/.fallback" ] && ok "'use global' immune to a ./use directory" || no "guard use"
( cd "$T/wd" && bash "$CA" create global </dev/null >/dev/null 2>&1 )
[ $? = 2 ] && ok "'create global' immune to a ./create directory" || no "guard create"

section "doctor: the claude >= 2.1.144 version gate"
D=$(FAKE_CLAUDE_VERSION="2.1.100 (Claude Code)" X doctor --no-refresh 2>&1)
if printf '%s' "$D" | grep -q "$T/bin/claude"; then
  printf '%s' "$D" | grep -q 'OLDER than 2.1.144' && ok "old version -> problem" || no "old not flagged"
  D=$(FAKE_CLAUDE_VERSION="2.1.144-beta.1 (Claude Code)" X doctor --no-refresh 2>&1)
  printf '%s' "$D" | grep -q 'OLDER than 2.1.144' && ok "a prerelease of the floor counts as OLDER" || no "prerelease"
  D=$(FAKE_CLAUDE_VERSION="mystery build" X doctor --no-refresh 2>&1)
  printf '%s' "$D" | grep -q 'could not read' && ok "unparseable -> warning, never 'too old'" || no "unparseable"
else
  echo "  SKIP  doctor resolved the real claude, not the stub"
fi

finish
