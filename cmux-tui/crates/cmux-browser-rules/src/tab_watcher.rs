//! The decisions of a driven tab's watcher (`TabWatcher.swift`). Stays in Swift: the KVO
//! observations of `url` and `isLoading`, Observation of `WebKitTab.state`, the navigation
//! observer, `MainDelivery`, and emitting the events (`tab.navigated`, `tab.crashed`).

use serde::{Deserialize, Serialize};

/// Whether `a` and `b` differ, and only in the fragment (`differOnlyInFragment`): the part before
/// the first `#` is equal.
pub fn differ_only_in_fragment(a: &str, b: &str) -> bool {
    fn base(url: &str) -> &str {
        url.split_once('#').map_or(url, |(head, _)| head)
    }
    a != b && base(a) == base(b)
}

/// What the watcher saw of the web view's URL changing.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UrlChange {
    /// The watcher's last seen URL.
    #[serde(default)]
    pub last_url: Option<String>,
    /// The web view's new URL.
    #[serde(default)]
    pub url: Option<String>,
    /// The web view is loading.
    #[serde(default)]
    pub loading: bool,
    /// The tab's phase is provisional.
    #[serde(default)]
    pub provisional: bool,
}

/// What the watcher does with a URL change (`urlChanged`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UrlChangeOutcome {
    /// The watcher's last seen URL after the change.
    pub last_url: Option<String>,
    /// Emit `tab.navigated {sameDocument: true}` and meet every wait (`LoadWaits.same_document`).
    pub same_document: bool,
}

/// `urlChanged`, without the `stopped` and weak-reference guards (the caller checks them): a
/// change of only the fragment is always same-document (HTML navigation); pushState and
/// replaceState change the URL outside a load. A URL that is the last one seen changes nothing;
/// a change to or from no URL updates the last one and is not a navigation.
pub fn url_changed(change: &UrlChange) -> UrlChangeOutcome {
    if change.url == change.last_url {
        return UrlChangeOutcome { last_url: change.last_url.clone(), same_document: false };
    }
    let outcome = |same_document| UrlChangeOutcome { last_url: change.url.clone(), same_document };
    let (Some(url), Some(previous)) = (&change.url, &change.last_url) else {
        return outcome(false);
    };
    outcome(differ_only_in_fragment(previous, url) || (!change.provisional && !change.loading))
}

/// Whether the tab's process exit is new to the watcher (`apply`): `exit` is the state's exit,
/// `last` the one seen. Then fail every wait with [`PROCESS_ENDED`] and emit `tab.crashed`.
pub fn process_exit_is_new<T: PartialEq>(exit: Option<&T>, last: Option<&T>) -> bool {
    exit.is_some() && exit != last
}

/// The text the waits fail with when the web content process ended.
pub const PROCESS_ENDED: &str = "the page's web content process ended";
