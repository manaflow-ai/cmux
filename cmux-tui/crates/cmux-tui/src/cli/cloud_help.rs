//! `cmux cloud --help` and `cmux cloud <verb> --help`: every Cloud verb the
//! CLI offers, grouped, with what it does and the flags it takes. The verbs
//! are the catalog's offered `cloud …` actions
//! (plans/cmux-next/action-surfaces.json); a test fails when one is missing
//! here or one here is no longer offered. Each verb's full argument list is
//! the app's `cmux action describe cloud <verb>`.

/// A machine action's target flag.
const TARGET: &str = "--target machine:MACHINE_ID";

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
                "[--size small|medium|large|xlarge] [--name NAME] [--persistent] [--repo OWNER/NAME[@REF]] [--machine-config FILE] [--bootstrap lane] [--bootstrap-script FILE]",
                "Create a machine; answers its machine_id",
                "マシンを作成し、machine_id を返す",
            ),
            verb(
                "machine-status",
                "{target}",
                "State, CPU, memory, disk and hourly cost",
                "状態、CPU、メモリ、ディスク、時間あたりの料金",
            ),
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
                "{target} --size small|medium|large|xlarge",
                "Change its size (2 to 16 vCPU)",
                "サイズを変更（2〜16 vCPU）",
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
                "{target} --confirm",
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
            verb(
                "share-machine",
                "{target} [--teammate USER_ID] [--revoke]",
                "Share a team machine's chats with a teammate (no --teammate lists them)",
                "チームのマシンのチャットをチームメイトと共有（--teammate なしで一覧表示）",
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
                "({target} | --name NAME) --agent AGENT [--cwd DIR]",
                "Start an agent session (claude, codex, ...) there",
                "エージェントセッション（claude、codex など）を開始",
            ),
            verb(
                "open-desktop",
                "{target} [--viewer web]",
                "Show the machine's desktop in a browser tab",
                "マシンのデスクトップをブラウザタブに表示",
            ),
            verb(
                "setup-github",
                "{target} [--focus]",
                "Set up git and GitHub on the machine",
                "マシンに git と GitHub を設定",
            ),
            verb(
                "enroll-machine",
                "{target} [--ssh-key FILE] [--name HOST]",
                "Make it an ssh host and acpmux peer of this Mac",
                "この Mac の ssh ホストと acpmux ピアにする",
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
                "Send the secrets its machine config names",
                "マシン設定で宣言されたシークレットを送信",
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
            verb(
                "file-remove",
                "{target} --path /FILE --confirm",
                "Remove a file",
                "ファイルを削除",
            ),
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
                "{target} --snapshot SNAPSHOT_ID --confirm",
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
                "--public-key KEY",
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
                "--arg path=RULE_ID --confirm",
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
                "--path PUBLICATION --key KEY_ID --confirm",
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
                "[--path DIR] [--machine machine:MACHINE_ID]",
                "Move a chat tab to a Cloud machine",
                "チャットタブを Cloud マシンに移す",
            ),
            verb(
                "bring-back",
                "",
                "Bring a moved chat back to this Mac",
                "移したチャットをこの Mac に戻す",
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
  cmux cloud <action> [--target machine:MACHINE_ID] [--<argument> VALUE]...
  cmux cloud <action> --help

These actions run through the cmux app, signed in (`cmux cloud sign-in`).
An action on one machine needs --target machine:MACHINE_ID, even with one
machine: `cmux cloud list-machines` prints each machine's target. Without the
app (CI, a headless agent), `cmux machine --help` talks to the cmux VM API
directly.

QUICK START
  cmux cloud list-machines --json
  cmux cloud new-machine --size small --json
  cmux cloud exec --target machine:MACHINE_ID --command 'uname -a' --json
  cmux cloud pause-machine --target machine:MACHINE_ID
  cmux cloud resume-machine --target machine:MACHINE_ID
  cmux cloud kill-machine --target machine:MACHINE_ID --confirm
";

const INTRO_JA: &str = "\
使い方
  cmux cloud <アクション> [--target machine:MACHINE_ID] [--<引数> VALUE]...
  cmux cloud <アクション> --help

これらのアクションはサインイン済みの cmux アプリ経由で動きます（`cmux cloud sign-in`）。
特定のマシンを操作するアクションには、マシンが 1 台でも --target machine:MACHINE_ID が必要です。
各マシンの target は `cmux cloud list-machines` で確認できます。アプリなしで使う場合
（CI、画面のないエージェント）は、`cmux machine --help` で cmux VM API を直接使えます。

クイックスタート
  cmux cloud list-machines --json
  cmux cloud new-machine --size small --json
  cmux cloud exec --target machine:MACHINE_ID --command 'uname -a' --json
  cmux cloud pause-machine --target machine:MACHINE_ID
  cmux cloud resume-machine --target machine:MACHINE_ID
  cmux cloud kill-machine --target machine:MACHINE_ID --confirm
";

const OUTRO_EN: &str = "\
SECRETS (stored in this Mac's Keychain)
  cmux cloud secret set NAME [--repo OWNER/NAME]
  cmux cloud secret ls
  cmux cloud secret rm NAME [--repo OWNER/NAME]
set reads the value from a hidden prompt or stdin, never a command argument.

CLIENT SESSIONS (a scoped token for one of your machines, no app needed)
  cmux cloud client-session create --target machine:VM_ID [--ttl SECONDS] [--token-file PATH]
  cmux cloud client-session exec --target machine:VM_ID -- COMMAND...

Actions marked --confirm delete something and refuse to run without it.
Run `cmux action list --category cloud --json` for the live catalog and
`cmux action describe cloud <action> --json` for an action's arguments.
";

const OUTRO_JA: &str = "\
シークレット（この Mac のキーチェーンに保存）
  cmux cloud secret set NAME [--repo OWNER/NAME]
  cmux cloud secret ls
  cmux cloud secret rm NAME [--repo OWNER/NAME]
set は値を非表示の入力プロンプトまたは標準入力から読み取ります。コマンドの引数には指定しません。

クライアントセッション（自分のマシン 1 台だけに使える短期トークン、アプリ不要）
  cmux cloud client-session create --target machine:VM_ID [--ttl SECONDS] [--token-file PATH]
  cmux cloud client-session exec --target machine:VM_ID -- COMMAND...

--confirm が付くアクションは何かを削除するため、--confirm なしでは実行されません。
現在のカタログは `cmux action list --category cloud --json`、引数は
`cmux action describe cloud <アクション> --json` で確認できます。
";

fn find(name: &str) -> Option<&'static Verb> {
    GROUPS.iter().flat_map(|group| group.verbs).find(|verb| verb.name == name)
}

