//! `cmux cloud --help` and `cmux cloud <verb> --help`: every Cloud verb the
//! CLI offers, grouped, with what it does and the flags it takes. The verbs
//! are the catalog's offered `cloud …` actions
//! (plans/cmux-next/action-surfaces.json); a test fails when one is missing
//! here or one here is no longer offered. Each verb's full argument list is
//! the app's `cmux action describe cloud <verb>`.

/// Verbs the app still answers that `cmux cloud --help` no longer lists: the
/// old spelling of a `cmux machine` verb (cmuxterm-hq docs/naming.md).
/// `cmux cloud <verb> --help` still describes each and names the new one.
const HIDDEN: &[(&str, &str)] = &[("new-machine", "cmux vm new"), ("list-machines", "cmux vm ls")];

/// Verbs the app answers with a refusal on NEXT Cloud: cmux-platform has no
/// firewall rules or machine network policy yet (CloudHandlers+Network.swift,
/// CloudNetworkAccessActions.swift). Help still lists them, marked, so a
/// person or agent learns that before running one.
const NOT_ON_CLOUD_YET: &[&str] =
    &["firewall-list", "firewall-get", "firewall-create", "firewall-delete", "set-network-access"];

/// The CLI's own Cloud verb, not an app action: start a chat and send it a prompt
/// (cloud_start_chat.rs).
pub(super) const START_CHAT: &str = "start-chat";

/// The CLI-owned runtime backend selector (available before app startup).
pub(super) const ENV_USAGE: &str = "usage: cmux cloud env get [--backend NAME|ORIGIN] [--json]\n       cmux cloud env set local|dev|preview-N|staging|prod [--json]\n       cmux cloud env check-create --backend NAME|ORIGIN --params JSON [--json]\n\nThe selection is isolated to this app bundle. DEV and NEXT nightly may switch;\nRelease and RC default to prod and accept allowlisted launch backends.\nLaunch the app with --cloud-backend NAME or CMUX_NEXT_CLOUD_BACKEND.\ncheck-create performs a capability-only preflight and never creates a machine.\nSwitching requires a fresh Cloud sign-in.\n";

pub(super) const ENV_USAGE_JA: &str = "使い方: cmux cloud env get [--json]\n        cmux cloud env set local|dev|preview-N|staging|prod [--json]\n        cmux cloud env check-create --backend NAME|ORIGIN --params JSON [--json]\n\n選択はこのアプリのバンドルごとに保存されます。DEV と NEXT nightly は切り替え可能です。\ncheck-create は capability の事前確認だけを行い、マシンを作成しません。\nRelease と RC は既定で prod を使用し、許可された起動先へ切り替え可能です。切り替え後は Cloud に再度サインインしてください。\n";

/// A machine action's target flag.
const TARGET: &str = "--target vm:VM_ID";

struct Verb {
    name: &'static str,
    /// The flags after the verb; `{target}` is [`TARGET`].
    usage: &'static str,
    en: &'static str,
    ja: &'static str,
}

struct Group {
    en: &'static str,
    ja: &'static str,
    verbs: &'static [Verb],
}

const fn verb(name: &'static str, usage: &'static str, en: &'static str, ja: &'static str) -> Verb {
    Verb { name, usage, en, ja }
}

