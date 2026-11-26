//! The browser automation's load waits (`LoadWaits`, `LoadState`), out of the app's
//! CmuxNextBrowserAutomation Swift: which pending wait for a tab's main-frame load state an
//! engine event meets or fails.
//!
//! Pure: the state is a value the app holds (JSON through [`crate::ops`]). What stays in Swift:
//! the continuation each wait resumes, its one-shot deadline (`DemandTimer`) and the
//! `DriverError` it resumes with; the app names a wait by an id of its own and applies the
//! [`Resolution`]s each call returns.
//!
//! A wait belongs to the navigation its call started (`WebKitTab.startLoad` and friends return
//! its id). Its commit and load are that navigation's `didCommit` and `didFinish`; its
//! domcontentloaded is the load-state message of the document that commit made; its failure is
//! that navigation's. A commit of any other document (a superseded load, a page's own
//! navigation) never meets it.
//!
//! Two engine behaviors differ by macOS version (probed with WKWebView on macOS 26.5 and 27.0):
//! - A load that cannot connect fails provisionally on 27; on 26 the same navigation commits
//!   and finishes a blank document (about:blank). A navigation that asked for another URL and
//!   commits about:blank failed ([`is_blank_error_document`]).
//! - A same-document load (a fragment) gets no delegate callbacks; on 26 the web view's URL
//!   shows the `#` as `%23`, so the URL change does not look like a fragment change. Such a
//!   navigation never starts; when loading ends and it has not started, it was same-document and
//!   its wait is met.

use crate::address::NSURL_ERROR_DOMAIN;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Load states in order; a wait for one is met by it or any later one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LoadState {
    Commit,
    Domcontentloaded,
    Load,
}

impl LoadState {
    /// `LoadState(name:)`: `networkidle` resolves at load (no resource-load events yet;
    /// UNVERIFIED against pages that keep fetching after load).
    ///
    /// ```
    /// use cmux_browser_rules::load_waits::LoadState;
    /// assert_eq!(LoadState::from_name("networkidle"), Some(LoadState::Load));
    /// assert_eq!(LoadState::from_name("idle"), None);
    /// ```
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "commit" => Some(Self::Commit),
            "domcontentloaded" => Some(Self::Domcontentloaded),
            "load" | "networkidle" => Some(Self::Load),
            _ => None,
        }
    }

    /// The protocol name (`LoadState.name`).
    pub fn name(self) -> &'static str {
        match self {
            Self::Commit => "commit",
            Self::Domcontentloaded => "domcontentloaded",
            Self::Load => "load",
        }
    }
}

/// A load failure an engine reported (`BrowserLoadError`, the fields the waits read).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct LoadError {
    pub domain: String,
    pub code: i64,
    pub message: String,
}

impl LoadError {
    /// `BrowserLoadError.isBenignInterruption`: not a user-visible error, a cancelled load
    /// (Stop, or a new navigation replacing this one, `NSURLErrorCancelled`) or WebKit's "frame
    /// load interrupted" (102) when a response becomes a download.
    pub fn is_benign_interruption(&self) -> bool {
        (self.domain == NSURL_ERROR_DOMAIN && self.code == -999)
            || (self.domain == "WebKitErrorDomain" && self.code == 102)
    }
}

/// The tab's navigation events the waits read (`BrowserNavigationEvent`; every other case is
/// [`NavigationEvent::Other`]). Navigation ids are `BrowserNavigationID.rawValue`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum NavigationEvent {
    Started {
        id: u64,
    },
    Committed {
        id: u64,
        #[serde(default)]
        url: Option<String>,
    },
    Finished {
        id: u64,
    },
    Failed {
        id: u64,
        error: LoadError,
    },
    Other,
}

/// What a wait is for (`LoadWaits.Ticket`): `navigation`, or, when the engine started none, the
/// next document committed after `generation`. A same-document navigation since the call
/// started (`same_documents`) meets it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Ticket {
    pub navigation: Option<u64>,
    /// The URL a load asked for (nil for history and reload).
    pub requested_url: Option<String>,
    pub generation: u64,
    pub same_documents: u64,
    pub loading_ends: u64,
}

/// One pending wait (`LoadWaits.Wait`, less its timer and continuation).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Wait {
    pub target: LoadState,
    #[serde(default)]
    pub navigation: Option<u64>,
    /// Its navigation was replaced (a benign interruption): the next navigation that starts
    /// carries the wait.
    #[serde(default)]
    pub follows_next_navigation: bool,
    /// Its navigation reported `started` (a cross-document load).
    #[serde(default)]
    pub started: bool,
    #[serde(default)]
    pub requested_url: Option<String>,
    #[serde(default)]
    pub generation: u64,
}

/// How a wait ended.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "outcome", rename_all = "camelCase")]
pub enum Outcome {
    /// The load state was reached: the wait resumes with success.
    Met,
    /// Its navigation failed: the wait resumes with `DriverError(.invalid, message)`.
    Failed { message: String },
}

