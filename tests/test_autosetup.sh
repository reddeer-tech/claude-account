#!/bin/bash
# The automatic setup (1.2.8): every command keeps the Mac set up, once per version.
# Every run here uses its OWN home under $T, with the config folders NOT redirected (a redirect
# turns the automatic run off, which is exactly what keeps every other suite off the real Mac),
# a real zsh as the login shell (logged, so the stamp's "no work" can be proven), and stand-in
# editor tools under $T/apps. Nothing here can reach the real ~/bin, editors or shell profile.
. "$(dirname "$0")/lib.sh"
ca_sandbox; fail=0
unset CLAUDE_ACCOUNTS_MAP CLAUDE_ACCOUNTS_DIR CLAUDE_ACCOUNTS_NO_AUTOSETUP
export CA_EDITOR_APPS="$T/apps"
WANT_ITEM=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$REPO/vscode-status/package.json.in")
CAV=$(sed -n 's/^CA_VERSION="\([^"]*\)".*/\1/p' "$CA")
printf '#!/bin/bash\necho probe >> "%s/shell.log"\nexec /bin/zsh "$@"\n' "$T" > "$T/zsh"; chmod +x "$T/zsh"; export SHELL="$T/zsh"

# a home of its own: VS Code (Claude extension, JSONC settings with comments, a stand-in tool),
# Windsurf (no Claude extension: it must be left alone)
newhome(){
  export HOME="$T/$1"; mkdir -p "$HOME"
  local U="$HOME/Library/Application Support/Code/User"
  mkdir -p "$U" "$HOME/.vscode/extensions/anthropic.claude-code-2.1.301-darwin-arm64" \
           "$HOME/Library/Application Support/Windsurf/User" "$HOME/.windsurf/extensions"
  printf '{\n    // my editor settings\n    "editor.fontSize": 13, // big enough\n    "files.autoSave": "off",\n}\n' > "$U/settings.json"
  cp "$U/settings.json" "$T/$1.settings.orig"
  printf '{\n  "workbench.colorTheme": "x"\n}\n' > "$HOME/Library/Application Support/Windsurf/User/settings.json"
  local bin="$T/apps/Visual Studio Code.app/Contents/Resources/app/bin"; mkdir -p "$bin"
  cat > "$bin/code" <<'STUB'
#!/bin/bash
echo "$*" >> "$T_TOOLLOG"
exec python3 -I - "$HOME/.vscode/extensions" "$@" <<'PY'
import json, os, shutil, sys, zipfile
x, args = sys.argv[1], sys.argv[2:]
reg = os.path.join(x, "extensions.json"); entries = json.load(open(reg)) if os.path.exists(reg) else []
if args[0] == "--install-extension":
    z = zipfile.ZipFile(args[1]); pkg = json.loads(z.read("extension/package.json"))
    ident = "%s.%s" % (pkg["publisher"], pkg["name"]); dest = os.path.join(x, "%s-%s" % (ident, pkg["version"]))
    shutil.rmtree(dest, ignore_errors=True)
    for n in z.namelist():
        if n.startswith("extension/") and not n.endswith("/"):
            p = os.path.join(dest, n[10:]); os.makedirs(os.path.dirname(p), exist_ok=True); open(p, "wb").write(z.read(n))
    entries = [e for e in entries if e["identifier"]["id"] != ident]
    entries.append({"identifier": {"id": ident}, "version": pkg["version"], "location": {"$mid": 1, "path": dest, "scheme": "file"}, "relativeLocation": os.path.basename(dest)})
elif args[0] == "--uninstall-extension":
    for e in [e for e in entries if e["identifier"]["id"] == args[1]]: shutil.rmtree(e["location"]["path"], ignore_errors=True)
    entries = [e for e in entries if e["identifier"]["id"] != args[1]]
json.dump(entries, open(reg, "w"))
PY
STUB
  chmod +x "$bin/code"
}
export T_TOOLLOG="$T/tool.log"; : > "$T_TOOLLOG"
VSET(){ printf '%s' "$HOME/Library/Application Support/Code/User/settings.json"; }
key_in(){ python3 -I -c "$(sed -n '/^read -r -d "" JSONC_PY/,/^JSONCPY$/p' "$CA" | sed '1d;$d')" get "$1" claudeCode.claudeProcessWrapper; }
item_rec(){ python3 -I -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except OSError: d=[]
print(" ".join(e["version"] for e in d if e["identifier"]["id"]=="reddeer-tech.claude-account-status"))' "$HOME/.vscode/extensions/extensions.json"; }
login_claude(){ "$SHELL" -lc 'command -v claude' 2>/dev/null | tail -1; }
# Run claude-account the way a person does: a terminal on its input (the automatic run needs one).
# TX <stderr file> <args…>; stdout comes back with script's carriage returns and ^D stripped.
TX(){ local e="$1"; shift; : | script -q /dev/null bash -c 'exec 2>"$1"; shift; exec bash "$@"' _ "$e" "$CA" "$@" | tr -d '\r' | sed 's/^\^D//'; }
PRIV="$T/h1/.config/claude-accounts/backups"

section "a Mac that never ran setup: the first command does it, and says so"
newhome h1
out=$(TX "$T/err" list); err=$(cat "$T/err")
grep -q 'claude-account set itself up:' <<<"$err" && ok "it says it set itself up — on stderr, so the command's own output stays clean" || no "$err"
! grep -q 'set itself up' <<<"$out" && ok "…and nothing of it on stdout" || no "stdout: $out"
grep -q 'undo all of it: claude-account uninstall' <<<"$err" && ok "…with how to undo all of it" || no "$err"
grep -q 'claude-accounts' "$HOME/bin/claude" 2>/dev/null && cmp -s "$HOME/bin/claude" "$REPO/bin/claude-shim" && [ -x "$HOME/bin/claude-vscode-wrapper" ] && ok "the launchers are in ~/bin" || no "$(ls -la "$HOME/bin" 2>&1)"
cmp -s "$HOME/.config/claude-accounts/resolve.sh" "$REPO/libexec/resolve.sh" && ok "the resolver is in ~/.config/claude-accounts" || no "no resolver"
grep -qx "version=$CAV" "$HOME/.config/claude-accounts/.setup-state" && ok "the stamp records $CAV" || no "$(cat "$HOME/.config/claude-accounts/.setup-state" 2>&1)"
grep -q '>>> claude-account >>>' "$HOME/.zprofile" 2>/dev/null && [ "$(login_claude)" = "$HOME/bin/claude" ] && ok "PATH: a marked block in ~/.zprofile, and a real zsh login shell now finds the launcher first" || no "$(login_claude); $(cat "$HOME/.zprofile" 2>&1)"
[ "$(key_in "$(VSET)")" = "present	$HOME/bin/claude-vscode-wrapper" ] && ok "VS Code: the wrapper setting was written" || no "$(key_in "$(VSET)")"
grep -q '// my editor settings' "$(VSET)" && grep -q '// big enough' "$(VSET)" && ok "…its comments kept" || no "$(cat "$(VSET)")"
ls "$PRIV"/*settings.json.* >/dev/null 2>&1 && ok "…after a backup" || no "no backup in $PRIV"
[ "$(stat -f %Lp "$PRIV")" = 700 ] && [ "$(stat -f %Lp "$(ls "$PRIV"/*settings.json.* | head -1)")" = 600 ] && ok "…kept private: folder 700, files 600 (settings and profiles can hold tokens)" || no "$(ls -la "$PRIV")"
! grep -q 'claudeProcessWrapper' "$HOME/Library/Application Support/Windsurf/User/settings.json" && ok "Windsurf, without the Claude extension, is left alone" || no "Windsurf was edited"
[ "$(item_rec)" = "$WANT_ITEM" ] && ok "VS Code: the status bar item is installed ($WANT_ITEM), through the editor's tool" || no "$(item_rec); $(cat "$T_TOOLLOG")"

section "every later command: one file read, nothing else"
[ -s "$T/shell.log" ] && [ -s "$T_TOOLLOG" ] && ok "(the first run's login-shell probes and tool call were logged — so the next check is not vacuous)" || no "nothing logged: the checks below would prove nothing"
: > "$T/shell.log"; : > "$T_TOOLLOG"
out=$(TX "$T/err" list)
[ ! -s "$T/err" ] && [ ! -s "$T/shell.log" ] && [ ! -s "$T_TOOLLOG" ] && ok "no output, no login-shell probe, no editor tool" || no "err: $(cat "$T/err"); probes: $(wc -l < "$T/shell.log"); tool: $(cat "$T_TOOLLOG")"

section "help, version, the status line and the view's data calls never set anything up"
newhome h2; : > "$T/shell.log"
for v in --help --version statusline _ui-state; do TX /dev/null $v >/dev/null; done
[ ! -e "$HOME/bin/claude" ] && [ ! -e "$HOME/.config/claude-accounts/.setup-state" ] && [ ! -e "$HOME/.zprofile" ] && ok "nothing placed by --help, --version, statusline or _ui-state" || no "$(ls -la "$HOME" "$HOME/bin" 2>&1 | head)"

section "after an upgrade: the first command brings it up to date, once"
export HOME="$T/h1"
printf '\n# an older launcher\n' >> "$HOME/bin/claude"
python3 -I - "$HOME/.config/claude-accounts/.setup-state" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read().splitlines()
open(p, "w").write("\n".join(("version=0.0.1" if l.startswith("version=") else l) for l in s) + "\n")
PY
: > "$T_TOOLLOG"; s1=$(cat "$(VSET)"); z1=$(cat "$HOME/.zprofile")
TX "$T/err" list >/dev/null
grep -q "claude-account updated itself to $CAV" "$T/err" && grep -q 'Updated the launchers' "$T/err" && ok "it says it updated itself, and what" || no "$(cat "$T/err")"
cmp -s "$HOME/bin/claude" "$REPO/bin/claude-shim" && ok "the launcher is current again" || no "launcher still old"
[ ! -s "$T_TOOLLOG" ] && [ "$(cat "$(VSET)")" = "$s1" ] && [ "$(cat "$HOME/.zprofile")" = "$z1" ] && ok "…and nothing else is touched: the item, the settings and the profile were already right" || no "tool: $(cat "$T_TOOLLOG")"

section "removed by hand: it stays removed, and setup puts it back"
python3 -I -c "$(sed -n '/^read -r -d "" JSONC_PY/,/^JSONCPY$/p' "$CA" | sed '1d;$d')" del "$(VSET)" claudeCode.claudeProcessWrapper "$HOME/bin/claude-vscode-wrapper" "$T/bk" T >/dev/null
python3 -I -c "$(sed -n '/^read -r -d "" PROFILE_PY/,/^PROFPY$/p' "$CA" | sed '1d;$d')" del "$HOME/.zprofile" "$T/bk" >/dev/null
"$T/apps/Visual Studio Code.app/Contents/Resources/app/bin/code" --uninstall-extension reddeer-tech.claude-account-status
sed -i '' "s/^version=.*/version=0.0.1/" "$HOME/.config/claude-accounts/.setup-state"; : > "$T_TOOLLOG"
TX "$T/err" list >/dev/null
[ "$(key_in "$(VSET)")" = absent ] && ! grep -q 'claude-account' "$HOME/.zprofile" 2>/dev/null && [ -z "$(item_rec)" ] && [ ! -s "$T_TOOLLOG" ] \
  && ok "after the next upgrade the editor line, the PATH block and the item all stay removed" || no "key: $(key_in "$(VSET)"); profile: $(cat "$HOME/.zprofile" 2>&1); item: $(item_rec)"
out=$(X setup 2>&1)
[ "$(key_in "$(VSET)")" = "present	$HOME/bin/claude-vscode-wrapper" ] && grep -q '>>> claude-account >>>' "$HOME/.zprofile" && [ "$(item_rec)" = "$WANT_ITEM" ] \
  && ok "claude-account setup puts all three back" || no "$out"
grep -q 'added the wrapper setting' <<<"$out" && grep -q 'first on PATH' <<<"$out" && grep -q 'installed the Claude Account status bar item' <<<"$out" && ok "…and says each one" || no "$out"
dr=$(X doctor --no-refresh 2>&1)
grep -q "automatic setup on (last checked for $CAV)" <<<"$dr" && ok "doctor: automatic setup on" || no "$(grep -i 'automatic' <<<"$dr")"

section "uninstall takes it all out and keeps rules, groups and logins"
mkdir -p "$T/projA"; X add "$T/projA" keepme >/dev/null 2>&1
out=$(X uninstall 2>&1)
[ ! -e "$HOME/bin/claude" ] && [ ! -e "$HOME/bin/claude-vscode-wrapper" ] && ok "the launchers are gone" || no "$(ls "$HOME/bin")"
cmp -s "$(VSET)" "$T/h1.settings.orig" && ok "VS Code's settings.json is back exactly as it was, comments and all" || no "$(diff "$T/h1.settings.orig" "$(VSET)")"
[ ! -e "$HOME/.zprofile" ] && ok "the ~/.zprofile setup created is gone again" || no "$(cat "$HOME/.zprofile")"
[ -z "$(item_rec)" ] && ok "the status bar item is uninstalled, through the editor's tool" || no "$(item_rec)"
grep -q "$T/projA" "$HOME/.config/claude-accounts/paths.map" && [ -d "$HOME/.config/claude-accounts/profiles/keepme" ] && ok "rules and profiles are kept" || no "$(cat "$HOME/.config/claude-accounts/paths.map")"
grep -q 'Put it all back with: claude-account setup' <<<"$out" && ok "…and it says how to put it all back" || no "$out"
TX /dev/null list >/dev/null; [ ! -e "$HOME/bin/claude" ] && ok "after uninstall, commands no longer set anything up" || no "the launcher came back"
grep -q 'automatic setup is off since claude-account uninstall' <<<"$(X doctor --no-refresh 2>&1)" && ok "doctor says it is off, and how to turn it back on" || no "doctor"
X setup >/dev/null 2>&1; [ -e "$HOME/bin/claude" ] && ! grep -qx 'auto=off' "$HOME/.config/claude-accounts/.setup-state" && ok "setup turns it back on" || no "$(cat "$HOME/.config/claude-accounts/.setup-state")"

section "a claude that is not ours is never overwritten"
newhome h3; mkdir -p "$HOME/bin"; printf '#!/bin/sh\necho the real claude\n' > "$HOME/bin/claude"; chmod +x "$HOME/bin/claude"; cp "$HOME/bin/claude" "$T/h3.claude"
TX "$T/err" list >/dev/null
cmp -s "$HOME/bin/claude" "$T/h3.claude" && grep -q 'is not claude-account.s launcher — left alone' "$T/err" && ok "it says so and leaves it alone" || no "$(cat "$T/err")"
cmp -s "$(VSET)" "$T/h3.settings.orig" && ok "…and points no editor at a wrapper that is not there: settings.json untouched" || no "$(cat "$(VSET)")"
TX "$T/err" list >/dev/null; [ ! -s "$T/err" ] && ok "…and does not repeat that on every command" || no "$(cat "$T/err")"
grep -q 'the last setup could not finish everything' <<<"$(X doctor --no-refresh 2>&1)" && grep -q 'left alone' <<<"$(X doctor --no-refresh 2>&1)" && ok "doctor keeps showing what it could not do" || no "$(X doctor --no-refresh 2>&1 | grep -A2 'could not')"
newhome h3b; mkdir -p "$HOME/bin"; printf '#!/bin/sh\n# not ours, though it mentions claude-accounts\nexec /usr/local/bin/claude "$@"\n' > "$HOME/bin/claude"; cp "$HOME/bin/claude" "$T/h3b.claude"
TX /dev/null list >/dev/null; cmp -s "$HOME/bin/claude" "$T/h3b.claude" && ok "a file that merely mentions claude-accounts is not ours: left alone" || no "it was overwritten"

section "never automatic in a redirected config, or with the switch set"
newhome h4; CLAUDE_ACCOUNTS_MAP="$T/h4map" TX /dev/null list >/dev/null; [ ! -e "$HOME/bin/claude" ] && ok "a redirected rules file (every test sandbox) turns it off" || no "it ran"
CLAUDE_ACCOUNTS_DIR="$T/h4prof" TX /dev/null list >/dev/null; [ ! -e "$HOME/bin/claude" ] && ok "so does a redirected profiles folder" || no "it ran"
CLAUDE_ACCOUNTS_NO_AUTOSETUP=1 TX /dev/null list >/dev/null; [ ! -e "$HOME/bin/claude" ] && ok "and CLAUDE_ACCOUNTS_NO_AUTOSETUP=1" || no "it ran"
CI=true TX /dev/null list >/dev/null; [ ! -e "$HOME/bin/claude" ] && ok "and CI" || no "it ran under CI"
X list >/dev/null 2>&1; [ ! -e "$HOME/bin/claude" ] && ok "and a script with no terminal on its input" || no "it ran without a terminal"
TX /dev/null list >/dev/null; [ -e "$HOME/bin/claude" ] && ok "(the same home, from a terminal, does get set up — so the checks above are not vacuous)" || no "it never runs"

section "where the launchers go: never from BINDIR, and never a folder that is not safe"
newhome h6; mkdir -p "$T/evil"
BINDIR="$T/evil" TX /dev/null list >/dev/null
[ -e "$HOME/bin/claude" ] && [ -z "$(ls -A "$T/evil")" ] && ok "the automatic run ignores BINDIR from the environment (a project's .envrc, a CI job)" || no "evil: $(ls "$T/evil"); bin: $(ls "$HOME/bin" 2>&1)"
for bad in "bin" $'/tmp/a\nb'; do
  newhome h7; out=$(CLAUDE_ACCOUNTS_BINDIR="$bad" X setup 2>&1); rc=$?
  [ $rc = 1 ] && grep -q 'will not put the launchers in' <<<"$out" && [ ! -e "$HOME/.zprofile" ] && ! grep -q claudeProcessWrapper "$(VSET)" \
    && ok "setup refuses $(printf '%q' "$bad"): $(grep -o 'it [a-z ]*' <<<"$out" | head -1), and writes no PATH block or editor line" || no "rc=$rc: $out"
  rm -rf "$T/h7"
done
mkdir -p "$T/repo"; git -C "$T/repo" init -q; newhome h8
out=$(CLAUDE_ACCOUNTS_BINDIR="$T/repo/bin" X setup 2>&1); [ $? = 1 ] && grep -q 'inside a git repository' <<<"$out" && [ ! -e "$T/repo/bin" ] && ok "setup refuses a folder inside a git repository" || no "$out"
mkdir -p "$T/shared"; chmod 777 "$T/shared"; newhome h9
out=$(CLAUDE_ACCOUNTS_BINDIR="$T/shared" X setup 2>&1); [ $? = 1 ] && grep -q 'can be written by other users' <<<"$out" && [ -z "$(ls -A "$T/shared")" ] && ok "setup refuses a folder other users can write to" || no "$out"
mkdir -p "$T/mybin"; chmod 755 "$T/mybin"; newhome h10
out=$(CLAUDE_ACCOUNTS_BINDIR="$T/mybin" X setup 2>&1); is_ours=$(head -c 400 "$T/mybin/claude" 2>/dev/null | grep -c '^# Per-path Claude account routing')
[ "$is_ours" = 1 ] && [ "$(head -1 "$HOME/.config/claude-accounts/.bindir")" = "$T/mybin" ] && ok "setup honours CLAUDE_ACCOUNTS_BINDIR for a safe folder of your own, and records it" || no "$out"
newhome h11; mkdir -p "$HOME/.config/claude-accounts"; printf 'bin\n' > "$HOME/.config/claude-accounts/.bindir"
TX "$T/err" list >/dev/null
[ ! -e "$HOME/bin/claude" ] && [ ! -e "$HOME/.zprofile" ] && grep -q 'will not put the launchers in bin: it is not an absolute path' "$T/err" && ok "a tampered record of the folder is refused too, and said" || no "$(cat "$T/err")"

section "the lock: a dead holder is taken over, a live one is left alone"
newhome h12; mkdir -p "$HOME/.config/claude-accounts/.setup.lock"; echo 99999 > "$HOME/.config/claude-accounts/.setup.lock/pid"
TX /dev/null list >/dev/null; [ -e "$HOME/bin/claude" ] && [ ! -d "$HOME/.config/claude-accounts/.setup.lock" ] && ok "a lock whose holder is gone (pid 99999) is taken over, then released" || no "$(ls -la "$HOME/.config/claude-accounts")"
newhome h13; mkdir -p "$HOME/.config/claude-accounts/.setup.lock"; sleep 300 & live=$!; echo $live > "$HOME/.config/claude-accounts/.setup.lock/pid"
TX /dev/null list >/dev/null; [ ! -e "$HOME/bin/claude" ] && [ "$(cat "$HOME/.config/claude-accounts/.setup.lock/pid")" = "$live" ] && ok "a lock whose holder is alive is left alone, and this command just carries on" || no "it ran under a live lock"
kill $live 2>/dev/null

section "two commands at once: one sets up, both work"
newhome h5
TX "$T/e1" list >"$T/o1" & p1=$!; TX "$T/e2" list >"$T/o2" & p2=$!; wait $p1; r1=$?; wait $p2; r2=$?
[ $r1 = 0 ] && [ $r2 = 0 ] && [ "$(grep -c 'set itself up' "$T/e1" "$T/e2" | awk -F: '{s+=$2} END{print s}')" = 1 ] && ok "both exit 0, one of them did the setup" || no "rc $r1/$r2; $(cat "$T/e1" "$T/e2")"
grep -q '>>> claude-account >>>' "$HOME/.zprofile" && [ "$(grep -c '>>> claude-account >>>' "$HOME/.zprofile")" = 1 ] && [ ! -d "$HOME/.config/claude-accounts/.setup.lock" ] && ok "one PATH block, and no lock left behind" || no "$(cat "$HOME/.zprofile")"

finish
