//! The browser automation's tab watcher rule (`TabWatcher.urlChanged`), out of the app's
//! CmuxNextBrowserAutomation Swift: which web view URL changes are same-document navigations
//! (fragment, pushState), so the app emits `tab.navigated {sameDocument: true}` and meets every
//! load wait ([`crate::load_waits::LoadWaits::same_document`]).
//!
//! What stays in Swift: the KVO and Observation subscriptions, the event emission, and the crash
//! rule (a `BrowserProcessExit` unlike the last one fails every wait and emits `tab.crashed`),
//! one equality test on an engine type.

use serde::{Deserialize, Serialize};

/// What the watcher remembers between URL changes.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UrlWatch {
    /// The web view's URL at the last change (`absoluteString`).
    pub last_url: Option<String>,
}

/// `TabWatcher.differOnlyInFragment`: the URLs differ, and only after their first `#`.
///
/// ```
/// use cmux_browser_rules::tab_watcher::differ_only_in_fragment;
/// assert!(differ_only_in_fragment("https://a.test/p#x", "https://a.test/p#y"));
/// assert!(differ_only_in_fragment("https://a.test/p", "https://a.test/p#y"));
/// assert!(!differ_only_in_fragment("https://a.test/p#x", "https://a.test/p#x"));
/// assert!(!differ_only_in_fragment("https://a.test/p", "https://a.test/q"));
/// ```
pub fn differ_only_in_fragment(a: &str, b: &str) -> bool {
    fn before_fragment(url: &str) -> &str {
        url.split_once('#').map_or(url, |(before, _)| before)
    }
    a != b && before_fragment(a) == before_fragment(b)
}

impl UrlWatch {
    /// The web view's URL changed to `url` (KVO), while the tab's phase is `provisional` or not
    /// and the web view is `loading` or not. True when it is a same-document navigation: only
    /// the fragment changed (always same-document, HTML navigation), or the URL changed outside a
    /// load (pushState, replaceState). A change from or to no URL is none.
    pub fn url_changed(&mut self, url: Option<&str>, provisional: bool, loading: bool) -> bool {
        if url == self.last_url.as_deref() {
            return false;
        }
        let previous = std::mem::replace(&mut self.last_url, url.map(str::to_owned));
        let (Some(url), Some(previous)) = (url, previous) else {
            return false;
        };
        differ_only_in_fragment(&previous, url) || (!provisional && !loading)
    }
}
