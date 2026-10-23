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
         NO_COLOR=1 CA_NO_REFRESH=1 \
         CLAUDE_ACCOUNTS_NO_AUTOSETUP=1    # never the automatic setup: it writes into ~/bin, shell and editor files
  install -m 0600 "$REPO/templates/paths.map" "$CLAUDE_ACCOUNTS_MAP"
  mkdir -p "$T/profiles" "$T/bin"

  # `security`: a service listed in $T_SIGNED is signed in. -w returns a plausible token
  # blob so acct_identity reads a real plan|tier, not just "exit 0". SEC_MODE=err makes
  # every probe fail with a NON-44 status, which must read as a probe ERROR and never as
  # "not signed in" — the rule that stops a locked Keychain silently billing global.
  cat > "$T/bin/security" <<'STUB'
#!/bin/bash
# T_SECLOG=<file> records one line per call, so a test can assert a command read no login.
[ -n "${T_SECLOG:-}" ] && echo "$*" >> "$T_SECLOG"
# T_SECHOLD=<file>: every call touches <file>.in, then waits while <file> exists, so a test can
# hold a command at a Keychain read: inside the rules lock, or half-way through a rename.
if [ -n "${T_SECHOLD:-}" ]; then : > "$T_SECHOLD.in"; while [ -e "$T_SECHOLD" ]; do sleep 0.05; done; fi
[ "${SEC_MODE:-}" = "err" ] && exit 36
# T_KC=<dir> (opt-in) makes this a real store for what rename does: add-generic-password, on
# argv or through `security -i` on stdin, writes the bytes to $T_KC/<service>; find prints
# them (-w) or the acct attribute (no -w); delete removes them. $T_KC/channel.log records how
# each write arrived. Like the real tool, -i splits a line over 4096 characters and echoes the
# rest as `unknown command "<rest>"`. SEC_ADD_MODE=drop claims success and stores nothing;
# SEC_ADD_MODE=corrupt stores the copy one byte short.
if [ -n "${T_KC:-}" ]; then
  kc_add(){ # <channel> <the add-generic-password arguments…>
    local ch=$1 s="" a="" hx="" pw="" how=""; shift
    while [ $# -gt 0 ]; do case "$1" in -s) s=$2; shift ;; -a) a=$2; shift ;; -X) hx=$2; how=X; shift ;; -w) pw=$2; how=w; shift ;; esac; shift; done
    echo "$ch ${#hx}${#pw}" >> "$T_KC/channel.log"
    [ "${SEC_ADD_MODE:-}" = drop ] && return 0
    if [ "$how" = X ]; then printf '%s' "$hx" | xxd -r -p > "$T_KC/$s.tmp"; else printf '%s' "$pw" > "$T_KC/$s.tmp"; fi
    [ "${SEC_ADD_MODE:-}" = corrupt ] && { head -c "$(( $(wc -c < "$T_KC/$s.tmp") - 1 ))" "$T_KC/$s.tmp" > "$T_KC/$s.cut"; mv "$T_KC/$s.cut" "$T_KC/$s.tmp"; }
    mv "$T_KC/$s.tmp" "$T_KC/$s"; printf '%s' "${a:-?}" > "$T_KC/$s.acct"
  }
  case "${1:-}" in
    -i) while IFS= read -r line || [ -n "$line" ]; do
          if [ "${#line}" -gt 4095 ]; then printf 'unknown command "%s"\n' "${line:4095}"; line=${line:0:4095}; fi
          eval "set -- $line"; [ "${1:-}" = add-generic-password ] && { shift; kc_add stdin "$@"; }
        done; exit 0 ;;
    add-generic-password) shift; kc_add argv "$@"; exit 0 ;;
  esac
fi
if [ -n "${T_KC:-}" ] && [ "${1:-}" = delete-generic-password ]; then
  # an entry the store holds is removed; anything else falls through, so its exit code
  # (0 for a T_SIGNED/T_BLANK service, 44 otherwise) is what it always was
  prev=""; for x in "$@"; do [ "$prev" = "-s" ] && [ -f "$T_KC/$x" ] && { rm -f "$T_KC/$x" "$T_KC/$x.acct"; exit 0; }; prev=$x; done
fi
if [ -n "${T_KC:-}" ] && [ "${1:-}" = find-generic-password ]; then
  s=""; wf=0; for x in "$@"; do [ "$prev" = "-s" ] && s=$x; [ "$x" = "-w" ] && wf=1; prev=$x; done
  if [ -f "$T_KC/$s" ]; then
    # like the real tool: plain ASCII prints as text, anything else as hex (measured 2026-10-18)
    if [ "$wf" = 1 ]; then if LC_ALL=C grep -q '[^ -~]' "$T_KC/$s"; then xxd -p "$T_KC/$s" | tr -d '\n'; else cat "$T_KC/$s"; fi; else printf '    "acct"<blob>="%s"\n' "$(cat "$T_KC/$s.acct" 2>/dev/null)"; fi
    exit 0
  fi
