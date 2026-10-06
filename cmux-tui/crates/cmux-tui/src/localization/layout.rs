//! `layout` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct LayoutMessages {
    pub startup_shortcuts: &'static str,
    pub verb_help_heading: &'static str,
    pub new_pane_right_help: &'static str,
    pub set_viewport_pane_width_help: &'static str,
    pub undo_layout_help: &'static str,
    pub create_viewport_pane_operation: &'static str,
    pub undo_layout_operation: &'static str,
    pub resize_exact_split_operation: &'static str,
    pub split_id_subject: &'static str,
    pub resize_viewport_pane_operation: &'static str,
    pub viewport_pane_subject: &'static str,
    pub remote_viewport_panes_unsupported: &'static str,
    pub ratio_must_be_number: &'static str,
    pub ratio_must_be_finite: &'static str,
    pub viewport_width_must_be_number: &'static str,
    pub viewport_width_must_be_finite: &'static str,
    pub viewport_width_out_of_range: &'static str,
    pub(super) surface_size_release_failed: &'static str,
    pub(super) pane_without_resizable_column: &'static str,
    pub remote_viewport_resize_unsupported: &'static str,
    pub remote_layout_undo_unsupported: &'static str,
    pub layout_undo_missing_screen: &'static str,
    pub layout_undo_missing_revision: &'static str,
    pub layout_undo_missing_closes_panes: &'static str,
    pub layout_undo_invalid_pane: &'static str,
    pub layout_undo_missing_outcome: &'static str,
    pub layout_undo_confirmation_flags_together: &'static str,
    pub layout_changed_before_undo: &'static str,
    pub(super) unknown_split: &'static str,
    pub(super) unknown_pane_split: &'static str,
    pub(super) unrepresentable_viewport_width: &'static str,
    pub(super) unrepresentable_viewport_ratio: &'static str,
    pub row_split_readonly: &'static str,
    pub viewport_ratio_target_missing: &'static str,
    pub viewport_ratio_out_of_range: &'static str,
    pub viewport_column_missing: &'static str,
    pub(super) unsupported_server_command: &'static str,
    pub(super) layout_undo_applied: &'static str,
    pub(super) layout_undo_confirmation_required: &'static str,
}

impl LayoutMessages {
    pub(crate) fn surface_size_release_failed(&self, surface: u64, error: &str) -> String {
        self.surface_size_release_failed
            .replace("{surface}", &surface.to_string())
            .replace("{error}", error)
    }

    pub(crate) fn pane_without_resizable_column(&self, pane: u64) -> String {
        self.pane_without_resizable_column.replace("{pane}", &pane.to_string())
    }

    pub(crate) fn unknown_split(&self, split: u64) -> String {
        self.unknown_split.replace("{split}", &split.to_string())
    }

    pub(crate) fn unknown_pane_split(&self, pane: u64) -> String {
        self.unknown_pane_split.replace("{pane}", &pane.to_string())
    }

    pub(crate) fn unrepresentable_viewport_width(
        &self,
        split: u64,
        ratio: f32,
        width: f32,
    ) -> String {
        self.unrepresentable_viewport_width
            .replace("{split}", &split.to_string())
            .replace("{ratio}", &ratio.to_string())
            .replace("{width}", &width.to_string())
    }

    pub(crate) fn unrepresentable_viewport_ratio(&self, split: u64, ratio: f32) -> String {
        self.unrepresentable_viewport_ratio
            .replace("{split}", &split.to_string())
            .replace("{ratio}", &ratio.to_string())
    }

    #[cfg(test)]
    pub(crate) fn unsupported_server_command(&self, command: &str) -> String {
        self.unsupported_server_command.replace("{command}", command)
    }

    #[cfg(test)]
    pub(crate) fn layout_undo_applied(&self, screen: u64, revision: u64) -> String {
        self.layout_undo_applied
            .replace("{screen}", &screen.to_string())
            .replace("{revision}", &revision.to_string())
    }

    #[cfg(test)]
    pub(crate) fn layout_undo_confirmation_required(&self, revision: u64, panes: &str) -> String {
        self.layout_undo_confirmation_required
            .replace("{revision}", &revision.to_string())
            .replace("{panes}", panes)
    }
}

