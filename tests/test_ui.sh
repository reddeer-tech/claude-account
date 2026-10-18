#!/bin/bash
# The full-screen view (1.2.0), driven for real: `claude-account ui` runs inside a private
# tmux server (-L its own socket, -f a config of its own, so no one's tmux setup applies), the test
# sends keystrokes and reads back what the screen shows, and checks what each action changed.
# HOME is the sandbox's too, so a sign-in run from the view cannot read this machine's
# ~/.claude.json for its label.
. "$(dirname "$0")/lib.sh"
ca_sandbox; fail=0
command -v tmux >/dev/null 2>&1 || { echo "  SKIP  tmux is not installed — the full-screen view is not tested"; finish; }
SOCK="ca-ui-test-$$"
# Our own config only: the terminal type the view is told it runs in, so the keys tmux sends
# (Home, End, arrows) are the ones that terminal type defines — as with a real terminal.
# /bin/sh, not your login shell: zsh reads ~/.zshenv even for `zsh -c`, and a PATH there
# that puts ~/.local/bin first made the view's sign-in run the REAL claude (2026-10-18 — it
# opened a browser and failed at the code prompt; nothing was stored).
printf 'set -g default-terminal xterm-256color\nset -g escape-time 10\nset -g default-shell /bin/sh\n' > "$T/tmux.conf"
TM(){ tmux -L "$SOCK" -f "$T/tmux.conf" "$@"; }
trap 'TM kill-server >/dev/null 2>&1' EXIT
mkdir -p "$T/home" "$T/A" "$T/B" "$T/D"
X add "$T/A" alpha >/dev/null 2>&1; X add "$T/B" beta >/dev/null 2>&1; mkdir -p "$T/profiles/gamma"
sign alpha; sign beta; sign gamma; sign_global
M="$T/paths.map"; G="$T/groups.tsv"

scr(){ TM capture-pane -p -t ui 2>/dev/null; }
# Wait until the screen shows a pattern (default 60 s: the machine may be loaded, and each
# action runs the CLI). Returns 1 on timeout, so the assertion that follows reports it.
wait_for(){ local n=$(( ${2:-60} * 4 )) i=0; while [ $i -lt $n ]; do scr | grep -qE -- "$1" && return 0; sleep 0.25; i=$((i+1)); done; return 1; }
wait_gone(){ local n=$(( ${2:-60} * 4 )) i=0; while [ $i -lt $n ]; do scr | grep -qE -- "$1" || return 0; sleep 0.25; i=$((i+1)); done; return 1; }
k(){ TM send-keys -t ui "$@"; sleep 0.3; }
lit(){ TM send-keys -t ui -l "$1"; sleep 0.3; }
# Everything a session runs gets the sandbox PATH spelled out, whatever a shell does.
SANDBOX_ENV="HOME='$T/home' PATH='$PATH' LANG=en_US.UTF-8 TERM=xterm-256color T_SECLOG='$T/seclog'"
start(){ # [extra env…] — the view in a 160×50 pane; the pane stays after it exits
  TM kill-session -t ui >/dev/null 2>&1
  TM new-session -d -s ui -x 160 -y 50 \
    "env $SANDBOX_ENV $* bash '$CA' ui; echo UI-EXITED-\$?; sleep 600"
}

# ⚠ GUARD, before any keystroke: inside a pane, every binary the CLI could reach for must be
# the sandbox's stub. If one is not, stop here — an action sent to the real one is a real
# sign-in, a real Keychain read, a real API call.
TM new-session -d -s guard -x 120 -y 10 "env $SANDBOX_ENV /bin/sh -c 'for b in claude security curl python3; do command -v \$b; done > \"$T/which.txt\" 2>&1; sleep 30'"
for _ in $(seq 1 40); do [ -s "$T/which.txt" ] && [ "$(grep -c . "$T/which.txt")" -ge 4 ] && break; sleep 0.25; done
TM kill-session -t guard >/dev/null 2>&1
for b in claude security curl; do
  if [ "$(grep "/$b\$" "$T/which.txt" | head -1)" != "$T/bin/$b" ]; then
    no "inside tmux, '$b' resolves to $(grep "/$b\$" "$T/which.txt" | head -1), not the sandbox stub — refusing to drive the view"
    finish
  fi
