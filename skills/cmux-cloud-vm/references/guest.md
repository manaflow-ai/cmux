# Working inside a Cloud machine

Read this for guest auth, peer access or presentation behavior.

## Guest auth and CodeRouter

Start with `cmux self --json` to identify the current machine, then use
`cmux self peers` to discover the owner's reachable machines. The guest reads
that reflection through its VM-bound TLS edge without a Mac account token. Host
lifecycle verbs still run on the Mac; read the guest's `cmux --help` for the
subset its image supports.

Inside a Cloud machine, the guest `cmux` adapter can report route health and run
an agent through the shared CodeRouter without exposing the Mac's Stack session:

```bash
cmux auth status --json
cmux coderouter status --json
cmux coderouter usage
cmux coderouter models
cmux coderouter agent claude "summarize the current checkout"
cmux agent codex "run the tests"
```

These commands describe the machine's daemon, TLS edge, and VM-bound route.
Host account login and upstream credential management remain on the Mac; do not
copy those tokens into a VM. `vm agent` still starts a detached terminal on the
selected machine, while the guest `cmux agent` form runs through CodeRouter.

## The grammar (one spelling per concept)

| Where you are | What you address | Spelling |
|---|---|---|
| Mac | a machine | `cmux vm <verb> <machine> …` — everything about machines lives here |
| Mac | this Mac's own session | the unprefixed local verbs (`cmux send-key`, `cmux new-workspace`, …) |
| inside a machine | **this** machine's session | the same unprefixed local verbs as on a Mac (`cmux send-key`, `cmux terminal send`, `cmux layout apply`, `cmux env set`, `cmux notify`) |
| inside a machine | **another** machine | `cmux vm <verb> <machine> …` — the same grammar as on the Mac |
| inside a machine | the owner's machines | `cmux self peers` (with reachability) |
| inside a machine | myself | `cmux self [peers\|integrations\|owner\|machine] [--json]` (aliases: `cmux whoami`, `cmux reflect [<path>]`) |
| Mac | a machine's identity | `cmux vm self <machine> [<path>] [--json]` — the same reflection payloads through your session |

## Inside a machine: the same verbs, and other machines

Every machine has its own `cmux` (a shim over its cmux-tui daemon). An agent running *in* the machine drives its own session with the Mac spellings — the target defaults to its own terminal (`$CMUX_TUI_TERMINAL_ID`):

```bash
cmux self                               # who am I: name, id, status, team, owner, plan (reflection; no credential in the guest)
cmux self peers                         # the owner's other machines and their routes; `cmux self integrations` = what I can use, with help commands
cmux self peers                         # the owner's other machines and their reachable/linked state
cmux tree --json                        # this machine's workspaces/terminals
cmux new-workspace --name tests         # a workspace here
cmux terminal send <term> 'bun test' --keys enter ; cmux terminal wait <term> --pattern 'pass|fail' ; cmux terminal read <term>
cmux terminal wait-exit <term> --timeout 600 ; cmux terminal output <term>   # block until the process exits, then read the full output (not just the screen)
cmux send-key --terminal <term> ctrl+c  # keys into another terminal on this machine
cmux layout apply --name app app.json   # the same layout verb, locally
cmux env ls                             # the same env file
cmux notify --title "done" --body "…"   # lands on the Mac pane showing this terminal
cmux agent claude --timeout 600 "fix the tests"     # runs in this terminal until it exits (it is the wait; exit code passes through; --timeout caps it)
```

