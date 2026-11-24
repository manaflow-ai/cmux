//! What Move to Cloud's and Bring Back Local's working toast says while the chat moves: the step it
//! is on, why it waits there, and about how long is left (Leo, 2026-11-09: "the ergonomic part is
//! super big for us."). The app says which step runs, how long it has run and what the folder copy
//! reported (`moves::seed`); here that becomes the toast's second line. Pure: no clock, no I/O.
//!
//! From the click on, the line names a step: Move to Cloud's first is the folder check before a
//! machine is picked. A step past its usual time says how long it has run so far, and keeps
//! counting (Leo, 2026-11-23: "you guys need to be absolutely exhaustively testing out what would
//! a new user be seeing here?"; the new-user journey found no progress shown while a move runs).

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
    /// About how long is left of the whole move; none once a step runs past what it usually takes
    /// and no copy progress says how far it is.
    pub eta_ms: Option<u64>,
    /// How long from now until this text changes on its own (the countdown reaches its next
    /// value, or the step runs past its usual time, or a measured copy past its estimate); none
    /// when only a new fact changes it (a new step, the copy's next progress line, which the app
    /// hands on as it comes). The app asks again once at that time, and never after the move ended.
    pub next_ms: Option<u64>,
}

/// How long a measured copy may run past its estimate with no new progress line before the
/// estimate is stale.
const STALE_AFTER_MS: u64 = 5_000;

/// The longest countdown searched for its next change, in whole seconds (an hour).
const MAX_SEARCH_SECONDS: u64 = 3_600;

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
    // is stale and says so instead.
    let measured = facts.copy.as_ref().and_then(|copy| {
        let at = facts.copy_ms.unwrap_or(facts.stage_ms).min(facts.stage_ms);
        let left = copy_left_ms(copy, at)?;
        let since = facts.stage_ms.saturating_sub(at);
        let fresh = left.saturating_add(STALE_AFTER_MS);
        Some((since <= fresh).then(|| (left.saturating_sub(since), fresh.saturating_sub(since))))
    });
    // What is left of this step, and how long until the line says it overran.
    let current = match measured {
        Some(left) => left,
        None if facts.stage_ms <= typical => {
            let left = typical.saturating_sub(facts.stage_ms);
            Some((left, left))
        }
        None => None,
    };
    let eta_ms = current.map(|(current, _)| current.saturating_add(later));
    // A countdown wakes when its text changes (only while it still counts down: past its estimate a
    // measured copy holds there) or it overruns; an overrun line wakes when its "so far" next
    // reads differently.
    let next_ms = match (current, eta_ms) {
        (Some((left, overrun)), Some(eta)) => {
            let overrun = overrun.saturating_add(1);
            let change = next_change_ms(eta).filter(|next| *next <= left);
            Some(change.map_or(overrun, |next| next.min(overrun)))
        }
        _ => Some(so_far_next_ms(facts.stage_ms)),
    };
    let what = doing(facts);
    let so_far = so_far(facts.stage_ms);
    let when = match (eta_ms, measured) {
        (Some(eta), _) => left_text(eta),
        (None, Some(None)) => format!("taking longer than its progress said, {so_far} so far"),
        (None, _) => {
            format!("taking longer than usual, {so_far} so far (usually {})", about(typical))
        }
    };
    let steps = stages.len();
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

/// How long a step has run, as a clock a person reads at a glance: whole seconds under 10 s, then
/// 5 s steps under a minute, then whole minutes. Rounded down: never more than has passed.
fn so_far(ms: u64) -> String {
    let seconds = ms / 1_000;
    match seconds {
        0..=9 => format!("{seconds} s"),
        10..=59 => format!("{} s", (seconds / 5).saturating_mul(5)),
        _ => format!("{} min", seconds / 60),
    }
}

