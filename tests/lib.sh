#!/bin/bash
# Shared sandbox for every suite in this folder.
#
# ⚠ ISOLATION IS THE WHOLE POINT. All FOUR overrides must be set, never the map alone:
# CLAUDE_ACCOUNTS_MAP redirects only the map, so with PROFILES still pointing at the real
# one a "test" run of `forget` deletes a REAL profile dir and its REAL Keychain entry, and
# every mutating verb writes snapshots into the real backups folder. On top of that,
# `security`, `claude` and `curl` are stubbed on PATH so nothing touches the Keychain, the
# network, or your quota. CA_NO_REFRESH stops the reporting commands spending a request.
#
# Source this, then call ca_sandbox. It sets $T (the sandbox root) and exports everything.

fail=0
ok(){ echo "  PASS  $1"; }
no(){ echo "  FAIL  $1"; fail=1; }
section(){ echo; echo "=== $1 ==="; }

ca_sandbox(){
  REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
  cd "$REPO" || exit 1
  CA="$REPO/bin/claude-account"
  T=$(mktemp -d); T=$(cd "$T" && pwd -P)
  export CLAUDE_ACCOUNTS_MAP="$T/paths.map" \
         CLAUDE_ACCOUNTS_DIR="$T/profiles" \
         CLAUDE_ACCOUNTS_BACKUPS="$T/bk" \
         CLAUDE_ACCOUNTS_LIB="$REPO/libexec" \
         NO_COLOR=1 CA_NO_REFRESH=1
  install -m 0600 "$REPO/templates/paths.map" "$CLAUDE_ACCOUNTS_MAP"
  mkdir -p "$T/profiles" "$T/bin"

  # `security`: a service listed in $T_SIGNED is signed in. -w returns a plausible token
  # blob so acct_identity reads a real plan|tier, not just "exit 0". SEC_MODE=err makes
  # every probe fail with a NON-44 status, which must read as a probe ERROR and never as
  # "not signed in" — the rule that stops a locked Keychain silently billing global.
  cat > "$T/bin/security" <<'STUB'
#!/bin/bash
[ "${SEC_MODE:-}" = "err" ] && exit 36
svc=""; w=0
while [ $# -gt 0 ]; do [ "$1" = "-s" ] && svc="$2"; [ "$1" = "-w" ] && w=1; shift; done
if grep -qxF "$svc" "$T_SIGNED" 2>/dev/null; then
  [ "$w" = 1 ] && printf '{"claudeAiOauth":{"accessToken":"stub","subscriptionType":"max","rateLimitTier":"demo","expiresAt":4102444800000}}'
  exit 0
fi
exit 44
STUB
  cat > "$T/bin/claude" <<'STUB'
#!/bin/bash
case "$1" in
  --version) echo "${FAKE_CLAUDE_VERSION:-2.1.238 (Claude Code)}" ;;
  auth)      exit "${FAKE_AUTH_RC:-0}" ;;
  *)         echo pong ;;
esac
STUB
  cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
printf '{"limits":[{"kind":"session","percent":40,"severity":"normal","resets_at":"2030-01-01T15:40:00Z"},{"kind":"weekly_all","percent":34,"severity":"normal","resets_at":"2030-01-03T15:00:00Z"}]}'
STUB
  chmod +x "$T/bin/security" "$T/bin/claude" "$T/bin/curl"
  export T_SIGNED="$T/signed"; : > "$T_SIGNED"
  export PATH="$T/bin:$PATH"
}

svc_of(){ printf 'Claude Code-credentials-%s' "$(printf '%s' "$T/profiles/$1" | shasum -a 256 | cut -c1-8)"; }
sign(){ svc_of "$1" >> "$T_SIGNED"; echo >> "$T_SIGNED"; }   # the newline matters: grep -qxF
# The global account is the ABSENCE of a profile dir, so its Keychain service carries no
# hash suffix. Anything reading global's own credential needs this, not sign().
sign_global(){ printf 'Claude Code-credentials\n' >> "$T_SIGNED"; }
X(){ bash "$CA" "$@"; }
# resolve.sh's answer for a dir: field 1 is the profile, empty output means the real global
R(){ bash "$REPO/libexec/resolve.sh" "$1" 2>/dev/null; }
Rn(){ local r; r=$(R "$1"); [ -z "$r" ] && echo "(global)" || printf '%s' "$r" | cut -f1; }

# Run the CLI under a real pseudo-terminal, feeding one line of input. Needed for every
# [ -t 0 ] / [ -t 1 ] branch: the y/N offers, the interactive confirms, and the coloured
# help. stdin is held open past the prompt, else script(1) exits at EOF before the read.
PTY(){ { sleep 1; printf '%s\n' "$1"; sleep 3; } | script -q /dev/null bash "$CA" "${@:2}" 2>&1; }
# Same, with colour left on: ca_sandbox exports NO_COLOR=1 so every other assertion sees
# plain text, but the colouring itself has to be tested somewhere.
PTYC(){ { sleep 1; printf '%s\n' "$1"; sleep 3; } | script -q /dev/null env -u NO_COLOR bash "$CA" "${@:2}" 2>&1; }

finish(){ rm -rf "$T"; echo; [ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILURES"; exit $fail; }
