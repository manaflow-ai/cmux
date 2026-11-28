//! `Open in cmux`: a Slack thread's one canonical forum thread (RFD 0170 "Slack bridge" and phase 4;
//! RFD 0123's thread-to-app handoff).
//!
//! A Slack root or any reply in it resolves to the same forum thread, so one click opens the
//! conversation in the app. The binding is one to one: a Slack thread never becomes a second forum
//! thread, and a forum thread projects back to the one Slack thread it came from. A cmux reply posted
//! into Slack carries origin metadata ([`MIRROR_ORIGIN`]); when Slack echoes it back to the bridge it
//! resolves to [`Handoff::Echo`] and is not imported again, which stops the loop.
//!
//! Who may open the thread is still the forum's permission: the handoff names a target, it never
//! grants reading it.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::refs::{RefError, RefKey, RefKind, RefSource};

/// The origin a cmux reply carries in its Slack message metadata.
pub const MIRROR_ORIGIN: &str = "cmux";

/// One Slack message as the bridge receives it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SlackMessage {
    /// The Slack workspace (team) id.
    pub workspace: String,
    pub channel: String,
    pub ts: String,
    /// The root's `ts` for a reply; absent on a root.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread_ts: Option<String>,
    /// The message metadata's origin, when it has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
}

impl SlackMessage {
    /// The Slack thread this message belongs to: `slack-thread:slack/WORKSPACE/CHANNEL/ROOT_TS`.
    pub fn thread_key(&self) -> Result<RefKey, RefError> {
        let root = self.thread_ts.as_deref().filter(|t| !t.trim().is_empty()).unwrap_or(&self.ts);
        let parts = [self.workspace.trim(), self.channel.trim(), root.trim()];
        if parts.iter().any(|p| p.is_empty() || p.contains('/')) {
            return Err(RefError::BadId(parts.join("/")));
        }
        RefKey::new(RefKind::SlackThread, RefSource::Slack, &parts.join("/"))
    }

    /// Whether cmux itself posted this (a projected reply coming back).
    pub fn is_mirror(&self) -> bool {
        self.origin.as_deref().is_some_and(|o| o.trim().eq_ignore_ascii_case(MIRROR_ORIGIN))
    }
}

/// What the bridge does with a Slack message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "handoff")]
pub enum Handoff {
    /// `Open in cmux` opens `thread`.
    Open { slack: RefKey, thread: RefKey },
    /// No forum thread yet; the bridge creates one and [`HandoffIndex::bind`]s it.
    Unbound { slack: RefKey },
    /// cmux's own projected reply; not imported again.
    Echo,
    /// Not a Slack thread the bridge can name.
    Invalid,
}

/// What a cmux reply carries when it is projected into Slack.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Projection {
    /// The Slack thread to reply in.
    pub slack: RefKey,
    /// Always [`MIRROR_ORIGIN`].
    pub origin: String,
    /// The forum thread's canonical ref.
    pub thread: String,
    pub message_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BindError {
    /// The Slack ref is not a Slack thread, or the thread ref not a cmux thread.
    WrongKind,
    /// The Slack thread already opens another forum thread.
    SlackBound { thread: RefKey },
    /// The forum thread already mirrors another Slack thread.
    ThreadBound { slack: RefKey },
}

impl std::fmt::Display for BindError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::WrongKind => write!(f, "a handoff binds a Slack thread to a cmux thread"),
            Self::SlackBound { thread } => write!(f, "that Slack thread already opens {thread}"),
            Self::ThreadBound { slack } => write!(f, "that thread already mirrors {slack}"),
        }
    }
}

impl std::error::Error for BindError {}

/// Slack thread to forum thread, one to one.
#[derive(Debug, Clone, Default)]
pub struct HandoffIndex {
    by_slack: BTreeMap<RefKey, RefKey>,
    by_thread: BTreeMap<RefKey, RefKey>,
}

impl HandoffIndex {
    pub fn new() -> Self {
        Self::default()
    }

    /// Bind `slack` to `thread`. Binding the same pair again is a no-op; either side already bound
    /// elsewhere is refused, so each Slack thread has one canonical forum thread.
    pub fn bind(&mut self, slack: RefKey, thread: RefKey) -> Result<(), BindError> {
        if slack.kind != RefKind::SlackThread
            || slack.source != RefSource::Slack
            || thread.kind != RefKind::Thread
            || thread.source != RefSource::Cmux
        {
            return Err(BindError::WrongKind);
        }
        match (self.by_slack.get(&slack), self.by_thread.get(&thread)) {
            (Some(t), _) if *t == thread => Ok(()),
            (Some(t), _) => Err(BindError::SlackBound { thread: t.clone() }),
            (None, Some(s)) => Err(BindError::ThreadBound { slack: s.clone() }),
            (None, None) => {
                self.by_slack.insert(slack.clone(), thread.clone());
                self.by_thread.insert(thread, slack);
                Ok(())
            }
        }
    }

    /// Where a Slack root or reply opens in cmux.
    pub fn resolve(&self, message: &SlackMessage) -> Handoff {
        if message.is_mirror() {
            return Handoff::Echo;
        }
        let Ok(slack) = message.thread_key() else { return Handoff::Invalid };
        match self.by_slack.get(&slack) {
            Some(thread) => Handoff::Open { slack, thread: thread.clone() },
            None => Handoff::Unbound { slack },
        }
    }

    /// The Slack thread a forum thread mirrors.
    pub fn slack_for(&self, thread: &RefKey) -> Option<&RefKey> {
        self.by_thread.get(thread)
    }

    /// How a cmux reply in `thread` goes to Slack: into the thread's one Slack thread, marked so its
    /// echo is not imported. `None` when the thread has no Slack side.
    pub fn project(&self, thread: &RefKey, message_id: &str) -> Option<Projection> {
        self.by_thread.get(thread).map(|slack| Projection {
            slack: slack.clone(),
            origin: MIRROR_ORIGIN.to_owned(),
            thread: thread.canonical(),
            message_id: message_id.to_owned(),
        })
    }

    pub fn len(&self) -> usize {
        self.by_slack.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_slack.is_empty()
    }
}