done
ok "inside tmux, claude, security and curl are the sandbox stubs — nothing real can be reached"
# Press ⏎ through the confirm menu: No is highlighted, so Up first to say Yes.
yes(){ wait_for 'Yes' 30; k Up; k Enter; }
popup_close(){ wait_for '⏎ close' 60 && k Enter; }
# Put the cursor on an account by name: Home, then down until the ▶ row is it.
goto(){ k Home; local i; for i in $(seq 1 20); do scr | grep -qE "▶ (● )? *$1( |\$)" && return 0; k Down; done; return 1; }

section "it opens on your accounts"
start
wait_for 'this machine: \(global\)' 60 && ok "the header names the account this machine is on" || no "$(scr | head -5)"
wait_for 'week +34%' 60 && ok "usage arrives in the rows (5h 40%, week 34% from the stub)" || no "$(scr | head -12)"
s=$(scr)
grep -qE '▶ ● \(global\)' <<<"$s" && ok "the cursor starts on the first account, (global), marked as the machine's" || no "$s"
grep -q 'gamma.*floating — no path' <<<"$s" && grep -q 'alpha.*1 path' <<<"$s" && ok "each row says what uses the account" || no "$s"
grep -q '⏎ actions' <<<"$s" && ok "the keys are always on screen" || no "no key hints"

section "moving, and an account's paths"
k Down; wait_for '▶ +alpha' 10 && ok "↓ moves to the next account" || no "$(scr | head -8)"
k Right; wait_for "└ $T/A +in use" 10 && ok "→ shows its paths, and what each is doing" || no "$(scr | head -10)"

section "a key the terminal does not know is ignored, never read as quit"
# A bare ESC, then raw sequences no terminfo entry here defines. curses hands those over as
# ESC plus loose bytes; the view used to quit on the ESC and could read "[" as "move up".
k Escape; TM send-keys -t ui -H 1b 5b 39 39 7e; sleep 0.3; TM send-keys -t ui -H 1b 5b 31 3b 39 41; sleep 1
# Home and End as different terminals send them: ESC[1~ (tmux), ESC[H (xterm), ESC OH, ESC[4~
TM send-keys -t ui -H 1b 5b 34 7e; sleep 0.5; scr | grep -qE '▶ +gamma' && ok "End sent as ESC[4~ goes to the last account" || no "$(scr | head -8)"
TM send-keys -t ui -H 1b 5b 31 7e; sleep 0.5; scr | grep -qE '▶ ● \(global\)' && ok "Home sent as ESC[1~ goes to the first" || no "$(scr | head -8)"
TM send-keys -t ui -H 1b 4f 46; sleep 0.5; TM send-keys -t ui -H 1b 5b 48; sleep 0.5
scr | grep -qE '▶ ● \(global\)' && ok "…and ESC OF / ESC[H work the same way" || no "$(scr | head -8)"
scr | grep -q 'UI-EXITED' && no "an escape sequence quit the view" || ok "Esc and unknown escape sequences leave the view open"
[ ! -f "$G" ] && ok "…and move nothing (no order was written)" || no "an escape sequence reordered: $(cat "$G")"

section "refreshing usage, for one account and for all"
goto alpha
wait_gone 'loading usage' 60; : > "$T_CURLED"
k Enter; wait_for '▶ Refresh its usage' 15 && ok "⏎'s first item refreshes the account's usage" || no "$(scr)"
k Enter; wait_for "refreshing alpha's usage" 15 && ok "…and says so" || no "$(scr | tail -4)"
for _ in $(seq 1 240); do [ "$(grep -c '^args:' "$T_CURLED")" -ge 1 ] && scr | grep -qE '▶ +alpha .*week +34%' && break; sleep 0.25; done
[ "$(grep -c '^args:' "$T_CURLED")" = 1 ] && ok "…asking the usage endpoint once, for that account only" || no "$(grep -c '^args:' "$T_CURLED") usage calls"
: > "$T_CURLED"
k m; wait_for '▶ Refresh every account.s usage' 15 && ok "m's first item refreshes every account's usage" || no "$(scr)"
k Enter; wait_for 'refreshing usage' 15
for _ in $(seq 1 240); do [ "$(grep -c '^args:' "$T_CURLED")" -ge 4 ] && ! scr | grep -q 'loading usage' && break; sleep 0.25; done
[ "$(grep -c '^args:' "$T_CURLED")" = 4 ] && ok "…one usage call per signed-in account, four here" || no "$(grep -c '^args:' "$T_CURLED") usage calls"