/// A wait the call ended; the app resumes the wait `id` with `outcome` and cancels its timer.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Resolution {
    pub id: u64,
    #[serde(flatten)]
    pub outcome: Outcome,
}

/// Bound of [`LoadWaits::started_navigations`] (navigation ids only grow).
const STARTED_NAVIGATIONS: usize = 32;

/// Pending waits for a tab's main-frame load states (`LoadWaits`). Nothing polls: an event
/// resolves the waits it meets; the app's deadline ends the rest ([`LoadWaits::expire`]).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LoadWaits {
    pub waits: BTreeMap<u64, Wait>,
    /// Increments at each main-frame document start (load-state message), for `tab.info` and
    /// for tickets without a navigation.
    pub generation: u64,
    pub state: Option<LoadState>,
    /// The document token of the latest commit: states posted by an older document (a process
    /// swap can deliver them late) are ignored.
    pub document: Option<String>,
    /// The navigation that committed last and has no document token yet: the next
    /// document-start message is its document (WebKit sends the commit before the document's
    /// scripts run).
    pub committed_navigation: Option<u64>,
    /// The navigation that committed `document`, when one did.
    pub document_navigation: Option<u64>,
    /// Same-document navigations so far. WebKit reports one (the URL KVO) inside the `load`
    /// call that makes it, before the call's wait exists.
    pub same_documents: u64,
    /// The newest navigation that started (ids grow per tab).
    pub latest_started: Option<u64>,
    /// Recent navigations that started, for tickets whose wait does not exist yet.
    pub started_navigations: Vec<u64>,
    /// Times the web view stopped loading.
    pub loading_ends: u64,
}

/// `LoadWaits.isBlankErrorDocument`: macOS 26 commits a blank document for a load that cannot
/// connect, so a navigation that asked for another URL and committed `about:blank` failed.
///
/// ```
/// use cmux_browser_rules::load_waits::is_blank_error_document;
/// assert!(is_blank_error_document(Some("about:blank"), Some("https://nowhere.invalid/")));
/// assert!(!is_blank_error_document(Some("about:blank"), Some("about:blank")));
/// assert!(!is_blank_error_document(Some("about:blank"), None));
/// ```
pub fn is_blank_error_document(committed: Option<&str>, requested: Option<&str>) -> bool {
    let Some(requested) = requested else {
        return false;
    };
    let scheme =
        cmux_url_input::parse_url(requested).map(|parts| parts.scheme.to_ascii_lowercase());
    if scheme.as_deref() == Some("about") {
        return false;
    }
    committed == Some("about:blank")
}

impl LoadWaits {
    /// Waits not yet met (tests, diagnostics).
    pub fn pending_count(&self) -> usize {
        self.waits.len()
    }

    /// `beginNavigation`: the ticket of a call about to start a navigation, taken before it
    /// starts (its start can report a same-document navigation at once). The app sets
    /// [`Ticket::navigation`] to the id the start returned.
    pub fn begin_navigation(&self, requested_url: Option<String>) -> Ticket {
        Ticket {
            navigation: None,
            requested_url,
            generation: self.generation,
            same_documents: self.same_documents,
            loading_ends: self.loading_ends,
        }
    }

    /// The tab's navigation events (`WebKitTab.observeNavigationEvents`).
    pub fn navigation_event(&mut self, event: &NavigationEvent) -> Vec<Resolution> {
        let mut resolved = Vec::new();
        match event {
            NavigationEvent::Started { id } => {
                let id = *id;
                if self.latest_started.is_none_or(|latest| id > latest) {
                    self.latest_started = Some(id);
                }
                self.started_navigations.push(id);
                if self.started_navigations.len() > STARTED_NAVIGATIONS {
                    self.started_navigations.remove(0);
                }
                for wait in self.waits.values_mut() {
                    if wait.follows_next_navigation || wait.navigation == Some(id) {
                        wait.navigation = Some(id);
                        wait.follows_next_navigation = false;
                        wait.started = true;
                    }
                }
            }
            NavigationEvent::Committed { id, url } => {
                let id = *id;
                self.committed_navigation = Some(id);
                let failed: Vec<(u64, String)> = self
                    .waits
                    .iter()
                    .filter(|(_, wait)| {
                        wait.navigation == Some(id)
                            && is_blank_error_document(
                                url.as_deref(),
                                wait.requested_url.as_deref(),
                            )
                    })
                    .map(|(key, wait)| {
                        let requested = wait.requested_url.clone().unwrap_or_default();
                        (*key, format!("navigation failed: {requested} did not load"))
                    })
                    .collect();
                for (key, message) in failed {
                    self.finish(key, Outcome::Failed { message }, &mut resolved);
                }
                self.reached(LoadState::Commit, id, &mut resolved);
            }
            NavigationEvent::Finished { id } => self.reached(LoadState::Load, *id, &mut resolved),
            NavigationEvent::Failed { id, error } => {
                let id = *id;
                if error.is_benign_interruption() {
                    // Stopped or replaced: the replacing navigation carries the wait, whether it
                    // started before this report or starts later.
                    let replacement = self.latest_started.filter(|latest| *latest > id);
                    for wait in self.waits.values_mut() {
                        if wait.navigation == Some(id) {
                            wait.navigation = replacement;
                            wait.follows_next_navigation = replacement.is_none();
                            wait.started = replacement.is_some();
                        }
                    }
                } else {
                    let keys = self.keys_where(|wait| wait.navigation == Some(id));
                    for key in keys {
                        let message = format!("navigation failed: {}", error.message);
                        self.finish(key, Outcome::Failed { message }, &mut resolved);
                    }
                }
            }
            NavigationEvent::Other => {}
        }
        resolved
    }

