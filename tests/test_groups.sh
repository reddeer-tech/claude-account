#!/bin/bash
# Groups and order (1.2.0): the `group` and `order` commands, what they write, and the four
# printed views that follow them. The full-screen view has its own file, test_ui.sh.
. "$(dirname "$0")/lib.sh"
ca_sandbox; fail=0
G="$T/groups.tsv"
mkdir -p "$T/A" "$T/B" "$T/C"
X add "$T/A" alpha >/dev/null 2>&1; X add "$T/B" beta >/dev/null 2>&1; X add "$T/C" gamma >/dev/null 2>&1
sign alpha; sign beta; sign gamma; sign_global
row(){ grep -qxF "$(printf "$@")" "$G"; }

section "nothing changes until you arrange"
[ ! -f "$G" ] && ok "no groups file until a group or an order is made" || no "a groups file appeared on its own"
X overview --no-refresh 2>&1 | grep -q '══' && no "section headings with no groups" || ok "overview has no sections without groups"
X list --no-refresh 2>&1 | grep -q '══' && no "list grew sections" || ok "…nor list"
X group 2>&1 | grep -q 'no groups yet' && ok "group lists nothing, and says how to start" || no "$(X group 2>&1)"

section "group: add, several groups, remove"
out=$(X group Clients alpha beta 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'Clients: alpha, beta' <<<"$out" && ok "group creates the group and adds both" || no "rc=$rc $out"
row 'group\tClients\talpha' && row 'group\tClients\tbeta' && ok "…one line per member, in the order given" || no "$(cat "$G")"
X group clients gamma >/dev/null 2>&1; row 'group\tClients\tgamma' && ok "group names match whatever the case, and keep the first spelling" || no "$(cat "$G")"
grep -q 'group	clients' "$G" && no "a second spelling made a second group" || ok "…with no second group"
X group Personal global >/dev/null 2>&1; row 'group\tPersonal\t(global)' && ok "'global' is stored as (global), which no profile can be called" || no "$(cat "$G")"
X group Personal alpha >/dev/null 2>&1; row 'group\tPersonal\talpha' && row 'group\tClients\talpha' && ok "one account can be in two groups" || no "$(cat "$G")"
out=$(X group Clients alpha 2>&1); grep -q 'already in it' <<<"$out" && ok "adding a member twice changes nothing, and says so" || no "$out"
X group Clients --remove beta >/dev/null 2>&1; row 'group\tClients\tbeta' && no "remove left beta in" || ok "--remove takes it out"
before=$(cat "$G")
X group Clients --remove beta >/dev/null 2>&1; [ $? = 1 ] && ok "removing a non-member is refused (exit 1)" || no "removing a non-member was accepted"
X group Clients nosuch >/dev/null 2>&1; [ $? = 1 ] && [ "$(cat "$G")" = "$before" ] && ok "an unknown account is refused, the file untouched" || no "unknown account accepted"
X group Nope --remove alpha >/dev/null 2>&1; [ $? = 1 ] && ok "an unknown group is refused" || no "unknown group accepted"
X group 'a/b' alpha >/dev/null 2>&1; [ $? = 2 ] && ok "a group name with a slash is refused (exit 2)" || no "bad name accepted"
X group Ungrouped alpha >/dev/null 2>&1; [ $? = 2 ] && ok "'ungrouped' is reserved for the last section" || no "ungrouped accepted"
X group "$(printf 'x\ty')" alpha >/dev/null 2>&1; [ $? = 2 ] && ok "a TAB in a group name is refused — it would split the file" || no "TAB accepted"
[ "$(cat "$G")" = "$before" ] && ok "…and none of the refusals wrote anything" || no "a refusal wrote: $(diff <(echo "$before") "$G")"

section "group: new, rename, delete"
X group --new Spare >/dev/null 2>&1; row 'group\tSpare' && ok "--new makes an empty group" || no "$(cat "$G")"
X group --new spare >/dev/null 2>&1; [ $? = 1 ] && ok "…and refuses one that exists, whatever the case" || no "duplicate group accepted"
X group --rename Spare Later >/dev/null 2>&1; row 'group\tLater' && ok "--rename renames it" || no "$(cat "$G")"
X group --rename Later Clients >/dev/null 2>&1; [ $? = 1 ] && ok "…but not onto a group that exists" || no "rename onto an existing group accepted"
X group --delete Later >/dev/null 2>&1; grep -q 'Later' "$G" && no "--delete left it" || ok "--delete removes the group"
X group --delete Clients >/dev/null 2>&1; [ -d "$T/profiles/alpha" ] && grep -q "alpha" "$T/paths.map" && ok "…and never touches its accounts" || no "delete touched an account"
X group Clients alpha gamma >/dev/null 2>&1
ls "$T/bk"/groups.tsv.* >/dev/null 2>&1 && ok "every change backs the file up first" || no "no groups backups"

section "order: overall, inside a group, the groups themselves"
X order gamma alpha >/dev/null 2>&1
[ "$(grep '^order' "$G" | cut -f2 | head -2 | tr '\n' ' ')" = "gamma alpha " ] && ok "order puts the named accounts first, in that order" || no "$(grep '^order' "$G")"
X order --in Clients gamma >/dev/null 2>&1
[ "$(grep $'^group\tClients\t' "$G" | cut -f3 | tr '\n' ' ')" = "gamma alpha " ] && ok "order --in reorders one group" || no "$(grep Clients "$G")"
X order --in Clients beta >/dev/null 2>&1; [ $? = 1 ] && ok "…and refuses an account that is not in it" || no "order --in accepted a non-member"
X order --groups Clients Personal >/dev/null 2>&1
[ "$(grep '^group' "$G" | cut -f2 | uniq | tr '\n' ' ')" = "Clients Personal " ] && ok "order --groups orders the sections" || no "$(grep '^group' "$G")"
X order --reset >/dev/null 2>&1; grep -q '^order' "$G" && no "--reset left the order" || ok "order --reset clears your order"
grep -q $'^group\tClients' "$G" && ok "…and keeps the groups" || no "--reset dropped the groups"
X order gamma beta >/dev/null 2>&1

section "the views follow your groups"
ov=$(X overview --no-refresh 2>&1)
heads=$(grep '══' <<<"$ov" | sed 's/[═ ]*$//; s/^ *══ //' | tr '\n' '|')
[ "$heads" = "Clients|Personal|Ungrouped|" ] && ok "overview: one section per group, in your order, then Ungrouped" || no "sections: $heads"
grep -q '^  this machine: (global)' <<<"$ov" && ok "…headed by the account this machine is on" || no "$(head -5 <<<"$ov")"
[ "$(grep -c '── alpha ' <<<"$ov")" = 2 ] && ok "…an account in two groups has a card in each" || no "alpha cards: $(grep -c '── alpha ' <<<"$ov")"
cards=$(awk '/══/{s=$2} /── [a-z(]/{print s":"$2}' <<<"$ov" | tr '\n' ' ')
[ "$cards" = "Clients:gamma Clients:alpha Personal:(global) Personal:alpha Ungrouped:beta " ] && ok "…each group in its own order, the rest in yours" || no "cards: $cards"
: > "$T_CURLED"; X overview --no-refresh >/dev/null 2>&1
[ "$(grep -c "^args:" "$T_CURLED")" = 4 ] && ok "…and fetches each account's usage once, however often it is shown" || no "usage calls: $(grep -c "^args:" "$T_CURLED")"
pr=$(X profiles --no-refresh 2>&1)
[ "$(grep '══' <<<"$pr" | sed 's/[═ ]*$//; s/^ *══ //' | tr '\n' '|')" = "Clients|Personal|Ungrouped|" ] && ok "profiles: the same sections" || no "$(grep '══' <<<"$pr")"
awk '/══ Personal/{p=1} /══ Ungrouped/{p=0} p' <<<"$pr" | grep -q '(global)' && ok "…with (global) placed like any other account" || no "$pr"
X pause beta >/dev/null 2>&1
li=$(X list --no-refresh 2>&1)
[ "$(grep -c "$T/A" <<<"$li")" = 1 ] && ok "list: a path appears once, even when its account is in two groups" || no "$li"
awk '/══ Clients/{p=1} /══ Personal/{p=0} p' <<<"$li" | grep -q "$T/A" && ok "…under the first group of the account it uses" || no "$li"
awk '/══ Personal/{p=1} /══ Ungrouped/{p=0} p' <<<"$li" | grep -q "$T/B" && ok "…a paused path sits with (global), the account it uses meanwhile" || no "$li"
ve=$(X verify --no-refresh 2>&1)
[ "$(grep -c '══' <<<"$ve")" -ge 2 ] && [ "$(grep -c "$T/A" <<<"$ve")" = 1 ] && ok "verify: the same sections, each path once" || no "$ve"
X resume beta >/dev/null 2>&1

section "rename, forget, export and import carry the groups"
X rename gamma delta >/dev/null 2>&1
row 'group\tClients\tdelta' && ! grep -q gamma "$G" && ok "rename follows the profile into every group and the order" || no "$(cat "$G")"
X forget delta --force >/dev/null 2>&1
grep -q delta "$G" && no "forget left it in the groups" || ok "forget takes it out of every group and the order"
exp=$(X export 2>&1)
grep -qxF "$(printf 'group\tClients\talpha')" <<<"$exp" && grep -q $'^order\t' <<<"$exp" && ok "export carries the groups and the order" || no "$exp"
printf '%s\n' "$exp" > "$T/export.tsv"
: > "$G"; rm -f "$G"
X import "$T/export.tsv" >/dev/null 2>&1
row 'group\tClients\talpha' && row 'group\tPersonal\t(global)' && ok "import puts them back" || no "$(cat "$G" 2>&1)"

section "the full-screen view's data"
st=$(X _ui-state 2>&1)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); a={x["name"]:x for x in d["accounts"]}; assert "(global)" in a and "alpha" in a; assert d["machine"]=="(global)"; assert [s["section"] for s in d["layout"]][:2]==["Clients","Personal"]; assert a["alpha"]["paths"][0]["state"]=="active"' "$st" \
  && ok "_ui-state: accounts, the machine account, paths and the layout, as JSON" || no "$st"
