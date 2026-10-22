#!/bin/bash
# The VS Code status bar item (1.2.7): installed through each editor's OWN tool from a real
# .vsix, so the editor's record (extensions.json) stays right. Before 1.2.7 setup copied a folder
# named with the CLI version; VS Code kept pointing at the first one and showed the item as
# invalid ("Unable to read file …-1.1.8/package.json", measured 2026-10-22).
# HOME and the editors' apps are the sandbox's: nothing here can reach a real editor.
. "$(dirname "$0")/lib.sh"
ca_sandbox; fail=0
export HOME="$T/home" CA_EDITOR_APPS="$T/apps"
WANT=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$REPO/vscode-status/package.json.in")
ID=reddeer-tech.claude-account-status

# <app name> <tool> <extensions dir under HOME> <settings dir name>: an editor with the Claude
# extension, and a stand-in for its tool that installs a .vsix the way the editor does
mk_editor(){
  mkdir -p "$HOME/Library/Application Support/$4/User" "$HOME/$3/extensions/anthropic.claude-code-2.1.301-darwin-arm64"
  local bin="$T/apps/$1.app/Contents/Resources/app/bin"; mkdir -p "$bin"
  cat > "$bin/$2" <<STUB
#!/bin/bash
echo "\$*" >> "$T/tool-$2.log"
[ -n "\${STUB_FAIL:-}" ] && { echo "Failed Installing Extensions: stub refused" >&2; exit 1; }
exec python3 -I - "$HOME/$3/extensions" "$T" "\$@" <<'PY'
import json, os, shutil, sys, zipfile
x, t, args = sys.argv[1], sys.argv[2], sys.argv[3:]
reg = os.path.join(x, "extensions.json")
entries = json.load(open(reg)) if os.path.exists(reg) else []
if args[0] == "--install-extension":
    shutil.copy(args[1], os.path.join(t, "last.vsix"))
    z = zipfile.ZipFile(args[1]); pkg = json.loads(z.read("extension/package.json"))
    ident = "%s.%s" % (pkg["publisher"], pkg["name"]); dest = os.path.join(x, "%s-%s" % (ident, pkg["version"]))
    shutil.rmtree(dest, ignore_errors=True)
    for n in z.namelist():
        if n.startswith("extension/") and not n.endswith("/"):
            p = os.path.join(dest, n[len("extension/"):]); os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "wb").write(z.read(n))
    entries = [e for e in entries if e["identifier"]["id"] != ident]
    entries.append({"identifier": {"id": ident}, "version": pkg["version"],
                    "location": {"\$mid": 1, "path": dest, "scheme": "file"}, "relativeLocation": os.path.basename(dest)})
elif args[0] == "--uninstall-extension":
    for e in [e for e in entries if e["identifier"]["id"] == args[1]]:
        shutil.rmtree(e["location"]["path"], ignore_errors=True)
    entries = [e for e in entries if e["identifier"]["id"] != args[1]]
