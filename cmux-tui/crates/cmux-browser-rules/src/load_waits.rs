//! Pending waits for a tab's main-frame load states (`LoadWaits.swift`), as a state machine with
//! no timers and no continuations. Swift keeps the one-shot deadline (`DemandTimer`) and the
//! suspended call of each wait, keyed by the wait id this machine hands out; every event method
//! answers the waits it resolved, and Swift cancels each one's timer and resumes its call.
//!
//! A wait belongs to the navigation its call started. Its commit and load are that navigation's
//! `didCommit` and `didFinish`; its domcontentloaded is the load-state message of the document
//! that commit made; its failure is that navigation's. A commit of any other document (a
//! superseded load, a page's own navigation) never meets it.
//!
//! Two engine behaviors differ by macOS version (probed with WKWebView on macOS 26.5 and 27.0):
//! a load that cannot connect fails provisionally on 27, while on 26 the same navigation commits
//! a blank document (a navigation that asked for another URL and commits about:blank failed); and
//! a same-document load (a fragment) gets no delegate callbacks, so a navigation that never
//! started when loading ends was same-document and its wait is met.
//!
//! The whole machine is `Serialize`/`Deserialize`, so the app's JSON channel (op
//! `browser_rules_automation_load_waits`) can hold it between events.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Load states in order; a wait for one is met by it or any later one (`LoadState`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LoadState {
    Commit,
    Domcontentloaded,
    Load,
}

impl LoadState {
    /// `LoadState.init?(name:)`. No resource-load events yet: `networkidle` resolves at load
    /// (unverified against pages that keep fetching after load).
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "commit" => Some(Self::Commit),
            "domcontentloaded" => Some(Self::Domcontentloaded),
            "load" | "networkidle" => Some(Self::Load),
            _ => None,
        }
    }

    /// `LoadState.name`.
    pub fn name(self) -> &'static str {
        match self {
            Self::Commit => "commit",
            Self::Domcontentloaded => "domcontentloaded",
            Self::Load => "load",
        }
    }
}

/// `DriverError.Code`, the ones a load wait fails with.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ErrorKind {
    Invalid,
    Timeout,
    Closed,
}

/// The `DriverError` a wait fails with (agent-facing protocol text).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WaitError {
    pub kind: ErrorKind,
    pub message: String,
}

/// A wait that ended: met (`error` None) or failed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Resolution {
    pub wait: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<WaitError>,
}

impl Resolution {
    fn met(wait: u64) -> Self {
        Self { wait, error: None }
    }

    fn failed(wait: u64, kind: ErrorKind, message: String) -> Self {
        Self { wait, error: Some(WaitError { kind, message }) }
    }
}

/// The navigation events a tab reports (`BrowserNavigationEvent`, the ones a wait reads). The
/// other cases are `Other`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum NavigationEvent {
    Started {
        id: u64,
    },
    Committed {
        id: u64,
        url: Option<String>,
    },
    Finished {
        id: u64,
    },
    /// `benign` is `BrowserLoadError.isBenignInterruption`; `message` its text.
    Failed {
        id: u64,
        benign: bool,
        message: String,
    },
    Other,
}

/// What a wait is for (`LoadWaits.Ticket`): `navigation`, or, when the engine started none, the
/// next document committed after `generation`. A same-document navigation since the call started
/// (`same_documents`) meets it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Ticket {
    pub navigation: Option<u64>,
    /// The URL a load asked for (None for history and reload).
    pub requested_url: Option<String>,
    pub generation: u64,
    pub same_documents: u64,
    pub loading_ends: u64,
}

/// What [`LoadWaits::reach`] decided.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Reach {
    /// Already met: return at once.
    Met,
    /// Pending as `wait`: suspend the call, arm its deadline if it has one.
    Pending { wait: u64 },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Wait {
    target: LoadState,
    navigation: Option<u64>,
    /// Its navigation was replaced (a benign interruption): the next navigation that starts
    /// carries the wait.
    follows_next_navigation: bool,
    /// Its navigation reported `started` (a cross-document load).
    started: bool,
    requested_url: Option<String>,
    generation: u64,
}

/// Most recent started navigations kept (navigation ids only grow).
const STARTED_KEPT: usize = 32;

