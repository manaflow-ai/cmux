# Working inside a Cloud machine

Read this for guest auth, the in-machine grammar, notifications or browser
authentication.

Every machine has its own `cmux`, a guest adapter over the machine's cmux-tui daemon
(session `cloud`). It passes the cmux-tui resource grammar through and adds a few
guest verbs. The machine's `cmux --help` is authoritative when versions differ.

## Guest auth and CodeRouter

```bash
cmux self --json                 # name, id, status, team, owner, plan
cmux self peers                  # the owner's other machines and their routes
cmux auth status --json
cmux coderouter status --json
cmux coderouter usage
cmux coderouter models
cmux coderouter agent claude "summarize the current checkout"
cmux agent codex "run the tests"
```

These describe the machine's daemon, TLS edge and VM-bound route. Account login and
upstream credential management stay on the Mac; do not copy those tokens into a VM.

## The grammar

| Where you are | What you address | Spelling |
|---|---|---|
| Mac | a machine | `cmux cloud <verb> --target machine:vm-…` app actions |
| Mac | the Mac's own session | the resource grammar (`cmux workspace list`, `cmux pane current split --right`) |
| inside a machine | this machine's session | the same resource grammar; `current` is the session's active workspace, pane and terminal; `$CMUX_TUI_TERMINAL_ID` is the caller's |
| inside a machine | the owner's machines | `cmux self peers`, or `cmux vm ls` where supported |
| inside a machine | myself | `cmux self [peers\|integrations\|owner\|machine] [--json]` |

The Mac's `cmux vm <verb> <machine> …` family and the guest's peer verbs
(`vm exec`, `vm terminal …`, `vm push`, `vm agent` toward another machine) were
removed. Open a terminal on the other machine instead.

## Drive this machine's session

```bash
cmux workspace list
cmux workspace create --name tests
cmux terminal list
cmux terminal term_… write --text $'bun test\n'
cmux terminal term_… screen wait --pattern 'pass|fail' --timeout-ms 600000
cmux terminal term_… screen read
cmux terminal term_… process wait --timeout-ms 600000
cmux terminal term_… output read
cmux terminal term_… keys ctrl+c
cmux layout apply --name app app.json
cmux env ls
cmux notify --title "done" --body "…"
cmux agent claude --timeout 600 "fix the tests"
```

`cmux agent <claude|codex|opencode|pi>` runs in the calling terminal until it exits;
its exit code passes through. `cmux env set|ls|rm|path` edits the machine env file
that every cmux shell and agent sources.

A pane on the Mac showing a machine terminal is an ordinary pane: closing it never
kills the machine's terminal.

## Notifications

`cmux notify` run inside a machine reaches the user's Mac as data: the daemon records
it and the Mac shows it on the pane displaying the terminal it ran in. `--title`,
`--subtitle` and `--body` are supported; `--desktop` is validated as `true|false` and
otherwise ignored; `--reply` is refused because a reply would type into a terminal
across the link.

## Arrange the view from inside the machine

Take workspace, screen, pane and tab IDs from `cmux workspace list`, `cmux pane list`
and `cmux tab list`:

```bash
cmux workspace ws_… rename --name "Review ready"
cmux tab tab_… rename --name "Test results"
cmux pane pane_… split --right --ratio 0.6
cmux tab tab_… move --workspace ws_… --screen screen_… --pane pane_… --index 0
cmux pane pane_… swap --other-workspace ws_… --other-screen screen_… --other-pane pane_…
cmux pane pane_… split ratio set --split split_… --ratio 0.65
cmux workspace ws_… move --index 0
cmux tab tab_… focus
```

Moving, renaming, swapping and changing split ratios preserve running terminal
processes. A terminal with several views should be moved by its tab ID. `layout
apply` is for new or empty workspaces; use the commands above to change an occupied
workspace without restarting its agents. Machine resource resizing is the app's
`cmux cloud resize-machine` action on the Mac.

## Browser authentication from guest terminals

`cmux open-url <http-or-https-url>` asks the Mac projecting that exact terminal
to open the URL using its terminal-link preference, without changing workspace
or keyboard focus. Create/heal installs `cmux-open-url`, PATH wrappers for
`xdg-open`, `x-www-browser`, and `sensible-browser`, and Bash/zsh/fish defaults
for `BROWSER` and `GH_BROWSER`. Explicit browser environment overrides survive.
Direct Chrome, `agent-browser`, and CUA keep their existing `DISPLAY=:1` behavior.

The opener uses a bounded, transient request over the authenticated cmux-tui
link, with a frontend delivery acknowledgement. No attached projection, old
binaries, denied placement, disconnect, or timeout prints `Open this URL: <url>`
and exits successfully so the auth CLI keeps polling. URLs are never stored as
notifications or replayed on reconnect.

ブラウザー認証: `cmux open-url <URL>` は、その端末を表示している Mac の
リンク設定に従って URL を開き、ワークスペースや入力フォーカスを変更しません。
接続されていない場合、旧バージョンの場合、配信失敗やタイムアウトの場合は
URL を表示して正常終了します。Chrome、`agent-browser`、CUA の `DISPLAY=:1`
での動作は変わりません。URL は通知として保存されず、再接続時にも再実行されません。

HTTP(S) MIME handlers also use `cmux-open-url`, covering absolute and CLI-bundled
`xdg-open` and GIO. File associations and direct Chrome launchers are unchanged.
HTTP(S) の MIME ハンドラーも cmux を使用します。ファイルの関連付けと
Chrome の直接起動は変更しません。
