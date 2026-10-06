//! The provider's tab table and the per-tab refusals (D1 browser pages,
//! the interim extension rule).

use super::*;

/// `errorName` of a call refused by the interim extension rule.
pub const EXTENSION_HOST_ACCESS: &str = "extension_host_access";

/// `errorName` of a call on a tab that shows a browser page (chrome://,
/// first-party cmux-page hosts: `policy::is_browser_page`).
pub const BROWSER_PAGE: &str = "browser_page";

/// The password lead's text (2026-10-04), the same as the app's control
/// path (`AppBrowserPage.agentExtensionRefusal`). Names go in `data`.
const EXTENSION_REFUSAL: &str = "the tab's profile has an enabled extension with access to this \
     page; open the tab with openBrowser profile \"agent\" (a profile without extensions), or ask \
     the person to allow agents in this tab";
const EXTENSION_REFUSAL_HINT: &str = "open the tab with openBrowser profile \"agent\" (a profile \
     without extensions), or ask the person to allow agents in this tab";

/// The provider's tabs as the app reports them: engine per tab, and for CEF
/// tabs the last `tab.access` report (interim extension rule).
#[derive(Default)]
pub(super) struct TabTable {
    /// targetId -> (extension_host_access, user_override, extension names).
    pub(super) access: HashMap<String, (bool, bool, Vec<String>)>,
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
        self.access.remove(target_id);
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

    /// Why an agent call on `target_id` is refused, or `None`. WebKit tabs
    /// have no extensions. Every other tab (CEF, or one the app did not
    /// announce) needs a `tab.access` report that says no enabled extension
    /// holds host access on its page, or the person's override: fail closed.
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
        if self.tab(target_id).is_some_and(|tab| tab.engine == "webkit") {
            return None;
        }
        let (message, names) = match self.access.get(target_id) {
            Some((false, _, _) | (true, true, _)) => return None,
            Some((true, false, names)) => (EXTENSION_REFUSAL.to_owned(), names.clone()),
            None => (
                format!(
                    "{method}: the cmux app has not reported this tab's extension access yet; {EXTENSION_REFUSAL_HINT}"
                ),
                Vec::new(),
            ),
        };
        let mut error = DriverError::new(crate::protocol::ErrorCode::Forbidden, message);
        error.error_name = Some(EXTENSION_HOST_ACCESS.to_owned());
        error.data = Some(json!({"reason": EXTENSION_HOST_ACCESS, "extensions": names}));
        Some(error)
    }
}
