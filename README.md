# Claude Account

Route **Claude Code subscriptions per project path** on macOS. Open one project and Claude uses
that project's account; open anything else and it uses the one you signed in with normally.

**Only the account changes.** Plugins, MCP servers, memory, settings, hooks and session history
stay shared, because only `CLAUDE_SECURESTORAGE_CONFIG_DIR` is set - never `CLAUDE_CONFIG_DIR`.
Most multi-account guides set both, which silently costs you all of the above.

```
PATH RULES - what each project path does  (one row per rule)

  PATH                  PROFILE    STATUS  SIGNED IN AS (plan | tier)
  /project/path         work       ACTIVE  you@company.com · team
  /another/project      personal   PAUSED  using (global): you@personal.com · max   (login kept)
```

## Install

### Homebrew

```sh
brew install reddeer-tech/tap/claude-account
```

The tap is applied implicitly - there is no separate `brew tap` step.

### npm

```sh
npm install -g claude-account
```

### From source

```sh
git clone git@github.com:reddeer-tech/claude-account.git
cd claude-account && ./install.sh
```

### After installing - nothing to run

The first `claude-account` command you run at a terminal sets everything up, and says what it did
(never as root, in CI or from a script):

- the routing launchers in `~/bin` and the resolver in `~/.config/claude-accounts`, so typing
  `claude` picks the account by folder (with no rules yet it behaves exactly as before)
- `~/bin` first on your `PATH`, when it is not already, as a marked block in your login shell's
  profile (`~/.zprofile`, `~/.bash_profile`, or a fish `conf.d` file)
- the `claudeCode.claudeProcessWrapper` line in each VS Code-family editor that has the Claude
  extension, because those editors start Claude by absolute path and never see `PATH`. The file
  keeps its comments, a backup is taken first, and the editor needs one restart
- the status bar item that names each window's account, installed with the editor's own tool

`claude-account doctor` shows the result. `claude-account setup` does the same with a full
report, and puts back anything you removed by hand; `claude-account uninstall` takes all of it
out again and keeps your rules, groups and logins. `CLAUDE_ACCOUNTS_NO_AUTOSETUP=1` turns the
automatic part off. To put the launchers somewhere other than `~/bin`, run
`CLAUDE_ACCOUNTS_BINDIR=<folder> claude-account setup` once; the folder must be your own and not
writable by other users.

Anything you remove by hand later - the `PATH` block, the editor line, the status bar item -
stays removed. A `claude` in `~/bin` that is not claude-account's is never touched.

### Updating

```sh
brew upgrade claude-account        # Homebrew
npm update -g claude-account       # npm
git pull && ./install.sh           # from source
```

That is all: the first command after an upgrade brings the launchers, the resolver and the
status bar item up to date, once, and every command after that costs nothing extra.

## Use

```sh
claude-account add /project/path      # bind a path to a profile
claude-account login <profile>        # opens a browser to sign in
claude-account list                   # what each path does
claude-account usage --all            # live quota for every account
```

Day to day you run nothing: open the project and work.

### The full-screen view

```sh
claude-account            # in a terminal; also: claude-account ui
```

Every account in one screen, with its live usage, its paths and what each one is doing, in your
own groups and order. Each percentage is followed by how long until that window resets
(`5h 7% 2h  week 45% 3d`); the exact times are in the panel under the list. Arrow keys move, Enter opens what you can do with the account or path under
the cursor, `→` `←` show and hide an account's paths and `e` shows or hides every account's at
once, `[` `]` move an account inside its group, `g` puts it in groups, `s` sorts for a moment
by usage left or by when the sign-in ends, `r` fetches every account's usage again, and `m` has
the rest. The first item when you press Enter on an account refreshes just its usage, and the
first item in `m` refreshes everyone's. Everything the commands below do
can be done from there - each change runs the same `claude-account` command you would type and
shows what it printed. Signing out and forgetting a profile ask you to type its name first. Piped
or in a script, plain `claude-account` still prints `list`.

### Groups and order

```sh
claude-account group clients every kindly     # a group (an account can be in several)
claude-account group personal global gmail    # global is the global account
claude-account order outlook gmail            # these first, in this order
claude-account order --in clients kindly      # the order inside one group
```

`overview`, `profiles`, `list`, `verify` and the full-screen view all follow it. They look exactly
as before until you make a group or an order. Kept in `~/.config/claude-accounts/groups.tsv`;
`export` and `import` carry it to another Mac.

| | |
|---|---|
| `ui` | the full-screen view (also plain `claude-account` in a terminal) |
| `group` / `order` | your groups and order - `group --help`, `order --help` |
| `overview` (alias `ov`) | the whole picture in one screen: every credential, its paths, live usage |
| `statusline` | the account this session is spending - wire it into Claude Code's `statusLine` setting |
| `vscode-status install\|remove\|status` | the status bar item for VS Code/Cursor naming the account each window's folder uses (`setup` installs it) |
| `undo` | restore `paths.map` from the newest automatic snapshot |
| `list --json` | the whole state as one JSON object, for scripts |
| `list` / `profiles` / `verify` | what routes where, and which account each holds |
| `usage [name\|--all]` | live session/weekly/model quotas and reset times |
| `reset-page [name]` | open claude.ai → Settings → Usage, where a *limit reset* ("Reset for free") is used, and say which account to sign in as. `usage` and `overview` point here on their own when a weekly limit is spent. This tool cannot see whether an account has a reset — only claude.ai shows that |
| `pause` / `resume` / `switch` | park a depleted account, or move paths to another one |
| `unbind <path>` / `unbind <profile> --all` | that path stops using its profile - the rule goes, the login stays (named `remove` before 1.1.0) |
| `forget <profile>` | delete the profile itself, its label and its login |
| `create <profile>` | new profile with no path bound, and the browser sign-in, in one command - bind a path later with `add <path> <profile>`, or never |
| `use <profile>` / `use global` | point every path with no rule at that profile / back at your global account - switch the machine's "default" account at ease; no credential is copied or replaced (`fallback` is the older name, same command) |
| `use` / `use -q` | show what is selected / just the name, for scripts |
| `login` / `logout` / `refresh` | credentials; `refresh` renews an expired access token. A sign-in itself lasts about four weeks from `login`, however much it is used - `list`, `profiles` and `doctor` warn five days ahead, and only `login` renews it |
| `doctor` / `setup` / `uninstall` | health check; set everything up with a full report (any command does it quietly, once per version); and take it all out again, keeping rules and logins |
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
restart the session - `claude -c` resumes it with full context. `claude-account doctor` lists
any open chat still on the account it started with.

## Caveats

- **macOS only** - uses the Keychain via `security`, and VS Code's settings path.
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
