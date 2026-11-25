//! Where a chat's work should sit, simulated: on this computer, on a woken Cloud machine, or
//! split (Leo, 2026-11-24: "i think there are simulations where it's like... ok we can strike a
//! lot of optimal balances between having things on your computer vs on a woken machine, etc.").
//!
//! Pure: the caller sends what it measured ([`Facts`]: the folder's size and the head-first
//! seed's head, the upload rate, how long the machine takes to wake, what the first turn reads
//! past the head, whether this computer can serve the chat and whether the chat must keep
//! running without it); [`simulate`] plays each [`Place`] out and answers when its first tool
//! could run, when the machine's copy is whole, the awake hours it spends and whether it outlives
//! a closed lid, then picks one ([`Report::best`]) and says why.
//!
//! The placements, each played the way cmux runs it today:
//! - [`Place::Local`]: the chat runs here. Nothing to copy, no awake hours; it stops with the lid.
//! - [`Place::CloudWhole`]: wake the machine, copy the whole folder, then start there.
//! - [`Place::CloudHeadFirst`]: wake the machine, copy the head (the root's files, harness folders,
//!   the chat's subpath: `cmux-tui-core` `git_seed`), start there, fill the rest behind it; the
//!   first turn's reads past the head wait on the `want` ledger (`cmux-git` `sync_barrier`).
//! - [`Place::Hybrid`]: the chat answers here at once while the machine wakes and fills
//!   ([`crate::hybrid`]), and moves at a tool boundary once the head is there.
//!
//! It changes nothing on its own: served over the app FFI's JSON channel as
//! `cloud_hybrid_balance`, a read-out the start, the keep-running switch and Auto can ask.

use serde::{Deserialize, Serialize};

/// The upload rate used when none was measured: 10 Mbit/s, a slow home uplink.
pub const DEFAULT_UPLOAD_BYTES_PER_SEC: u64 = 1_250_000;
/// The machine's wake when none was measured: a paused VM's resume (RFD 0063).
pub const DEFAULT_WAKE_MS: u64 = 8_000;
/// The session length the awake hours are counted over when none was given: one hour.
pub const DEFAULT_SESSION_MS: u64 = 3_600_000;

/// What the caller measured. Every field has a default, so `{}` is a valid question.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Facts {
    /// The folder's bytes, all of it.
    pub folder_bytes: u64,
    /// The head-first seed's head; clamped to the folder.
    pub head_bytes: u64,
    /// Bytes the first turn reads past the head (the `want` ledger's first asks).
    pub first_read_bytes: u64,
    /// This computer's upload to the machine; None or 0 takes [`DEFAULT_UPLOAD_BYTES_PER_SEC`].
    pub upload_bytes_per_sec: Option<u64>,
    /// The machine's wake (a resume, or a create); None takes [`DEFAULT_WAKE_MS`].
    pub wake_ms: Option<u64>,
    /// The machine is awake already.
    pub awake: bool,
    /// The machine has the folder whole already (an earlier copy): nothing to send.
    pub machine_has_folder: bool,
    /// This computer cannot run the chat (no harness, asleep, battery or memory critical).
    pub local_unavailable: bool,
    /// The chat must keep running without this computer (its keep-running switch is on, or the
    /// lid is closing).
    pub keep_running: bool,
    /// How long the chat is expected to run, for its awake hours; None takes
    /// [`DEFAULT_SESSION_MS`].
    pub session_ms: Option<u64>,
}

/// A placement.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Place {
    Local,
    CloudWhole,
    CloudHeadFirst,
    Hybrid,
}

impl Place {
    /// Every placement, in the order [`Report::places`] lists them.
    pub const ALL: [Self; 4] = [Self::Local, Self::CloudWhole, Self::CloudHeadFirst, Self::Hybrid];
}

/// One placement played out.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub place: Place,
    /// It can run at all (Local needs this computer).
    pub possible: bool,
    /// From the start until the chat's first tool can run.
    pub first_tool_ms: u64,
    /// Until the first turn's reads past the head are there too.
    pub first_turn_ms: u64,
    /// Until the machine's copy is whole; 0 when nothing goes to the machine.
    pub machine_whole_ms: u64,
    /// Awake machine hours over the session, to a tenth.
    pub awake_hours: f64,
    /// It keeps running once this computer sleeps.
    pub outlives_lid: bool,
}

/// Why [`Report::best`] won.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Why {
    /// Nothing asks for the cloud: this computer serves it free and at once.
    LocalIsFree,
    /// It must outlive the lid, and answering here while the machine wakes starts it soonest.
    AnswerHereWhileItWakes,
    /// It must run on the machine and this computer cannot answer: the head first starts it
    /// soonest.
    HeadFirstStartsSoonest,
    /// The machine has the folder (or the folder is no bigger than its head): nothing to fill.
    NothingToFill,
}

