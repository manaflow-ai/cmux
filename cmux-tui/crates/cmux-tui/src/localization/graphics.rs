//! `graphics` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct GraphicsMessages {
    pub output_failed: &'static str,
    pub parser_recovery_failed: &'static str,
    pub(super) kitty_image_budget_worker_start_failed: &'static str,
    pub(super) kitty_image_budget_update_retrying: &'static str,
    pub(super) kitty_image_budget_update_exhausted: &'static str,
    pub(super) cell_pixel_update_retries_exhausted: &'static str,
    pub(super) browser_surface_resize_failed: &'static str,
}

impl GraphicsMessages {
    pub(crate) fn kitty_image_budget_worker_start_failed(&self, error: &str) -> String {
        self.kitty_image_budget_worker_start_failed.replace("{error}", error)
    }

    pub(crate) fn kitty_image_budget_update_failed(
        &self,
        retry_exhausted: bool,
        summary: &str,
    ) -> String {
        let template = if retry_exhausted {
            self.kitty_image_budget_update_exhausted
        } else {
            self.kitty_image_budget_update_retrying
        };
        template.replace("{summary}", summary)
    }

    pub(crate) fn cell_pixel_update_retries_exhausted(
        &self,
        attempts: u8,
        remaining: usize,
        cell_pixels: (u16, u16),
    ) -> String {
        self.cell_pixel_update_retries_exhausted
            .replace("{attempts}", &attempts.to_string())
            .replace("{remaining}", &remaining.to_string())
            .replace("{width}", &cell_pixels.0.to_string())
            .replace("{height}", &cell_pixels.1.to_string())
    }

    pub(crate) fn browser_surface_resize_failed(
        &self,
        surface: u64,
        cols: u16,
        rows: u16,
        error: &str,
    ) -> String {
        self.browser_surface_resize_failed
            .replace("{surface}", &surface.to_string())
            .replace("{cols}", &cols.to_string())
            .replace("{rows}", &rows.to_string())
            .replace("{error}", error)
    }
}

pub(super) const ENGLISH: GraphicsMessages = GraphicsMessages {
    output_failed: "Terminal graphics output failed; restoring the terminal",
    parser_recovery_failed: "Terminal graphics output could not reset the terminal parser; restoring the terminal",
    kitty_image_budget_worker_start_failed: "Failed to start Kitty image budget worker: {error}",
    kitty_image_budget_update_retrying: "Kitty image budget update failed, retrying: {summary}",
    kitty_image_budget_update_exhausted: "Kitty image budget update failed, stopped after exhausting retries: {summary}",
    cell_pixel_update_retries_exhausted: "Cell pixel update stopped after {attempts} retry attempts with {remaining} unconverged surface(s) at {width}x{height}; a later host acknowledgement can still recover",
    browser_surface_resize_failed: "Browser surface {surface} resize to {cols}x{rows} failed: {error}",
};

pub(super) const JAPANESE: GraphicsMessages = GraphicsMessages {
    output_failed: "ターミナル画像の出力に失敗したため、ターミナルを復元します",
    parser_recovery_failed: "ターミナル画像の出力後にパーサーをリセットできなかったため、ターミナルを復元します",
    kitty_image_budget_worker_start_failed: "Kitty 画像予算ワーカーを開始できませんでした: {error}",
    kitty_image_budget_update_retrying: "Kitty 画像予算の更新に失敗しました。再試行しています: {summary}",
    kitty_image_budget_update_exhausted: "Kitty 画像予算の更新に失敗し、再試行回数の上限に達したため停止しました: {summary}",
    cell_pixel_update_retries_exhausted: "セルピクセル更新は {attempts} 回の再試行後に停止しました。{width}x{height} で未収束のサーフェスが {remaining} 個あります。後続のホスト確認応答で復旧できます",
    browser_surface_resize_failed: "ブラウザサーフェス {surface} の {cols}x{rows} へのサイズ変更に失敗しました: {error}",
};
