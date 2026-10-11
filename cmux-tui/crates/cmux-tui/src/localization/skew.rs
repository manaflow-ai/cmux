//! `skew` strings of the CLI catalog (English and Japanese): the version
//! skew re-exec line and its refusals (cli/skew.rs). `{…}` fields are
//! replaced at the call site; the fix command stays literal.

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct SkewMessages {
    /// `{own}` this CLI's build, `{daemon}` the daemon's build, `{cli}` its CLI.
    pub reexec: &'static str,
    /// `{daemon}` the daemon's build, `{why}` a refusal below, `{fix}` the command.
    pub refused: &'static str,
    pub loop_guard: &'static str,
    pub same_build: &'static str,
    /// `{uid}`.
    pub other_user: &'static str,
    pub not_the_daemon: &'static str,
    pub not_absolute: &'static str,
    pub not_regular_file: &'static str,
    pub not_in_cmux_bundle: &'static str,
    pub other_install_family: &'static str,
    /// `{path}`.
    pub writable: &'static str,
    /// `{path}`.
    pub other_owner: &'static str,
    /// `{why}`.
    pub team_id: &'static str,
    /// `{why}`.
    pub unreadable: &'static str,
    /// `{path}`, `{error}`.
    pub could_not_run: &'static str,
    /// A daemon without the session journal (cli/wire.rs).
    pub journal_unsupported: &'static str,
}

pub(super) const ENGLISH: SkewMessages = SkewMessages {
    reexec: "cmux: this CLI (build {own}) does not match the daemon (build {daemon}); running the daemon's CLI {cli}",
    refused: "cmux: the daemon runs build {daemon} and its CLI cannot be used ({why}); fix: {fix}",
    loop_guard: "this CLI was already started by a re-exec",
    same_build: "the daemon is this build",
    other_user: "the daemon runs as uid {uid}",
    not_the_daemon: "the socket peer is not the daemon process",
    not_absolute: "the daemon's CLI path is not absolute",
    not_regular_file: "the daemon's CLI is not a regular file",
    not_in_cmux_bundle: "the daemon's CLI is not inside a cmux app's Contents/Resources/bin",
    other_install_family: "the daemon's CLI belongs to another cmux install family",
    writable: "{path} is writable by group or other",
    other_owner: "{path} belongs to another user",
    team_id: "the daemon's CLI is not signed by this build's team: {why}",
    unreadable: "the daemon's CLI cannot be checked: {why}",
    could_not_run: "cmux: could not run {path}: {error}",
    journal_unsupported: "resident session does not support journal subscriptions; restart it with this cmux-tui binary",
};

pub(super) const JAPANESE: SkewMessages = SkewMessages {
    reexec: "cmux: この CLI (ビルド {own}) はデーモン (ビルド {daemon}) と一致しません。デーモンの CLI {cli} を実行します",
    refused: "cmux: デーモンはビルド {daemon} で動いていますが、その CLI は使えません ({why})。修正: {fix}",
    loop_guard: "この CLI はすでに再実行で起動されています",
    same_build: "デーモンはこのビルドです",
    other_user: "デーモンは uid {uid} で動いています",
    not_the_daemon: "ソケットの相手はデーモンのプロセスではありません",
    not_absolute: "デーモンの CLI のパスが絶対パスではありません",
    not_regular_file: "デーモンの CLI は通常のファイルではありません",
    not_in_cmux_bundle: "デーモンの CLI は cmux アプリの Contents/Resources/bin の中にありません",
    other_install_family: "デーモンの CLI は別の cmux インストール系統のものです",
    writable: "{path} はグループまたは他のユーザーが書き込めます",
    other_owner: "{path} は別のユーザーのものです",
    team_id: "デーモンの CLI はこのビルドのチームで署名されていません: {why}",
    unreadable: "デーモンの CLI を確認できません: {why}",
    could_not_run: "cmux: {path} を実行できませんでした: {error}",
    journal_unsupported: "常駐セッションはジャーナルの購読に対応していません。この cmux-tui バイナリで再起動してください",
};