const GROUPS: &[Group] = &[
    Group {
        en: "MACHINES",
        ja: "マシン",
        verbs: &[
            verb(
                "list-machines",
                "",
                "List machines with their ids and targets",
                "マシンを ID と target 付きで一覧表示",
            ),
            verb(
                "new-machine",
                "[--size small|medium|large|xlarge] [--name NAME] [--persistent] [--repo OWNER/NAME[@REF]] [--environment ENV] [--machine-config FILE] [--bootstrap lane] [--bootstrap-script FILE]",
                "Create a machine; answers its machine_id",
                "マシンを作成し、machine_id を返す",
            ),
            verb("machine-status", "{target}", "A machine's state", "マシンの状態"),
            verb(
                "pause-machine",
                "{target}",
                "Pause a machine (resume-machine starts it)",
                "マシンを一時停止（resume-machine で再開）",
            ),
            verb(
                "resume-machine",
                "{target}",
                "Resume a paused machine",
                "一時停止中のマシンを再開",
            ),
            verb(
                "resize-machine",
                "{target} [--size small|medium|large|xlarge] [--disk GIB]",
                "Change its size (2 to 16 vCPU) or grow its disk",
                "サイズを変更（2〜16 vCPU）、またはディスクを拡張",
            ),
            verb(
                "rename-machine",
                "{target} --name NAME",
                "Rename a machine (an empty name clears it)",
                "マシン名を変更（空の名前で消去）",
            ),
            verb(
                "set-idle-pause",
                "{target} --minutes off|15|30|60|120",
                "Pause after this many idle minutes",
                "指定した分数アイドルが続いたら一時停止",
            ),
            verb(
                "kill-machine",
                "{target} --yes",
                "Delete a machine and everything on it",
                "マシンとその中身をすべて削除",
            ),
            verb(
                "fork-machine",
                "{target}",
                "Copy a machine into a new one",
                "マシンを新しいマシンに複製",
            ),
            verb(
                "hand-off-machine",
                "{target}",
                "Text that hands the machine to someone else",
                "マシンを他の人に引き継ぐためのテキスト",
            ),
        ],
    },
    Group {
        en: "RUN AND CONNECT",
        ja: "実行と接続",
        verbs: &[
            verb(
                "exec",
                "{target} --command COMMAND",
                "Run a command; answers exit_code, stdout, stderr",
                "コマンドを実行し、exit_code、stdout、stderr を返す",
            ),
            verb(
                "ssh",
                "{target} [--focus]",
                "Open a terminal tab on the machine",
                "マシンのターミナルタブを開く",
            ),
            verb(
                "new-terminal-on-machine",
                "{target} [--workspace WORKSPACE_ID] [--focus]",
                "Open a workspace with a terminal there",
                "ターミナル付きのワークスペースを開く",
            ),
            verb(
                "new-workspace",
                "",
                "Open a Cloud workspace (may create a machine)",
                "Cloud ワークスペースを開く（マシンを作成する場合あり）",
            ),
            verb(
                "start-session",
                "({target} | --name NAME) --agent AGENT [--model MODEL] [--cwd DIR | --from-folder PATH] [--login pass|machine|none]",
                "Start an agent session (claude, codex, ...) there",
                "エージェントセッション（claude、codex など）を開始",
            ),
            verb(
                "open-desktop",
                "{target} [--viewer rd]",
                "Show the machine's desktop in a new workspace",
                "マシンのデスクトップを新しいワークスペースに表示",
            ),
            verb(
                "setup-github",
                "{target} [--focus]",
                "Set up git and GitHub on the machine",
                "マシンに git と GitHub を設定",
            ),
            verb(
                "apply-machine-config",
                "{target} [--machine-config FILE]",
                "Apply a .cmux/machine.toml",
                ".cmux/machine.toml を適用",
            ),
            verb(
                "deliver-secrets",
                "{target} [--repo OWNER/NAME] [--names A,B]",
                "Send the secrets its machine config names (--names: your own machines only)",
                "マシン設定で宣言されたシークレットを送信（--names は自分のマシンのみ）",
            ),
        ],
    },
    Group {
        en: "FILES",
        ja: "ファイル",
        verbs: &[
            verb(
                "files-list",
                "{target} --path /DIR",
                "List a directory",
                "ディレクトリの中身を一覧表示",
            ),
            verb("file-read", "{target} --path /FILE", "Read a file", "ファイルを読む"),
            verb(
                "file-write",
                "{target} --path /FILE --contents TEXT",
                "Write text to a file",
                "ファイルにテキストを書き込む",
            ),
            verb("file-mkdir", "{target} --path /DIR", "Create a directory", "ディレクトリを作成"),
            verb("file-remove", "{target} --path /FILE --yes", "Remove a file", "ファイルを削除"),
            verb(
                "file-stat",
                "{target} --path /PATH",
                "A file's kind, size and mode",
                "ファイルの種類、サイズ、モード",
            ),
            verb(
                "prepare-scp",
                "{target} --public-key KEY",
                "Authorize a key for scp or sftp",
                "scp や sftp 用に鍵を許可",
            ),
        ],
    },
    Group {
        en: "SNAPSHOTS",
        ja: "スナップショット",
        verbs: &[
            verb(
                "snapshot-machine",
                "{target}",
                "Snapshot a machine; answers snapshot_id",
                "スナップショットを作成し、snapshot_id を返す",
            ),
            verb(
                "restore-machine",
                "{target} --snapshot SNAPSHOT_ID",
                "Start a new machine from a snapshot",
                "スナップショットから新しいマシンを起動",
            ),
            verb(
                "delete-snapshot",
                "{target} --snapshot SNAPSHOT_ID --yes",
                "Delete a snapshot",
                "スナップショットを削除",
            ),
            verb(
                "promote-machine-to-template",
                "{target}",
                "Save a machine as a template",
                "マシンをテンプレートとして保存",
            ),
        ],
    },
    Group {
        en: "PORTS",
        ja: "ポート",
        verbs: &[
            verb(
                "machine-ports",
                "{target}",
                "TCP ports listening on the machine",
                "マシンで待ち受け中の TCP ポート",
            ),
            verb(
                "port-list",
                "{target}",
                "Ports forwarded to this Mac",
                "この Mac に転送中のポート",
            ),
            verb(
                "port-forward",
                "{target} --port PORT",
                "Forward a port to this Mac",
                "ポートをこの Mac に転送",
            ),
            verb(
                "port-close",
                "{target} --port PORT",
                "Stop forwarding a port",
                "ポートの転送を停止",
            ),
            verb(
                "preview-share",
                "{target} --port PORT",
                "Copy a one-day link anyone can open to a port",
                "誰でも開けるポートへの 1 日有効なリンクをコピー",
            ),
            verb(
                "preview-revoke",
                "{target} --port PORT --link-id ID",
                "Revoke a port's shared link",
                "ポートの共有リンクを無効にする",
            ),
            verb(
                "open-browser",
                "{target} --port PORT [--path /PATH]",
                "Open a port in a browser tab",
                "ポートをブラウザタブで開く",
            ),
            verb(
                "machine-link",
                "{target} [--port PORT]",
                "The machine's address and links",
                "マシンのアドレスとリンク",
            ),
        ],
    },
    Group {
        en: "NETWORK",
        ja: "ネットワーク",
        verbs: &[
            verb("network-list", "", "List private networks", "プライベートネットワークを一覧表示"),
            verb(
                "tunnel-attach",
                "--arg path=NETWORK_ID",
                "Attach this Mac's tunnel to a network",
                "この Mac のトンネルをネットワークに接続",
            ),
            verb(
                "tunnel-detach",
                "--arg path=NETWORK_ID",
                "Detach this Mac's tunnel from a network",
                "この Mac のトンネルをネットワークから切断",
            ),
            verb(
                "tunnel-rotate-key",
                "",
                "Replace this Mac's tunnel key",
                "この Mac のトンネル鍵を置き換え",
            ),
            verb("firewall-list", "", "List firewall rules", "ファイアウォールルールを一覧表示"),
            verb(
                "firewall-get",
                "--arg path=RULE_ID",
                "Read a firewall rule",
                "ファイアウォールルールを読む",
            ),
            verb(
                "firewall-create",
                "--arg 'path=RULE_JSON'",
                "Create a firewall rule",
                "ファイアウォールルールを作成",
            ),
            verb(
                "firewall-delete",
                "--arg path=RULE_ID --yes",
                "Delete a firewall rule",
                "ファイアウォールルールを削除",
            ),
            verb(
                "set-network-access",
                "{target} --access full|trusted|none",
                "Set a machine's internet access",
                "マシンのインターネットアクセスを設定",
            ),
            verb("domain-list", "", "List domains", "ドメインを一覧表示"),
            verb("publication-list", "", "List publications", "公開設定を一覧表示"),
            verb(
                "provision-api",
                "{target} --port PORT [--name NAME]",
                "Publish a machine port as an API and create a key",
                "マシンのポートを API として公開し、キーを作成",
            ),
            verb(
                "api-key-list",
                "--path PUBLICATION",
                "List a publication's API keys",
                "公開設定の API キーを一覧表示",
            ),
            verb(
                "api-key-revoke",
                "--path PUBLICATION --key KEY_ID --yes",
                "Revoke a publication's API key",
                "公開設定の API キーを失効",
            ),
        ],
    },
    Group {
        en: "CHATS",
        ja: "チャット",
        verbs: &[
            verb(
                "move",
                "[--path DIR] [--machine vm:VM_ID]",
                "Move a chat tab to a Cloud machine",
                "チャットタブを Cloud マシンに移す",
            ),
            verb(
                "bring-back",
                "",
                "Bring a moved chat back to this Mac",
                "移したチャットをこの Mac に戻す",
            ),
            verb(
                "move-to-machine",
                "[--machine vm:VM_ID]",
                "Move a moved chat on to another Cloud machine",
                "移したチャットを別の Cloud マシンに移す",
            ),
        ],
    },
    Group {
        en: "ACCOUNT",
        ja: "アカウント",
        verbs: &[
            verb("sign-in", "", "Open the cmux sign-in page", "cmux のサインインページを開く"),
            verb("sign-out", "", "Sign this Mac out of cmux", "この Mac を cmux からサインアウト"),
            verb(
                "diagnostics",
                "",
                "Check sign-in, backend and machine links",
                "サインイン、バックエンド、マシン接続を確認",
            ),
            verb("open-mobile-pairing", "[--focus]", "Pair an iPhone", "iPhone をペアリング"),
        ],
    },
];