/// The load waits of one tab (`LoadWaits`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LoadWaits {
    waits: BTreeMap<u64, Wait>,
    next_wait: u64,
    /// Increments at each main-frame document start, for `tab.info` and tickets without a
    /// navigation.
    pub generation: u64,
    pub state: Option<LoadState>,
    /// The document token of the latest commit: states posted by an older document (a process
    /// swap can deliver them late) are ignored.
    document: Option<String>,
    /// The navigation that committed last and has no document token yet: the next document-start
    /// message is its document.
    committed_navigation: Option<u64>,
    /// The navigation `document` belongs to.
    document_navigation: Option<u64>,
    same_documents: u64,
    /// The newest navigation that started.
    latest_started: Option<u64>,
    started_navigations: Vec<u64>,
    loading_ends: u64,
}

impl LoadWaits {
    /// Waits not yet met.
    pub fn pending_count(&self) -> usize {
        self.waits.len()
    }

    /// The counters a ticket carries, taken before the call starts its navigation (`start` can
    /// report a same-document navigation synchronously). The caller sets `navigation` and
    /// `requested_url` on the result (`beginNavigation`).
    pub fn snapshot(&self) -> Ticket {
        Ticket {
            navigation: None,
            requested_url: None,
            generation: self.generation,
            same_documents: self.same_documents,
            loading_ends: self.loading_ends,
        }
    }

    /// The tab's navigation events (`navigationEvent`).
    pub fn navigation_event(&mut self, event: &NavigationEvent) -> Vec<Resolution> {
        let mut out = Vec::new();
        match event {
            NavigationEvent::Started { id } => {
                if self.latest_started.is_none_or(|latest| *id > latest) {
                    self.latest_started = Some(*id);
                }
                self.started_navigations.push(*id);
                if self.started_navigations.len() > STARTED_KEPT {
                    self.started_navigations.remove(0);
                }
                for wait in self.waits.values_mut() {
                    if wait.follows_next_navigation || wait.navigation == Some(*id) {
                        wait.navigation = Some(*id);
                        wait.follows_next_navigation = false;
                        wait.started = true;
                    }
                }
            }
            NavigationEvent::Committed { id, url } => {
                self.committed_navigation = Some(*id);
                let blank: Vec<(u64, Option<String>)> = self
                    .waits
                    .iter()
                    .filter(|(_, wait)| {
                        wait.navigation == Some(*id)
                            && is_blank_error_document(
                                url.as_deref(),
                                wait.requested_url.as_deref(),
                            )
                    })
                    .map(|(key, wait)| (*key, wait.requested_url.clone()))
                    .collect();
                for (key, requested) in blank {
                    let message = format!(
                        "navigation failed: {} did not load",
                        requested.unwrap_or_default()
                    );
                    self.finish(key, Some((ErrorKind::Invalid, message)), &mut out);
                }
                self.reached(LoadState::Commit, *id, &mut out);
            }
            NavigationEvent::Finished { id } => self.reached(LoadState::Load, *id, &mut out),
            NavigationEvent::Failed { id, benign, message } => {
                if *benign {
                    // Stopped or replaced: the replacing navigation carries the wait, whether it
                    // started before this report or starts later.
                    let replacement = self.latest_started.filter(|latest| *latest > *id);
                    for wait in self.waits.values_mut() {
                        if wait.navigation == Some(*id) {
                            wait.navigation = replacement;
                            wait.follows_next_navigation = replacement.is_none();
                            wait.started = replacement.is_some();
                        }
                    }
                } else {
                    let keys = self.keys_where(|wait| wait.navigation == Some(*id));
                    for key in keys {
                        let text = format!("navigation failed: {message}");
                        self.finish(key, Some((ErrorKind::Invalid, text)), &mut out);
                    }
                }
            }
            NavigationEvent::Other => {}
        }
        out
    }

    /// A main-frame load-state message from the document `token` (`signal`).
    pub fn signal(&mut self, next: LoadState, token: &str) -> Vec<Resolution> {
        if next == LoadState::Commit {
            self.generation = self.generation.wrapping_add(1);
            self.document = Some(token.to_owned());
            self.document_navigation = self.committed_navigation.take();
        } else if self.document.as_deref() != Some(token) {
            return Vec::new();
        }
        self.state = Some(next);
        let mut out = Vec::new();
        if let Some(navigation) = self.document_navigation {
            self.reached(next, navigation, &mut out);
        }
        let generation = self.generation;
        let keys = self.keys_where(|wait| {
            wait.navigation.is_none()
                && !wait.follows_next_navigation
                && generation > wait.generation
                && next >= wait.target
        });
        for key in keys {
            self.finish(key, None, &mut out);
        }
        out
    }