section "a confirm defaults to No"
goto alpha
k Enter; wait_for 'Pause its 1 path' 15 && ok "⏎ opens what you can do with the account" || no "$(scr)"
k Down; k Down; k Enter; wait_for 'Pause alpha.s 1 path' 15 && k Enter
sleep 1; grep -q 'paused' "$M" && no "Enter on the confirm paused it — No was not the default" || ok "⏎ straight through the confirm changes nothing"

section "an action runs the command, shows what it said, and the screen follows"
k Enter; wait_for 'Pause its 1 path' 15; k Down; k Down; k Enter; yes
wait_for 'claude-account pause alpha' 60 && ok "the action's output appears, titled with the command it ran" || no "$(scr)"
popup_close
grep -qP "^$T/A\talpha\tpaused" "$M" 2>/dev/null || awk -F'\t' -v p="$T/A" '$1==p && $3=="paused"{f=1} END{exit !f}' "$M" \
  && ok "…and it really paused the path" || no "$(cat "$M")"
wait_for "└ $T/A +not in use → \(global\) · paused" 30 && ok "the path row now says where it goes" || no "$(scr | head -10)"

section "a path's own menu"
k Down; wait_for "▶ +└ $T/A" 10 || wait_for "▶.*$T/A" 5
k Enter; wait_for 'Resume this path on alpha' 15 && ok "⏎ on a path offers what fits it" || no "$(scr)"
k Enter; yes; popup_close
awk -F'\t' -v p="$T/A" '$1==p && $3==""{f=1} END{exit !f}' "$M" && ok "resume from the path's menu routes it again" || no "$(cat "$M")"
k Left; wait_for '▶ +alpha' 10 && ok "← hides the paths and goes back to the account" || no "$(scr | head -8)"

section "using an account for every path with no rule, and back"
k Enter; wait_for 'Use it for every path with no rule' 15; k Down; k Enter; yes; popup_close
wait_for "this machine: alpha" 30 && [ "$(cat "$T/profiles/.fallback" 2>/dev/null)" = alpha ] && ok "use, from the view, selects it — and the header says so" || no "$(scr | head -3)"
k Enter; wait_for 'Stop using it' 15; k Down; k Enter; yes; popup_close
wait_for 'this machine: \(global\)' 30 && [ ! -f "$T/profiles/.fallback" ] && ok "…and back to (global)" || no "$(scr | head -3)"

section "groups, from the view"
k g; wait_for 'Groups for alpha' 15 && ok "g opens the account's groups" || no "$(scr)"
k Enter; wait_for 'Name of the new group' 15; lit "Clients"; k Enter
wait_for 'alpha is in Clients' 60 && ok "＋ New group makes it, with the account already in" || no "$(scr)"
# One pick and back to the main screen — not the groups menu again (Alexy, 2026-10-18)
wait_for '── Clients \(1\)' 30 && ! scr | grep -q 'Groups for' && ok "…straight back to the main screen, which has a Clients section" || no "$(scr | head -12)"
grep -qxF "$(printf 'group\tClients\talpha')" "$G" && ok "…written to groups.tsv by the same group command" || no "$(cat "$G" 2>&1)"
# beta is in the Ungrouped section below; put it in Clients as well
goto beta
k g; wait_for '\[ \] Clients' 15; k Enter; wait_for 'beta is in Clients' 60
grep -qxF "$(printf 'group\tClients\tbeta')" "$G" && ok "picking a group puts the account in it" || no "$(cat "$G")"
wait_for '── Clients \(2\)' 30 && ! scr | grep -q 'Groups for' && ok "…the section counts it, and the menu is gone" || no "$(scr | head -12)"
# and out again, also one pick — the other one way round
goto beta
k g; wait_for '\[x\] Clients' 15; k Enter; wait_for 'beta is out of Clients' 60
! grep -qxF "$(printf 'group\tClients\tbeta')" "$G" && wait_for '── Clients \(1\)' 30 && ! scr | grep -q 'Groups for' \
  && ok "picking a group it is in takes it out, and back to the main screen" || no "$(cat "$G"; scr | head -12)"
k g; wait_for '\[ \] Clients' 15; k Enter; wait_for 'beta is in Clients' 60; wait_for '── Clients \(2\)' 30
# G, the groups manager, the same way: ＋ New group… is the item after the one group
k G; wait_for 'Groups — ' 15; k Down; k Enter; wait_for 'Name of the new group' 15; lit "Spare"; k Enter
wait_for '── Spare \(0\)' 60 && ! scr | grep -q 'Groups — ' && grep -qxF "$(printf 'group\tSpare')" "$G" \
  && ok "the groups manager does one thing too, then back to the main screen" || no "$(cat "$G"; scr | head -14)"

