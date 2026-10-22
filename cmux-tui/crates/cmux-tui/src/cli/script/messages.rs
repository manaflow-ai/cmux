//! `cmux script` messages in English and Japanese (crate::localization picks
//! the language from the locale).

pub(super) struct Messages {
    pub usage: &'static str,
    pub cancelled: &'static str,
    pub cancel_unconfirmed: &'static str,
    pub closed: &'static str,
    pub connect_failed: &'static str,
    pub bad_args: &'static str,
    pub bad_pair: &'static str,
    pub bad_timeout: &'static str,
    pub read_failed: &'static str,
    pub typescript: &'static str,
    pub restarted: &'static str,
    pub unsupported_daemon: &'static str,
    pub dropped_lines: &'static str,
    pub config_dir: &'static str,
    pub config_mode: &'static str,
}

static ENGLISH: Messages = Messages {
    usage: "usage: cmux script run (FILE | -e CODE | -) [KEY=VALUE ...] [--args JSON] [--timeout MS]\n       cmux script repl [--timeout MS]\n       cmux script types\n\n  run    Runs a JavaScript file, inline code or stdin in a sandboxed script session of the\n         session daemon and prints the value of its last expression. KEY=VALUE words and\n         --args JSON become `cmux.args`. Ctrl-C cancels (exit 130).\n  repl   Opens an interactive session: one line per cell (end a line with \\ to continue),\n         top-level await, bindings kept across cells. `.exit` or Ctrl-D ends it.\n  types  Prints the TypeScript declarations of the `cmux` global for editors.\n\n       cmux script status | reload | check [PATH]\n       cmux script action NAME [KEY=VALUE ...] [--args JSON]\n\n  status  Shows the config scripts (scripts/*.js beside the settings file) the daemon loaded:\n          their user actions, key bindings and key modes.\n  reload  Loads the config scripts again. A file with an error keeps the last good load.\n  check   Loads the config scripts, or PATH, without applying them, and reports errors.\n  action  Runs the user action user.NAME that a config script defines.\n\n  Scripts have no network, filesystem or process access; every `cmux.*` call is an op\n  the daemon checks.",
    cancelled: "cancelled",
    cancel_unconfirmed: "cancelled (no confirmation)",
    closed: "the daemon closed the connection before the script answered",
    connect_failed: "cannot connect to the session socket {path}: {error}",
    bad_args: "--args must be a JSON object: {error}",
    bad_pair: "script arguments are KEY=VALUE words: {word}",
    bad_timeout: "--timeout needs a number of milliseconds: {value}",
    read_failed: "cannot read {path}: {error}",
    typescript: "TypeScript files are not supported yet: {path} (run plain JavaScript)",
    restarted: "the session ended; a new one started (earlier bindings are gone)",
    unsupported_daemon: "this cmux daemon cannot run scripts: it is an older build than this CLI. Run the script's commands one at a time instead; do not stop the daemon, that ends its terminals.",
    dropped_lines: "{count} console lines were not shown (at most 200 per cell)",
    config_dir: "config scripts in {dir}:",
    config_mode: "  mode {mode}",
};

static JAPANESE: Messages = Messages {
    usage: "使い方: cmux script run (FILE | -e CODE | -) [KEY=VALUE ...] [--args JSON] [--timeout MS]\n        cmux script repl [--timeout MS]\n        cmux script types\n\n  run    JavaScript のファイル、インラインのコード、または標準入力を、セッションデーモンの\n         サンドボックス化されたスクリプトセッションで実行し、最後の式の値を表示します。\n         KEY=VALUE と --args JSON は `cmux.args` になります。Ctrl-C で取り消します (終了コード 130)。\n  repl   対話型セッションを開きます。1 行が 1 セルです (行末の \\ で続けます)。トップレベルの\n         await を使え、束縛はセルをまたいで残ります。`.exit` または Ctrl-D で終了します。\n  types  エディター用に `cmux` グローバルの TypeScript 宣言を表示します。\n\n        cmux script status | reload | check [PATH]\n        cmux script action NAME [KEY=VALUE ...] [--args JSON]\n\n  status  デーモンが読み込んだ設定スクリプト (設定ファイルの隣の scripts/*.js) と、その\n          ユーザーアクション、キー割り当て、キーモードを表示します。\n  reload  設定スクリプトを読み込み直します。エラーのあるファイルがあると、最後に正しく\n          読み込めた状態を保ちます。\n  check   設定スクリプト (または PATH) を適用せずに読み込み、エラーを報告します。\n  action  設定スクリプトが定義したユーザーアクション user.NAME を実行します。\n\n  スクリプトはネットワーク、ファイルシステム、プロセスにアクセスできません。`cmux.*` の\n  呼び出しはすべてデーモンが検査する操作です。",
    cancelled: "取り消しました",
    cancel_unconfirmed: "取り消しました (確認なし)",
    closed: "スクリプトが応答する前にデーモンが接続を閉じました",
    connect_failed: "セッションソケット {path} に接続できません: {error}",
    bad_args: "--args は JSON オブジェクトにしてください: {error}",
    bad_pair: "スクリプトの引数は KEY=VALUE の形にしてください: {word}",
    bad_timeout: "--timeout にはミリ秒の数値を指定してください: {value}",
    read_failed: "{path} を読み込めません: {error}",
    typescript: "TypeScript ファイルにはまだ対応していません: {path} (JavaScript で実行してください)",
    restarted: "セッションが終了したため、新しいセッションを開始しました (以前の束縛は失われました)",
    unsupported_daemon: "この cmux デーモンはスクリプトを実行できません。この CLI より古いビルドです。代わりにスクリプトのコマンドを一つずつ実行してください。デーモンを停止しないでください (ターミナルが終了します)。",
    dropped_lines: "コンソール出力 {count} 行を表示しませんでした (1 セルあたり最大 200 行)",
    config_dir: "{dir} の設定スクリプト:",
    config_mode: "  モード {mode}",
};

/// The messages for the CLI's language.
pub(super) fn messages() -> &'static Messages {
    let japanese = crate::localization::catalog_for_locale("ja");
    if std::ptr::eq(crate::localization::catalog(), japanese) { &JAPANESE } else { &ENGLISH }
}
