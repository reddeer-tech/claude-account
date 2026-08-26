# claude-account — route Claude Code subscriptions per project path (macOS).
# Local dev, then publish to a Homebrew tap and/or npm.
#   make install                 # deploy this working copy onto this machine
#   make check                   # shellcheck-ish gate + smoke tests, no network
#   make release VERSION=0.2.0   # tag + GitHub release + formula bump + npm publish
.PHONY: preflight help install uninstall check smoke doctor version dist clean sync check-sync \

VERSION      := $(shell cat VERSION 2>/dev/null || echo 0.0.0)
PREFIX      ?= $(HOME)
BINDIR      ?= $(PREFIX)/bin
LIBDIR      ?= $(PREFIX)/.config/claude-accounts
TAP         ?= reddeer-tech/homebrew-tap
REPO        ?= reddeer-tech/claude-account
DIST        := dist
TARBALL     := $(DIST)/claude-account-$(VERSION).tar.gz

# ⚠️ RESOLVE THESE OURSELVES. make runs recipes through /bin/sh, which never sources the
# user's profile — brew lives in /opt/homebrew/bin on Apple Silicon and gh may be the
# routing shim in ~/.local/bin. Without this every target dies with "command not found"
# in exactly the shells where it matters (make, CI, a tool-spawned shell).
BREW ?= $(if $(shell command -v brew 2>/dev/null),brew,/opt/homebrew/bin/brew)
GH   ?= $(if $(shell command -v gh   2>/dev/null),gh,$(HOME)/.local/bin/gh)
NPM  ?= $(if $(shell command -v npm  2>/dev/null),npm,/usr/local/bin/npm)

help:
	@echo "claude-account $(VERSION) — per-project Claude subscriptions (macOS only)"
	@echo "==========================================================="
	@echo "LOCAL"
	@echo "  make install                  - copy bin/ + libexec/ onto this machine ($(BINDIR))"
	@echo "  make uninstall                - remove them; leaves paths.map and logins alone"
	@echo "  make check                    - syntax + smoke tests, no network, no state change"
	@echo "  make doctor                   - run the installed health check"
	@echo "  make check-sync               - fail if the installed copy differs from this repo"
	@echo "  make sync                     - pull the installed copy back INTO this repo (rescue only)"
	@echo ""
	@echo "PACKAGE"
	@echo "  make version VERSION=0.2.0    - write VERSION and sync package.json"
	@echo "  make dist                     - build $(TARBALL) and print its sha256"
	@echo ""
	@echo "PUBLISH                          needs: gh auth, npm login, a tap repo"
	@echo "  make brew-formula             - regenerate Formula/claude-account.rb for this version"
	@echo "  make brew-local               - install from the local formula (test before tapping)"
	@echo "  make brew-publish             - push the formula to $(TAP)"
	@echo "  make npm-pack                 - build the npm tarball, publish nothing"
	@echo "  make npm-publish              - npm publish (public)"
	@echo "  make release VERSION=x.y.z    - version + dist + GitHub release + brew + npm"
	@echo ""
	@echo "macOS only: uses the Keychain (security) and VS Code's settings path."

# ── LOCAL ────────────────────────────────────────────────────────────────────────────────────────
# install is deliberately idempotent and never touches paths.map or the Keychain: re-running it
# after an edit is the normal dev loop.
install:
	@mkdir -p "$(BINDIR)" "$(LIBDIR)"
	@install -m 0755 bin/claude-account         "$(BINDIR)/claude-account"
	@install -m 0755 bin/claude-shim            "$(BINDIR)/claude"
	@install -m 0755 bin/claude-vscode-wrapper  "$(BINDIR)/claude-vscode-wrapper"
	@install -m 0755 bin/claude-whoami          "$(BINDIR)/claude-whoami"
	@install -m 0755 libexec/resolve.sh         "$(LIBDIR)/resolve.sh"
	@[ -f "$(LIBDIR)/paths.map" ] || install -m 0600 templates/paths.map "$(LIBDIR)/paths.map"
	@echo "installed $(VERSION) -> $(BINDIR)"
	@echo "next: ensure $(BINDIR) precedes the real claude on PATH, then"
	@echo "      claude-account doctor"

