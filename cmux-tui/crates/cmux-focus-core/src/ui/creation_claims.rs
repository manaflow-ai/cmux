//! The person's new terminals' claims on their windows' keyboards (Swift
//! `CreationKeyboardClaims`). Terminal input must never reach an agent,
//! whatever the timing (dogfood v2.2.3: the keys typed for a new terminal
//! asked for over Home went into Home's Chief message box, and Return sent a
//! shell command to the Chief as a message).
//!
//! The person's own new workspace with a terminal claims its window's
//! keyboard from the request until the person's next intent in that window: a
//! click, Escape, a focus or selection move of theirs, another of their
//! actions; or until the window shows the workspace. Never by a timeout, and
//! never by automation. While a claim holds and no creation hold keeps the
//! keys, every key that runs no binding is kept from the window ([`keeps`]).
//!
//! Claims are keyed by window number. The app keeps the window objects and
//! tells [`holds`] whether the window asked about is the claim's own; it logs
//! the claims that ended after keeping keys ([`CreationKeyboardClaims::take_ended`]).
//!
//! [`keeps`]: CreationKeyboardClaims::keeps
//! [`holds`]: CreationKeyboardClaims::holds

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use super::type_ahead_tail::ESCAPE;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Claim {
    /// The workspace the create made (None until its reply, or when it failed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    workspace: Option<String>,
    /// The timestamp of the person's input that asked for it: that input's
    /// own end does not end the claim it made.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    input_timestamp: Option<f64>,
    /// The hold of the create that made it: only that create's reply names its workspace.
    ticket: u64,
    /// The window's count of the person's own focus moves when it was made.
    intents: u64,
    /// The keys kept from the window while it held.
    #[serde(default)]
    kept: u64,
}

/// A claim that ended after keeping keys from its window.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EndedClaim {
    pub window: i64,
    pub kept: u64,
}

/// The claims. A value the app keeps and sends back.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CreationKeyboardClaims {
    claims: BTreeMap<i64, Claim>,
    #[serde(skip)]
    ended: Vec<EndedClaim>,
}

impl CreationKeyboardClaims {
    pub fn is_empty(&self) -> bool {
        self.claims.is_empty()
    }

    /// The claims that ended after keeping keys since the last call.
    pub fn take_ended(&mut self) -> Vec<EndedClaim> {
        std::mem::take(&mut self.ended)
    }

    fn set(&mut self, window: i64, claim: Option<Claim>) {
        let old = match claim {
            Some(claim) => self.claims.insert(window, claim),
            None => self.claims.remove(&window),
        };
        if let Some(old) = old.filter(|old| old.kept > 0) {
            self.ended.push(EndedClaim { window, kept: old.kept });
        }
    }

    /// The person's new workspace behind `ticket` claims window `window`'s
    /// keyboard, asked for by the input of timestamp `input`, while the
    /// window's own focus moves of the person number `intents`.
    pub fn claim(&mut self, window: i64, ticket: u64, input: Option<f64>, intents: u64) {
        let claim = Claim { workspace: None, input_timestamp: input, ticket, intents, kept: 0 };
        self.set(window, Some(claim));
    }

    /// The create behind `ticket` made `workspace`: the claim ends once the
    /// window shows it.
    pub fn made(&mut self, workspace: &str, ticket: u64, window: i64) {
        if let Some(claim) = self.claims.get_mut(&window).filter(|claim| claim.ticket == ticket) {
            claim.workspace = Some(workspace.to_owned());
        }
    }

    /// The person acted in window `window`, answering the input of timestamp
    /// `input`: a claim there ends. The input that asked for the claim does
    /// not end it. True when one ended.
    pub fn person_acted(&mut self, window: i64, input: Option<f64>) -> bool {
        let Some(claim) = self.claims.get(&window) else { return false };
        if input.is_some() && input == claim.input_timestamp {
            return false;
        }
        self.set(window, None);
        true
    }

