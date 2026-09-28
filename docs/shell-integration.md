# Shell integration: reducing Git watcher churn

`CMUX_NO_GIT_WATCH=1` is a **supported opt-out** for cmux's zsh and bash
Git integration. Use it to mitigate shell watcher process churn, including
frequent `sleep` launches and the resulting security-agent audit volume on
managed Macs. It can remain enabled; it is not an experimental or temporary-only
switch. The trade-off is losing shell-driven Git/PR updates and their immediate
cache-invalidation hints.

This is a shell setting, not an app-wide watcher switch. It does not stop cmux's
own Git filesystem watchers or shared GitHub PR polling, fix unrelated shell
integration problems, or remove orphaned processes from older sessions. It does
not control Git work done by your prompt theme, plugins, or commands.

## Enable and undo

Run this in each existing zsh or bash pane that needs the mitigation:

```sh
export CMUX_NO_GIT_WATCH=1
```

The shell applies it when the next cmux prompt hook runs. An already-running
command or child watcher has its previous environment until the shell regains
control; this is not an immediate process-wide stop. At that prompt, the
integration stops its tracked Git job and legacy PR loop, and zsh also stops its
HEAD watcher. It does not discover or reap detached watchers from other sessions.

For new panes, add the same export to the startup file your interactive shell
reads:

- **zsh:** `~/.zshrc` (or `$ZDOTDIR/.zshrc` when using a custom `ZDOTDIR`).
- **bash:** `~/.bashrc`; for login shells, ensure the active login file
  (`~/.bash_profile`, `~/.bash_login`, or `~/.profile`) sources it, or put the
  export in that file too.

Put it before startup commands that launch nested shells. Open a new pane and
check `printf '%s\n' "${CMUX_NO_GIT_WATCH:-unset}"`: it must print `1`.
Only the literal value `1` disables the feature; `true`, `0`, an empty value,
and an unset variable do not. No additional `CMUX_NO_PR_WATCH` setting is needed.

For managed Macs, deploy the export through the shell startup configuration
your organization already manages. A change in one pane does not modify
sibling panes or the running app's environment. Apply it to existing panes as
above, or replace those shells after saving their work. Remote shells need the
setting in their own environment/startup files; do not assume SSH or a tmux
server forwards a later local environment change.

To restore shell-driven updates, remove the startup export and run
`unset CMUX_NO_GIT_WATCH` in affected panes, or open new panes with it unset.
Updates resume through the normal prompt/command hooks.

## Exact scope in the current integrations

| Behavior | With `CMUX_NO_GIT_WATCH=1` |
| --- | --- |
| Prompt-time HEAD inspection and branch refresh | Disabled in both shells, including after `cd`, a branch change, or a Git command. No new async branch-report job is started. |
| HEAD watching during a foreground command | Disabled in zsh. Bash has no equivalent active foreground HEAD loop in the current integration. |
| Legacy per-shell PR polling | Startup is blocked in both shells. Current prompt/command hooks already do **not** start this poller, even with the flag unset; retained helper definitions are not evidence of active polling. |
| Shell branch/PR badge messages | Suppresses `report_git_branch`, `clear_git_branch`, HEAD-change `clear_pr`, and prompt-time `report_pr_action` hints after successful `gh pr` commands. It does not send a one-time clear to hide existing badges. |
| Shell PR caches and force signals | Cleanup still runs at prompts: existing per-panel `/tmp/cmux-pr-cache-<panel>.*` cache files and the PR force signal are removed, and pending action hints are discarded. Bash also removes its action-hint file. This is local cleanup, not a GitHub refresh or invalidation of the app's cache. |
| Git active-CWD marker | A fresh disabled shell does not create this temporary file. A marker created before enabling the flag may still be updated until shell-exit cleanup. |
| Other shell integration | CWD and TTY reporting, prompt/running activity messages, port-scan kicks, keyboard-protocol resets, terminal history, startup/PATH integration, and agent wrappers remain enabled. Commands such as `git` and `gh` still run normally. |
| App-owned metadata and watchers | Unchanged. The app can independently update branch/dirty/PR badges and poll GitHub; other panes and restored metadata can also supply badge state. |

Treat badge visibility and freshness separately: this opt-out removes shell
refreshes and immediate PR hints, so a badge may be absent or stale where those
were its source. A visible or still-updating badge does not mean the opt-out
failed. The shell branch report normally sends `--status=unknown`; the flag is
not a separate control for the app's dirty-status calculation.

Bash can still parse a PR command and briefly write its local hint file before
discarding it at the next prompt. Both shells can still send non-Git socket
messages and start work for other integration features. This setting therefore
does not promise zero child processes, zero filesystem activity, or zero
security-agent logs.

## Validate and troubleshoot

After setting the variable, return to the prompt in each affected pane, run a
command, change directories, and confirm normal shell use still works. For a
churn incident, compare process-launch measurements for those same panes before
and after; distinguish shell-owned watchers from app-owned watchers and other
programs. The environment value proves configuration, not that every source of
churn has stopped.

The source contract runs without launching cmux or contacting GitHub:

```sh
python3 tests/test_shell_no_git_watch.py
```

It sources the shipped [zsh](../Resources/shell-integration/cmux-zsh-integration.zsh)
and [bash](../Resources/shell-integration/cmux-bash-integration.bash) integrations
in isolated shells, checks disabled reports and watcher startup, cache cleanup,
preserved messages, literal-value semantics, and re-enabling reports. It replaces
message delivery and the watcher process-creation boundary; it does not measure
production launch rates or exercise the app's metadata services.

This support contract complements the watcher repairs rather than implementing
them: [#15066](https://github.com/manaflow-ai/cmux/issues/15066) /
[#6032](https://github.com/manaflow-ai/cmux/pull/6032) cover zsh fork-free waits,
[#15067](https://github.com/manaflow-ai/cmux/issues/15067) covers bash churn and
app-level ownership, [#10926](https://github.com/manaflow-ai/cmux/issues/10926)
tracks orphan lifecycle problems, and
[#2924](https://github.com/manaflow-ai/cmux/pull/2924) removes dead per-shell PR
polling code. Those fixes are still needed; this mitigation does not replace them.
