//! Comments and votes on a target (an RFD, a thread, a session).
//!
//! Votes are feedback, never permissions or merge gates. One person has one current vote per target;
//! changing it appends an event and updates the summary. An agent's vote is advisory and records its
//! owner. The same feedback id arriving twice (a retry, a bridge echo) counts once, and a bridge
//! author never casts a vote, so a Slack message never creates a second one.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::identity::{self, IdentityError, PrincipalKind};
use crate::model::Feedback;
use crate::refs::RefKey;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FeedbackKind {
    Comment,
    Vote,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FeedbackError {
    Identity(IdentityError),
    /// A vote with no value.
    NoValue,
}

/// What one target's feedback adds up to.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct VoteSummary {
    /// Value to the number of people whose current vote it is.
    pub people: BTreeMap<i8, u32>,
    /// The same for agents, labelled advisory and never mixed into `people`.
    pub advisory: BTreeMap<i8, u32>,
    pub comments: u32,
}

/// The feedback log and current votes.
#[derive(Debug, Clone, Default)]
pub struct VoteBoard {
    events: Vec<Feedback>,
    seen: BTreeSet<String>,
    current: BTreeMap<(RefKey, String), Feedback>,
}

impl VoteBoard {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record one comment or vote. Returns `Ok(false)` for a feedback id already recorded.
    pub fn record(&mut self, f: Feedback) -> Result<bool, FeedbackError> {
        identity::validate(&f.author).map_err(FeedbackError::Identity)?;
        identity::require_rights(&f.author).map_err(FeedbackError::Identity)?;
        if f.kind == FeedbackKind::Vote && f.value.is_none() {
            return Err(FeedbackError::NoValue);
        }
        if !self.seen.insert(f.id.clone()) {
            return Ok(false);
        }
        if f.kind == FeedbackKind::Vote {
            let key = (f.target_ref.key.clone(), f.author.id.clone());
            // The latest vote is current, whatever order the events arrive in (ties: the larger id).
            let newer = self
                .current
                .get(&key)
                .is_none_or(|old| (f.created_at, &f.id) > (old.created_at, &old.id));
            if newer {
                self.current.insert(key, f.clone());
            }
        }
        self.events.push(f);
        Ok(true)
    }

    /// Every event in arrival order: the history behind the summary.
    pub fn events(&self) -> &[Feedback] {
        &self.events
    }

    /// The author's current vote on `target`.
    pub fn current(&self, target: &RefKey, author: &str) -> Option<&Feedback> {
        self.current.get(&(target.clone(), author.to_owned()))
    }

    pub fn summary(&self, target: &RefKey) -> VoteSummary {
        let mut s = VoteSummary::default();
        for ((t, _), f) in &self.current {
            if t != target {
                continue;
            }
            let Some(v) = f.value else { continue };
            let bucket = match f.author.kind {
                PrincipalKind::Person => &mut s.people,
                PrincipalKind::Agent => &mut s.advisory,
            };
            *bucket.entry(v).or_default() += 1;
        }
        s.comments = self
            .events
            .iter()
            .filter(|f| f.kind == FeedbackKind::Comment && &f.target_ref.key == target)
            .count() as u32;
        s
    }
}