/// [`simulate`]'s answer.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub places: Vec<Outcome>,
    pub best: Place,
    pub why: Why,
    /// The head-first fill saves this long over a whole copy before the first tool runs on the
    /// machine (0 when there is nothing to fill).
    pub head_first_saves_ms: u64,
    /// Sending the rest takes longer than the machine's wake: the upload, not the machine, is
    /// what the person waits on, so a smaller head pays more than a faster wake.
    pub upload_bound: bool,
}

/// Milliseconds to send `bytes` at `rate` bytes a second, rounded up.
fn send_ms(bytes: u64, rate: u64) -> u64 {
    let ms = u128::from(bytes) * 1_000;
    let rate = u128::from(rate.max(1));
    u64::try_from(ms.div_ceil(rate)).unwrap_or(u64::MAX)
}

fn hours(ms: u64) -> f64 {
    (ms as f64 / 3_600_000.0 * 10.0).round() / 10.0
}

/// Plays each placement out and picks one (module docs).
pub fn simulate(facts: &Facts) -> Report {
    let rate =
        facts.upload_bytes_per_sec.filter(|rate| *rate > 0).unwrap_or(DEFAULT_UPLOAD_BYTES_PER_SEC);
    let wake = if facts.awake { 0 } else { facts.wake_ms.unwrap_or(DEFAULT_WAKE_MS) };
    let session = facts.session_ms.unwrap_or(DEFAULT_SESSION_MS);
    let (folder, head) = if facts.machine_has_folder {
        (0, 0)
    } else {
        (facts.folder_bytes, facts.head_bytes.min(facts.folder_bytes))
    };
    let first_reads = facts.first_read_bytes.min(folder - head);
    let whole = wake.max(send_ms(folder, rate));
    let at_head = wake.max(send_ms(head, rate));
    // Reads past the head jump the queue (the `want` ledger), so they cost their own bytes.
    let after_reads = whole.min(at_head.saturating_add(send_ms(first_reads, rate)));
    let awake = hours(session);

    let local = Outcome {
        place: Place::Local,
        possible: !facts.local_unavailable,
        first_tool_ms: 0,
        first_turn_ms: 0,
        machine_whole_ms: 0,
        awake_hours: 0.0,
        outlives_lid: false,
    };
    let cloud_whole = Outcome {
        place: Place::CloudWhole,
        possible: true,
        first_tool_ms: whole,
        first_turn_ms: whole,
        machine_whole_ms: whole,
        awake_hours: awake,
        outlives_lid: true,
    };
    let head_first = Outcome {
        place: Place::CloudHeadFirst,
        possible: true,
        first_tool_ms: at_head,
        first_turn_ms: after_reads,
        machine_whole_ms: whole,
        awake_hours: awake,
        outlives_lid: true,
    };
    let hybrid = Outcome {
        place: Place::Hybrid,
        possible: !facts.local_unavailable,
        first_tool_ms: 0,
        first_turn_ms: 0,
        machine_whole_ms: whole,
        // The machine is awake from the start, the chat on it from the move.
        awake_hours: awake,
        outlives_lid: true,
    };

    let (best, why) = if !facts.keep_running && local.possible {
        (Place::Local, Why::LocalIsFree)
    } else if hybrid.possible {
        (Place::Hybrid, Why::AnswerHereWhileItWakes)
    } else if folder == head {
        (Place::CloudHeadFirst, Why::NothingToFill)
    } else {
        (Place::CloudHeadFirst, Why::HeadFirstStartsSoonest)
    };
    Report {
        places: vec![local, cloud_whole, head_first, hybrid],
        best,
        why,
        head_first_saves_ms: whole - at_head,
        upload_bound: send_ms(folder, rate) > wake,
    }
}

/// The largest head a first tool on the machine can wait for and still start no later than the
/// machine wakes: below it the wake hides the copy. The ordering lever for the head-first seed
/// ("fold the first reads into the head" in cmuxterm-hq RFD hybrid-lazy-hydrate).
pub fn head_that_hides_behind_wake(facts: &Facts) -> u64 {
    let rate =
        facts.upload_bytes_per_sec.filter(|rate| *rate > 0).unwrap_or(DEFAULT_UPLOAD_BYTES_PER_SEC);
    let wake = if facts.awake { 0 } else { facts.wake_ms.unwrap_or(DEFAULT_WAKE_MS) };
    let bytes = u128::from(wake) * u128::from(rate) / 1_000;
    u64::try_from(bytes).unwrap_or(u64::MAX).min(facts.folder_bytes)
}

#[cfg(test)]
#[path = "balance/tests.rs"]
mod tests;