const INTRO_EN: &str = "\
USAGE
  cmux cloud <action> [--target vm:VM_ID] [--<argument> VALUE]...
  cmux cloud <action> --help

These actions run through the cmux app, signed in (`cmux login`).
The everyday verbs take the VM's name or id, or nothing when you have one VM:
  cmux cloud ls | status | pause | resume | rm | resize | fork | rename [NAME|ID]
  cmux cloud ssh | move [NAME|ID]  and  cmux cloud exec [NAME|ID] -- COMMAND...
The others take --target vm:VM_ID: `cmux cloud ls` prints each VM's
target. Without the app (CI, a headless agent), the VM API verbs below
(`cmux vm run`, `cmux vm new`, ...) talk to the cmux VM API directly.

QUICK START
  Start a Cloud chat, send it a prompt and print the reply, in one command
  (it answers reply, machine_id, session_id, workspace_id and tab_id;
  `cmux chat --help` has every flag):
  cmux chat --on vm:new --prompt 'Summarize README.md' --wait --json
  cmux chat --on vm:dev --prompt 'Run the tests' --json

  Then, the next prompt to that chat and its reply (SESSION_ID from the answer):
  cmux chat send SESSION_ID 'next prompt' --wait

  Machines:
  cmux cloud ls --json
  cmux vm new --size small --json
  cmux cloud exec dev -- uname -a
  cmux cloud ssh dev
  cmux cloud status dev
  cmux cloud pause dev
  cmux cloud resume dev
  cmux cloud rm dev
  (rm asks first at a terminal; --yes skips the question)
