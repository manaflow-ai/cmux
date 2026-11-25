//! `shortcuts` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ShortcutMessages {
    pub title: &'static str,
    pub close_button: &'static str,
    pub footer: &'static str,
    /// First line of `cmux help keys`: `{prefix}` is the prefix chord and
    /// `{show}` the key that shows the list inside the TUI.
    pub cli_intro: &'static str,
}

pub(super) const ENGLISH: ShortcutMessages = ShortcutMessages {
    title: "Keyboard shortcuts",
    close_button: "Esc close",
    footer: "↑/↓ or wheel scroll · Esc or ? close",
    cli_intro: "Key bindings of the cmux-tui TUI. The prefix is {prefix}: press it, then the \
                key after it. Inside the TUI, {show} shows this list. The keys section of the \
                cmux-tui config changes them.",
};

pub(super) const JAPANESE: ShortcutMessages = ShortcutMessages {
    title: "キーボードショートカット",
    close_button: "Esc 閉じる",
    footer: "↑/↓ またはホイールでスクロール · Esc または ? で閉じる",
    cli_intro: "cmux-tui の TUI のキー割り当てです。プレフィックスは {prefix} です。これを押してから、\
                続くキーを押します。TUI 内では {show} でこの一覧を表示します。cmux-tui の設定の \
                keys セクションで変更できます。",
};