pub(super) const ENGLISH: LayoutMessages = LayoutMessages {
    startup_shortcuts: "  g  new 2/3 column right   U    undo layout",
    verb_help_heading: "VERB HELP",
    new_pane_right_help: "Create a viewport pane to the right (default width: two-thirds).",
    set_viewport_pane_width_help: "Set the viewport width of the column containing a pane.",
    undo_layout_help: "Undo the latest structural layout change.",
    create_viewport_pane_operation: "create viewport pane",
    undo_layout_operation: "undo layout",
    resize_exact_split_operation: "resize exact pane split",
    split_id_subject: "split id",
    resize_viewport_pane_operation: "resize viewport pane",
    viewport_pane_subject: "viewport pane",
    remote_viewport_panes_unsupported: "remote cmux server does not support viewport panes; upgrade the server before using new-pane-right",
    ratio_must_be_number: "--ratio must be a number",
    ratio_must_be_finite: "--ratio must be a finite number",
    viewport_width_must_be_number: "--width must be a number",
    viewport_width_must_be_finite: "--width must be a finite number",
    viewport_width_out_of_range: "viewport pane width must be between 0.1 and 1.0",
    surface_size_release_failed: "surface {surface} size release failed; retrying on the next layout: {error}",
    pane_without_resizable_column: "pane {pane} has no resizable viewport column",
    remote_viewport_resize_unsupported: "remote cmux server does not support viewport pane resizing; upgrade the server",
    remote_layout_undo_unsupported: "remote cmux server does not support layout undo; upgrade the server",
    layout_undo_missing_screen: "layout undo response is missing screen",
    layout_undo_missing_revision: "layout undo response is missing revision",
    layout_undo_missing_closes_panes: "layout undo response is missing closes_panes",
    layout_undo_invalid_pane: "layout undo response contains an invalid pane",
    layout_undo_missing_outcome: "layout undo response does not contain exactly one valid outcome",
    layout_undo_confirmation_flags_together: "--revision and --confirm-close must be supplied together",
    layout_changed_before_undo: "layout changed before undo",
    unknown_split: "unknown split {split}",
    unknown_pane_split: "unknown pane/split {pane}",
    unrepresentable_viewport_width: "split {split} ratio {ratio} implies viewport width {width}; width must be between 0.1 and 1",
    unrepresentable_viewport_ratio: "split {split} ratio {ratio} cannot be represented as a viewport width between 0.1 and 1",
    row_split_readonly: "this split joins two rows; set row heights instead",
    viewport_ratio_target_missing: "the pane or split no longer exists",
    viewport_ratio_out_of_range: "the requested ratio cannot be represented by a viewport width between 0.1 and 1",
    viewport_column_missing: "the pane has no resizable viewport column",
    unsupported_server_command: "{command} is not supported by this server",
    layout_undo_applied: "undone screen={screen} revision={revision}",
    layout_undo_confirmation_required: "confirmation required: rerun with --revision {revision} --confirm-close (closes panes {panes})",
};

pub(super) const JAPANESE: LayoutMessages = LayoutMessages {
    startup_shortcuts: "  g  右に 2/3 幅の列を追加   U    レイアウトを元に戻す",
    verb_help_heading: "コマンドヘルプ",
    new_pane_right_help: "右側にビューポートペインを作成（既定の幅: 3 分の 2）。",
    set_viewport_pane_width_help: "ペインを含むビューポート列の幅を設定。",
    undo_layout_help: "直前のレイアウト変更を元に戻す。",
    create_viewport_pane_operation: "ビューポートペインを作成",
    undo_layout_operation: "レイアウトを元に戻す",
    resize_exact_split_operation: "ペイン分割のサイズを変更",
    split_id_subject: "分割 ID",
    resize_viewport_pane_operation: "ビューポートペインのサイズを変更",
    viewport_pane_subject: "ビューポートペイン",
    remote_viewport_panes_unsupported: "リモート cmux サーバーはビューポートペインに対応していません。new-pane-right を使用する前にサーバーをアップグレードしてください",
    ratio_must_be_number: "--ratio には数値を指定してください",
    ratio_must_be_finite: "--ratio には有限の数値を指定してください",
    viewport_width_must_be_number: "--width には数値を指定してください",
    viewport_width_must_be_finite: "--width には有限の数値を指定してください",
    viewport_width_out_of_range: "ビューポートペインの幅は 0.1 から 1.0 の範囲で指定してください",
    surface_size_release_failed: "サーフェス {surface} のサイズ設定の解放に失敗しました。次回のレイアウト更新時に再試行します: {error}",
    pane_without_resizable_column: "ペイン {pane} にはサイズ変更可能なビューポート列がありません",
    remote_viewport_resize_unsupported: "リモート cmux サーバーはビューポートペインのサイズ変更に対応していません。サーバーをアップグレードしてください",
    remote_layout_undo_unsupported: "リモート cmux サーバーはレイアウトの取り消しに対応していません。サーバーをアップグレードしてください",
    layout_undo_missing_screen: "レイアウト取り消し応答にスクリーンがありません",
    layout_undo_missing_revision: "レイアウト取り消し応答にリビジョンがありません",
    layout_undo_missing_closes_panes: "レイアウト取り消し応答に closes_panes がありません",
    layout_undo_invalid_pane: "レイアウト取り消し応答に無効なペインがあります",
    layout_undo_missing_outcome: "レイアウト取り消し応答に有効な結果が1つだけ含まれていません",
    layout_undo_confirmation_flags_together: "--revision と --confirm-close は同時に指定してください",
    layout_changed_before_undo: "取り消し前にレイアウトが変更されました",
    unknown_split: "分割 {split} が見つかりません",
    unknown_pane_split: "ペインまたは分割 {pane} が見つかりません",
    unrepresentable_viewport_width: "分割 {split} の比率 {ratio} ではビューポート幅が {width} になります。幅は 0.1 から 1 の範囲で指定してください",
    unrepresentable_viewport_ratio: "分割 {split} の比率 {ratio} は 0.1 から 1 の範囲のビューポート幅では表現できません",
    row_split_readonly: "この分割は2つの行の境界です。行の高さを設定してください",
    viewport_ratio_target_missing: "対象のペインまたは分割が存在しません",
    viewport_ratio_out_of_range: "指定した比率は 0.1 から 1 の範囲のビューポート幅では表現できません",
    viewport_column_missing: "対象のペインにはサイズ変更可能なビューポート列がありません",
    unsupported_server_command: "{command} はこのサーバーではサポートされていません",
    layout_undo_applied: "元に戻しました screen={screen} revision={revision}",
    layout_undo_confirmation_required: "確認が必要です: --revision {revision} --confirm-close を付けて再実行してください（閉じるペイン: {panes}）",
};
