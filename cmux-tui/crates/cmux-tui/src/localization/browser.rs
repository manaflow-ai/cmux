//! `browser` strings of the CLI catalog (English and Japanese).

use cmux_tui_core::BrowserFailure;

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct BrowserMessages {
    pub(super) failed_prefix: &'static str,
    pub(super) control_failed: &'static str,
    pub(super) control_unavailable: &'static str,
    pub(super) not_responding: &'static str,
    pub(super) resize_recovery: &'static str,
    pub(super) new_page_verification_prefix: &'static str,
    pub(super) updated_page_verification_prefix: &'static str,
    pub(super) verification_suffix: &'static str,
    pub starting: &'static str,
    pub attach_unsupported: &'static str,
    pub graphics_unsupported: &'static str,
    pub loading: &'static str,
    pub busy: &'static str,
    pub no_active_surface: &'static str,
    pub not_browser: &'static str,
    pub unknown_surface: &'static str,
}

impl BrowserMessages {
    pub(crate) fn control_failed(&self, error: &str) -> String {
        self.control_failed.replace("{error}", error)
    }

    pub(crate) fn control_unavailable(&self) -> String {
        self.control_failed.replace("{error}", self.control_unavailable)
    }

    pub(crate) fn loading(&self, url: &str) -> String {
        self.loading.replace("{url}", url)
    }
    pub(crate) fn failure_message(&self, failure: BrowserFailure<'_>) -> String {
        match failure {
            BrowserFailure::NotResponding => self.not_responding.to_string(),
            BrowserFailure::ResizeRecovery => self.resize_recovery.to_string(),
            BrowserFailure::NewPageVerification(detail) => {
                format!("{}{detail}{}", self.new_page_verification_prefix, self.verification_suffix)
            }
            BrowserFailure::UpdatedPageVerification(detail) => format!(
                "{}{detail}{}",
                self.updated_page_verification_prefix, self.verification_suffix
            ),
            BrowserFailure::Other(detail) => format!("{}{detail}", self.failed_prefix),
        }
    }
}

pub(super) const ENGLISH: BrowserMessages = BrowserMessages {
    failed_prefix: "browser failed: ",
    control_failed: "browser command failed: {error}",
    control_unavailable: "browser connection unavailable; retry the command",
    not_responding: "browser failed: browser is not responding",
    resize_recovery: "browser failed: browser resize recovery failed; reload to retry",
    new_page_verification_prefix: "browser failed: could not verify new page pixels: ",
    updated_page_verification_prefix: "browser failed: could not verify updated page pixels: ",
    verification_suffix: "; reload to retry",
    starting: "starting browser...",
    attach_unsupported: "browser panes are not supported over attach yet",
    graphics_unsupported: "terminal has no kitty graphics support",
    loading: "loading {url}...",
    busy: "browser is busy; command dropped",
    no_active_surface: "no active surface",
    not_browser: "active surface is not a browser",
    unknown_surface: "unknown browser surface",
};

pub(super) const JAPANESE: BrowserMessages = BrowserMessages {
    failed_prefix: "ブラウザでエラーが発生しました: ",
    control_failed: "ブラウザ操作に失敗しました: {error}",
    control_unavailable: "ブラウザ接続を利用できません。コマンドを再試行してください",
    not_responding: "ブラウザが応答していません",
    resize_recovery: "ブラウザのサイズ変更を復旧できませんでした。再読み込みして再試行してください",
    new_page_verification_prefix: "新しいページの表示を確認できませんでした: ",
    updated_page_verification_prefix: "更新後のページ表示を確認できませんでした: ",
    verification_suffix: "。再読み込みして再試行してください",
    starting: "ブラウザを起動しています…",
    attach_unsupported: "アタッチ経由ではブラウザペインにまだ対応していません",
    graphics_unsupported: "ターミナルが Kitty グラフィックスに対応していません",
    loading: "{url} を読み込んでいます…",
    busy: "ブラウザが処理中のため、コマンドを破棄しました",
    no_active_surface: "アクティブなサーフェスがありません",
    not_browser: "アクティブなサーフェスはブラウザではありません",
    unknown_surface: "不明なブラウザサーフェスです",
};