    /// A main-frame load-state message from the document `token` (`signal(_:document:)`).
    pub fn signal(&mut self, next: LoadState, token: &str) -> Vec<Resolution> {
        let mut resolved = Vec::new();
        if next == LoadState::Commit {
            self.generation = self.generation.wrapping_add(1);
            self.document = Some(token.to_owned());
            self.document_navigation = self.committed_navigation.take();
        } else if self.document.as_deref() != Some(token) {
            return resolved;
        }
        self.state = Some(next);
        if let Some(navigation) = self.document_navigation {
            self.reached(next, navigation, &mut resolved);
        }
        let generation = self.generation;
        let keys = self.keys_where(|wait| {
            wait.navigation.is_none()
                && !wait.follows_next_navigation
                && generation > wait.generation
                && next >= wait.target
        });
        for key in keys {
            self.finish(key, Outcome::Met, &mut resolved);
        }
        resolved
    }

    /// The web view stopped loading (`loadingEnded`). A wait whose navigation never started was
    /// a same-document load: it is met.
    pub fn loading_ended(&mut self) -> Vec<Resolution> {
        let mut resolved = Vec::new();
        self.loading_ends = self.loading_ends.wrapping_add(1);
        let keys = self.keys_where(|wait| {
            wait.navigation.is_some() && !wait.started && !wait.follows_next_navigation
        });
        for key in keys {
            self.finish(key, Outcome::Met, &mut resolved);
        }
        resolved
    }

    /// A same-document navigation (fragment, pushState): no new document, every pending wait is
    /// met.
    pub fn same_document(&mut self) -> Vec<Resolution> {
        let mut resolved = Vec::new();
        self.generation = self.generation.wrapping_add(1);
        self.same_documents = self.same_documents.wrapping_add(1);
        self.state = Some(LoadState::Load);
        let keys = self.keys_where(|_| true);
        for key in keys {
            self.finish(key, Outcome::Met, &mut resolved);
        }
        resolved
    }

    /// The start of `reach(_:for:timeout:what:)`: true when `ticket`'s navigation already
    /// reached `target` (the call returns at once); otherwise the wait `id` is pending and the
    /// app arms its deadline.
    pub fn reach(&mut self, id: u64, target: LoadState, ticket: &Ticket) -> bool {
        if self.same_documents > ticket.same_documents {
            return true;
        }
        let started = ticket
            .navigation
            .is_some_and(|navigation| self.started_navigations.contains(&navigation));
        if ticket.navigation.is_some() && !started && self.loading_ends > ticket.loading_ends {
            return true;
        }
        if ticket.navigation.is_none()
            && self.generation > ticket.generation
            && self.state.is_some_and(|state| state >= target)
        {
            return true;
        }
        self.waits.insert(
            id,
            Wait {
                target,
                navigation: ticket.navigation,
                follows_next_navigation: false,
                started,
                requested_url: ticket.requested_url.clone(),
                generation: ticket.generation,
            },
        );
        false
    }

    /// The deadline of wait `id` passed: true when it was pending (the app resumes it with its
    /// timeout error), false when an event ended it first.
    pub fn expire(&mut self, id: u64) -> bool {
        self.waits.remove(&id).is_some()
    }

    /// `failAll`: the tab closed or crashed. Answers the waits that were pending; the app resumes
    /// each with its error.
    pub fn fail_all(&mut self) -> Vec<u64> {
        std::mem::take(&mut self.waits).into_keys().collect()
    }

    fn keys_where(&self, keep: impl Fn(&Wait) -> bool) -> Vec<u64> {
        self.waits.iter().filter(|(_, wait)| keep(wait)).map(|(key, _)| *key).collect()
    }

    fn reached(&mut self, state: LoadState, navigation: u64, resolved: &mut Vec<Resolution>) {
        let keys =
            self.keys_where(|wait| wait.navigation == Some(navigation) && state >= wait.target);
        for key in keys {
            self.finish(key, Outcome::Met, resolved);
        }
    }

    fn finish(&mut self, id: u64, outcome: Outcome, resolved: &mut Vec<Resolution>) {
        if self.waits.remove(&id).is_some() {
            resolved.push(Resolution { id, outcome });
        }
    }
}
