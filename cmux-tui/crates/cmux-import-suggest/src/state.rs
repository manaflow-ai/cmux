//! What the person said about the cards (`ImportSuggestionState`): which they dismissed, and
//! the agents' open requests. The app keeps it in UserDefaults under [`DEFAULTS_KEY`].

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::model::Finding;
use crate::request::Request;

/// The UserDefaults key the app saves the state under.
pub const DEFAULTS_KEY: &str = "importSuggestions.state";
/// The most open requests kept; the oldest go first.
pub const MAXIMUM_REQUESTS: usize = 6;
/// A request older than a day is dropped, in milliseconds.
pub const REQUEST_LIFETIME_MS: f64 = 24.0 * 3600.0 * 1000.0;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct State {
    /// Finding id to its fingerprint when the person dismissed it.
    pub dismissed: BTreeMap<String, String>,
    /// Newest first.
    pub requests: Vec<Request>,
}

impl State {
    /// The finding's card stays hidden: dismissed, and nothing new since (same source and
    /// access, no profile or kind it did not have then).
    pub fn hides(&self, finding: &Finding) -> bool {
        let Some(stored) = self.dismissed.get(&finding.id) else { return false };
        let fingerprint = finding.fingerprint();
        let then: Vec<&str> = stored.split('|').collect();
        let now: Vec<&str> = fingerprint.split('|').collect();
        if then.len() < 2 || now.len() < 2 || then[..2] != now[..2] {
            return false;
        }
        let held: BTreeSet<&str> = then[2..].iter().copied().collect();
        now[2..].iter().all(|part| held.contains(part))
    }

    pub fn dismiss(&mut self, finding: &Finding) {
        self.dismissed.insert(finding.id.clone(), finding.fingerprint());
    }

    pub fn restore(&mut self, id: &str) {
        self.dismissed.remove(id);
    }

    /// Puts the request first, replacing one for the same browser and site.
    pub fn raise(&mut self, request: Request) {
        let id = request.id();
        self.requests.retain(|kept| kept.id() != id);
        self.requests.insert(0, request);
        self.requests.truncate(MAXIMUM_REQUESTS);
    }

    pub fn drop_request(&mut self, id: &str) {
        self.requests.retain(|kept| kept.id() != id);
    }

    /// Drops requests older than [`REQUEST_LIFETIME_MS`] at `now` (milliseconds since 1970).
    pub fn expire(&mut self, now: f64) {
        self.requests.retain(|kept| now - kept.requested_at <= REQUEST_LIFETIME_MS);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Access, DataKind, Profile, SourceKind};

    fn chrome(profiles: Vec<Profile>) -> Finding {
        let mut finding = Finding::new("browser.chrome", SourceKind::Browser, "Chrome");
        finding.browser = Some("chrome".into());
        finding.profiles = profiles;
        finding
    }

    #[test]
    fn a_dismissed_card_stays_hidden_until_something_new_appears() {
        let first =
            chrome(vec![Profile::new("Default", vec![DataKind::History, DataKind::Bookmarks])]);
        let mut state = State::default();
        assert!(!state.hides(&first));
        state.dismiss(&first);
        assert!(state.hides(&first));
        let fewer = chrome(vec![Profile::new("Default", vec![DataKind::History])]);
        assert!(state.hides(&fewer));
        let more = chrome(vec![
            Profile::new("Default", vec![DataKind::History, DataKind::Bookmarks]),
            Profile::new("Profile 1", vec![DataKind::History]),
        ]);
        assert!(!state.hides(&more));
        let mut locked = first.clone();
        locked.access = Access::NeedsFullDiskAccess;
        assert!(!state.hides(&locked));
        state.restore(&first.id);
        assert!(!state.hides(&first));
    }

    #[test]
    fn counts_do_not_bring_a_card_back() {
        let mut agents = Finding::new("agents.claudeCode", SourceKind::ClaudeCode, "Claude Code");
        agents.count = Some(3);
        let mut state = State::default();
        state.dismiss(&agents);
        agents.count = Some(40);
        assert!(state.hides(&agents));
    }

    #[test]
    fn requests_are_newest_first_capped_and_expire() {
        let mut state = State::default();
        for index in 0..8 {
            state.raise(Request::new("chrome", format!("s{index}.com"), "why", f64::from(index)));
        }
        assert_eq!(state.requests.len(), MAXIMUM_REQUESTS);
        assert_eq!(state.requests[0].site, "s7.com");
        state.raise(Request::new("chrome", "s4.com", "again", 100.0));
        assert_eq!(state.requests.len(), MAXIMUM_REQUESTS);
        assert_eq!(state.requests[0].reason, "again");
        state.drop_request("request.cookies.chrome.s4.com");
        assert!(state.requests.iter().all(|kept| kept.site != "s4.com"));
        state.expire(REQUEST_LIFETIME_MS + 5.0);
        assert_eq!(
            state.requests.iter().map(|kept| kept.site.as_str()).collect::<Vec<_>>(),
            ["s7.com", "s6.com", "s5.com"]
        );
    }

    #[test]
    fn the_saved_shape_reads_back() {
        let json = r#"{"dismissed":{"a":"a|ready"},"requests":[{"browser":"arc","site":"x.com","reason":"r","requestedAt":1000}]}"#;
        let state: State = serde_json::from_str(json).unwrap();
        assert_eq!(state.requests[0].requested_at, 1000.0);
        assert_eq!(serde_json::from_str::<State>("{}").unwrap(), State::default());
    }
}
