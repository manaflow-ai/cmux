//! What Move to Cloud's and Bring Back Local's working toast says while the chat moves: the step it
//! is on, why it waits there, and about how long is left (Leo, 2026-11-09: "the ergonomic part is
//! super big for us."). The app says which step runs, how long it has run and what the folder copy
//! reported (`moves::seed`); here that becomes the toast's second line. Pure: no clock, no I/O.

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

/// A move's steps, in order. Both directions take the same four.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Stage {
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

const STAGES: [Stage; 4] = [Stage::Machine, Stage::Copy, Stage::Agent, Stage::Tab];

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
}

/// The toast's second line, and what it is made of.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Line {
    pub text: String,
    /// 1-based.
    pub step: usize,
    pub steps: usize,
    /// About how long is left of the whole move; none once a step runs past what it usually takes
    /// and no copy progress says how far it is.
    pub eta_ms: Option<u64>,
    /// How long from now until this text changes on its own (the countdown reaches its next
    /// value, or the step runs past its usual time); none when only a new fact changes it (a new
    /// step, the copy's next progress line, which the app hands on as it comes). The app asks
    /// again once at that time, and never after the move ended.
    pub next_ms: Option<u64>,
}

/// The longest countdown searched for its next change, in whole seconds (an hour).
const MAX_SEARCH_SECONDS: u64 = 3_600;