grep -q 'stub' <<<"$st" && no "_ui-state printed the access token" || ok "…and never the credential itself"
us=$(X _ui-usage alpha 2>&1)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); k=[r["kind"] for r in d["rows"]]; assert k==["session","weekly_all"], k; assert d["rows"][0]["pct"]==40' "$us" \
  && ok "_ui-usage: the usage rows as JSON" || no "$us"
mkdir -p "$T/profiles/nobody"
us=$(X _ui-usage nobody 2>&1)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["rows"]==[] and "not signed in" in d["note"]' "$us" \
  && ok "…and says so, rather than an empty account, when there is no login" || no "$us"

section "the usage call keeps the token off the command line"
: > "$T_CURLED"; X usage alpha >/dev/null 2>&1
grep '^args:' "$T_CURLED" | grep -q 'Bearer' && no "the token was on curl's argv: $(cat "$T_CURLED")" || ok "curl's arguments carry no token — ps cannot see it"
grep -q 'stdin:Authorization: Bearer stub' "$T_CURLED" && ok "…it reaches curl on stdin instead" || no "no header on stdin: $(cat "$T_CURLED")"

section "nothing is written outside the sandbox"
# GROUPS is a bash builtin (the gid list) that ignores assignment: the first draft named its
# file variable that, and wrote the groups file to "./20" — the current directory, the repo.
[ ! -e "$PWD/$(id -g)" ] && [ -f "$T/groups.tsv" ] && ok "the groups file lives in the sandbox, not in ./$(id -g)" || no "a file named after the gid appeared in $PWD"

