//! One chat's state on one machine, and what follows from it without an event.

use serde::{Deserialize, Serialize};

use super::{Effect, Event, ImportReason, step};
use crate::consts::SELF_STOP_MS;
use crate::wire::Blocked;

/// Which kind of machine this is. A laptop holds as `device:<id>`, stops by itself offline and
/// stands by; a Cloud machine holds as `vm:<machine>`, takes assignments and hands back.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Side {
    Laptop,
    Machine,
}

impl Side {
    pub fn as_str(self) -> &'static str {
        match self {
            Side::Laptop => "laptop",
            Side::Machine => "machine",
        }
    }
}

/// Why a laptop's process tree is stopped.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Stop {
    /// The laptop woke (or its clock jumped); the renewal sent at the wake has no answer yet.
    Wake,
    /// No renewal was answered: the laptop cannot reach the Cloud.
    Offline,
}

/// Where a chat is on this machine, with the data only that state has. The first six are a
/// laptop's states and the last five a Cloud machine's, so the state says which side it is.
/// `epoch` is the epoch this machine writes under (in `standby`, the last one it heard of).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum State {
    /// Laptop: Auto is off for the chat. It runs as any chat does.
    Off,
    /// Laptop: Auto was switched on; the store has not answered the `PUT` that registers the
    /// chat. It still runs as any chat does.
    Registering,
    /// Laptop: this laptop holds the chat and its processes may run.
    Holding { epoch: u64 },
    /// Laptop: this laptop held the chat when its process tree was stopped. The next answered
    /// renewal says whether it still does.
    Stopped { epoch: u64, why: Stop },
    /// Laptop: another holder runs the chat; this laptop renews as standby.
    Standby { epoch: u64 },
    /// Laptop: the store gave the chat back to this laptop; the import has not finished, so
    /// nothing runs. `failed`: the last attempt failed and the next tick tries again.
    ComingHome { epoch: u64, failed: bool },
    /// Machine: the chat is not this machine's. It does not run here until the store assigns
    /// it.
    Away,
    /// Machine: the store assigned the chat; the import has not finished, so nothing runs.
    /// `failed`: the last attempt failed and the next tick tries again.
    Taking { epoch: u64, reason: ImportReason, failed: bool },
    /// Machine: this machine holds the chat and its processes may run.
    Serving { epoch: u64 },
    /// Machine: a laptop stands by and the chat has no work. The snapshot numbered `copy` is
    /// on its way to the store; the release follows it.
    HandingBack { epoch: u64, copy: u64 },
    /// Machine: the release was sent and has no answer yet. Nothing new runs.
    Releasing { epoch: u64 },
}

impl State {
    /// Every state's name, in the table's order.
    pub const KINDS: [&'static str; 11] = [
        "off",
        "registering",
        "holding",
        "stopped",
        "standby",
        "coming_home",
        "away",
        "taking",
        "serving",
        "handing_back",
        "releasing",
    ];

    pub fn kind(&self) -> &'static str {
        match self {
            State::Off => "off",
            State::Registering => "registering",
            State::Holding { .. } => "holding",
            State::Stopped { .. } => "stopped",
            State::Standby { .. } => "standby",
            State::ComingHome { .. } => "coming_home",
            State::Away => "away",
            State::Taking { .. } => "taking",
            State::Serving { .. } => "serving",
            State::HandingBack { .. } => "handing_back",
            State::Releasing { .. } => "releasing",
        }
    }

    pub fn side(&self) -> Side {
        match self {
            State::Off
            | State::Registering
            | State::Holding { .. }
            | State::Stopped { .. }
            | State::Standby { .. }
            | State::ComingHome { .. } => Side::Laptop,
            State::Away
            | State::Taking { .. }
            | State::Serving { .. }
            | State::HandingBack { .. }
            | State::Releasing { .. } => Side::Machine,
        }
    }

    /// The epoch this machine writes under, or last heard of.
    pub fn epoch(&self) -> Option<u64> {
        match self {
            State::Off | State::Registering | State::Away => None,
            State::Holding { epoch }
            | State::Stopped { epoch, .. }
            | State::Standby { epoch }
            | State::ComingHome { epoch, .. }
            | State::Taking { epoch, .. }
            | State::Serving { epoch }
            | State::HandingBack { epoch, .. }
            | State::Releasing { epoch } => Some(*epoch),
        }
    }
}

/// A request to the store that has no answer yet.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Sent {
    /// Its number; the answer's event carries it back.
    pub request: u64,
    /// When it was sent. A lease counts from here, not from when the answer arrived.
    pub at: u64,
}

/// One Auto chat on one machine. Plain data: keep one per chat and replace it with what
/// [`step`] returns.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Chat {
    pub state: State,
    /// The chat has work here: a turn running, a prompt queued or a background task
    /// (`Hub::sessions_at_work`'s rule), as the last [`Event::Changed`] said.
    pub needs_run: bool,
    /// The `needsRun` the last renewal sent. A change is told to the store at once.
    pub told_needs_run: bool,
    /// The newest snapshot in the store that this machine stored or imported; 0 for none. A
    /// newer one in the store means another holder wrote since.
    pub snapshot: u64,
    /// The chat's snapshot is past the size cap, so it has no Cloud copy to go on from.
    pub too_large: bool,
    /// The `now` of the last step. A jump from it is a wake.
    pub seen_at: u64,
    /// When the last renewal the store answered "holder" was sent.
    pub fresh_at: u64,
    /// When the next renewal, or the next try of what failed, is due.
    pub renew_at: Option<u64>,
    /// The renewal or registration that has no answer yet. Any other answer is ignored.
    pub awaiting: Option<Sent>,
    /// The last request number issued.
    pub requests: u64,
    /// The last copy number issued (`UploadSnapshot.copy`).
    pub copies: u64,
    /// When the last copy was asked for.
    pub copied_at: u64,
}

