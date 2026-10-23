//! The provider's tab table and the per-tab refusal (D1 browser pages).

use super::*;

/// `errorName` of a call on a tab that shows a browser page (chrome://,
/// first-party cmux-page hosts: `policy::is_browser_page`).
pub const BROWSER_PAGE: &str = "browser_page";

/// The provider's tabs as the app reports them: engine and URL per tab.
#[derive(Default)]
pub(super) struct TabTable {
    /// Every announced tab, in announce order (`tabs.list`): the one record
    /// of each tab's engine and main-frame URL (hello, tab.announced,
    /// tab.navigated). The checks read it; nothing copies it.
    pub(super) info: Vec<TabAnnounce>,
}

impl TabTable {
    pub(super) fn announce(&mut self, tab: &TabAnnounce) {
        match self.info.iter_mut().find(|known| known.target_id == tab.target_id) {
            Some(known) => *known = tab.clone(),
            None => self.info.push(tab.clone()),
        }
    }

    pub(super) fn tab(&self, target_id: &str) -> Option<&TabAnnounce> {
        self.info.iter().find(|tab| tab.target_id == target_id)
    }

    pub(super) fn engine(&self, target_id: &str) -> Option<String> {
        self.tab(target_id).map(|tab| tab.engine.clone())
    }

    pub(super) fn forget(&mut self, target_id: &str) {
        self.info.retain(|tab| tab.target_id != target_id);
    }

    /// Updates the table from a provider event (`tab.announced`, `tab.gone`).
    pub(super) fn apply_event(&mut self, name: &str, payload: &Value) {
        match name {
            "tab.announced" => {
                if let Ok(tab) = serde_json::from_value::<TabAnnounce>(payload.clone()) {
                    self.announce(&tab);
                }
            }
            // Provider tab.navigated is the main frame's (a sub-frame one
            // names its frameId).
            "tab.navigated" => {
                let main =
                    matches!(payload.get("frameId").and_then(Value::as_str), None | Some("main"));
                if main
                    && let (Some(target_id), Some(url)) = (
                        payload.get("targetId").and_then(Value::as_str),
                        payload.get("url").and_then(Value::as_str),
                    )
                    && let Some(tab) = self.info.iter_mut().find(|t| t.target_id == target_id)
                {
                    tab.url = url.to_owned();
                }
            }
            "tab.gone" => {
                if let Some(target_id) = payload.get("targetId").and_then(Value::as_str) {
                    self.forget(target_id);
                }
            }
            _ => {}
        }
    }

    /// Why an agent call on `target_id` is refused, or `None`: only a tab
    /// that shows a browser page is.
    pub(super) fn refusal(&self, method: &str, target_id: &str) -> Option<DriverError> {
        // D1: a tab that shows a browser page is never driven, on any engine.
        if let Some(url) = self.tab(target_id).map(|tab| &tab.url)
            && crate::policy::is_browser_page(url)
        {
            let mut error = DriverError::new(
                crate::protocol::ErrorCode::Forbidden,
                format!("{method}: {} is a browser page, not available to agents", url.trim()),
            );
            error.error_name = Some(BROWSER_PAGE.to_owned());
            return Some(error);
        }
        // The interim extension rule is gone (#24413): an enabled extension
        // with access to the page is no gate. Every agent may drive every
        // tab; the automation lease coordinates agents on one tab.
        None
    }
}