/// How long from `ms` until [`so_far`] reads differently.
fn so_far_next_ms(ms: u64) -> u64 {
    let seconds = ms / 1_000;
    let unit: u64 = match seconds {
        0..=9 => 1_000,
        10..=59 => 5_000,
        _ => 60_000,
    };
    unit.saturating_sub(ms % unit)
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
                "1 of 5 · Checking the folder · about 40 s left",
                "2 of 5 · Connecting to dev · about 35 s left",
                "3 of 5 · Copying the folder · about 30 s left",
                "4 of 5 · Handing the agent to dev · about 15 s left",
                "5 of 5 · Opening its tab · a few seconds left",
            ]
        );
    }

    #[test]
    fn a_move_names_a_step_from_the_click_and_bring_back_has_no_folder_check() {
        let checking = line(&facts(Stage::Folder, 0));
        assert_eq!((checking.step, checking.steps), (1, 5));
        assert_eq!(checking.eta_ms, Some(36_000), "its own 3 s and the four steps after it");
        let mut back = facts(Stage::Machine, 0);
        back.direction = Direction::BringBack;
        assert_eq!((line(&back).step, line(&back).steps), (1, 4));
    }

    #[test]
    fn a_long_step_keeps_a_clock_of_how_long_it_has_run() {
        // Past its usual 10 s it says so with the time so far, and wakes when that next reads
        // differently: each second under 10 s, each 5 s under a minute, then each minute.
        let at = |ms| line(&facts(Stage::Agent, ms));
        assert_eq!(
            at(10_001).text,
            "4 of 5 · Handing the agent to dev · taking longer than usual, 10 s so far (usually about 10 s)"
        );
        assert_eq!(at(10_001).next_ms, Some(4_999));
        assert!(at(24_000).text.contains(", 20 s so far"));
        assert!(at(185_000).text.contains(", 3 min so far"));
        assert_eq!(at(185_000).next_ms, Some(55_000));
        let tab = line(&facts(Stage::Tab, 3_500));
        assert!(tab.text.ends_with("taking longer than usual, 3 s so far (usually a few seconds)"));
        assert_eq!(tab.next_ms, Some(500));
        assert_eq!(
            [0, 9_999, 10_000, 14_999, 59_999, 60_000, 3_599_999].map(so_far),
            ["0 s", "9 s", "10 s", "10 s", "55 s", "1 min", "59 min"]
        );
    }

    #[test]
    fn bring_back_says_where_it_goes() {
        // Bring Back Local's four steps: no folder check.
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
        assert_eq!(line_new.text, "2 of 5 · Starting a new Cloud machine · about 1 min left");
        assert_eq!(line_new.eta_ms, Some(88_000));
        let mut paused = facts(Stage::Machine, 10_000);
        paused.machine = Machine::Paused;
        assert_eq!(line(&paused).text, "2 of 5 · Resuming dev · about 50 s left");
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
        // An overrun line changes when its time so far does (30 s reads "30 s" until 35 s); a
        // measured copy counts down too: 43 s left reads "about 45 s" until 40 s, 3 s from now.
        assert_eq!(line(&facts(Stage::Agent, 30_000)).next_ms, Some(5_000));
        let mut copying = facts(Stage::Copy, 10_000);
        copying.copy = Some(copy(301, 1_204));
        assert_eq!(line(&copying).next_ms, Some(3_000));
        // Minutes: 88 s reads "about 1 min" until 55 s, 33 s from now.
        let mut new = facts(Stage::Machine, 0);
        new.machine = Machine::New;
        assert_eq!(line(&new).next_ms, Some(33_000));
    }

    #[test]
    fn every_wake_lands_on_a_change() {
        // Two hours in: the overrun clock wakes each minute for as long as the step runs.
        const HORIZON_MS: u64 = 7_200_000;
        for stage in STAGES {
            let mut ms = 0;
            while let Some(next) = line(&facts(stage, ms)).next_ms.filter(|_| ms < HORIZON_MS) {
                let before = line(&facts(stage, ms)).text;
                assert_eq!(
                    line(&facts(stage, ms.saturating_add(next).saturating_sub(1))).text,
                    before
                );
                ms = ms.saturating_add(next);
                assert_ne!(line(&facts(stage, ms)).text, before, "{stage:?} at {ms} ms");
            }
        }
        // A measured copy whose progress lines stopped, down to its stale line.
        let measured = |ms: u64| {
            let mut copying = facts(Stage::Copy, ms);
            (copying.copy, copying.copy_ms) = (Some(copy(301, 1_204)), Some(10_000));
            line(&copying)
        };
        let mut ms = 10_000;
        while let Some(next) = measured(ms).next_ms.filter(|_| ms < HORIZON_MS) {
            let before = measured(ms).text;
            assert_eq!(measured(ms.saturating_add(next).saturating_sub(1)).text, before);
            ms = ms.saturating_add(next);
            assert_ne!(measured(ms).text, before, "measured copy at {ms} ms");
        }
        assert!(measured(ms).text.contains("taking longer than its progress said, 120 min so far"));
    }

    #[test]
    fn a_step_past_its_usual_time_says_so_instead_of_a_wrong_eta() {
        let slow = line(&facts(Stage::Agent, 30_000));
        assert_eq!(slow.eta_ms, None);
        assert_eq!(
            slow.text,
            "4 of 5 · Handing the agent to dev · taking longer than usual, 30 s so far (usually about 10 s)"
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
            "3 of 5 · Copying the folder (1,204 files) · about 25 s left"
        );
        // A quarter done in 10 s: 30 s more, plus 13 s after it.
        copying.stage_ms = 10_000;
        copying.copy = Some(copy(301, 1_204));
        let measured = line(&copying);
        assert_eq!(measured.eta_ms, Some(43_000));
        assert_eq!(measured.text, "3 of 5 · Copying the folder (1,204 files) · about 45 s left");
        // A measured copy never reads "longer than usual", while its newest progress line is fresh.
        copying.stage_ms = 600_000;
        assert!(line(&copying).eta_ms.is_some());
    }

    #[test]
    fn a_measured_estimate_goes_stale_when_progress_stops() {
        // 99 small files in 10 s, then one large file copies with no progress line (Codex review of #39502).
        let mut copying = facts(Stage::Copy, 10_000);
        (copying.copy, copying.copy_ms) = (Some(copy(99, 100)), Some(10_000));
        let fresh = line(&copying);
        assert_eq!(fresh.eta_ms, Some(13_101));
        assert_eq!(fresh.next_ms, Some(5_102), "one wake, when the estimate goes stale");
        // Past its estimate it holds at the steps after it, a few seconds more.
        copying.stage_ms = 15_101;
        assert_eq!(line(&copying).eta_ms, Some(13_000));
        assert_eq!(line(&copying).next_ms, Some(1));
        copying.stage_ms = 15_102;
        let stale = line(&copying);
        assert_eq!((stale.eta_ms, stale.next_ms), (None, Some(4_898)), "its clock's next change");
        assert_eq!(
            stale.text,
            "3 of 5 · Copying the folder (100 files) · taking longer than its progress said, 15 s so far"
        );
        // Minutes later it still says so, never "about 15 s left", with the time so far.
        copying.stage_ms = 300_000;
        assert_eq!(
            line(&copying).text,
            "3 of 5 · Copying the folder (100 files) · taking longer than its progress said, 5 min so far"
        );
        // The next progress line measures again.
        copying.copy_ms = Some(300_000);
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
        assert_eq!(line(&copying).text, "3 of 5 · Copying the folder · about 25 s left");
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
        assert_eq!((read.step, read.eta_ms), (3, None), "a rate past u64 is no rate");
        assert!(read.text.contains("longer than usual"));
    }
}