";

const INTRO_JA: &str = "\
使い方
  cmux cloud <アクション> [--target vm:VM_ID] [--<引数> VALUE]...
  cmux cloud <アクション> --help

これらのアクションはサインイン済みの cmux アプリ経由で動きます（`cmux login`）。
よく使う動詞は VM の名前か ID を取ります。VM が 1 台なら省略できます:
  cmux cloud ls | status | pause | resume | rm | resize | fork | rename [名前|ID]
  cmux cloud ssh | move [名前|ID]  と  cmux cloud exec [名前|ID] -- コマンド...
ほかのアクションは --target vm:VM_ID を取ります。各 VM の target は
`cmux cloud ls` で確認できます。アプリなしで使う場合（CI、画面のないエージェント）は、
下の VM API の動詞（`cmux vm run`、`cmux vm new` など）で cmux VM API を直接使えます。

クイックスタート
  Cloud チャットを開始し、プロンプトを送り、返信を表示する（1 コマンド。
  reply、machine_id、session_id、workspace_id、tab_id を返す。
  全フラグは `cmux chat --help`）:
  cmux chat --on vm:new --prompt 'Summarize README.md' --wait --json
  cmux chat --on vm:dev --prompt 'Run the tests' --json

  続けて同じチャットに次のプロンプトを送り、返信を表示する（SESSION_ID は返答から）:
  cmux chat send SESSION_ID 'next prompt' --wait

  マシン:
  cmux cloud ls --json
  cmux vm new --size small --json
  cmux cloud exec dev -- uname -a
  cmux cloud ssh dev
  cmux cloud status dev
  cmux cloud pause dev
  cmux cloud resume dev
  cmux cloud rm dev
  （rm はターミナルで確認します。--yes で確認を省略）