section "reordering, and a sort that is not saved"
goto alpha
wait_gone 'loading usage' 60; [ -s "$T/seclog" ] && ok "the Keychain stub records the view's reads" || no "the stub recorded nothing"
: > "$T/seclog"
k ']'; wait_for 'done: claude-account order --in Clients beta alpha' 90
[ "$(grep $'^group\tClients\t' "$G" | cut -f3 | tr '\n' ' ')" = "beta alpha " ] && ok "] moves the account down inside its group, and saves it" || no "$(cat "$G")"
# It used to read every login back afterwards (1.1-1.6 s for 8 accounts), which is why [ ] lagged.
[ ! -s "$T/seclog" ] && ok "…without reading any login back, so the screen updates at once" || no "a reorder read the Keychain: $(wc -l < "$T/seclog") call(s)"
before=$(cat "$G")
k s; wait_for 'sort: most weekly left' 10 && ok "s switches to a temporary sort, named in the header" || no "$(scr | head -2)"
[ "$(cat "$G")" = "$before" ] && ok "…which writes nothing" || no "the sort wrote to groups.tsv"
k ']'; wait_for 'temporary sort' 10 && ok "arranging is refused while a temporary sort is showing" || no "$(scr | tail -3)"
k s; k s; k s; k s; wait_for 'sort: your order' 10 && ok "s round again comes back to your order" || no "$(scr | head -2)"

section "the two actions that cannot be undone ask for the name"
# gamma: floating. Its menu wraps: ↑ from the top lands on the last items (Forget, then Sign out).
goto gamma
k Enter; wait_for 'Sign out' 15; k Up; k Up; k Enter
wait_for 'type gamma to go ahead' 15 && ok "sign out asks you to type the profile name" || no "$(scr)"
lit "nope"; k Enter; wait_for "nothing changed: you typed 'nope'" 15 && ok "…and the wrong word changes nothing" || no "$(scr | tail -3)"
k Enter; wait_for 'Sign out' 15; k Up; k Up; k Enter; wait_for 'type gamma' 15; lit "gamma"; k Enter
wait_for "Signed out of profile 'gamma'" 60 && ok "…the right one signs it out" || no "$(scr)"
popup_close

section "forget, with its rules, by name"
goto beta
k Enter; wait_for 'Forget the profile' 15; k Up; k Enter
wait_for 'its 1 rule\(s\) are removed — type beta' 15 && ok "forget says it removes the rules too, and asks for the name" || no "$(scr)"
lit "beta"; k Enter; wait_for "Removed profile 'beta'" 60 && ok "…then forgets it" || no "$(scr)"
popup_close
[ ! -d "$T/profiles/beta" ] && ! grep -q 'beta' "$M" && ! grep -q 'beta' "$G" && ok "…profile, rule and group membership gone" || no "map: $(cat "$M") groups: $(cat "$G")"

section "the menu: adding a path"
k m; wait_for 'Add a path' 15 && ok "m opens the menu" || no "$(scr)"
k Down; k Enter; wait_for 'Bind a folder to which account' 15; k Enter
wait_for 'Folder to bind' 15; lit "$T/D"; k Enter; yes
wait_for 'claude-account add' 60 && popup_close
awk -F'\t' -v p="$T/D" '$1==p && $2=="alpha"{f=1} END{exit !f}' "$M" && ok "a folder bound from the menu lands in paths.map" || no "$(cat "$M")"
k m; wait_for 'Add a path' 15; k Down; k Enter; wait_for 'Bind a folder' 15; k Enter
wait_for 'Folder to bind' 15; lit "$T/no-such-folder"; k Enter; yes
wait_for 'failed \(exit [0-9]+\): claude-account add' 60 && ok "a command that fails says so, with its exit code and output" || no "$(scr)"
popup_close

