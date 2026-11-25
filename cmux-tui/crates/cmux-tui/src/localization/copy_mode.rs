//! `copy_mode` strings of the TUI catalog (English and Japanese): the mode
//! line of keyboard copy mode and its notices.

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct CopyModeMessages {
    pub mode_copy: &'static str,
    pub mode_visual: &'static str,
    pub mode_visual_line: &'static str,
    pub mode_visual_block: &'static str,
    pub hint_select: &'static str,
    pub hint_copy: &'static str,
    pub hint_search: &'static str,
    pub hint_exit: &'static str,
    pub nothing_selected: &'static str,
    pub no_match: &'static str,
    pub no_previous_search: &'static str,
}

pub(super) const ENGLISH: CopyModeMessages = CopyModeMessages {
    mode_copy: "COPY",
    mode_visual: "VISUAL",
    mode_visual_line: "V-LINE",
    mode_visual_block: "V-BLOCK",
    hint_select: "select",
    hint_copy: "copy",
    hint_search: "search",
    hint_exit: "exit",
    nothing_selected: "Nothing selected",
    no_match: "No match",
    no_previous_search: "No previous search",
};

pub(super) const JAPANESE: CopyModeMessages = CopyModeMessages {
    mode_copy: "コピー",
    mode_visual: "ビジュアル",
    mode_visual_line: "行選択",
    mode_visual_block: "矩形選択",
    hint_select: "選択",
    hint_copy: "コピー",
    hint_search: "検索",
    hint_exit: "終了",
    nothing_selected: "選択範囲がありません",
    no_match: "一致なし",
    no_previous_search: "前回の検索がありません",
};
