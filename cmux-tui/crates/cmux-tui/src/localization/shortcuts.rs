//! `shortcuts` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ShortcutMessages {
    pub title: &'static str,
    pub close_button: &'static str,
    pub footer: &'static str,
}

pub(super) const ENGLISH: ShortcutMessages = ShortcutMessages {
    title: "Keyboard shortcuts",
    close_button: "Esc close",
    footer: "↑/↓ or wheel scroll · Esc or ? close",
};

pub(super) const JAPANESE: ShortcutMessages = ShortcutMessages {
    title: "キーボードショートカット",
    close_button: "Esc 閉じる",
    footer: "↑/↓ またはホイールでスクロール · Esc または ? で閉じる",
};