To talk to **another** machine (a second agent, a service box), a machine discovers its peers through reflection (`cmux self peers`; the owner's private network is the trust boundary, so no Mac step is needed — older Mac-written route files still work). Inside a machine, `cmux vm …` takes the peer as its first argument with the same grammar the Mac uses: `cmux vm tree <dst>`, `cmux vm exec <dst> -- <cmd>`, `cmux vm terminal send|read|wait|close <dst> <term> …`, `cmux vm terminal send <dst> <term> enter`, `cmux vm workspace new|rename|close|rm <dst> …`, `cmux vm agent --machine <dst> --agent codex -- "review work/app"` (a durable terminal on the peer running the peer's own agent config), `cmux vm layout export|apply <dst> …`, `cmux vm env set|ls|rm <dst> …`, `cmux vm push <dst> <file> <remote-path>` (one file over the link, secret-safe), `cmux vm agent --machine <dst> … --wait --output` (until the peer's agent exits). No control-plane credential lives in any VM; a machine reaches only machines of its own owner.

A pane showing a machine surface is an ordinary local pane: move, split, reorder, or close it with the local topology verbs ([local topology](../../cmux/SKILL.md)) and the surface catalog follows the pane; closing a pane never kills the machine's terminal. A local workspace that *mirrors* a machine workspace (opened with `cmux vm workspace open`, or bound with `workspace.cloud_vm_bind`) is that workspace seen from the Mac, so its structure is the machine's: a pane moved into it takes its tab there (a pool terminal gets one), a terminal pane closed in it closes that tab (the terminal detaches into the Terminals pool, still running), and a tab or workspace renamed there is renamed on the machine. Closing the local workspace itself (⌘⇧W) only ends the view: the machine workspace and its terminals stay exactly as they were. Panes in any other local workspace are viewers and never touch the machine's layout. Rearranging the machine's topology in full is what `cmux vm tui <id>` is for.

## Notifications

`cmux notify` run inside a machine reaches the user's Mac as data: the machine's daemon records it and the Mac shows it on the pane displaying the terminal it ran in (or at workspace level wherever the machine is open; nowhere if nothing of the machine is on screen). Keep `--title`/`--body` short (128 B / 1 KiB caps, 5 per burst then 1 per second); `--subtitle` folds into the body; Mac selectors (`--workspace`, `--surface`, `--window`, `--tab`, `--panel`) and `--reply` are ignored there, and nothing can be typed back into the machine from the notification.

## Arrange the view from inside the machine

Use these commands in a daemon terminal (`cmux tree --json` supplies workspace,
screen, pane, split and tab IDs):

```bash
cmux workspace rename <ws> "Review ready"
cmux terminal rename current "Builder" --json
cmux tab rename <tab> "Test results" --json
cmux pane split <pane> right --ratio 0.6 --json
cmux tab move <tab> --workspace <ws> --screen <screen> --pane <destination-pane> --index 0 --json
cmux pane swap <pane> --other-workspace <ws> --other-screen <screen> --other-pane <other-pane> --json
cmux pane resize <pane> --split <split> --ratio 0.65 --json
cmux workspace move <ws> --index 0
cmux tab focus <tab>
cmux notify --title "Review ready" --body "The workspace has the app, logs, and test results."
```

`tab rename` labels one placement; `terminal rename` labels every current placement
of that terminal. Names, including spaces and an empty string, are passed as exact
arguments. A terminal with several views should be moved by its tab ID. Moving,
renaming, swapping, and changing split ratios preserve running terminal processes.
`pane resize` changes layout geometry. Machine resource resizing uses `vm resize` and preserves the existing VM identity and data.

Resource commands use `cmux <resource> <verb> …`; a peer uses
`cmux vm <resource> <verb> <machine> …` (for example,
`cmux vm tab rename <machine> <tab> "Logs"`). Top-level verbs retain their
existing forms, such as `cmux send-key`, `cmux new-workspace`, `cmux agent`, and
`cmux notify`. Existing ID-first daemon syntax is also supported. `cmux workspace
help` lists the full topology grammar.

Arrange the daemon workspace before presenting it. The Mac's
`cmux vm workspace open <machine> <ws>` reads that layout when creating its local
view. These guest commands do not force focus or rearrange an already-open Mac
projection. `layout apply` is for new/empty workspaces; use the commands above to
change an occupied workspace without restarting its agents.

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
notifications or replayed on reconnect. This requires the updated daemon and
Mac client; older combinations safely use the printable fallback.

ブラウザー認証: `cmux open-url <URL>` は、その端末を表示している Mac の
リンク設定に従って URL を開き、ワークスペースや入力フォーカスを変更しません。
接続されていない場合、旧バージョンの場合、配信失敗やタイムアウトの場合は
URL を表示して正常終了します。Chrome、`agent-browser`、CUA の `DISPLAY=:1`
での動作は変わりません。URL は通知として保存されず、再接続時にも再実行されません。

HTTP(S) MIME handlers also use `cmux-open-url`, covering absolute and CLI-bundled
`xdg-open` and GIO. File associations and direct Chrome launchers are unchanged.
HTTP(S) の MIME ハンドラーも cmux を使用します。ファイルの関連付けと
Chrome の直接起動は変更しません。
