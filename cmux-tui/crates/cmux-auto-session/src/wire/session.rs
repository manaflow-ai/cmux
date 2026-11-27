//! `session`: the view of one Auto chat that every route answers.

use serde::{Deserialize, Serialize};

use super::{Holder, MoveWish};

/// What a client shows for a chat.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    /// A laptop holds it.
    Local,
    /// A machine holds it and acked its assignment.
    Cloud,
    /// A machine holds it and has not acked yet.
    Resuming,
    /// Nobody holds it.
    Parked,
    /// A machine holds it and a handback is due at the next turn end.
    ComingBack,
}

impl State {
    pub const ALL: [State; 5] =
        [State::Local, State::Cloud, State::Resuming, State::Parked, State::ComingBack];

    pub fn as_str(self) -> &'static str {
        match self {
            State::Local => "local",
            State::Cloud => "cloud",
            State::Resuming => "resuming",
            State::Parked => "parked",
            State::ComingBack => "coming_back",
        }
    }
}

/// Why a chat cannot keep running in the Cloud. The store sets `no_machine`; a laptop's daemon
/// adds `too_large` and `offline` on its own session rows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Blocked {
    /// The owner has no Auto machine; the clients offer to make one.
    NoMachine,
    /// The chat's snapshot is past the size cap, so it stays local.
    TooLarge,
    /// The laptop cannot reach the Cloud; its Auto chats wait for the network.
    Offline,
}

impl Blocked {
    pub const ALL: [Blocked; 3] = [Blocked::NoMachine, Blocked::TooLarge, Blocked::Offline];

    pub fn as_str(self) -> &'static str {
        match self {
            Blocked::NoMachine => "no_machine",
            Blocked::TooLarge => "too_large",
            Blocked::Offline => "offline",
        }
    }
}

/// The repository and branch a chat works in.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Repo {
    pub remote: String,
    pub branch: String,
}

/// One Auto chat as the store answers it. Times are epoch milliseconds.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionView {
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub harness: String,
    /// The team the chat runs in: its creator's, then its machine's. The store answers `null`
    /// for a chat whose creator has none.
    #[serde(default)]
    pub team: Option<String>,
    #[serde(default)]
    pub owner: String,
    /// False once Auto was switched off for the chat (the chat is closed in the store).
    pub auto: bool,
    /// The person keeps this chat in the Cloud: no handback.
    #[serde(default)]
    pub keep_in_cloud: bool,
    pub holder: Holder,
    /// Grows by one at every change of holder. Every write names it.
    pub epoch: u64,
    pub state: State,
    #[serde(default)]
    pub blocked: Option<Blocked>,
    /// What the holder said at its last renewal: a turn running, a prompt queued or a background
    /// task at work.
    #[serde(default)]
    pub needs_run: bool,
    /// The laptops that are online and not the holder: each renewed as standby within the last
    /// lease.
    #[serde(default)]
    pub standby: Vec<Holder>,
    /// `move`: the person asked to move the chat and its holder has not given it yet. None when
    /// nobody asked.
    #[serde(rename = "move", default, skip_serializing_if = "Option::is_none")]
    pub moving: Option<MoveWish>,
    /// The last event seq the store has.
    #[serde(default)]
    pub last_seq: u64,
    /// The newest snapshot's number; 0 when there is none.
    #[serde(default)]
    pub snapshot: u64,
    /// The newest inbox message's number; 0 when there is none.
    #[serde(default)]
    pub inbox: u64,
    /// The newest inbox message the holder acked.
    #[serde(default)]
    pub inbox_acked: u64,
    #[serde(default)]
    pub repo: Option<Repo>,
    /// Grows at every change to this view; `wait` answers once it passes the caller's.
    pub version: u64,
    #[serde(default)]
    pub created_at: u64,
    #[serde(default)]
    pub updated_at: u64,
    /// When the holder's lease runs out without another renewal. 0 for a parked chat and for a
    /// machine that has not acked its assignment yet.
    #[serde(default)]
    pub lease_expires_at: u64,
}

impl SessionView {
    /// Inbox messages the holder has not acked.
    pub fn inbox_pending(&self) -> bool {
        self.inbox > self.inbox_acked
    }

    /// A handback is due: a machine holds the chat, a laptop stands by and the chat is not kept
    /// in the Cloud. The store gives the chat home at the machine's next renewal that says
    /// nothing is left to run, once the inbox and the assignment are acked and the newest
    /// snapshot covers the last event.
    pub fn handback_due(&self) -> bool {
        self.holder.is_vm() && !self.keep_in_cloud && !self.standby.is_empty()
    }
}

/// `{session}`: the answer of every route that changes one chat.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionAnswer {
    pub session: SessionView,
}

/// `GET /v1/auto-sessions`: one page of the owner's chats.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionList {
    pub sessions: Vec<SessionView>,
    /// The `cursor` of the next page; None on the last one.
    #[serde(default)]
    pub next_cursor: Option<String>,
}
