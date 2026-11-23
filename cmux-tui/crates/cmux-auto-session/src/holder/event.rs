//! What happens to a chat: the person's switches, time, the chat's own work and the store's
//! answers.

use serde::{Deserialize, Serialize};

use crate::cloud::AutoCloudError;
use crate::wire::{AssignmentKind, ErrorCode, Holder, LeaseAnswer, Role, SessionView};

/// What changed in the chat's own work.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Change {
    /// A turn started. Nothing to copy yet; the store learns the chat has work.
    TurnStarted,
    /// A turn is streaming. A copy goes at most every
    /// [`STREAM_COPY_MS`](crate::consts::STREAM_COPY_MS).
    Streaming,
    ToolEnded,
    TurnEnded,
    /// A prompt was queued or left the queue, or a background task started or ended.
    QueueChanged,
}

impl Change {
    pub fn as_str(self) -> &'static str {
        match self {
            Change::TurnStarted => "turn_started",
            Change::Streaming => "streaming",
            Change::ToolEnded => "tool_ended",
            Change::TurnEnded => "turn_ended",
            Change::QueueChanged => "queue_changed",
        }
    }
}

/// What the store said about who holds the chat.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    /// This machine holds it, at the answer's epoch.
    Holder,
    /// Another holder runs it and this laptop is listed to get it back.
    Standby,
    /// This machine does not hold it (the lease's `lost`, `auto.stale_epoch`,
    /// `auto.not_holder`).
    Lost,
    /// Auto is off for the chat (`auto.closed`, or the store does not know it).
    Closed,
}

impl Verdict {
    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Holder => "holder",
            Verdict::Standby => "standby",
            Verdict::Lost => "lost",
            Verdict::Closed => "closed",
        }
    }
}

/// The store's answer to a renewal or a registration, reduced to what the machine decides on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Answer {
    pub verdict: Verdict,
    /// The chat's epoch in the store; 0 when the answer was an error without a session.
    pub epoch: u64,
    /// The store's newest snapshot; 0 for none.
    pub snapshot: u64,
    /// The inbox has messages the holder has not acked.
    pub inbox_pending: bool,
    /// A laptop stands by and the chat is not kept in the Cloud.
    pub handback_due: bool,
}

impl Answer {
    fn of(verdict: Verdict, session: &SessionView) -> Answer {
        Answer {
            verdict,
            epoch: session.epoch,
            snapshot: session.snapshot,
            inbox_pending: session.inbox_pending(),
            handback_due: session.handback_due(),
        }
    }

    fn bare(verdict: Verdict) -> Answer {
        Answer { verdict, epoch: 0, snapshot: 0, inbox_pending: false, handback_due: false }
    }

    /// A lease's answer.
    pub fn from_lease(answer: &LeaseAnswer) -> Answer {
        let verdict = if !answer.session.auto {
            Verdict::Closed
        } else {
            match answer.role {
                Role::Holder => Verdict::Holder,
                Role::Standby => Verdict::Standby,
                Role::Lost => Verdict::Lost,
            }
        };
        Answer::of(verdict, &answer.session)
    }

    /// The session a `PUT /:id` answered, read as this machine (`me`).
    pub fn from_session(session: &SessionView, me: &Holder) -> Answer {
        let verdict = if !session.auto {
            Verdict::Closed
        } else if session.holder == *me {
            Verdict::Holder
        } else {
            Verdict::Lost
        };
        Answer::of(verdict, session)
    }

    /// An error that is an answer about the holder; None for one that says nothing (no
    /// network, a 5xx), which is [`Event::Unanswered`].
    pub fn from_error(error: &AutoCloudError) -> Option<Answer> {
        match error.code() {
            Some(ErrorCode::StaleEpoch | ErrorCode::NotHolder) => Some(Answer::bare(Verdict::Lost)),
            Some(ErrorCode::Closed) => Some(Answer::bare(Verdict::Closed)),
            Some(
                ErrorCode::NoMachine
                | ErrorCode::HeldInCloud
                | ErrorCode::SeqGap
                | ErrorCode::SnapshotIncomplete
                | ErrorCode::NoSnapshot
                | ErrorCode::ChunkMismatch
                | ErrorCode::TooLarge,
            ) => None,
            // The store does not know the chat: Auto is off as far as the Cloud can tell.
            None => (error.status() == Some(404)).then(|| Answer::bare(Verdict::Closed)),
        }
    }
}

