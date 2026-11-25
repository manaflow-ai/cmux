//! What Move to Cloud's and Bring Back Local's working toast says while the chat moves: the step it
//! is on and a live clock of how long that step has run (Leo, 2026-11-09: "the ergonomic part is
//! super big for us."; Austin, 2026-11-24: "show the seconds, dont need to show usually under a
//! minute that stuff"). The app says which step runs, how long it has run and what the folder copy
//! reported (`moves::seed`); here that becomes the toast's second line. Pure: no clock, no I/O.
//!
//! From the click on, the line names a step: Move to Cloud's first is the folder check before a
//! machine is picked. Its clock reads whole seconds, then m:ss, and never a guess at how long the
//! step usually takes (Leo, 2026-11-23: "you guys need to be absolutely exhaustively testing out
//! what would a new user be seeing here?"; the new-user journey found no progress shown while a move runs).

use crate::moves::seed;
use serde::{Deserialize, Serialize};

/// Which way the chat goes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Direction {
    /// Move to Cloud: this Mac to a machine.
    #[default]
    Move,
    /// Bring Back Local: the machine back to this Mac.
    BringBack,
}

/// A move's steps, in order. Move to Cloud takes five ([`Stage::Folder`] first), Bring Back Local
/// the last four.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Stage {
    /// Move to Cloud's check of the chat's folder (its size and how it copies) before a machine is
    /// picked or made.
    Folder,
    /// Reaching the machine: connecting, resuming a paused one, or starting a new one.
    #[default]
    Machine,
    /// Copying the chat's folder (to the machine, or back to this Mac).
    Copy,
    /// Moving the chat's agent to the other side.
    Agent,
    /// Opening the chat's tab where it landed.
    Tab,
}

const STAGES: [Stage; 5] = [Stage::Folder, Stage::Machine, Stage::Copy, Stage::Agent, Stage::Tab];

/// The steps a move in `direction` takes, in order: Bring Back Local has no folder check.
fn stages(direction: Direction) -> &'static [Stage] {
    match direction {
        Direction::Move => &STAGES,
        Direction::BringBack => &STAGES[1..],
    }
}

/// The machine the move reaches, from its status as the Cloud API names it (`paused`), or `new`
/// when there is none yet.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Machine {
    /// Paused (idle auto-pause): it resumes first.
    Paused,
    /// None to reuse: Cloud starts a new one.
    New,
    /// Any other status (running, starting, provisioning): a link opens.
    #[default]
    #[serde(other)]
    Live,
}

/// What the app knows now.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Facts {
    pub direction: Direction,
    pub stage: Stage,
    pub machine: Machine,
    /// The machine's name, when it has one yet.
    pub name: Option<String>,
    /// How long the current step has run.
    pub stage_ms: u64,
    /// The folder copy's newest progress line, during [`Stage::Copy`].
    pub copy: Option<seed::Progress>,
    /// How long the current step had run when that line came; none: just now (`stage_ms`).
    pub copy_ms: Option<u64>,
}

/// The toast's second line, and what it is made of.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Line {
    pub text: String,
    /// 1-based.
    pub step: usize,
    pub steps: usize,
    /// About how long is left of the whole move, for callers that schedule around it (never shown:
    /// the text counts up instead); none once a step runs past what it usually takes and no copy
    /// progress says how far it is.
    pub eta_ms: Option<u64>,
    /// How long from now until this text changes on its own: its clock's next whole second. The
    /// app asks again once at that time, and never after the move ended.
    pub next_ms: Option<u64>,
}

/// How long a measured copy may run past its estimate with no new progress line before the
/// estimate is stale.
const STALE_AFTER_MS: u64 = 5_000;

/// What a step usually takes, in milliseconds. Starting a new machine "usually takes under a
/// minute" (the New Cloud Workspace progress text); resuming a paused one is about half that.
/// A copy's own progress replaces its guess as soon as it reports.
pub fn typical_ms(facts: &Facts, stage: Stage) -> u64 {
    match stage {
        Stage::Folder => 3_000,
        Stage::Machine => match facts.machine {
            Machine::Live => 5_000,
            Machine::Paused => 30_000,
            Machine::New => 60_000,
        },
        Stage::Copy => copy_typical_ms(facts.copy.as_ref()),
        Stage::Agent => 10_000,
        Stage::Tab => 3_000,
    }
}

/// A copy of a folder the CLI counted: a few seconds plus about 4 ms a file, at most ten minutes;
/// 15 s before it counts.
fn copy_typical_ms(copy: Option<&seed::Progress>) -> u64 {
    match copy.and_then(|copy| count(copy.files_total)) {
        Some(files) => files.saturating_mul(4).saturating_add(4_000).min(600_000),
        None => 15_000,
    }
}

fn count(value: Option<i64>) -> Option<u64> {
    value.and_then(|value| u64::try_from(value).ok())
}

