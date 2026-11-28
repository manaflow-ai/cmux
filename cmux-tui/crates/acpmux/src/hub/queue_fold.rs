//! Part of `Hub`; see `digest.rs`. Which queued prompts go in with a turn: one state machine.
//!
//! Leo, 2026-11-25: our queuing and batching of the person's messages is awkward, "we need to
//! improve them". The rule was one long boolean inside `take_joined`, over seven flags of a
//! queued prompt that each meant a different send mode, so no test could say what each mode does.
//! Here each queued prompt has exactly one [`Mode`], each turn one [`Lead`], and [`step`] decides
//! every pair with no wildcard arm: a new mode or a new reason does not compile until it is
//! decided. `take_joined` walks the queue from its head and does what `step` says:
//!
//! - [`Step::Join`]: it leaves the queue and goes in with this turn, as it was sent.
//! - [`Step::Skip`]: it stays where it is and the walk goes on past it (held after a failed
//!   turn, or waiting for the owner's approval).
//! - [`Step::End`]: it stays, and so does everything behind it: a turn never takes a prompt
//!   from behind one it could not take, so nothing is reordered.
//!
//! Nothing here changes which prompts join: `queue_fold_tests.rs` checks every mode against the
//! rule as it was.

/// How a queued prompt is waiting: its send mode, as its flags in `QueuedPrompt` say.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Mode {
    /// Queued for after the running turn (⌘Return, or Return with Follow-Up Messages on Queue,
    /// an agent that cannot steer, a `--no-steer` send).
    Waiting,
    /// The person's steer that came while another prompt held the turn: it steers into that turn
    /// once it shows, and until then it waits like any other (`queue.rs` `steer_on_start`).
    SteerOnStart,
    /// Send now (`queue_edit.rs`): its own task steers it into the running turn.
    SteerNow,
    /// Sent now from the queue's ⋯ menu: it starts a turn of its own.
    SentNow,
    /// Waited behind a turn that failed (`pause_queue`): it waits until the queue resumes.
    Held,
    /// The person's prompt waiting for the owner's approval (`queue_approve.rs`).
    AwaitingOwner,
    /// Rebuilt from the log at daemon start, and no task claimed it yet (`queue_slot`): it would
    /// hear nothing of the turn it joined.
    Unclaimed,
}

impl Mode {
    /// The one mode of a queued prompt's flags. Aside (held, awaiting the owner) comes first,
    /// as `QueuedPrompt::aside` did: a held steer is still held.
    pub(super) fn of(f: Flags) -> Self {
        if f.held {
            Mode::Held
        } else if f.awaiting_owner {
            Mode::AwaitingOwner
        } else if f.unclaimed {
            Mode::Unclaimed
        } else if f.steer {
            Mode::SteerNow
        } else if f.sent_now {
            Mode::SentNow
        } else if f.steer_on_start {
            Mode::SteerOnStart
        } else {
            Mode::Waiting
        }
    }

    /// Every mode, for the tests.
    #[cfg(test)]
    pub(super) const ALL: [Mode; 7] = [
        Mode::Waiting,
        Mode::SteerOnStart,
        Mode::SteerNow,
        Mode::SentNow,
        Mode::Held,
        Mode::AwaitingOwner,
        Mode::Unclaimed,
    ];
}

/// A queued prompt's flags, read once under the queue's lock.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(super) struct Flags {
    pub(super) held: bool,
    pub(super) awaiting_owner: bool,
    pub(super) unclaimed: bool,
    pub(super) steer: bool,
    pub(super) sent_now: bool,
    pub(super) steer_on_start: bool,
}

/// Why a prompt goes in by itself: its own turn must see it first or check it again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Alone {
    /// A trigger's prompt (`prompt_provenance.rs`).
    Trigger,
    /// A slash command (`/compact`) runs only as a turn's first words.
    SlashCommand,
    /// Uploaded files: its turn reads and checks them (`prompt_uploads.rs`).
    Uploads,
    /// A sub-session family message: its own turn checks it again (`subsession_guard.rs`).
    Family,
    /// An inbox digest goes in as it was made (`inbox_digest.rs`).
    Digest,
    /// A goal's continuation runs alone, checked against its goal (`goal_tools.rs`).
    Continuation,
}

