#!/bin/bash
# The interactive paths — everything behind [ -t 0 ] / [ -t 1 ], which a plain
# non-TTY run can never reach. `script -q /dev/null` allocates a pseudo-terminal, and
# the stubbed `claude` means `auth login` returns without a browser or a real OAuth
# exchange: the flow AROUND the sign-in is what is under test, never the sign-in itself.
. "$(dirname "$0")/lib.sh"; ca_sandbox

section "login <unknown> under a real TTY: the create offer"
out=$(PTY n login ghost)
printf '%s' "$out" | grep -q "profile 'ghost' does not exist — create it now?" && ok "the y/N offer is shown" || no "no offer: $out"
printf '%s' "$out" | grep -q 'nothing created' && ok "'n' declines cleanly" || no "decline"
[ ! -d "$T/profiles/ghost" ] && ok "no dir after 'n'" || no "ghost dir created"

out=$(PTY y login ghost2)
printf '%s' "$out" | grep -q "Created floating profile 'ghost2'" && ok "'y' hands off to create" || no "no handoff: $out"
printf '%s' "$out" | grep -q "Signing in to Claude profile 'ghost2'" && ok "create runs the sign-in flow" || no "no sign-in flow"
[ -d "$T/profiles/ghost2" ] && ok "profile dir exists" || no "no dir"
printf '%s' "$out" | grep -q "profile 'ghost2' kept — sign in later" && ok "sign-in did not verify: profile KEPT, told to sign in later" || no "kept msg"

section "create under a real TTY: the one-command success path"
sign newp    # pre-sign the service the new dir hashes to, so the stubbed auth 'succeeds'
out=$(PTY '' create newp)
printf '%s' "$out" | grep -q "Created floating profile 'newp'" && ok "created" || no "create: $out"
printf '%s' "$out" | grep -q "Profile 'newp' is now: max | demo" && ok "sign-in verified against the credential, identity shown" || no "identity"
printf '%s' "$out" | grep -q 'kept — sign in later' && no "success path wrongly took the kept branch" || ok "no false 'kept' on success"

section "undo's interactive confirm"
mkdir -p "$T/proj/A"; X add "$T/proj/A" alpha >/dev/null 2>&1; sign alpha
X pause alpha >/dev/null 2>&1
out=$(PTY n undo)
printf '%s' "$out" | grep -qi 'restore\|diff\|undo' && ok "undo prompts under a TTY" || no "undo pty: $out"
grep -q 'paused' "$CLAUDE_ACCOUNTS_MAP" && ok "'n' left the map untouched" || no "undo ran despite n"

section "--help is coloured on a terminal, plain everywhere else"
h=$(PTYC '' --help | tr -d '\r')
printf '%s' "$h" | grep -q $'\033\[1mUSE' && ok "section headings bold on a tty" || no "no colour on tty"
printf '%s' "$h" | grep -q $'\033\[1mcreate' && ok "verbs bold (create included)" || no "verb not bold"
# create must be introduced BEFORE use: you cannot `use` a profile that does not exist
cl=$(printf '%s' "$h" | grep -n $'\033\[1mcreate' | head -1 | cut -d: -f1)
ul=$(printf '%s' "$h" | grep -n $'\033\[1muse' | head -1 | cut -d: -f1)
[ -n "$cl" ] && [ -n "$ul" ] && [ "$cl" -lt "$ul" ] && ok "create is documented before use" || no "create/use order: create=$cl use=$ul"
[ "$(X --help | grep -c $'\033')" = 0 ] && ok "piped output carries no escapes" || no "ANSI leaked into a pipe"

finish