/// How long the copy had left when its progress line came `stage_ms` into the step, at the rate it
/// ran until then: by files, else by bytes. None until it has run a second and a half and done some
/// of its work, or when its numbers do not add up.
fn copy_left_ms(copy: &seed::Progress, stage_ms: u64) -> Option<u64> {
    if stage_ms < 1_500 {
        return None;
    }
    let pairs = [(copy.files_done, copy.files_total), (copy.bytes_done, copy.bytes_total)];
    pairs.into_iter().find_map(|(done, total)| {
        let (done, total) = (count(done)?, count(total)?);
        if done == 0 || done > total {
            return None;
        }
        let left = u128::from(total.saturating_sub(done)).saturating_mul(u128::from(stage_ms));
        u64::try_from(left.checked_div(u128::from(done))?).ok()
    })
}

/// The toast's second line for `facts`.
pub fn line(facts: &Facts) -> Line {
    let stages = stages(facts.direction);
    let step = stages.iter().position(|stage| *stage == facts.stage).unwrap_or_default();
    let later: u64 = stages
        .iter()
        .skip(step.saturating_add(1))
        .map(|stage| typical_ms(facts, *stage))
        .fold(0, u64::saturating_add);
    let typical = typical_ms(facts, facts.stage);
    // A measured copy counts down from what its newest progress line said, while that line is fresh:
    // a few seconds past its estimate with no new line (one large file after many small ones), it
    // is stale and has no estimate.
    let measured = facts.copy.as_ref().and_then(|copy| {
        let at = facts.copy_ms.unwrap_or(facts.stage_ms).min(facts.stage_ms);
        let left = copy_left_ms(copy, at)?;
        let since = facts.stage_ms.saturating_sub(at);
        Some((since <= left.saturating_add(STALE_AFTER_MS)).then(|| left.saturating_sub(since)))
    });
    // What is left of this step.
    let current = match measured {
        Some(left) => left,
        None => (facts.stage_ms <= typical).then(|| typical.saturating_sub(facts.stage_ms)),
    };
    let eta_ms = current.map(|current| current.saturating_add(later));
    let steps = stages.len();
    let step = step.saturating_add(1);
    Line {
        text: format!("{step} of {steps} · {} · {}", doing(facts), clock(facts.stage_ms)),
        step,
        steps,
        eta_ms,
        next_ms: Some(1_000_u64.saturating_sub(facts.stage_ms % 1_000)),
    }
}

/// How long a step has run: whole seconds under a minute ("42s"), then minutes and seconds
/// ("1:05"), then hours ("1:02:03"), as the agent pane's Cloud start line counts
/// (`cloudStartViewModel.ts` `stageClock`). Rounded down: never more than has passed.
pub fn clock(ms: u64) -> String {
    let total = ms / 1_000;
    if total < 60 {
        return format!("{total}s");
    }
    let (minutes, seconds) = (total / 60, total % 60);
    if minutes < 60 {
        return format!("{minutes}:{seconds:02}");
    }
    format!("{}:{:02}:{seconds:02}", minutes / 60, minutes % 60)
}

/// The step, in the person's words.
fn doing(facts: &Facts) -> String {
    let name = facts.name.as_deref().filter(|name| !name.is_empty());
    let back = facts.direction == Direction::BringBack;
    match facts.stage {
        Stage::Folder => "Checking the folder".to_owned(),
        Stage::Machine => match (facts.machine, name) {
            (Machine::New, _) => "Starting a new Cloud machine".to_owned(),
            (Machine::Paused, Some(name)) => format!("Resuming {name}"),
            (Machine::Paused, None) => "Resuming the machine".to_owned(),
            (Machine::Live, Some(name)) => format!("Connecting to {name}"),
            (Machine::Live, None) => "Connecting to the machine".to_owned(),
        },
        Stage::Copy => {
            let verb = if back { "Copying the folder back" } else { "Copying the folder" };
            match facts.copy.as_ref().and_then(|copy| count(copy.files_total)) {
                Some(1) => format!("{verb} (1 file)"),
                Some(files) => format!("{verb} ({} files)", grouped(files)),
                None => verb.to_owned(),
            }
        }
        Stage::Agent if back => "Bringing the agent to this Mac".to_owned(),
        Stage::Agent => match name {
            Some(name) => format!("Handing the agent to {name}"),
            None => "Handing the agent over".to_owned(),
        },
        Stage::Tab if back => "Opening its tab here".to_owned(),
        Stage::Tab => "Opening its tab".to_owned(),
    }
}

/// `n` with thousands separators: 1204 reads "1,204".
fn grouped(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::with_capacity(digits.len().saturating_add(digits.len() / 3));
    let first = digits.len() % 3;
    for (at, digit) in digits.chars().enumerate() {
        if at != 0 && at % 3 == first {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

#[cfg(test)]
#[path = "progress_tests.rs"]
mod tests;