";

const OUTRO_EN: &str = "\
BACKEND (per NEXT app bundle)
  cmux cloud env get --json
  cmux cloud env set local|dev|preview-N|staging|prod --json
DEV and nightly may switch; Release and RC always use prod.

SECRETS (stored in this Mac's Keychain)
  cmux cloud secret set NAME [--repo OWNER/NAME]
  cmux cloud secret ls
  cmux cloud secret rm NAME [--repo OWNER/NAME]
set reads the value from a hidden prompt or stdin, never a command argument.

CLIENT SESSIONS (a scoped token for one of your machines, no app needed)
  cmux cloud client-session create --target vm:VM_ID [--ttl SECONDS] [--token-file PATH]
  cmux cloud client-session exec --target vm:VM_ID -- COMMAND...

`cmux vm rm NAME` asks first at a terminal; --yes (-y) skips the question.
Every other action that deletes something needs --yes.
Run `cmux action list --category cloud --json` for the live catalog and
`cmux action describe cloud <action> --json` for an action's arguments.
";

const OUTRO_JA: &str = "\
バックエンド（NEXT アプリのバンドルごと）
  cmux cloud env get --json
  cmux cloud env set local|dev|preview-N|staging|prod --json
DEV と nightly は切り替え可能です。Release と RC は既定で prod を使用し、許可された起動先へ切り替え可能です。

シークレット（この Mac のキーチェーンに保存）
  cmux cloud secret set NAME [--repo OWNER/NAME]
  cmux cloud secret ls
  cmux cloud secret rm NAME [--repo OWNER/NAME]
set は値を非表示の入力プロンプトまたは標準入力から読み取ります。コマンドの引数には指定しません。

クライアントセッション（自分のマシン 1 台だけに使える短期トークン、アプリ不要）
  cmux cloud client-session create --target vm:VM_ID [--ttl SECONDS] [--token-file PATH]
  cmux cloud client-session exec --target vm:VM_ID -- COMMAND...

`cmux vm rm 名前` はターミナルで確認します。--yes（-y）で確認を省略できます。
ほかの削除するアクションには --yes が必要です。
現在のカタログは `cmux action list --category cloud --json`、引数は
`cmux action describe cloud <アクション> --json` で確認できます。
";

/// `cmux cloud start-chat --help` (cloud_start_chat.rs runs it).
pub(super) const START_CHAT_USAGE: &str = "\
usage: cmux cloud start-chat [--prompt TEXT] [--agent AGENT] [--model MODEL]
                             [--cwd DIR | --from-folder PATH [--allow-large]]
                             [--login pass|machine|none] [--environment ENV]
                             [--name VM | --target vm:VM_ID]
                             [--wait] [--timeout SECONDS] [--make-room] [--json]

Starts an agent chat on a Cloud machine and sends it a prompt, in one step.
The chat opens as a tab in the machine's workspace in the cmux app.
This is `cmux chat --on vm:ID|NAME|new` (`cmux chat --help`), by its
older name; both run the same start.

  --prompt TEXT      What to send (`-` reads it from stdin). Without it the
                     chat starts and nothing is sent; the answer has ready_ms
                     and follow_up.send for the first message
  -- TEXT            The same as --prompt, read as text even when it starts
                     with `-`
  --agent AGENT      claude (default), codex, ...; claude/MODEL also names
                     the model
  --model MODEL      The model the agent starts on there (claude-haiku-5-5;
                     default: the harness's own)
  --cwd DIR          A folder on the machine (default: a new one under ~/chats)
  --from-folder PATH A folder on this Mac (relative: of this shell's folder),
                     copied to the machine as the composer's Cloud start
                     copies one; the chat starts in the copy. Never home,
                     the disk's root or a credential folder; not with
                     --cwd. The same command again on the same machine
                     reuses the finished copy.
  --allow-large      Copy --from-folder even past 20 GB or 500,000 files
                     (the files the copy sends), which are refused without it
  --login pass|machine|none
                     The agent's login there: yours from this Mac, the
                     machine's own, or none (default: the machine's login or
                     your earlier choice)
  --name VM          Use the VM with this name, or create it
  --target vm:VM_ID  Use this VM (`cmux vm ls`)
                     Neither: create a new small machine with a new name
  --environment ENV  Boot the new machine in this Cloud environment (its
                     env_ id or its name); not with --target
  --wait             Wait for the turn to end and print the reply (no
                     prompt: the chat is ready, nothing to wait for)
  --timeout SECONDS  How long --wait waits (default 900)
  --make-room        At a machine cap, free the machine the refusal offers
                     (a leftover it names is deleted; else the paused one
                     used longest ago is archived and deleted) and start again

Answers machine_id, machine_name, session_id, workspace_id and tab_id,
plus reply with --wait, or sent: false and ready_ms with no prompt, and
new_machine: true when this run made the machine.

EXAMPLES
  cmux cloud start-chat --prompt 'Summarize README.md' --wait --json
  cmux cloud start-chat --name dev --prompt 'Run the tests' --json
  cmux cloud start-chat --agent codex --login machine --json

FOLLOW-UPS (SESSION_ID from the answer)
  cmux chat send SESSION_ID 'next prompt' --wait

Run from an agent chat, it starts at once, as from a terminal: no card asks
the person. Only when they turned off cloud.agentsStartWithoutAsking does the
app ask first with a card in that chat (Start, Not now); `cmux agents dialog
list` lists it.
";

/// The CLI's own cleanup verbs, not app actions (cloud_retention.rs runs them).
pub(super) const KEEP: &str = "keep-machine";
pub(super) const ARCHIVE: &str = "archive-machine";

pub(super) const KEEP_USAGE: &str = "\
usage: cmux vm keep-machine --target vm:VM_ID [--off] [--json]

Keeps a machine: nothing deletes it automatically, whatever the plan's
cleanup. --off lets the plan's cleanup apply again. The machine's creator or
a team admin only.
";

pub(super) const ARCHIVE_USAGE: &str = "\
usage: cmux vm archive-machine --target vm:VM_ID --yes [--json]

Archives a paused machine's disk, then deletes the machine. The archive is a
snapshot kept for the plan's archive days; the Cloud page's Archives list it
and restore it as a new machine. It needs a person: when the CLI may not run
it, it says where the app offers it.
";

/// The new spelling of a hidden old verb.
/// Whether Cloud's `verb` deletes something and so takes `--yes` (the app's `--confirm`): its
/// usage here says `--yes`. Only these verbs get `--yes` respelled, so a `--yes` that is another
/// verb's value (`start-chat --prompt --yes`) stays as typed.
pub(super) fn confirms(verb: &str) -> bool {
    verb == ARCHIVE
        || GROUPS
            .iter()
            .flat_map(|group| group.verbs.iter())
            .any(|known| known.name == verb && known.usage.contains("--yes"))
}

pub(super) fn renamed(name: &str) -> Option<&'static str> {
    HIDDEN.iter().find(|(old, _)| *old == name).map(|(_, new)| *new)
}

fn find(name: &str) -> Option<&'static Verb> {
    GROUPS.iter().flat_map(|group| group.verbs).find(|verb| verb.name == name)
}