fi
svc=""; w=0
while [ $# -gt 0 ]; do [ "$1" = "-s" ] && svc="$2"; [ "$1" = "-w" ] && w=1; shift; done
# A service in $T_BLANK is the state Claude Code leaves behind when a refresh token dies:
# the entry EXISTS but its accessToken is "". Plan and tier survive, which is what used to
# make it read as signed in. The mcpOAuth block carries its own empty accessToken on
# purpose — a loose substring match on \"accessToken\":\"\" must not fire on a LIVE blob.
# FAKE_MCP_FIRST=1 writes mcpOAuth FIRST, the order newer Claude Code uses (measured
# 2026-10-18 on 5 of 8 real credentials): a blank check anchored at the start missed it.
if grep -qxF "$svc" "$T_BLANK" 2>/dev/null; then
  if [ "$w" = 1 ] && [ -n "${FAKE_MCP_FIRST:-}" ]; then
    printf '{"mcpOAuth":{"srv":{"accessToken":""}},"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"subscriptionType":"team","rateLimitTier":"default_raven"}}'
  elif [ "$w" = 1 ]; then
    printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"subscriptionType":"team","rateLimitTier":"default_raven"},"mcpOAuth":{"srv":{"accessToken":""}}}'
  fi
  exit 0
fi
# FAKE_ACCESS_EXPIRES_MS / FAKE_SIGNIN_ENDS_MS shape the signed-in blob: the access token's
# expiry (default year 2100) and the refresh token's hard end, refreshTokenExpiresAt (default
# absent — older credentials do not carry it, and absence must claim nothing).
if grep -qxF "$svc" "$T_SIGNED" 2>/dev/null; then
  if [ "$w" = 1 ] && [ -n "${FAKE_MCP_FIRST:-}" ]; then
    printf '{"mcpOAuth":{"srv":{"accessToken":""}},"claudeAiOauth":{"accessToken":"stub","subscriptionType":"max","rateLimitTier":"demo","expiresAt":%s%s}}' \
      "${FAKE_ACCESS_EXPIRES_MS:-4102444800000}" "${FAKE_SIGNIN_ENDS_MS:+,\"refreshTokenExpiresAt\":$FAKE_SIGNIN_ENDS_MS}"
  elif [ "$w" = 1 ]; then
    printf '{"claudeAiOauth":{"accessToken":"stub","subscriptionType":"max","rateLimitTier":"demo","expiresAt":%s%s},"mcpOAuth":{"srv":{"accessToken":""}}}' \
      "${FAKE_ACCESS_EXPIRES_MS:-4102444800000}" "${FAKE_SIGNIN_ENDS_MS:+,\"refreshTokenExpiresAt\":$FAKE_SIGNIN_ENDS_MS}"
  fi
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
  # $FAKE_RESETS_AT overrides both reset timestamps, so a test can put the window in the
  # PAST — the branch that used to render a negative gap as a positive countdown.
  # Each call is recorded — its arguments, and an Authorization header if one came on stdin —
  # so a test can count usage calls and prove the token never rides on curl's argv.
  cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
hdr=""; [ ! -t 0 ] && hdr=$(cat 2>/dev/null | grep -i '^Authorization:' | head -1)
printf 'args:%s\n' "$*" >> "$T_CURLED"; [ -n "$hdr" ] && printf 'stdin:%s\n' "$hdr" >> "$T_CURLED"
A="${FAKE_RESETS_AT:-2030-01-01T15:40:00Z}"; B="${FAKE_RESETS_AT:-2030-01-03T15:00:00Z}"
printf '{"limits":[{"kind":"session","percent":40,"severity":"normal","resets_at":"%s"},{"kind":"weekly_all","percent":34,"severity":"normal","resets_at":"%s"}]}' "$A" "$B"
STUB
  # `open` must never reach a real browser from a test. Records what it was asked to open.
  cat > "$T/bin/open" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$T_OPENED"
STUB
  chmod +x "$T/bin/security" "$T/bin/claude" "$T/bin/curl" "$T/bin/open"
  export T_SIGNED="$T/signed"; : > "$T_SIGNED"
  export T_BLANK="$T/blank";  : > "$T_BLANK"
  # ⚠ $T itself is NOT exported, so a stub must use one of these exported paths — a stub
  # writing to "$T/…" writes to "/…", fails silently, and every "nothing was opened"
  # assertion then passes for the wrong reason.
  export T_OPENED="$T/opened"; : > "$T_OPENED"
  export T_CURLED="$T/curled"; : > "$T_CURLED"
  # The security stub keeps what is written (rename copies a login and reads it back, 1.2.5)
  export T_KC="$T/kc"; mkdir -p "$T_KC"
  # doctor's live-sessions scan looks only at this sandbox's stand-in sessions, never at the
  # real Claude sessions on the machine: results stop depending on what is open, and each of
  # the ~36 doctor runs stops paying a ps + lsof per real session. The path is one the
  # production pattern (native-binary/claude, .local/bin/claude) does NOT match, so a stand-in
  # left running by an interrupted test can never show up in a real doctor run.
  export CA_DOCTOR_PROC_MATCH="$T/fake/stand-in/claude"
  export PATH="$T/bin:$PATH"
}

svc_of(){ printf 'Claude Code-credentials-%s' "$(printf '%s' "$T/profiles/$1" | shasum -a 256 | cut -c1-8)"; }
sign(){ svc_of "$1" >> "$T_SIGNED"; echo >> "$T_SIGNED"; }   # the newline matters: grep -qxF
# Signed in once, then the refresh token died: the slot is present and useless.
blank(){ svc_of "$1" >> "$T_BLANK"; echo >> "$T_BLANK"; }
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