/// What a step usually takes, in milliseconds. Starting a new machine "usually takes under a
/// minute" (the New Cloud Workspace progress text); resuming a paused one is about half that.
/// A copy's own progress replaces its guess as soon as it reports.
pub fn typical_ms(facts: &Facts, stage: Stage) -> u64 {
    match stage {
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

/// How long the copy has left at the rate it ran so far: by files, else by bytes. None until it
/// has run a second and a half and done some of its work, or when its numbers do not add up.
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
    let step = STAGES.iter().position(|stage| *stage == facts.stage).unwrap_or_default();
    let later: u64 = STAGES
        .iter()
        .skip(step.saturating_add(1))
        .map(|stage| typical_ms(facts, *stage))
        .fold(0, u64::saturating_add);
    let typical = typical_ms(facts, facts.stage);
    let measured = facts.copy.as_ref().and_then(|copy| copy_left_ms(copy, facts.stage_ms));
    let current = match measured {
        Some(left) => Some(left),
        None if facts.stage_ms <= typical => Some(typical.saturating_sub(facts.stage_ms)),
        None => None,
    };
    let eta_ms = current.map(|current| current.saturating_add(later));
    // A measured copy changes with its progress lines; an overrun line never changes on its own.
    let next_ms = match (measured, current, eta_ms) {
        (None, Some(current), Some(eta)) => {
            let overrun = current.saturating_add(1);
            Some(next_change_ms(eta).map_or(overrun, |next| next.min(overrun)))
        }
        _ => None,
    };
    let what = doing(facts);
    let when = match eta_ms {
        Some(eta) => left_text(eta),
        None => format!("taking longer than usual (usually {})", about(typical)),
    };
    let steps = STAGES.len();
    let step = step.saturating_add(1);
    Line { text: format!("{step} of {steps} · {what} · {when}"), step, steps, eta_ms, next_ms }
}

/// How long until the text for `eta` left reads differently as it counts down: the time to the
/// whole second below which `left_text` changes. None past an hour, or when it never changes.
fn next_change_ms(eta: u64) -> Option<u64> {
    let now = left_text(eta);
    let seconds = eta.saturating_add(999) / 1_000;
    (0..seconds.min(MAX_SEARCH_SECONDS))
        .rev()
        .map(|whole| whole.saturating_mul(1_000))
        .find(|at| left_text(*at) != now)
        .map(|at| eta.saturating_sub(at))
}

/// The step, in the person's words.
fn doing(facts: &Facts) -> String {
    let name = facts.name.as_deref().filter(|name| !name.is_empty());
    let back = facts.direction == Direction::BringBack;
    match facts.stage {
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

/// "about 40 s left", "about 2 min left", "a few seconds left" (under 5 whole seconds, as `about`
/// counts them).
fn left_text(ms: u64) -> String {
    if ms.saturating_add(999) / 1_000 < 5 {
        "a few seconds left".to_owned()
    } else {
        format!("{} left", about(ms))
    }
}

/// A duration as a person reads it: under a minute in 5 s steps, rounded up; then whole minutes.
fn about(ms: u64) -> String {
    let seconds = ms.saturating_add(999) / 1_000;
    if seconds < 5 {
        return "a few seconds".to_owned();
    }
    let up = (seconds.saturating_add(4) / 5).saturating_mul(5);
    if up < 60 {
        return format!("about {up} s");
    }
    let minutes = seconds.saturating_add(30) / 60;
    let minutes = minutes.max(1);
    format!("about {minutes} min")
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
mod tests {
    use super::*;

    fn facts(stage: Stage, stage_ms: u64) -> Facts {
        Facts { stage, stage_ms, name: Some("dev".to_owned()), ..Facts::default() }
    }

    fn copy(files_done: i64, files_total: i64) -> seed::Progress {
        seed::Progress {
            phase: "copy".to_owned(),
            files_done: Some(files_done),
            files_total: Some(files_total),
            ..seed::Progress::default()
        }
    }

    #[test]
    fn every_step_names_itself_and_counts() {
        let texts: Vec<String> = STAGES.iter().map(|stage| line(&facts(*stage, 0)).text).collect();
        assert_eq!(
            texts,
            [
                "1 of 4 · Connecting to dev · about 35 s left",
                "2 of 4 · Copying the folder · about 30 s left",
                "3 of 4 · Handing the agent to dev · about 15 s left",
                "4 of 4 · Opening its tab · a few seconds left",
            ]
        );
    }

    #[test]
    fn bring_back_says_where_it_goes() {
        let mut back = facts(Stage::Copy, 0);
        back.direction = Direction::BringBack;
        back.copy = Some(copy(0, 1));
        assert_eq!(line(&back).text, "2 of 4 · Copying the folder back (1 file) · about 20 s left");
        back.stage = Stage::Agent;
        assert_eq!(line(&back).text, "3 of 4 · Bringing the agent to this Mac · about 15 s left");
        back.stage = Stage::Tab;
        assert_eq!(line(&back).text, "4 of 4 · Opening its tab here · a few seconds left");
    }

    #[test]
    fn a_new_or_paused_machine_takes_longer() {
        let mut new = facts(Stage::Machine, 0);
        new.machine = Machine::New;
        let line_new = line(&new);
        assert_eq!(line_new.text, "1 of 4 · Starting a new Cloud machine · about 1 min left");
        assert_eq!(line_new.eta_ms, Some(88_000));
        let mut paused = facts(Stage::Machine, 10_000);
        paused.machine = Machine::Paused;
        assert_eq!(line(&paused).text, "1 of 4 · Resuming dev · about 50 s left");
    }

    #[test]
    fn the_countdown_runs_with_the_step() {
        let early = line(&facts(Stage::Agent, 0)).eta_ms;
        let later = line(&facts(Stage::Agent, 6_000)).eta_ms;
        assert_eq!((early, later), (Some(13_000), Some(7_000)));
    }

    #[test]
    fn the_app_asks_again_only_when_the_text_would_change() {
        // 13 s left reads "about 15 s" until it reaches 10 s: 3 s from now.
        let agent = line(&facts(Stage::Agent, 0));
        assert_eq!(agent.next_ms, Some(3_000));
        let at_ten = line(&facts(Stage::Agent, 3_000));
        assert_ne!(at_ten.text, agent.text);
        assert_eq!(line(&facts(Stage::Agent, 2_999)).text, agent.text);
        // "a few seconds left" changes only when the step runs past its usual 3 s.
        assert_eq!(line(&facts(Stage::Tab, 1_000)).next_ms, Some(2_001));
        assert!(line(&facts(Stage::Tab, 3_001)).text.contains("longer than usual"));
        // An overrun line, and a copy its progress lines measure, never change on their own.
        assert_eq!(line(&facts(Stage::Agent, 30_000)).next_ms, None);
        let mut copying = facts(Stage::Copy, 10_000);
        copying.copy = Some(copy(301, 1_204));
        assert_eq!(line(&copying).next_ms, None);
        // Minutes: 88 s reads "about 1 min" until 55 s, 33 s from now.
        let mut new = facts(Stage::Machine, 0);
        new.machine = Machine::New;
        assert_eq!(line(&new).next_ms, Some(33_000));
    }

    #[test]
    fn every_wake_lands_on_a_change() {
        for stage in STAGES {
            let mut ms = 0;
            while let Some(next) = line(&facts(stage, ms)).next_ms {
                let before = line(&facts(stage, ms)).text;
                assert_eq!(
                    line(&facts(stage, ms.saturating_add(next).saturating_sub(1))).text,
                    before
                );
                ms = ms.saturating_add(next);
                assert_ne!(line(&facts(stage, ms)).text, before, "{stage:?} at {ms} ms");
            }
        }
    }

    #[test]
    fn a_step_past_its_usual_time_says_so_instead_of_a_wrong_eta() {
        let slow = line(&facts(Stage::Agent, 30_000));
        assert_eq!(slow.eta_ms, None);
        assert_eq!(
            slow.text,
            "3 of 4 · Handing the agent to dev · taking longer than usual (usually about 10 s)"
        );
    }

    #[test]
    fn the_copy_counts_its_files_and_measures_its_rate() {
        let mut copying = facts(Stage::Copy, 1_000);
        copying.copy = Some(copy(0, 1_204));
        // Before it measured: a few seconds plus 4 ms a file, then the agent and the tab.
        assert_eq!(copy_typical_ms(copying.copy.as_ref()), 8_816);
        assert_eq!(
            line(&copying).text,
            "2 of 4 · Copying the folder (1,204 files) · about 25 s left"
        );
        // A quarter done in 10 s: 30 s more, plus 13 s after it.
        copying.stage_ms = 10_000;
        copying.copy = Some(copy(301, 1_204));
        let measured = line(&copying);
        assert_eq!(measured.eta_ms, Some(43_000));
        assert_eq!(measured.text, "2 of 4 · Copying the folder (1,204 files) · about 45 s left");
        // A measured copy never reads "longer than usual".
        copying.stage_ms = 600_000;
        assert!(line(&copying).eta_ms.is_some());
    }

    #[test]
    fn a_copy_by_bytes_measures_too_and_bad_numbers_fall_back() {
        let mut copying = facts(Stage::Copy, 4_000);
        copying.copy = Some(seed::Progress {
            phase: "upload".to_owned(),
            bytes_done: Some(50),
            bytes_total: Some(100),
            ..seed::Progress::default()
        });
        assert_eq!(line(&copying).eta_ms, Some(17_000));
        copying.copy = Some(seed::Progress {
            phase: "upload".to_owned(),
            bytes_done: Some(200),
            bytes_total: Some(100),
            ..seed::Progress::default()
        });
        assert_eq!(line(&copying).eta_ms, Some(24_000), "done past total: the usual time");
        copying.copy = Some(copy(-1, -5));
        assert_eq!(line(&copying).text, "2 of 4 · Copying the folder · about 25 s left");
    }

    #[test]
    fn durations_read_as_a_person_says_them() {
        let read: Vec<String> =
            [0, 4_000, 5_000, 41_000, 59_000, 61_000, 89_000, 91_000, 600_000].map(about).to_vec();
        assert_eq!(
            read,
            [
                "a few seconds",
                "a few seconds",
                "about 5 s",
                "about 45 s",
                "about 1 min",
                "about 1 min",
                "about 1 min",
                "about 2 min",
                "about 10 min"
            ]
        );
        assert_eq!(
            [0, 7, 999, 1_000, 12_345, 1_234_567].map(grouped),
            ["0", "7", "999", "1,000", "12,345", "1,234,567"]
        );
    }

    #[test]
    fn huge_numbers_saturate() {
        let mut copying = facts(Stage::Copy, u64::MAX);
        copying.copy = Some(copy(1, i64::MAX));
        let read = line(&copying);
        assert_eq!((read.step, read.eta_ms), (2, None), "a rate past u64 is no rate");
        assert!(read.text.contains("longer than usual"));
    }
}