uninstall:
	@rm -f "$(BINDIR)/claude-account" "$(BINDIR)/claude" "$(BINDIR)/claude-vscode-wrapper" "$(BINDIR)/claude-whoami"
	@echo "removed the binaries. paths.map, labels and Keychain logins were left alone."
	@echo "to remove those too:  rm -rf $(LIBDIR)   (logins stay in the Keychain)"

check: check-sync smoke
	@for f in bin/* libexec/*.sh; do bash -n "$$f" || exit 1; done
	@echo "✓ check passed (syntax + smoke)"

# Smoke runs the read-only verbs against a THROWAWAY map so it cannot touch real rules.
smoke:
	@tmp=$$(mktemp -d); : > "$$tmp/paths.map"; \
	CLAUDE_ACCOUNTS_MAP="$$tmp/paths.map" CLAUDE_ACCOUNTS_DIR="$$tmp/profiles" \
	CLAUDE_ACCOUNTS_LIB="$$PWD/libexec" bash bin/claude-account list >/dev/null || exit 1; \
	CLAUDE_ACCOUNTS_MAP="$$tmp/paths.map" CLAUDE_ACCOUNTS_DIR="$$tmp/profiles" \
	CLAUDE_ACCOUNTS_LIB="$$PWD/libexec" bash bin/claude-account --help >/dev/null || exit 1; \
	rm -rf "$$tmp"; echo "✓ smoke ok"

doctor: ; @"$(BINDIR)/claude-account" doctor

# ── SOURCE OF TRUTH ──────────────────────────────────────────────────────────────────────────────
# THIS REPO is the source; $(BINDIR) is a deployment of it. Edit here, then `make install`.
# `sync` exists only to rescue an edit made directly in $(BINDIR) — it copies backwards, and
# check-sync is the gate that stops that drift going unnoticed.
check-sync:
	@rc=0; \
	for pair in "claude-account:bin/claude-account" "claude:bin/claude-shim" \
	            "claude-vscode-wrapper:bin/claude-vscode-wrapper" "claude-whoami:bin/claude-whoami"; do \
	  live="$(BINDIR)/$${pair%%:*}"; pkg="$${pair##*:}"; \
	  [ -f "$$live" ] || continue; \
	  if ! cmp -s "$$live" "$$pkg"; then echo "  DRIFT: $$live differs from $$pkg"; rc=1; fi; \
	done; \
	if [ -f "$(LIBDIR)/resolve.sh" ] && ! cmp -s "$(LIBDIR)/resolve.sh" libexec/resolve.sh; then \
	  echo "  DRIFT: $(LIBDIR)/resolve.sh differs from libexec/resolve.sh"; rc=1; fi; \
	[ $$rc = 0 ] && echo "✓ installed copy matches this repo" || \
	  { echo "run 'make install' (repo -> machine) or 'make sync' (machine -> repo)"; exit 1; }

sync:
	@cp "$(BINDIR)/claude-account"        bin/claude-account        2>/dev/null || true
	@cp "$(BINDIR)/claude"                bin/claude-shim           2>/dev/null || true
	@cp "$(BINDIR)/claude-vscode-wrapper" bin/claude-vscode-wrapper 2>/dev/null || true
	@cp "$(BINDIR)/claude-whoami"         bin/claude-whoami         2>/dev/null || true
	@cp "$(LIBDIR)/resolve.sh"            libexec/resolve.sh        2>/dev/null || true
	@chmod +x bin/* libexec/resolve.sh
	@echo "pulled the installed copy into this repo — commit it, then edit HERE from now on"

# ── PACKAGE ──────────────────────────────────────────────────────────────────────────────────────
# ⚠️ IDEMPOTENT ON PURPOSE — DO NOT go back to plain `npm version`. It rewrites package.json
# in npm's canonical format every run (re-indenting arrays, \u-escaping the em dash, and
# dropping the trailing newline) even with --allow-same-version. `version` is a prerequisite
# of `release`, so that dirtied the tree before release's clean-tree guard ran and made
# `make release` impossible to complete. Write only when a value actually differs, and patch
# the one field in place so the file's formatting survives.
version:
	@test -n "$(VERSION)" || { echo "usage: make version VERSION=x.y.z"; exit 2; }
	@test "$$(cat VERSION 2>/dev/null)" = "$(VERSION)" || echo "$(VERSION)" > VERSION
	@cur=$$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' package.json | head -1); \
	 if [ "$$cur" != "$(VERSION)" ]; then \
	   sed -i '' -E 's/("version"[[:space:]]*:[[:space:]]*")[^"]*(")/\1$(VERSION)\2/' package.json; \
	   echo "package.json  $$cur -> $(VERSION)   ⚠ commit this before releasing"; \
	 fi
	@echo "version -> $(VERSION)"

# ⚠️ A FILE TARGET, NOT A PHONY REBUILD. This used to be `dist: clean`, so every reference
# rebuilt the tarball — and tar embeds mtimes, so each rebuild has a DIFFERENT sha256. During
# a release that meant `dist` uploaded one tarball and `brew-formula` then hashed a freshly
# rebuilt one, publishing a formula whose checksum did not match the asset users download.
# Every `brew install` would have failed verification. Build once, reuse, and rebuild only
# when a source file actually changes.
SOURCES := $(shell find bin libexec templates -type f 2>/dev/null) README.md LICENSE VERSION

$(TARBALL): $(SOURCES)
	@mkdir -p $(DIST)
	@tar --exclude='./dist' --exclude='./.git' --exclude='./node_modules' \
	     -czf $(TARBALL) bin libexec templates README.md LICENSE VERSION
	@echo "$(TARBALL)"
	@shasum -a 256 $(TARBALL) | awk '{print "sha256: "$$1}'

dist: $(TARBALL)

clean: ; @rm -rf $(DIST)

# ── HOMEBREW ─────────────────────────────────────────────────────────────────────────────────────
# The formula points at a GitHub release tarball, so `make release` must tag and upload BEFORE
# the formula is regenerated — otherwise the sha256 is of a file nobody else can download.
# SHA256_OVERRIDE lets `release` pin the formula to the sha of the asset ACTUALLY PUBLISHED.
# GitHub's CDN can keep serving a previous upload for a while, and tar embeds mtimes, so a
# locally recomputed hash is not necessarily the hash users will download. Describe reality.
brew-formula: $(TARBALL)
	@sha=$${SHA256_OVERRIDE:-$$(shasum -a 256 $(TARBALL) | awk '{print $$1}')}; \
	sed -e 's|@@VERSION@@|$(VERSION)|g' -e "s|@@SHA256@@|$$sha|g" -e 's|@@REPO@@|$(REPO)|g' \
	    Formula/claude-account.rb.in > Formula/claude-account.rb; \
	echo "Formula/claude-account.rb -> $(VERSION) ($$sha)"

brew-local: brew-formula
	@$(BREW) install --formula --build-from-source ./Formula/claude-account.rb
	@echo "installed locally. verify:  claude-account doctor"

# ⚠️ ALWAYS RE-SYNC THE TAP CLONE. This used to `test -d || clone`, which reuses whatever
# was left in /tmp from a previous release — so the formula got committed onto a stale base
# and the push was rejected (or worse, raced a change made in the tap's web UI).
TAPDIR := $(DIST)/homebrew-tap
# `brew install owner/tap/formula` is the user-facing form: Homebrew maps the short name
# "tap" back to the repo "homebrew-tap". A :pattern=% substitution can't do this (it only
# anchors at the start of a word, and the word starts with the owner), so use subst.
TAPSHORT := $(subst /homebrew-,/,$(TAP))
brew-publish: brew-formula
	@if [ -d $(TAPDIR)/.git ]; then \
	  git -C $(TAPDIR) fetch --quiet origin; \
	  git -C $(TAPDIR) rev-parse --verify --quiet origin/HEAD >/dev/null \
	    && git -C $(TAPDIR) reset --quiet --hard origin/HEAD || true; \
	else rm -rf $(TAPDIR) && git clone git@github.com:$(TAP).git $(TAPDIR); fi
	@mkdir -p $(TAPDIR)/Formula
	@cp Formula/claude-account.rb $(TAPDIR)/Formula/
	@# `git push` alone fails on a brand-new EMPTY tap: the clone has an unborn branch with
	@# no upstream ("has no upstream branch"). -u origin HEAD covers the first push and every
	@# one after it. And skip the commit when the formula is byte-identical, so re-running a
	@# release does not die on "nothing to commit".
	@cd $(TAPDIR) && git add Formula/claude-account.rb && \
	  if git diff --cached --quiet; then echo "  formula unchanged — nothing to push"; \
	  else git -c user.email="$$(git config user.email || echo release@localhost)" \
	          -c user.name="$$(git config user.name || echo release)" \
	          commit -q -m "claude-account $(VERSION)" && git push -u origin HEAD; fi
	@echo "published. users install with ONE command (the tap is implicit):"
	@echo "    brew install $(TAPSHORT)/claude-account"

# ── NPM ──────────────────────────────────────────────────────────────────────────────────────────
npm-pack:    ; @$(NPM) pack --pack-destination $(DIST) && ls -1 $(DIST)/*.tgz
npm-publish: ; @$(NPM) publish --access public && echo "published $(VERSION) to npm"

# ── RELEASE ──────────────────────────────────────────────────────────────────────────────────────
# ⚠️ IRREVERSIBLE. A pushed tag and a GitHub release are public instantly, and npm cannot be
# unpublished after 72 hours — the name stays permanently blocked even if you remove it.
# So every step here VERIFIES ITS OWN OUTPUT instead of trusting an exit code. The previous
# version ended `git push --tags` with `|| true` and hid `gh release create` behind 2>/dev/null,
# which meant a failed push still ran brew-publish and shipped a formula whose url 404s for
# every user who taps it.

ASSET_URL = https://github.com/$(REPO)/releases/download/v$(VERSION)/claude-account-$(VERSION).tar.gz

# ⚠️ CHECK CREDENTIALS FIRST. npm-publish is the LAST step of `release`, so an auth failure
# there used to land after the tag was pushed, the GitHub release was cut and the formula was
# already in the tap — a half-published version that has to be unwound by hand. Prove every
# credential up front, when the cost of stopping is zero.
preflight:
	@$(NPM) whoami >/dev/null 2>&1 || { \
	  echo "npm: not authenticated."; \
	  echo "  interactive (2h session):  npm login"; \
	  echo "  or a granular token:       see RELEASING.md"; exit 1; }
	@$(GH) auth status >/dev/null 2>&1 || { echo "gh: not authenticated. run: gh auth login"; exit 1; }
	@echo "  npm  $$($(NPM) whoami 2>/dev/null)"
	@echo "  gh   $$($(GH) auth status >/dev/null 2>&1 && $(GH) api user --jq .login 2>/dev/null)"

release-dry: check version dist
	@echo "DRY RUN — nothing is published."
	@echo "  tag          v$(VERSION)"
	@echo "  tarball      $(TARBALL)  ($$(wc -c < $(TARBALL) | tr -d ' ') bytes)"
	@echo "  sha256       $$(shasum -a 256 $(TARBALL) | cut -d' ' -f1)"
	@echo "  asset url    $(ASSET_URL)"
	@echo "  tap          $(TAP)  ->  brew install $(TAPSHORT)/claude-account"
	@echo "  npm          $$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' package.json | head -1)@$(VERSION)"
	@echo "  tree         $$(test -z "$$(git status --porcelain)" && echo clean || echo DIRTY)"
	@# Local checks only — `npm whoami` costs a network round trip and hung the dry run.
	@# Never print the token itself, only whether one is configured.
	@# `npm config get` REFUSES to return auth tokens ("the option is protected, and cannot
	@# be retrieved in this way"), so every config-based heuristic reported NONE while a
	@# perfectly good token was configured. whoami is the only honest check; it costs a
	@# network round trip and that is the correct price for a pre-release check.
	@echo "  npm auth     $$($(NPM) whoami 2>/dev/null || echo 'NONE — release will stop')"
	@echo "  gh auth      $$($(GH) auth status >/dev/null 2>&1 && echo 'ok' || echo 'NONE — release will stop')"
	@echo
	@echo "to publish for real:  make release CONFIRM=yes"

release: check version dist
	@test -z "$$(git status --porcelain)" || { \
	  echo "refusing to release: working tree is dirty. The tag must match the tarball."; \
	  git status --short; exit 1; }
	@test "$(CONFIRM)" = "yes" || { \
	  echo "refusing to release without CONFIRM=yes."; \
	  echo "this publishes to GitHub, Homebrew and npm. npm is PERMANENT after 72h."; \
	  echo "see what would happen:  make release-dry"; exit 2; }
	@$(MAKE) --no-print-directory preflight
	@git tag -a "v$(VERSION)" -m "claude-account $(VERSION)" 2>/dev/null || echo "tag v$(VERSION) already exists"
	@git push origin "v$(VERSION)"
	@# ⚠️ NEVER `--clobber`, AND NEVER RE-UPLOAD NEEDLESSLY. --clobber leaves a metadata record
	@# whose backing blob is gone (API says state=uploaded, every download 404s BlobNotFound),
	@# and even a clean delete+upload needs time to propagate — so re-uploading on every run
	@# left the asset broken for minutes at a time. Upload only when the published bytes are
	@# actually wrong.
	@if $(GH) release view "v$(VERSION)" >/dev/null 2>&1; then \
	  want=$$(shasum -a 256 $(TARBALL) | awk '{print $$1}'); \
	  got=$$(curl -sSLf --retry 3 --retry-delay 2 "$(ASSET_URL)" 2>/dev/null | shasum -a 256 | awk '{print $$1}'); \
	  if [ "$$want" = "$$got" ]; then echo "  release asset already matches — not re-uploading"; \
	  else \
	    id=$$($(GH) api repos/$(REPO)/releases/tags/v$(VERSION) \
	          --jq '.assets[]|select(.name=="claude-account-$(VERSION).tar.gz")|.id' 2>/dev/null); \
	    [ -n "$$id" ] && $(GH) api -X DELETE repos/$(REPO)/releases/assets/$$id >/dev/null 2>&1 || true; \
	    $(GH) release upload "v$(VERSION)" $(TARBALL); \
	  fi; \
	else \
	  $(GH) release create "v$(VERSION)" $(TARBALL) --title "claude-account $(VERSION)" --generate-notes; \
	fi
	@echo "checking the published asset's CONTENTS against the local build..."
	@rm -rf $(DIST)/_pub $(DIST)/_loc && mkdir -p $(DIST)/_pub $(DIST)/_loc
	@curl -sSLf --retry 10 --retry-delay 5 --retry-all-errors "$(ASSET_URL)" | tar xz -C $(DIST)/_pub
	@tar xzf $(TARBALL) -C $(DIST)/_loc
	@diff -r $(DIST)/_pub $(DIST)/_loc >/dev/null || { \
	  echo "  ✗ the published asset does NOT contain this build — re-upload it"; \
	  diff -rq $(DIST)/_pub $(DIST)/_loc; exit 1; }
	@rm -rf $(DIST)/_pub $(DIST)/_loc
	@published=$$(curl -sSLf --retry 10 --retry-delay 5 --retry-all-errors "$(ASSET_URL)" | shasum -a 256 | awk '{print $$1}'); \
	 echo "  ✓ contents match; pinning the formula to the published sha $$published"; \
	 $(MAKE) --no-print-directory brew-publish SHA256_OVERRIDE=$$published
	@$(MAKE) npm-publish
	@echo "✓ released $(VERSION)"
	@echo "    brew install $(TAPSHORT)/claude-account"
	@echo "    npm i -g $$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' package.json | head -1)"