    /// Ends the claim of window `window`.
    pub fn end(&mut self, window: i64) {
        self.set(window, None);
    }

    /// Whether window `window`'s claim holds while it shows workspace `shown`
    /// and the person made `intents` focus or selection moves of their own
    /// there, the last one answering the input of timestamp `last_input`.
    /// `same_window`: the window asked about is the claim's own (the app's
    /// identity check). A claim that ended is removed here.
    pub fn holds(
        &mut self,
        window: i64,
        same_window: bool,
        shown: Option<&str>,
        intents: u64,
        last_input: Option<f64>,
    ) -> bool {
        let Some(claim) = self.claims.get(&window) else { return false };
        let moved = intents != claim.intents
            && (last_input.is_none() || last_input != claim.input_timestamp);
        let shows = claim.workspace.is_some() && claim.workspace.as_deref() == shown;
        if !same_window || moved || shows {
            self.set(window, None);
            return false;
        }
        true
    }

    /// A key of window `window` while its claim holds and no creation hold
    /// keeps it: false when it goes on, true when it is kept from the window;
    /// None for Escape, which ends the claim and goes on. A key that runs a
    /// binding or the next key of a pending chord goes on: the action it runs
    /// is the person's next intent. Every other key is kept.
    pub fn keeps(
        &mut self,
        window: i64,
        key_code: u16,
        chord_pending: bool,
        runs_binding: bool,
    ) -> Option<bool> {
        if key_code == ESCAPE {
            self.set(window, None);
            return None;
        }
        if chord_pending || runs_binding {
            return Some(false);
        }
        if let Some(claim) = self.claims.get_mut(&window) {
            claim.kept += 1;
        }
        Some(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_claim_holds_until_the_window_shows_its_workspace() {
        let mut claims = CreationKeyboardClaims::default();
        claims.claim(7, 1, Some(2.0), 3);
        assert!(claims.holds(7, true, Some("home"), 3, None));
        claims.made("w1", 2, 7);
        assert!(claims.holds(7, true, Some("w1"), 3, None), "another create's reply named it");
        claims.made("w1", 1, 7);
        assert!(claims.holds(7, true, Some("home"), 3, None));
        assert!(!claims.holds(7, true, Some("w1"), 3, None));
        assert!(claims.is_empty());
    }

    #[test]
    fn the_persons_own_move_ends_a_claim_but_not_the_one_that_asked_for_it() {
        let mut claims = CreationKeyboardClaims::default();
        claims.claim(7, 1, Some(2.0), 3);
        assert!(claims.holds(7, true, None, 4, Some(2.0)), "the asking input's move ended it");
        assert!(!claims.person_acted(7, Some(2.0)));
        assert!(claims.person_acted(7, Some(2.5)));
        assert!(!claims.person_acted(7, Some(2.5)));
        claims.claim(7, 1, Some(2.0), 3);
        assert!(!claims.holds(7, true, None, 4, None));
        claims.claim(7, 1, Some(2.0), 3);
        assert!(!claims.holds(7, false, None, 3, None), "another window with its number");
    }

    #[test]
    fn keys_are_kept_but_bindings_and_escape_go_on() {
        let mut claims = CreationKeyboardClaims::default();
        claims.claim(7, 1, None, 0);
        assert_eq!(claims.keeps(7, 0, false, false), Some(true));
        assert_eq!(claims.keeps(7, 36, false, false), Some(true));
        assert_eq!(claims.keeps(7, 48, false, true), Some(false));
        assert_eq!(claims.keeps(7, 0, true, false), Some(false));
        assert!(claims.take_ended().is_empty());
        assert_eq!(claims.keeps(7, ESCAPE, false, false), None);
        assert!(claims.is_empty());
        assert_eq!(claims.take_ended(), vec![EndedClaim { window: 7, kept: 2 }]);
    }
}