fn usage_line(verb: &Verb) -> String {
    let flags = verb.usage.replace("{target}", TARGET);
    if flags.is_empty() {
        format!("cmux cloud {}", verb.name)
    } else {
        format!("cmux cloud {} {flags}", verb.name)
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
        for verb in group.verbs {
            let marker = if verb.usage.contains("--confirm") { " (--confirm)" } else { "" };
            let description = if japanese { verb.ja } else { verb.en };
            text.push_str(&format!("  {:width$}  {description}{marker}\n", verb.name));
        }
    }
    text.push_str(if japanese {
        "\nチャットのリポジトリ\n  repo list --session CHAT [--query NAME]\n  repo add --session CHAT --repo NAME [--ref REF]\n  repo wait-github --session CHAT [--timeout-ms N]\n  repo attached --session CHAT\n  repo local\n  repo sync --repos-json JSON [--recent-json JSON] [--install-url URL] [--complete true|false]\n"
    } else {
        "\nCHAT REPOSITORIES (use --socket for the Cloud machine)\n  repo list --session CHAT [--query NAME]\n  repo add --session CHAT --repo NAME [--ref REF]\n  repo wait-github --session CHAT [--timeout-ms N]\n  repo attached --session CHAT\n  repo local\n  repo sync --repos-json JSON [--recent-json JSON] [--install-url URL] [--complete true|false]\n"
    });
    text.push('\n');
    text.push_str(if japanese { OUTRO_JA } else { OUTRO_EN });
    text
}

/// `cmux cloud <verb> --help`: that verb's usage and what it does. `None` for
/// a word that is not a Cloud verb, which gets the overview.
#[cfg_attr(not(unix), allow(dead_code))]
pub(super) fn verb_help(name: &str, japanese: bool) -> Option<String> {
    let verb = find(name)?;
    let usage = usage_line(verb);
    Some(if japanese {
        format!(
            "使い方: {usage}\n\n{}。\n\n全引数: `cmux action describe cloud {} --json`（アプリ起動中）\n",
            verb.ja, verb.name
        )
    } else {
        format!(
            "usage: {usage}\n\n{}.\n\nEvery argument: `cmux action describe cloud {} --json` (with the app running)\n",
            verb.en, verb.name
        )
    })
}

/// The usage line alone, for a parse error that names the verb.
#[cfg_attr(not(unix), allow(dead_code))]
pub(super) fn usage(name: &str) -> Option<String> {
    find(name).map(usage_line)
}

#[cfg(test)]
mod tests;
