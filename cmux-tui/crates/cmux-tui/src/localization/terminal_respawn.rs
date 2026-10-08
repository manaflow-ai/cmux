//! The marker line of a respawned terminal (cx-6so.49 L2), in every
//! supported language. The daemon installs the text of its language into
//! cmux-tui-core before it opens the session.

use cmux_tui_core::terminal_respawn_text::{ENGLISH, TerminalRespawnText};

static JAPANESE: TerminalRespawnText = TerminalRespawnText {
    restored: "\u{2014} セッションを復元しました（前のプロセスは終了しました） \u{2014}",
    restored_command: "\u{2014} セッションを復元しました（前のプロセスは終了しました。実行していたコマンド: {program}） \u{2014}",
    recovered_workspace: "復元されたターミナル",
};

fn text_for(catalog: &'static super::Catalog) -> &'static TerminalRespawnText {
    if std::ptr::eq(catalog, &super::JAPANESE) { &JAPANESE } else { &ENGLISH }
}

/// Give the daemon's terminal respawns the text of [`super::catalog`].
pub(crate) fn install() {
    cmux_tui_core::terminal_respawn_text::install(text_for(super::catalog()));
}

#[cfg(test)]
mod tests {
    #[test]
    fn every_language_has_the_respawn_marker() {
        let en = super::text_for(super::super::catalog_for_locale("en_US.UTF-8"));
        let ja = super::text_for(super::super::catalog_for_locale("ja_JP.UTF-8"));
        assert_eq!(en.restored, "\u{2014} session restored (previous process ended) \u{2014}");
        assert!(
            ja.restored_command.contains("{program}") && en.restored_command.contains("{program}")
        );
        assert_ne!(en.restored, ja.restored);
        assert_ne!(en.recovered_workspace, ja.recovered_workspace);
    }
}