fn usage_line(verb: &Verb) -> String {
    let flags = verb.usage.replace("{target}", TARGET);
    if flags.is_empty() {
        format!("cmux vm {}", verb.name)
    } else {
        format!("cmux vm {} {flags}", verb.name)
    }
}

/// `cmux cloud --help`: the quick start, then every verb by group, one row
/// each, in one column so every description starts at the same place.
pub(super) fn overview(japanese: bool) -> String {
    let width =
        GROUPS.iter().flat_map(|group| group.verbs).map(|verb| verb.name.len()).max().unwrap_or(0);
    let mut text = String::from(if japanese { INTRO_JA } else { INTRO_EN });
    for group in GROUPS {
        text.push('\n');
        text.push_str(if japanese { group.ja } else { group.en });
        text.push('\n');
        for verb in group.verbs.iter().filter(|verb| renamed(verb.name).is_none()) {
            let not_yet = match (NOT_ON_CLOUD_YET.contains(&verb.name), japanese) {
                (false, _) => "",
                (true, false) => " (not on Cloud yet)",
                (true, true) => "（Cloud では未対応）",
            };
            let marker = if verb.usage.contains("--yes") { " (--yes)" } else { "" };
            let description = if japanese { verb.ja } else { verb.en };
            text.push_str(&format!("  {:width$}  {description}{not_yet}{marker}\n", verb.name));
        }
    }
    text.push_str(if japanese {
        "\nチャットのリポジトリ\n  repo list --session CHAT [--query NAME]\n  repo add --session CHAT --repo NAME [--ref REF]\n  repo wait-github --session CHAT [--timeout-ms N]\n  repo attached --session CHAT\n  repo local\n  repo sync --repos-json JSON [--recent-json JSON] [--install-url URL] [--complete true|false]\n"
    } else {
        "\nCHAT REPOSITORIES (use --socket for the Cloud machine)\n  repo list --session CHAT [--query NAME]\n  repo add --session CHAT --repo NAME [--ref REF]\n  repo wait-github --session CHAT [--timeout-ms N]\n  repo attached --session CHAT\n  repo local\n  repo sync --repos-json JSON [--recent-json JSON] [--install-url URL] [--complete true|false]\n"
    });
    text.push_str(if japanese {
        "\nクリーンアップ\n  keep-machine --target vm:VM_ID [--off]       自動で削除されないよう保持\n  archive-machine --target vm:VM_ID --yes      一時停止中のマシンをアーカイブして削除 (--yes)\n"
    } else {
        "\nCLEANUP\n  keep-machine --target vm:VM_ID [--off]       Keep a machine from automatic deletion\n  archive-machine --target vm:VM_ID --yes      Archive a paused machine's disk, then delete it (--yes)\n"
    });
    text.push('\n');
    text.push_str(if japanese { OUTRO_JA } else { OUTRO_EN });
    // `cmux cloud` is now `cmux vm` (vm.rs `cloud_alias`); the texts keep one spelling.
    text.replace("cmux cloud ", "cmux vm ").replace("cmux cloud`", "cmux vm`")
}

