//! What happens to a chat: the person's switches, time, the chat's own work and the store's
//! answers.

use serde::{Deserialize, Serialize};

use crate::cloud::AutoCloudError;
// Where the person wants the chat to run now is the store's own word (`move`): one type.
pub use crate::wire::MoveTo;
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
    /// The chat is this machine's, at the answer's epoch. To a standby's renewal it means the
    /// store gave the chat to this laptop, which imports the Cloud copy first.
    Holder,
    /// Another holder runs it and this laptop is listed to get it back.
    Standby,
    /// What this machine runs is not the chat any more: the lease's `lost`. The store answers
    /// a renewal with it, never with `auto.stale_epoch`; a write refused `auto.stale_epoch` or
    /// `auto.not_holder` reads the same.
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

/// Why the store did not take a give (`POST /:id/give`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GiveFailure {
    /// `auto.not_copied`: the store's newest snapshot does not cover its last event. Copy
    /// again and ask again.
    NotCopied,
    /// `auto.no_move`: the person no longer wants the chat moved. It goes on here.
    NoMove,
    /// Any other refusal that names a reason (no laptop stands by, no machine to be found):
    /// the chat goes on here, and the same wish is not tried again.
    Refused,
    /// `auto.stale_epoch` or `auto.not_holder`: what runs here may not be the chat any more.
    /// The next renewal's answer says.
    Lost,
    /// The store did not answer. The next tick asks again.
    Unanswered,
    /// The daemon's own word, not the store's: the turn that runs here did not stop (a
    /// `StopTurn` that failed). The chat goes on here, and the same wish is not tried again.
    Stuck,
}

impl GiveFailure {
    pub fn as_str(self) -> &'static str {
        match self {
            GiveFailure::NotCopied => "not_copied",
            GiveFailure::NoMove => "no_move",
            GiveFailure::Refused => "refused",
            GiveFailure::Lost => "lost",
            GiveFailure::Unanswered => "unanswered",
            GiveFailure::Stuck => "stuck",
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
    /// A machine holds the chat, a laptop stands by and the chat is not kept in the Cloud. A
    /// machine that reads it in a "holder" answer was not relieved by its renewal.
    pub handback_due: bool,
    /// The person asked for the chat to be moved, and this holder has not given it yet (the
    /// lease answer's `move`). The store tells a wish only to the holder that must give.
    pub wish: Option<MoveTo>,
}

impl Answer {
    fn of(verdict: Verdict, session: &SessionView) -> Answer {
        Answer {
            verdict,
            epoch: session.epoch,
            snapshot: session.snapshot,
            inbox_pending: session.inbox_pending(),
            handback_due: session.handback_due(),
            wish: None,
        }
    }

    fn bare(verdict: Verdict) -> Answer {
        Answer {
            verdict,
            epoch: 0,
            snapshot: 0,
            inbox_pending: false,
            handback_due: false,
            wish: None,
        }
    }

    /// The same answer with the store's wish for the chat.
    pub fn wishing(self, wish: Option<MoveTo>) -> Answer {
        Answer { wish, ..self }
    }

    /// A lease's answer. The wish in it (`move`) is the holder's to act on: the store tells it
    /// to nobody else, and it is read from nobody else's answer.
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
        let wish = answer.move_to.filter(|_| verdict == Verdict::Holder);
        Answer::of(verdict, &answer.session).wishing(wish)
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