json.dump(entries, open(reg, "w"))
PY
STUB
  chmod +x "$bin/$2"
}
reg_of(){ python3 -I -c '
import json, os, sys
try: d = json.load(open(sys.argv[1] + "/extensions.json"))
except OSError: d = []
print(" ".join("%s@%s:%s" % (e["identifier"]["id"], e["version"], "ok" if os.path.isdir(e["location"]["path"]) else "MISSING") for e in d))' "$1"; }

section "the state VS Code was in: its record names a folder that is gone"
mk_editor "Visual Studio Code" code .vscode Code
X="$HOME/.vscode/extensions"
# what setup 1.2.6 left: the record still on 1.1.8, whose folder it had replaced with 1.2.6
mkdir -p "$X/$ID-1.2.6"; printf '{"name":"claude-account-status","version":"1.2.6"}' > "$X/$ID-1.2.6/package.json"
printf '[{"identifier":{"id":"%s"},"version":"1.1.8","location":{"$mid":1,"path":"%s","scheme":"file"},"relativeLocation":"%s"}]' \
  "$ID" "$X/$ID-1.1.8" "$ID-1.1.8" > "$X/extensions.json"
st=$(X vscode-status status 2>&1)
grep -q 'VS Code: the editor.s record points at a folder that is gone (1.1.8)' <<<"$st" && ok "status says the editor's record points at a folder that is gone" || no "$st"
dr=$(X doctor --no-refresh 2>&1)
grep -q 'vscode-status item needs reinstalling' <<<"$dr" && ok "doctor warns, instead of 'installed and current'" || no "$(grep -i vscode <<<"$dr")"

section "install goes through the editor's own tool, from a real .vsix"
out=$(X vscode-status install 2>&1)
[ -s "$T/tool-code.log" ] && ok "(the stand-in tool records — so the checks below are not vacuous)" || no "the stand-in was never run: $out"
grep -qE -- "--install-extension .*claude-account-status-$WANT\.vsix --force" "$T/tool-code.log" && ok "it ran: code --install-extension <the .vsix> --force" || no "$(cat "$T/tool-code.log")"
[ "$(reg_of "$X")" = "$ID@$WANT:ok" ] && ok "the editor's record now names $WANT, and its folder is there" || no "$(reg_of "$X")"
cmp -s "$X/$ID-$WANT/extension.js" "$REPO/vscode-status/extension.js" && ok "…with the item's code, byte for byte" || no "$(ls "$X")"
[ ! -e "$X/$ID-1.2.6" ] && ok "the folder an older setup copied in is gone" || no "$(ls "$X")"
grep -q "installed the Claude Account status bar item ($WANT)" <<<"$out" && ok "…and it says so" || no "$out"
grep -q "VS Code: installed ($WANT)" <<<"$(X vscode-status status 2>&1)" && ok "status agrees" || no "$(X vscode-status status 2>&1)"
python3 -I - "$T/last.vsix" "$WANT" <<'PY' && ok "the .vsix is a real package: manifest, content types, and the item under extension/" || no "the .vsix is malformed"
import json, re, sys, zipfile
z = zipfile.ZipFile(sys.argv[1]); n = set(z.namelist())
assert {"[Content_Types].xml", "extension.vsixmanifest", "extension/package.json", "extension/extension.js"} <= n, n
m = z.read("extension.vsixmanifest").decode()
assert re.search(r'<Identity [^>]*Id="claude-account-status"[^>]*Version="%s"[^>]*Publisher="reddeer-tech"' % re.escape(sys.argv[2]), m), m
assert json.loads(z.read("extension/package.json"))["version"] == sys.argv[2]
PY

section "setup does nothing when the editor already has this version"
before=$(wc -l < "$T/tool-code.log")
out=$(X vscode-status install --only-with-claude 2>&1)
[ "$(wc -l < "$T/tool-code.log")" = "$before" ] && [ -z "$out" ] && ok "no reinstall and nothing printed — a CLI upgrade alone leaves it alone" || no "$out / $(tail -1 "$T/tool-code.log")"

section "an editor whose tool cannot be found, and a tool that fails"
mkdir -p "$HOME/Library/Application Support/Cursor/User" "$HOME/.cursor/extensions/anthropic.claude-code-2.1.301-darwin-arm64"
out=$(X vscode-status install 2>&1)
grep -q "Cursor: its command-line tool was not found" <<<"$out" && ls "$HOME/.config/claude-accounts/claude-account-status-$WANT.vsix" >/dev/null 2>&1 \
  && ok "no tool: it says so and leaves the .vsix to install from the editor" || no "$out"
! ls -d "$HOME/.cursor/extensions/$ID"-* >/dev/null 2>&1 && ok "…and copies no folder in behind the editor's back" || no "$(ls "$HOME/.cursor/extensions")"
mkdir -p "$X/$ID-0.9.0"; regb=$(reg_of "$X")
out=$(STUB_FAIL=1 X vscode-status install 2>&1)
grep -q "VS Code: the editor's tool did not install the status bar item" <<<"$out" && grep -q 'stub refused' <<<"$out" && ok "a tool that fails is reported, with what it said" || no "$out"
[ "$(reg_of "$X")" = "$regb" ] && [ -d "$X/$ID-0.9.0" ] && ok "…and nothing is cleaned up on a failed install" || no "$(reg_of "$X"); $(ls "$X")"

section "remove goes through the tool too"
out=$(X vscode-status remove 2>&1)
grep -qE -- "--uninstall-extension $ID" "$T/tool-code.log" && ok "it ran: code --uninstall-extension $ID" || no "$(tail -2 "$T/tool-code.log")"
[ -z "$(reg_of "$X")" ] && ! ls -d "$X/$ID"-* >/dev/null 2>&1 && ok "no record and no folder left" || no "$(reg_of "$X"); $(ls "$X")"
grep -q "VS Code: not installed" <<<"$(X vscode-status status 2>&1)" && ok "status: not installed" || no "$(X vscode-status status 2>&1)"

finish