/// `cmux cloud <verb> --help`: that verb's usage and what it does. `None` for
/// a word that is not a Cloud verb, which gets the overview.
#[cfg_attr(not(unix), allow(dead_code))]
pub(super) fn verb_help(name: &str, japanese: bool) -> Option<String> {
    if name == "env" {
        return Some(if japanese { ENV_USAGE_JA } else { ENV_USAGE }.to_owned());
    }
    if name == START_CHAT {
        return Some(START_CHAT_USAGE.to_owned());
    }
    if name == KEEP {
        return Some(KEEP_USAGE.to_owned());
    }
    if name == ARCHIVE {
        return Some(ARCHIVE_USAGE.to_owned());
    }
    let verb = find(name)?;
    let usage = usage_line(verb);
    let note = renamed(name).map_or_else(String::new, |new| {
        if japanese {
            format!("`cmux vm {name}` は `{new}` の旧名です（`{new} --help`）。\n\n")
        } else {
            format!("`cmux vm {name}` is the old name of `{new}` (`{new} --help`).\n\n")
        }
    });
    let note = if !NOT_ON_CLOUD_YET.contains(&name) {
        note
    } else if japanese {
        note + "Cloud はまだこのアクションに対応していません。アプリは実行を断ります。\n\n"
    } else {
        note + "Cloud does not offer this yet: the app refuses it.\n\n"
    };
    Some(
        note + &if japanese {
            format!(
                "使い方: {usage}\n\n{}。\n\n全引数: `cmux action describe cloud {} --json`（アプリ起動中）\n",
                verb.ja, verb.name
            )
        } else {
            format!(
                "usage: {usage}\n\n{}.\n\nEvery argument: `cmux action describe cloud {} --json` (with the app running)\n",
                verb.en, verb.name
            )
        },
    )
}

/// The usage line alone, for a parse error that names the verb.
#[cfg_attr(not(unix), allow(dead_code))]
pub(super) fn usage(name: &str) -> Option<String> {
    find(name).map(usage_line)
}

#[cfg(test)]
mod tests;
