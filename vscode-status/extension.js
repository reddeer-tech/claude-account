// claude-account status — a VS Code status bar item naming the Claude account this
// FOLDER routes to. The Claude extension's own panel shows an email from a shared
// cache (the most recent sign-in of ANY profile), so it is the same in every window;
// this is per-window and comes from the router itself.
//
// Deliberately reports the FOLDER (what a session started here will use), not a live
// session: a running session is frozen to its launch-time account and this process
// cannot see another process's environment. The tooltip says so.
const vscode = require('vscode');
const { execFile } = require('child_process');
const os = require('os');
const path = require('path');

// A GUI app does not inherit a login shell's PATH, so never rely on bare names.
const CANDIDATES = [
  '/opt/homebrew/bin/claude-whoami',
  '/usr/local/bin/claude-whoami',
  path.join(os.homedir(), 'bin', 'claude-whoami'),
  path.join(os.homedir(), '.local', 'bin', 'claude-whoami'),
];
const fs = require('fs');
function findWhoami() {
  for (const c of CANDIDATES) { try { fs.accessSync(c, fs.constants.X_OK); return c; } catch (e) {} }
  return null;
}

function folder() {
  const f = vscode.workspace.workspaceFolders;
  return f && f.length ? f[0].uri.fsPath : os.homedir();
}

function activate(context) {
  const item = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 99);
  item.command = 'claudeAccountStatus.refresh';
  context.subscriptions.push(item);

  const refresh = () => {
    const bin = findWhoami();
    if (!bin) {
      item.text = '⌁ claude-account?';
      item.tooltip = 'claude-whoami not found in /opt/homebrew/bin, /usr/local/bin, ~/bin or ~/.local/bin.';
      item.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
      item.show();
      return;
    }
    execFile(bin, ['--porcelain', folder()], { timeout: 5000 }, (err, stdout) => {
      if (err) { item.hide(); return; }
      const [account, source, signedIn] = String(stdout).trim().split('\t');
      if (!account) { item.hide(); return; }
      item.text = '⌁ ' + account;
      const why = {
        rule: 'a path rule covers this folder',
        worktree: 'a path rule covers the MAIN repo of this git worktree',
        fallback: 'no rule matches — the machine-wide fallback applies',
        none: 'no rule matches — your global account',
        'env-override': 'an explicit account override is set in the environment',
        'token-override': 'CLAUDE_CODE_OAUTH_TOKEN overrides all routing',
      }[source] || source;
      const lines = [
        'Claude account for this folder: ' + account,
        why,
        signedIn === 'no' ? '⚠ that profile is NOT signed in — sessions fall back to your global account'
          : signedIn === 'error' ? '⚠ could not verify the credential (Keychain locked?)' : '',
        '',
        'This is what a session STARTED HERE will use. Sessions already open keep the',
        'account they launched with until restarted.',
        '',
        'Click to refresh.',
      ].filter(Boolean);
      item.tooltip = lines.join('\n');
      item.backgroundColor = (signedIn === 'no' || signedIn === 'error')
        ? new vscode.ThemeColor('statusBarItem.warningBackground') : undefined;
      item.show();
    });
  };

  // Update the moment the rules change, not just when the window regains focus:
  // `pause`/`resume`/`switch`/`fallback`/`add`/`remove` all rewrite these two files,
  // so watching them covers every routing change — including one made in THIS
  // window's integrated terminal, where no focus event ever fires.
  const cfgDir = path.join(os.homedir(), '.config', 'claude-accounts');
  const watchers = [];
  for (const [base, glob] of [[cfgDir, 'paths.map'], [path.join(cfgDir, 'profiles'), '.fallback']]) {
    try {
      const w = vscode.workspace.createFileSystemWatcher(
        new vscode.RelativePattern(vscode.Uri.file(base), glob));
      w.onDidChange(refresh); w.onDidCreate(refresh); w.onDidDelete(refresh);
      watchers.push(w); context.subscriptions.push(w);
    } catch (e) { /* watcher unavailable — the timer below still catches it */ }
  }
  // Safety net: file watchers outside the workspace are not guaranteed on every
  // platform, and this costs one ~15ms local probe.
  const timer = setInterval(refresh, 60000);
  context.subscriptions.push({ dispose: () => clearInterval(timer) });

  context.subscriptions.push(
    vscode.commands.registerCommand('claudeAccountStatus.refresh', refresh),
    vscode.window.onDidChangeWindowState((s) => { if (s.focused) refresh(); }),
    vscode.workspace.onDidChangeWorkspaceFolders(refresh),
  );
  refresh();
}

function deactivate() {}
module.exports = { activate, deactivate };