    /// The web view stopped loading. A wait whose navigation never started was a same-document
    /// load: it is met (`loadingEnded`).
    pub fn loading_ended(&mut self) -> Vec<Resolution> {
        self.loading_ends = self.loading_ends.wrapping_add(1);
        let keys = self.keys_where(|wait| {
            wait.navigation.is_some() && !wait.started && !wait.follows_next_navigation
        });
        let mut out = Vec::new();
        for key in keys {
            self.finish(key, None, &mut out);
        }
        out
    }

    /// A same-document navigation (fragment, pushState): no new document, every pending wait is
    /// met (`sameDocument`).
    pub fn same_document(&mut self) -> Vec<Resolution> {
        self.generation = self.generation.wrapping_add(1);
        self.same_documents = self.same_documents.wrapping_add(1);
        self.state = Some(LoadState::Load);
        self.drain(None)
    }

    /// Whether a wait for `target` on `ticket` is met at once, or else the wait to suspend on
    /// (`reach`, before its continuation).
    pub fn reach(&mut self, target: LoadState, ticket: &Ticket) -> Reach {
        if self.same_documents > ticket.same_documents {
            return Reach::Met;
        }
        let started = ticket.navigation.is_some_and(|id| self.started_navigations.contains(&id));
        if ticket.navigation.is_some() && !started && self.loading_ends > ticket.loading_ends {
            return Reach::Met;
        }
        if ticket.navigation.is_none()
            && self.generation > ticket.generation
            && self.state.is_some_and(|state| state >= target)
        {
            return Reach::Met;
        }
        let wait = self.next_wait;
        self.next_wait += 1;
        self.waits.insert(
            wait,
            Wait {
                target,
                navigation: ticket.navigation,
                follows_next_navigation: false,
                started,
                requested_url: ticket.requested_url.clone(),
                generation: ticket.generation,
            },
        );
        Reach::Pending { wait }
    }

    /// The deadline of `wait` passed (`what` names the call, `timeout` is Swift's text of the
    /// duration). None when the wait was already met.
    pub fn timed_out(&mut self, wait: u64, what: &str, timeout: &str) -> Option<Resolution> {
        let target = self.waits.get(&wait)?.target;
        let message = format!("{what}: Timeout {timeout} exceeded waiting for {}", target.name());
        let mut out = Vec::new();
        self.finish(wait, Some((ErrorKind::Timeout, message)), &mut out);
        out.pop()
    }

    /// Fails every pending wait (the tab closed or crashed) (`failAll`).
    pub fn fail_all(&mut self, error: &WaitError) -> Vec<Resolution> {
        self.drain(Some((error.kind, error.message.clone())))
    }

    fn drain(&mut self, result: Option<(ErrorKind, String)>) -> Vec<Resolution> {
        let keys: Vec<u64> = self.waits.keys().copied().collect();
        let mut out = Vec::new();
        for key in keys {
            self.finish(key, result.clone(), &mut out);
        }
        out
    }

    fn keys_where(&self, mut keep: impl FnMut(&Wait) -> bool) -> Vec<u64> {
        self.waits.iter().filter(|(_, wait)| keep(wait)).map(|(key, _)| *key).collect()
    }

    fn reached(&mut self, state: LoadState, navigation: u64, out: &mut Vec<Resolution>) {
        let keys =
            self.keys_where(|wait| wait.navigation == Some(navigation) && state >= wait.target);
        for key in keys {
            self.finish(key, None, out);
        }
    }

    fn finish(&mut self, id: u64, result: Option<(ErrorKind, String)>, out: &mut Vec<Resolution>) {
        if self.waits.remove(&id).is_none() {
            return;
        }
        out.push(match result {
            None => Resolution::met(id),
            Some((kind, message)) => Resolution::failed(id, kind, message),
        });
    }
}

/// macOS 26 commits a blank document for a load that cannot connect
/// (`LoadWaits.isBlankErrorDocument`): the navigation asked for a URL that is not an `about:`
/// one and committed `about:blank`.
pub fn is_blank_error_document(committed: Option<&str>, requested: Option<&str>) -> bool {
    let Some(requested) = requested else { return false };
    if scheme(requested).is_some_and(|scheme| scheme.eq_ignore_ascii_case("about")) {
        return false;
    }
    committed == Some("about:blank")
}

/// The scheme of a URL string (RFC 3986: a letter, then letters, digits, `+`, `-`, `.`, then `:`).
pub fn scheme(url: &str) -> Option<&str> {
    let end = url.find(':')?;
    let head = &url[..end];
    let mut chars = head.chars();
    let first = chars.next()?;
    (first.is_ascii_alphabetic()
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.')))
    .then_some(head)
}
