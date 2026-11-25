//! One chat's state on one machine, and what follows from it without an event.

use serde::{Deserialize, Serialize};

use super::{Effect, Event, ImportReason, MoveTo, step};
use crate::consts::SELF_STOP_MS;
use crate::wire::Blocked;

/// How far a give is: the holder hands the chat to where the person wants it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GiveStep {
    /// The turn that ran here is being stopped.
    Stopping,
    /// Nothing runs here. The copy that covers the chat's last event is on its way, or
    /// failed and the next tick sends it again; with it stored, the next tick asks again for a
    /// give the store did not answer.
    Copying,
    /// The store has the copy and was asked to take the chat.
    Asking,
}

impl GiveStep {
    pub fn as_str(self) -> &'static str {
        match self {
            GiveStep::Stopping => "stopping",
            GiveStep::Copying => "copying",
            GiveStep::Asking => "asking",
        }
    }
}

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

/// Where the newest copy this machine asked for is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CopyState {
    /// The store has it, or none was asked for since the chat came here.
    Stored,
    /// It is on its way to the store.
    Sending,
    /// It did not reach the store.
    Failed,
}

/// Where a chat is on this machine, with the data only that state has. The first seven are a
/// laptop's states and the last four a Cloud machine's, so the state says which side it is.
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
    /// Laptop: another holder runs the chat, or nobody does; this laptop renews as standby.
    Standby { epoch: u64 },
    /// Laptop: the store gave the chat to this laptop; the import has not finished, so
    /// nothing runs. `failed`: the last attempt failed and the next tick tries again.
    ComingHome { epoch: u64, failed: bool },
    /// Laptop: this laptop holds the chat and the person moved it (`to`): its turn is stopped,
    /// its last copy goes to the store, and the store is asked to take it. Nothing of the chat
    /// starts here meanwhile.
    Giving { epoch: u64, step: GiveStep, to: MoveTo },
    /// Machine: the chat is not this machine's. It does not run here until the store assigns
    /// it.
    Away,
    /// Machine: the store assigned the chat; the import has not finished, so nothing runs.
    /// `failed`: the last attempt failed and the next tick tries again.
    Taking { epoch: u64, reason: ImportReason, failed: bool },
    /// Machine: this machine holds the chat and its processes may run. Once it has nothing
    /// left to run and the store has its last copy, its renewal says so, and the store gives
    /// the chat home to a laptop standing by.
    Serving { epoch: u64 },
    /// Machine: this machine holds the chat and the person moved it (`to`): the machine's
    /// [`State::Giving`].
    Returning { epoch: u64, step: GiveStep, to: MoveTo },
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
        "giving",
        "away",
        "taking",
        "serving",
        "returning",
    ];

    pub fn kind(&self) -> &'static str {
        match self {
            State::Off => "off",
            State::Registering => "registering",
            State::Holding { .. } => "holding",
            State::Stopped { .. } => "stopped",
            State::Standby { .. } => "standby",
            State::ComingHome { .. } => "coming_home",
            State::Giving { .. } => "giving",
            State::Away => "away",
            State::Taking { .. } => "taking",
            State::Serving { .. } => "serving",
            State::Returning { .. } => "returning",
        }
    }

    pub fn side(&self) -> Side {
        match self {
            State::Off
            | State::Registering
            | State::Holding { .. }
            | State::Stopped { .. }
            | State::Standby { .. }
            | State::ComingHome { .. }
            | State::Giving { .. } => Side::Laptop,
            State::Away
            | State::Taking { .. }
            | State::Serving { .. }
            | State::Returning { .. } => Side::Machine,
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
            | State::Giving { epoch, .. }
            | State::Taking { epoch, .. }
            | State::Serving { epoch }
            | State::Returning { epoch, .. } => Some(*epoch),
        }
    }

    /// The give this holder is in the middle of: how far it is and where the chat goes.
    pub fn giving(&self) -> Option<(GiveStep, MoveTo)> {
        match self {
            State::Giving { step, to, .. } | State::Returning { step, to, .. } => {
                Some((*step, *to))
            }
            State::Off
            | State::Registering
            | State::Holding { .. }
            | State::Stopped { .. }
            | State::Standby { .. }
            | State::ComingHome { .. }
            | State::Away
            | State::Taking { .. }
            | State::Serving { .. } => None,
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
    /// (`Hub::sessions_at_work`'s rule), as the last [`Event::Changed`] said. An import on a
    /// Cloud machine and a drain of the inbox set it too: the chat was given work, and the
    /// next `Changed` says when it is done.
    pub needs_run: bool,
    /// The `needsRun` the last renewal sent. A change is told to the store at once.
    pub told_needs_run: bool,
    /// The newest snapshot in the store that this machine stored or imported; 0 for none.
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
    /// The last renewal went unanswered or was answered slowly: the next ones go
    /// [`RENEW_RETRY_MS`](crate::consts::RENEW_RETRY_MS) apart until one is answered in time.
    /// Absent from a chat saved before it was added, which renews at the usual pace.
    #[serde(default)]
    pub renew_soon: bool,
    /// The last request number issued.
    pub requests: u64,
    /// The last copy number issued (`UploadSnapshot.copy`).
    pub copies: u64,
    /// Where that copy is. A Cloud machine says it has nothing left to run only once the
    /// store has it: the store gives the chat home on that word.
    pub copy: CopyState,
    /// When the last copy was asked for.
    pub copied_at: u64,
    /// The store refused to take this chat for the wish it still tells, or the chat is too
    /// large to copy: the wish is not acted on again until an answer comes without one, or the
    /// person asks again.
    #[serde(default)]
    pub declined: bool,
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
            renew_soon: false,
            requests: 0,
            copies: 0,
            copy: CopyState::Stored,
            copied_at: 0,
            declined: false,
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
    /// store before anything runs; a Cloud machine renews. The machine cannot know that the
    /// store has what it did last, so it copies the chat again before it says nothing is left
    /// to run.
    pub fn resume(side: Side, epoch: u64, snapshot: u64, now: u64) -> (Chat, Vec<Effect>) {
        let (state, copy) = match side {
            Side::Laptop => (State::Holding { epoch }, CopyState::Stored),
            Side::Machine => (State::Serving { epoch }, CopyState::Failed),
        };
        step(Chat { state, snapshot, copy, ..Chat::new(side, now) }, Event::Wake, now)
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
            | State::Giving { .. }
            | State::Taking { .. }
            | State::Serving { .. }
            | State::Returning { .. } => true,
            State::Off | State::Registering | State::Standby { .. } | State::Away => false,
        }
    }

    /// The chat's agent may run here now: start a turn, run a queued prompt, go on with a
    /// tool. False while the tree is stopped, while another holder runs the chat, during an
    /// import, and while the chat is being given to where the person moved it.
    pub fn may_run(&self) -> bool {
        match self.state {
            State::Off | State::Registering | State::Holding { .. } | State::Serving { .. } => true,
            State::Stopped { .. }
            | State::Standby { .. }
            | State::ComingHome { .. }
            | State::Giving { .. }
            | State::Away
            | State::Taking { .. }
            | State::Returning { .. } => false,
        }
    }

    /// Where the chat is being moved to by this holder, while it is (the row's `moving`).
    pub fn moving(&self) -> Option<MoveTo> {
        self.state.giving().map(|(_, to)| to)
    }

    /// What the session row shows as `blocked` from this machine's side. The store's own
    /// `no_machine` is on the session view.
    pub fn blocked(&self) -> Option<Blocked> {
        match self.state {
            State::Stopped { why: Stop::Offline, .. } => Some(Blocked::Offline),
            State::Holding { .. }
            | State::Stopped { why: Stop::Wake, .. }
            | State::Giving { .. } => self.too_large.then_some(Blocked::TooLarge),
            State::Off
            | State::Registering
            | State::Standby { .. }
            | State::ComingHome { .. }
            | State::Away
            | State::Taking { .. }
            | State::Serving { .. }
            | State::Returning { .. } => None,
        }
    }

    /// The `needsRun` a renewal sends.
    ///
    /// A laptop says it only once the store has a snapshot to take over from and the chat is
    /// not too large; otherwise a lapsed lease parks the chat instead of starting a machine
    /// that could not go on with it.
    ///
    /// A Cloud machine also says it while its newest copy is not in the store. The store gives
    /// the chat home on a machine's `false`, so the machine says `false` only when the laptop
    /// would import everything it did: events first, then the snapshot covering them, then
    /// this renewal.
    pub fn reports_needs_run(&self) -> bool {
        match self.state {
            State::Holding { .. } | State::Stopped { .. } | State::Giving { .. } => {
                self.needs_run && self.snapshot > 0 && !self.too_large
            }
            State::Serving { .. } | State::Returning { .. } => {
                self.needs_run || self.copy != CopyState::Stored
            }
            State::Off
            | State::Registering
            | State::Standby { .. }
            | State::ComingHome { .. }
            | State::Away
            | State::Taking { .. } => false,
        }
    }

    /// When a laptop that holds the chat stops it by itself, with no renewal answered by then.
    /// A laptop in the middle of a give holds the chat too.
    pub fn self_stop_at(&self) -> Option<u64> {
        match self.state {
            State::Holding { .. } | State::Giving { .. } => {
                Some(self.fresh_at.saturating_add(SELF_STOP_MS))
            }
            State::Off
            | State::Registering
            | State::Stopped { .. }
            | State::Standby { .. }
            | State::ComingHome { .. }
            | State::Away
            | State::Taking { .. }
            | State::Serving { .. }
            | State::Returning { .. } => None,
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
