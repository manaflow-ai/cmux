//! `pane_cli` strings of the CLI catalog (English and Japanese): the labels
//! of `cmux identify` in a cmux-tui pane (cli/pane_identify.rs), the root
//! help's heading for scopes that need the cmux app (cli/root_help.rs) and
//! the `cmux skill` usage (cli/skill.rs).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct PaneCliMessages {
    pub session: &'static str,
    pub machine: &'static str,
    pub workspace: &'static str,
    pub screen: &'static str,
    pub pane: &'static str,
    pub tab: &'static str,
    pub terminal: &'static str,
    pub socket: &'static str,
    pub outer_app: &'static str,
    pub guide: &'static str,
    /// `cmux identify` with no cmux app: the app row's label and value.
    pub app: &'static str,
    pub no_app: &'static str,
    /// The session does not place the caller's terminal: `{why}`.
    pub not_found: &'static str,
    /// The root help's heading over the app scopes when no cmux app answers.
    pub app_heading_unreachable: &'static str,
    /// The same in a cmux-tui pane whose session the reachable app does not own.
    pub app_heading_outer: &'static str,
    /// `cmux skill` without a known verb.
    pub skill_usage: &'static str,
    /// The warning row's label of `cmux identify`.
    pub warning: &'static str,
    /// `cmux identify` from a `cmux` of another build than the session
    /// daemon: `{own}` this build, `{daemon}` the daemon's, `{cli}` the
    /// daemon's own `cmux`.
    pub build_mismatch: &'static str,
}

pub(super) const ENGLISH: PaneCliMessages = PaneCliMessages {
    session: "cmux-tui session",
    machine: "machine",
    workspace: "workspace",
    screen: "screen",
    pane: "pane",
    tab: "tab",
    terminal: "terminal",
    socket: "socket",
    outer_app: "outer cmux app",
    guide: "agent guide",
    app: "cmux app",
    no_app: "none (this session runs headless; app commands need --app-socket PATH)",
    not_found: "not placed in this session ({why})",
    app_heading_unreachable: "CMUX APP (these scopes need the cmux app; none answers here)",
    app_heading_outer: "CMUX APP (the cmux app around this session; it does not own this session)",
    skill_usage: "usage: cmux skill show [--json]\n\n`cmux skill show` prints the agent guide for this cmux CLI, built from the\nCLI that runs it. --json prints it as {\"name\", \"version\", \"markdown\"}.\n",
    warning: "warning",
    build_mismatch: "this cmux is build {own}, but the session daemon is build {daemon}; run the session's own cmux: \"$CMUX_TUI_CLI\" ({cli})",
};

pub(super) const JAPANESE: PaneCliMessages = PaneCliMessages {
    session: "cmux-tui セッション",
    machine: "マシン",
    workspace: "ワークスペース",
    screen: "スクリーン",
    pane: "ペイン",
    tab: "タブ",
    terminal: "ターミナル",
    socket: "ソケット",
    outer_app: "外側の cmux アプリ",
    guide: "エージェントガイド",
    app: "cmux アプリ",
    no_app: "なし (このセッションはヘッドレスで動作中。アプリのコマンドには --app-socket パス が必要です)",
    not_found: "このセッションに配置されていません ({why})",
    app_heading_unreachable: "CMUX アプリ (これらのスコープには cmux アプリが必要です。ここでは応答するアプリがありません)",
    app_heading_outer: "CMUX アプリ (このセッションの外側の cmux アプリ。このセッションの所有者ではありません)",
    skill_usage: "使い方: cmux skill show [--json]\n\n`cmux skill show` は、この cmux CLI のエージェントガイドを、実行中の CLI から\n生成して表示します。--json は {\"name\", \"version\", \"markdown\"} として表示します。\n",
    warning: "警告",
    build_mismatch: "この cmux はビルド {own} ですが、セッションデーモンはビルド {daemon} です。セッション自身の cmux を使ってください: \"$CMUX_TUI_CLI\" ({cli})",
};