impl Chat {
    /// A chat this machine knows nothing more of: `off` on a laptop, `away` on a Cloud machine.
    pub fn new(side: Side, now: u64) -> Chat {
        let state = match side {
            Side::Laptop => State::Off,
            Side::Machine => State::Away,
        };
        Chat {
            state,
            needs_run: false,
            told_needs_run: false,
            snapshot: 0,
            too_large: false,
            seen_at: now,
            fresh_at: now,
            renew_at: None,
            awaiting: None,
            requests: 0,
            copies: 0,
            copied_at: 0,
        }
    }

    /// A chat another holder runs, which this laptop learned of (from the owner's list, or
    /// from its own record after a restart): it renews as standby at once.
    pub fn standby(epoch: u64, now: u64) -> (Chat, Vec<Effect>) {
        let chat = Chat { state: State::Standby { epoch }, ..Chat::new(Side::Laptop, now) };
        // A wake only renews a standby chat.
        step(chat, Event::Wake, now)
    }

    /// A chat this machine held when its daemon last ran, with the last snapshot it stored or
    /// imported. It is treated as a wake: a laptop stops the chat's process tree and asks the
    /// store before anything runs; a Cloud machine renews.
    pub fn resume(side: Side, epoch: u64, snapshot: u64, now: u64) -> (Chat, Vec<Effect>) {
        let state = match side {
            Side::Laptop => State::Holding { epoch },
            Side::Machine => State::Serving { epoch },
        };
        step(Chat { state, snapshot, ..Chat::new(side, now) }, Event::Wake, now)
    }

    pub fn side(&self) -> Side {
        self.state.side()
    }

    /// The epoch this machine writes under, or last heard of.
    pub fn epoch(&self) -> Option<u64> {
        self.state.epoch()
    }

    /// This machine is the chat's holder as far as it knows (the session row's `here`).
    pub fn here(&self) -> bool {
        match self.state {
            State::Holding { .. }
            | State::Stopped { .. }
            | State::ComingHome { .. }
            | State::Taking { .. }
            | State::Serving { .. }
            | State::HandingBack { .. }
            | State::Releasing { .. } => true,
            State::Off | State::Registering | State::Standby { .. } | State::Away => false,
        }
    }

    /// The chat's agent may run here now: start a turn, run a queued prompt, go on with a
    /// tool. False while the tree is stopped, while another holder runs the chat, and during an
    /// import or a release.
    pub fn may_run(&self) -> bool {
        match self.state {
            State::Off | State::Registering | State::Holding { .. } | State::Serving { .. } => true,
            // A handback copies an idle chat; new work ends the handback.
            State::HandingBack { .. } => true,
            State::Stopped { .. }
            | State::Standby { .. }
            | State::ComingHome { .. }
            | State::Away
            | State::Taking { .. }
            | State::Releasing { .. } => false,
        }
    }

    /// What the session row shows as `blocked` from this machine's side. The store's own
    /// `no_machine` is on the session view.
    pub fn blocked(&self) -> Option<Blocked> {
        match self.state {
            State::Stopped { why: Stop::Offline, .. } => Some(Blocked::Offline),
            State::Holding { .. } | State::Stopped { why: Stop::Wake, .. } => {
                self.too_large.then_some(Blocked::TooLarge)
            }
            State::Off
            | State::Registering
            | State::Standby { .. }
            | State::ComingHome { .. }
            | State::Away
            | State::Taking { .. }
            | State::Serving { .. }
            | State::HandingBack { .. }
            | State::Releasing { .. } => None,
        }
    }

    /// The `needsRun` a renewal sends. A laptop says it only once the store has a snapshot to
    /// take over from and the chat is not too large; otherwise a lapsed lease parks the chat
    /// instead of starting a machine that could not go on with it.
    pub fn reports_needs_run(&self) -> bool {
        match self.state {
            State::Holding { .. } | State::Stopped { .. } => {
                self.needs_run && self.snapshot > 0 && !self.too_large
            }
            State::Serving { .. } | State::HandingBack { .. } => self.needs_run,
            State::Off
            | State::Registering
            | State::Standby { .. }
            | State::ComingHome { .. }
            | State::Away
            | State::Taking { .. }
            | State::Releasing { .. } => false,
        }
    }

    /// When a laptop that holds the chat stops it by itself, with no renewal answered by then.
    pub fn self_stop_at(&self) -> Option<u64> {
        match self.state {
            State::Holding { .. } => Some(self.fresh_at.saturating_add(SELF_STOP_MS)),
            State::Off
            | State::Registering
            | State::Stopped { .. }
            | State::Standby { .. }
            | State::ComingHome { .. }
            | State::Away
            | State::Taking { .. }
            | State::Serving { .. }
            | State::HandingBack { .. }
            | State::Releasing { .. } => None,
        }
    }

    /// When the next [`Event::Tick`] is due: the earlier of the next renewal and the
    /// self-stop. None when nothing is scheduled.
    pub fn wake_at(&self) -> Option<u64> {
        match (self.renew_at, self.self_stop_at()) {
            (Some(renew), Some(stop)) => Some(renew.min(stop)),
            (Some(at), None) | (None, Some(at)) => Some(at),
            (None, None) => None,
        }
    }
}