section "rename, label, the printed views, help"
goto gamma
k Enter; wait_for 'Rename' 15; k Up; k Up; k Up; k Up; k Enter
wait_for 'New name for the profile gamma' 15; TM send-keys -t ui C-u; lit "delta"; k Enter; yes
wait_for "claude-account rename gamma delta" 60 && popup_close
[ -d "$T/profiles/delta" ] && [ ! -d "$T/profiles/gamma" ] && ok "rename from the view moves the profile" || no "$(ls "$T/profiles")"
k m; wait_for 'Show a printed view' 15; for _ in 1 2 3 4 5 6 7 8; do k Down; done; k Enter
wait_for 'Show the printed view' 15; k Enter
wait_for 'CLAUDE ACCOUNTS' 60 && ok "the printed overview opens inside the view" || no "$(scr)"
popup_close
k '?'; wait_for 'Keys' 10 && wait_for 'shift' 5 && ok "? shows the keys" || no "$(scr)"
popup_close

section "a sign-in leaves the screen for the terminal and comes back"
goto alpha
k Enter; wait_for 'Sign in again' 15
for _ in $(seq 1 7); do k Down; done; k Enter
wait_for 'How to sign in' 15 && ok "sign in again offers the browser, an email, SSO or Console" || no "$(scr)"
k Enter; wait_for 'press Enter to go back to the view' 60 && ok "…runs the real login in the terminal" || no "$(scr)"
scr | grep -q '\$ claude-account login alpha' && ok "…showing the command it ran" || no "$(scr)"
k Enter; wait_for 'this machine:' 30 && ok "…and Enter brings the view back" || no "$(scr)"

section "a small window, and quitting"
TM resize-window -t ui -x 80 -y 20; sleep 1
wait_for 'this machine' 15 && ok "it redraws in an 80×20 window" || no "$(scr)"
TM resize-window -t ui -x 160 -y 50; sleep 0.5
k q; wait_for 'UI-EXITED-0' 15 && ok "q quits cleanly (exit 0)" || no "$(scr | tail -3)"

section "plain claude-account in a terminal opens it"
TM kill-session -t ui >/dev/null 2>&1
TM new-session -d -s ui -x 160 -y 50 "env $SANDBOX_ENV bash '$CA'; echo UI-EXITED-\$?; sleep 600"
wait_for 'this machine:' 60 && ok "bare claude-account on a terminal is the view" || no "$(scr)"
k q; wait_for 'UI-EXITED-0' 15

section "the python macOS ships, without colour, without a UTF-8 locale"
if [ -x /usr/bin/python3 ] && /usr/bin/python3 -c 'import curses' 2>/dev/null; then
  mkdir -p "$T/py39"; ln -sf /usr/bin/python3 "$T/py39/python3"
  start "PATH='$T/py39:$PATH'" NO_COLOR=1     # later on the env line, so it wins
  wait_for 'this machine:' 120 && wait_for 'week +34%' 120 && ok "it runs on $(/usr/bin/python3 -c 'import sys;print("python "+sys.version.split()[0])') with NO_COLOR" || no "$(scr)"
  k Enter; wait_for 'Use it for' 15 && k Escape
  k q; wait_for 'UI-EXITED-0' 15 && ok "…menus and quit too" || no "$(scr | tail -3)"
else
  echo "  SKIP  no /usr/bin/python3 with curses here"
fi
start LANG=C LC_ALL=C
wait_for ' - this machine:' 60 && wait_for '^ -- Clients' 15 && wait_for '^ > ' 15 && ! scr | grep -q '[▶─█]' \
  && ok "in the C locale it draws plain ASCII instead of garbage" || no "$(scr | head -5)"
k q; wait_for 'UI-EXITED-0' 15

section "with no groups, [ and ] arrange the accounts all the same"
rm -f "$G"
start
wait_for 'this machine:' 60
# a group's heading carries its count, "── Clients (2) ──"; the detail panel's "── (global) ──" does not
scr | grep -qE '^ ── .+ \([0-9]+\) ─' && no "a section line with no groups: $(scr | head -6)" || ok "no groups, so no section lines"
read -r o1 o2 orest <<<"$(X _ui-groups | python3 -I -c 'import json,sys; print(" ".join(json.load(sys.stdin)["order"]))')"
goto "$o2"; k '['; wait_for 'done: claude-account order' 90
[ "$(grep $'^order\t' "$G" | cut -f2 | tr '\n' ' ')" = "$o2 $o1 ${orest:+$orest }" ] && ok "[ moves $o2 above $o1, saved as your own order" || no "$(cat "$G" 2>&1)"
! grep -q $'^group\t' "$G" && ok "…and makes no group" || no "$(cat "$G")"
k q; wait_for 'UI-EXITED-0' 15

finish