impl Alone {
    #[cfg(test)]
    pub(super) const ALL: [Alone; 6] = [
        Alone::Trigger,
        Alone::SlashCommand,
        Alone::Uploads,
        Alone::Family,
        Alone::Digest,
        Alone::Continuation,
    ];
}

/// Who a turn's batch is for, once its head may lead one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Lead {
    /// The person's prompt a held chat held (`person_hold.rs`): the person's prompts behind it
    /// join it.
    Person,
    /// Another agent's message, or a cold batch's inbox notice (`cold_wake.rs`): the agent
    /// messages behind it join it.
    Agents,
}

/// Why a turn's head leads no batch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum NoLead {
    /// The person's prompt outside a hold: it runs as its own turn, as always.
    PersonUnheld,
    /// An inbox notice outside a cold batch.
    NoticeOutsideBatch,
    /// The head must go in by itself.
    Alone(Alone),
    /// A review box runs each agent message as its own prompt behind the review (`inbox.rs`).
    ReviewBox,
}

/// The turn's head, as [`lead`] reads it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Head {
    /// Another agent's message (`PromptRun::agent` is set).
    pub(super) from_agent: bool,
    /// acpmux's inbox notice (`inbox::is_notice`).
    pub(super) notice: bool,
    /// The held chat's hold ended at this turn (`person_hold::folds`, read once).
    pub(super) person_fold: bool,
    /// This turn is a cold chat's batch (`Session::cold_batch_turn`).
    pub(super) cold_batch: bool,
    /// What makes the head go in by itself; the head is never a family message, digest (taken
    /// before) or continuation for this rule, so only these three are read.
    pub(super) alone: Option<Alone>,
    pub(super) review_box: bool,
}

/// Whether a turn whose head is `h` takes the prompts behind it, and whose.
pub(super) fn lead(h: Head) -> Result<Lead, NoLead> {
    if let Some(a) = h.alone {
        return Err(NoLead::Alone(a));
    }
    if h.review_box {
        return Err(NoLead::ReviewBox);
    }
    if h.from_agent {
        return Ok(Lead::Agents);
    }
    if h.person_fold {
        return Ok(Lead::Person);
    }
    if h.notice && h.cold_batch {
        return Ok(Lead::Agents);
    }
    Err(if h.notice { NoLead::NoticeOutsideBatch } else { NoLead::PersonUnheld })
}

/// One queued prompt behind the head, as [`step`] reads it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Next {
    pub(super) mode: Mode,
    pub(super) from_agent: bool,
    pub(super) alone: Option<Alone>,
    /// Its control, trust gate and phone flag are the head's: one turn runs under one set.
    pub(super) same_rules: bool,
    /// Its words still fit under `DIGEST_MAX_BYTES` with what the turn took.
    pub(super) fits: bool,
}

/// Why the walk stops at a prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum End {
    /// Its mode sends it some other way (steer now, sent now, unclaimed).
    Mode(Mode),
    /// It is the other side's: the person's behind agents, or an agent's behind the person.
    OtherSender,
    Alone(Alone),
    OtherRules,
    TooBig,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Step {
    Join,
    Skip,
    End(End),
}

/// What a turn led by `lead` does with the queued prompt `n` (module docs).
pub(super) fn step(lead: Lead, n: Next) -> Step {
    match n.mode {
        Mode::Held | Mode::AwaitingOwner => return Step::Skip,
        Mode::Unclaimed | Mode::SteerNow | Mode::SentNow => return Step::End(End::Mode(n.mode)),
        Mode::Waiting | Mode::SteerOnStart => {}
    }
    let theirs = match lead {
        Lead::Person => !n.from_agent,
        Lead::Agents => n.from_agent,
    };
    if !theirs {
        return Step::End(End::OtherSender);
    }
    if let Some(a) = n.alone {
        return Step::End(End::Alone(a));
    }
    if !n.same_rules {
        return Step::End(End::OtherRules);
    }
    if !n.fits {
        return Step::End(End::TooBig);
    }
    Step::Join
}

#[cfg(test)]
#[path = "queue_fold_tests.rs"]
mod tests;