section "every install layout finds the full-screen view"
# Homebrew: a symlink in bin/ to Cellar/<v>/bin, with ui.py in Cellar/<v>/libexec. With no
# terminal, `ui` says it needs one (exit 2) only AFTER finding ui.py — not found is exit 1.
mkdir -p "$T/cellar/bin" "$T/cellar/libexec" "$T/linkbin"
cp "$CA" "$T/cellar/bin/claude-account"; cp "$REPO/libexec/resolve.sh" "$REPO/libexec/ui.py" "$T/cellar/libexec/"
ln -s "$T/cellar/bin/claude-account" "$T/linkbin/claude-account"
env -u CLAUDE_ACCOUNTS_LIB HOME="$T/home-none" bash "$T/linkbin/claude-account" ui </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "Homebrew layout: found through the bin/ symlink (bin/../libexec/ui.py)" || no "rc=$rc"
rm -f "$T/cellar/libexec/ui.py"
env -u CLAUDE_ACCOUNTS_LIB HOME="$T/home-none" bash "$T/linkbin/claude-account" ui </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "…and a missing ui.py is said plainly (exit 1), not a python traceback" || no "rc=$rc"
grep -q 'libexec/ui.py' "$REPO/install.sh" && ok "install.sh copies ui.py beside the resolver" || no "install.sh does not install ui.py"

section "plain claude-account, with no terminal, still prints the rules"
X 2>&1 </dev/null | grep -q 'PATH RULES' && ok "piped, bare claude-account is list, as before" || no "$(X </dev/null 2>&1 | head -3)"
X ui </dev/null >/dev/null 2>&1; [ $? = 2 ] && ok "claude-account ui with no terminal says it needs one (exit 2)" || no "ui ran without a terminal"

finish
