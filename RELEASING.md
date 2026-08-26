# Releasing

Everything runs locally. There is no CI, by design — you push, you release.

```sh
make release-dry              # what would happen; publishes nothing
make release CONFIRM=yes      # tag, GitHub release, tap, npm
```

`release` refuses on a dirty tree, refuses without `CONFIRM=yes`, proves both credentials
before the first irreversible step, and checks the uploaded tarball actually returns 200
before pointing a Homebrew formula at it.

## Credentials

Two are needed. `make preflight` verifies both without publishing anything.

### GitHub

```sh
gh auth status || gh auth login
```

Routing is automatic — `git@github.com:reddeer-tech/**` resolves to the `default` identity.

### npm

`npm login` gives a **2-hour session token** and is the simplest path. For a token instead:

1. npmjs.com → Access Tokens → **Granular Access Token**
2. Packages: **All packages** for the *first* publish of a new package — a token cannot be
   scoped to a package that does not exist yet. Narrow it to `claude-account` afterwards.
3. Permissions: **Read and write**
4. Expiry: 7 days by default, **90 days maximum**. There is no permanent token any more.

```sh
npm config set //registry.npmjs.org/:_authToken <token>   # writes ~/.npmrc
chmod 600 ~/.npmrc
npm whoami                                                # must print reddeer-admin
```

⚠️ A publish token can push code to every machine that installs this package. Never commit it
(`.npmrc` and `.env` are gitignored), never paste it into a chat or an issue, and re-mint it
rather than extending it.

⚠️ Classic tokens were permanently revoked on 2025-12-09. If `npm whoami` fails while a token
*is* configured, that is a dead classic token — replace it.

## Cutting a version

```sh
make version VERSION=0.2.0    # updates VERSION + package.json
git commit -am "0.2.0"        # the tree must be clean before releasing
make release CONFIRM=yes
```

## If a release fails partway

Work out how far it got before retrying — the steps are not atomic.

| Reached | State | To retry |
|---|---|---|
| tag pushed | tag is public | `make release CONFIRM=yes` is idempotent from here |
| GitHub release | asset uploaded | re-runs with `--clobber` |
| tap pushed | formula live | re-running overwrites it |
| npm published | **permanent** | you cannot republish the same version — bump it |

npm cannot be unpublished after 72 hours, and the version number stays burned even if removed.
