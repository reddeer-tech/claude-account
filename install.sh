#!/bin/bash
# claude-account installer.
#   ./install.sh            interactive: copies files, wires VS Code, checks PATH
#   ./install.sh --quiet    files only, no PATH or VS Code advice printed
# Never touches paths.map, labels, or Keychain logins if they already exist.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDIR="${BINDIR:-$HOME/bin}"
LIBDIR="${LIBDIR:-$HOME/.config/claude-accounts}"
QUIET=0; case "${1:-}" in --quiet|--npm) QUIET=1 ;; esac
say(){ [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

mkdir -p "$BINDIR" "$LIBDIR" "$LIBDIR/profiles"
install -m 0755 "$HERE/bin/claude-account"        "$BINDIR/claude-account"
install -m 0755 "$HERE/bin/claude-whoami"         "$BINDIR/claude-whoami"
install -m 0755 "$HERE/bin/claude-shim"           "$BINDIR/claude"
install -m 0755 "$HERE/bin/claude-vscode-wrapper" "$BINDIR/claude-vscode-wrapper"
install -m 0755 "$HERE/libexec/resolve.sh"        "$LIBDIR/resolve.sh"
[ -f "$LIBDIR/paths.map" ] || install -m 0600 "$HERE/templates/paths.map" "$LIBDIR/paths.map"
say "installed to $BINDIR"

[ "$QUIET" = 1 ] && exit 0

# PATH: the shim only routes if it precedes the real claude. Check the LOGIN shell,
# which is what the user actually gets — not whatever PATH this script inherited.
real_claude=$("$SHELL" -lc 'command -v claude' 2>/dev/null | tail -1)
if [ "$real_claude" = "$BINDIR/claude" ]; then
  say "PATH ok — $BINDIR/claude wins in your login shell"
else
  say ""
  say "⚠ PATH: your login shell resolves claude to '${real_claude:-<not found>}'."
  say "  Add this to your shell profile so the shim wins, then open a new terminal:"
  say "      export PATH=\"$BINDIR:\$PATH\""
fi

# VS Code launches its own bundled binary by absolute path, so a PATH shim never
# reaches it. This setting is the supported hook; it is machine-scoped, so it lives
# in User settings and applies to every window.
VS="$HOME/Library/Application Support/Code/User/settings.json"
if [ -f "$VS" ]; then
  if grep -q 'claudeCode.claudeProcessWrapper' "$VS"; then
    say "VS Code: wrapper already configured"
  else
    say ""
    say "VS Code: add this to $VS"
    say "      \"claudeCode.claudeProcessWrapper\": \"$BINDIR/claude-vscode-wrapper\","
    say "  then restart VS Code once."
  fi
else
  say "VS Code settings not found — skipping (terminal routing still works)"
fi

say ""
say "next:  claude-account doctor"