/// One thing that happened. The daemon sends each to [`step`](super::step) with the time.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Event {
    /// The person switched Auto on for this chat.
    AutoOn,
    /// The person switched Auto off for this chat. The chat stays an Auto chat until the store
    /// confirms it ([`Event::Closed`]).
    AutoOff,
    /// The time a `ScheduleAt` effect named has come.
    Tick,
    /// The system woke from sleep (the app's notice). A jump of the clock between two steps
    /// counts as one too, whatever the event.
    Wake,
    /// The chat's own work changed; `needs_run` is `Hub::sessions_at_work`'s rule for it now.
    Changed { change: Change, needs_run: bool },
    /// The store answered the renewal or registration numbered `request`.
    Answered { request: u64, answer: Answer },
    /// The renewal or registration numbered `request` got no answer about the holder. The
    /// daemon gives a request up within [`RENEW_MS`](crate::consts::RENEW_MS).
    Unanswered { request: u64 },
    /// The store assigned the chat to this Cloud machine, at `epoch`.
    Assigned { kind: AssignmentKind, epoch: u64 },
    /// The import asked for at `epoch` finished: the chat is a local session. `snapshot` is the
    /// snapshot it came from, 0 for none.
    ImportDone { epoch: u64, snapshot: u64 },
    /// The import asked for at `epoch` failed.
    ImportFailed { epoch: u64 },
    /// The store has the copy numbered `copy` and every event up to it, as its snapshot number
    /// `snapshot`.
    SnapshotStored { copy: u64, snapshot: u64 },
    /// The copy numbered `copy` did not reach the store. `too_large`: it is past the cap.
    SnapshotFailed { copy: u64, too_large: bool },
    /// The store took the release, or said the chat is no longer this machine's.
    Released,
    /// The store closed the chat: Auto is off.
    Closed,
}

impl Event {
    /// The event for a renewal's result.
    pub fn from_renewal(request: u64, result: &Result<LeaseAnswer, AutoCloudError>) -> Event {
        let answer = match result {
            Ok(answer) => Some(Answer::from_lease(answer)),
            Err(error) => Answer::from_error(error),
        };
        Event::answer(request, answer)
    }

    /// The event for a registration's result (`PUT /:id` with `auto: true`), read as `me`.
    pub fn from_registration(
        request: u64,
        me: &Holder,
        result: &Result<SessionView, AutoCloudError>,
    ) -> Event {
        let answer = match result {
            Ok(session) => Some(Answer::from_session(session, me)),
            Err(error) => Answer::from_error(error),
        };
        Event::answer(request, answer)
    }

    fn answer(request: u64, answer: Option<Answer>) -> Event {
        match answer {
            Some(answer) => Event::Answered { request, answer },
            None => Event::Unanswered { request },
        }
    }

    /// Every event's name, in the order of the enum.
    pub const KINDS: [&'static str; 14] = [
        "auto_on",
        "auto_off",
        "tick",
        "wake",
        "changed",
        "answered",
        "unanswered",
        "assigned",
        "import_done",
        "import_failed",
        "snapshot_stored",
        "snapshot_failed",
        "released",
        "closed",
    ];

    /// The event's name, without its data.
    pub fn kind(&self) -> &'static str {
        match self {
            Event::AutoOn => "auto_on",
            Event::AutoOff => "auto_off",
            Event::Tick => "tick",
            Event::Wake => "wake",
            Event::Changed { .. } => "changed",
            Event::Answered { .. } => "answered",
            Event::Unanswered { .. } => "unanswered",
            Event::Assigned { .. } => "assigned",
            Event::ImportDone { .. } => "import_done",
            Event::ImportFailed { .. } => "import_failed",
            Event::SnapshotStored { .. } => "snapshot_stored",
            Event::SnapshotFailed { .. } => "snapshot_failed",
            Event::Released => "released",
            Event::Closed => "closed",
        }
    }
}
