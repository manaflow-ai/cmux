//! The marker line of a respawned terminal (cx-6so.49 L2) and of a reopened
//! archived terminal (ARCHIVE-1), in every
//! supported language. The daemon installs the text of its language into
//! cmux-tui-core before it opens the session.

use cmux_tui_core::terminal_respawn_text::{ENGLISH, TerminalRespawnText};

static JAPANESE: TerminalRespawnText = TerminalRespawnText {
    restored: "\u{2014} セッションを復元しました（前のプロセスは終了しました） \u{2014}",
    restored_command: "\u{2014} セッションを復元しました（前のプロセスは終了しました。実行していたコマンド: {program}） \u{2014}",
    recovered_workspace: "復元されたターミナル",
    stopped: "\u{2014} このタブを閉じたときに {program} を停止しました \u{2014}",
};

fn text_for(catalog: &'static super::Catalog) -> &'static TerminalRespawnText {
    if std::ptr::eq(catalog, &super::JAPANESE) { &JAPANESE } else { &ENGLISH }
}

/// Give the daemon's terminal respawns the text of [`super::catalog`].
pub(crate) fn install() {
    cmux_tui_core::terminal_respawn_text::install(text_for(super::catalog()));
}
