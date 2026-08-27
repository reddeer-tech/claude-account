# claude-account

Route **Claude Code subscriptions per project path** on macOS. Open one project and Claude uses
that project's account; open anything else and it uses the one you signed in with normally.

**Only the account changes.** Plugins, MCP servers, memory, settings, hooks and session history
stay shared, because only `CLAUDE_SECURESTORAGE_CONFIG_DIR` is set — never `CLAUDE_CONFIG_DIR`.
Most multi-account guides set both, which silently costs you all of the above.

```
PATH RULES — what each project path does  (one row per rule)

  PATH                  PROFILE    STATUS  SIGNED IN AS (plan | tier)
  /project/path         work       ACTIVE  you@company.com · team
  /another/project      personal   PAUSED  using global: you@personal.com · max   (login kept)
```

## Install

### Homebrew

```sh
brew install reddeer-tech/tap/claude-account
```

The tap is applied implicitly — there is no separate `brew tap` step.

### npm

```sh
npm install -g claude-account
```

### From source

```sh
git clone git@github.com:reddeer-tech/claude-account.git
cd claude-account && ./install.sh
```

### After installing — required

```sh
claude-account setup
```

**This step is not optional.** Until it runs, typing `claude` still starts the real binary and
no rule you add has any effect. It links the routing shims, checks they win on your `PATH`, and
prints the one line VS Code needs — VS Code launches its binary by absolute path, so a `PATH`
shim alone never reaches it.

It only *reports* on `PATH` order and VS Code rather than changing them: both mean editing files
you own — your shell profile, and a `settings.json` that is JSONC with comments.

Then `claude-account doctor` verifies the result.

## Use

```sh
claude-account add /project/path      # bind a path to a profile
claude-account login <profile>        # opens a browser to sign in
claude-account list                   # what each path does
claude-account usage --all            # live quota for every account
```

Day to day you run nothing: open the project and work.

| | |
|---|---|
| `list` / `profiles` / `verify` | what routes where, and which account each holds |
| `usage [name\|--all]` | live session/weekly/model quotas and reset times |
| `pause` / `resume` / `switch` | park a depleted account, or move paths to another one |
| `login` / `logout` / `refresh` | credentials; `refresh` renews an expired access token |
| `doctor` / `setup` | health check; and one-time PATH + VS Code wiring |
| `export` / `import` | move rules and labels to another machine |

`claude-account --help` is the full reference.

## How it works

```
cwd  →  paths.map  →  CLAUDE_SECURESTORAGE_CONFIG_DIR  →  sha256(dir)  →  Keychain entry
```

Resolved **once, at process launch**, by a `PATH` shim for the terminal and by
`claudeCode.claudeProcessWrapper` for VS Code, which launches its own binary by absolute path
so a `PATH` shim never reaches it.

A running session is therefore frozen to its launch-time routing. After `pause` or `switch`,
restart the session — `claude -c` resumes it with full context.

## Caveats

- **macOS only** — uses the Keychain via `security`, and VS Code's settings path.
- **Unofficial.** It relies on `CLAUDE_SECURESTORAGE_CONFIG_DIR`, the `sha256(dir)` Keychain
  naming, and an internal usage endpoint. All are internal to Claude Code and can change on
  any update.
- **The in-app Account panel shows a stale email.** It reads identity from the shared
  `~/.claude.json`, which holds the most recent sign-in from any profile, while Plan and the
  usage bars come from the session's real token. Trust those, or run `claude-account verify`.
- Each account needs its own valid subscription. This routes credentials; it does not share them.

## Contributing

The routing logic is `libexec/resolve.sh`; everything else is a thin shim around it.
`claude-account doctor` is the fastest way to see whether a change broke the plumbing.

Issues and pull requests: <https://github.com/reddeer-tech/claude-account>

## License

MIT