    /// An error that is an answer about the holder, read as this machine (`me`); None for one
    /// that says nothing (no network, a 5xx), which is [`Event::Unanswered`]. A refusal that
    /// carries the chat gives the answer its epoch.
    ///
    /// A 404 is never a laptop's answer. Only `auto.closed` closes a laptop's chat: a 404 can
    /// come from another account's sign-in, a Worker that does not serve the routes or a
    /// proxy, while a Cloud machine runs the chat. Read as "Auto is off" it would continue a
    /// stopped tree beside that machine and end the renewals that would say so; read as no
    /// answer, the chat stays stopped.
    pub fn from_error(error: &AutoCloudError, me: &Holder) -> Option<Answer> {
        let of = |verdict| match error.session() {
            Some(session) => Answer::of(verdict, session),
            None => Answer::bare(verdict),
        };
        match error.code() {
            Some(ErrorCode::StaleEpoch | ErrorCode::NotHolder) => Some(of(Verdict::Lost)),
            Some(ErrorCode::Closed) => Some(of(Verdict::Closed)),
            Some(
                ErrorCode::NoMachine
                | ErrorCode::HeldInCloud
                | ErrorCode::SeqGap
                | ErrorCode::SnapshotIncomplete
                | ErrorCode::NoSnapshot
                | ErrorCode::ChunkMismatch
                | ErrorCode::TooLarge,
            ) => None,
            // The store's own word that it has no such chat for this caller tells a machine
            // its chat was moved to another machine.
            None => (matches!(me, Holder::Vm(_)) && error.store_not_found())
                .then(|| Answer::bare(Verdict::Closed)),
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
    /// The daemon also sends it (as a queue change) once a `DrainInbox` gave its messages to
    /// the chat.
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
    /// The store closed the chat on this machine's word: Auto is off. `epoch` is the chat's
    /// epoch in the store's answer, 0 when the answer named none.
    Closed { epoch: u64 },
    /// The store's view of the chat says the person wants it moved (`session.move`), heard
    /// outside a renewal: this daemon just asked for the move, or a view came with another
    /// answer. The holder gives the chat as on a renewal's wish.
    Wished { to: MoveTo },
    /// A `StopTurn` is done: no turn of the chat runs here. One that failed is a
    /// [`GiveFailure::Stuck`].
    TurnStopped,
    /// The store took the give: the chat is another holder's, at `epoch`.
    Gave { epoch: u64 },
    /// The store did not take the give.
    GiveFailed { why: GiveFailure },
}

impl Event {
    /// The event for a renewal's result, read as `me`.
    pub fn from_renewal(
        request: u64,
        me: &Holder,
        result: &Result<LeaseAnswer, AutoCloudError>,
    ) -> Event {
        let answer = match result {
            Ok(answer) => Some(Answer::from_lease(answer)),
            Err(error) => Answer::from_error(error, me),
        };
        Event::answer(request, answer)
    }

    /// The event for a registration's result (`PUT /:id` with `auto: true`), read as `me`. A
    /// 404 here says the store does not take Auto chats: nothing was registered, the chat runs
    /// as any chat does, and Auto goes off for it.
    pub fn from_registration(
        request: u64,
        me: &Holder,
        result: &Result<SessionView, AutoCloudError>,
    ) -> Event {
        let answer = match result {
            Ok(session) => Some(Answer::from_session(session, me)),
            Err(error) => Answer::from_error(error, me)
                .or_else(|| (error.status() == Some(404)).then(|| Answer::bare(Verdict::Closed))),
        };
        Event::answer(request, answer)
    }

    fn answer(request: u64, answer: Option<Answer>) -> Event {
        match answer {
            Some(answer) => Event::Answered { request, answer },
            None => Event::Unanswered { request },
        }
    }

    /// The event for a give's result (`POST /:id/give`). The store names its refusals by code;
    /// `auto.not_copied` and `auto.no_move` are read from the answer's own text, so a build
    /// whose code list is older still reads them.
    pub fn from_give(result: &Result<SessionView, AutoCloudError>) -> Event {
        let error = match result {
            Ok(session) => return Event::Gave { epoch: session.epoch },
            Err(error) => error,
        };
        let named = error.envelope().map(|(_, envelope)| envelope.error.code);
        let why = match named.as_deref() {
            Some("auto.not_copied") => GiveFailure::NotCopied,
            Some("auto.no_move") => GiveFailure::NoMove,
            Some("auto.stale_epoch" | "auto.not_holder") => GiveFailure::Lost,
            Some(code) if code.starts_with("auto.") => GiveFailure::Refused,
            Some(_) | None => GiveFailure::Unanswered,
        };
        Event::GiveFailed { why }
    }

    /// Every event's name, in the order of the enum.
    pub const KINDS: [&'static str; 17] = [
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
        "closed",
        "wished",
        "turn_stopped",
        "gave",
        "give_failed",
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
            Event::Closed { .. } => "closed",
            Event::Wished { .. } => "wished",
            Event::TurnStopped => "turn_stopped",
            Event::Gave { .. } => "gave",
            Event::GiveFailed { .. } => "give_failed",
        }
    }
}
