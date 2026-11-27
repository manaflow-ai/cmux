//! Set Up cmux and Start cmux on a device (`MacScreenDeviceSetup.swift`): the daemon's `device-setup`
//! step and summary lines, one run's steps and how it ended, which buttons a device row shows, and the
//! runs by device id. Running the daemon stays in Swift; it feeds lines and the end in here.

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

/// The daemon's `device-setup` verbs.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[serde(rename_all = "snake_case")]
pub enum Verb {
    Setup,
    Start,
}

/// A step's state; a word this app does not know reads as a warning, never a pass.
#[derive(Serialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StepState {
    Ok,
    Changed,
    Warn,
    Fail,
    Skip,
}

impl StepState {
    pub fn of(word: &str) -> Self {
        match word {
            "ok" => Self::Ok,
            "changed" => Self::Changed,
            "fail" => Self::Fail,
            "skip" => Self::Skip,
            _ => Self::Warn,
        }
    }
}

impl<'de> Deserialize<'de> for StepState {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(Self::of(&String::deserialize(d)?))
    }
}

fn empty_is_none<'de, D: Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    Ok(Option::<String>::deserialize(d)?.filter(|s| !s.is_empty()))
}

/// One step event (`{"device","step","state","detail","fix"}`); an empty fix is none.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct Step {
    #[serde(default)]
    pub device: String,
    pub step: String,
    pub state: StepState,
    #[serde(default)]
    pub detail: String,
    #[serde(default, deserialize_with = "empty_is_none")]
    pub fix: Option<String>,
}

impl Step {
    pub fn new(device: &str, step: &str, state: StepState) -> Self {
        Step { device: device.into(), step: step.into(), state, detail: String::new(), fix: None }
    }
}

/// The run's last line (the command's reply): what it changed.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct Summary {
    #[serde(default)]
    pub device: String,
    pub summary: String,
    #[serde(default)]
    pub changed: Vec<String>,
}

/// A line of the daemon's output: a step or the summary.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Line {
    Step(Step),
    Summary(Summary),
}

impl Line {
    /// A JSON object as a line: a summary first, then a step; anything else is none.
    pub fn of_value(value: &Value) -> Option<Self> {
        if !value.is_object() {
            return None;
        }
        if let Ok(summary) = serde_json::from_value::<Summary>(value.clone()) {
            return Some(Line::Summary(summary));
        }
        serde_json::from_value::<Step>(value.clone()).ok().map(Line::Step)
    }

    /// A text line: trimmed, a JSON object, else none.
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim();
        if !text.starts_with('{') {
            return None;
        }
        Self::of_value(&serde_json::from_str(text).ok()?)
    }
}

/// Whether a daemon error's message says it does not know the command (an older cmux).
pub fn is_unknown_command(message: &str) -> bool {
    let text = message.to_lowercase();
    text.contains("unknown variant")
        || text.contains("unknown command")
        || text.contains("unknown cmd")
}

/// Why a run stopped short.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
pub struct RunStop {
    #[serde(default)]
    pub unknown_command: bool,
    #[serde(default)]
    pub message: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    Running,
    Succeeded,
    /// The CLI's last words, or empty when a failed step already says why.
    Failed(String),
    /// The daemon does not know `device-setup`.
    NeedsNewerCmux,
}

/// One Set Up or Start run.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct Run {
    pub verb: Verb,
    pub steps: Vec<Step>,
    pub summary: Option<Summary>,
    pub phase: Phase,
}

impl Run {
    pub fn new(verb: Verb) -> Self {
        Run { verb, steps: Vec::new(), summary: None, phase: Phase::Running }
    }

    pub fn is_running(&self) -> bool {
        self.phase == Phase::Running
    }

    /// A step that reports again replaces its line.
    pub fn take(&mut self, line: Line) {
        match line {
            Line::Step(step) => match self.steps.iter_mut().find(|s| s.step == step.step) {
                Some(seen) => *seen = step,
                None => self.steps.push(step),
            },
            Line::Summary(summary) => self.summary = Some(summary),
        }
    }

    pub fn end(&mut self, stop: Option<RunStop>) {
        let failed_step = self.steps.iter().any(|s| s.state == StepState::Fail);
        self.phase = match stop {
            None if failed_step => Phase::Failed(String::new()),
            None => Phase::Succeeded,
            Some(stop)
                if stop.unknown_command && self.steps.is_empty() && self.summary.is_none() =>
            {
                Phase::NeedsNewerCmux
            }
            Some(_) if failed_step => Phase::Failed(String::new()),
            Some(stop) => Phase::Failed(stop.message),
        };
    }
}

/// What a device row shows of setup.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
pub struct SetupRow {
    pub shows_setup: bool,
    pub shows_start: bool,
    pub run: Option<Run>,
}

impl SetupRow {
    /// `verbs` None: not read yet (or no daemon): nothing shows. Start only while the Mac is offline, or
    /// while its own start runs (so the button stays, disabled, as the Mac comes online).
    pub fn make(
        is_mac: bool,
        online: bool,
        verbs: Option<&BTreeSet<Verb>>,
        run: Option<Run>,
    ) -> Self {
        if !is_mac {
            return Self::default();
        }
        let empty = BTreeSet::new();
        let verbs = verbs.unwrap_or(&empty);
        let starting = run.as_ref().is_some_and(|r| r.verb == Verb::Start && r.is_running());
        SetupRow {
            shows_setup: verbs.contains(&Verb::Setup),
            shows_start: verbs.contains(&Verb::Start) && (!online || starting),
            run,
        }
    }

    /// A host that does not let this Mac in offers no Set Up.
    pub fn blocking(mut self, allows_requests: bool) -> Self {
        if !allows_requests {
            self.shows_setup = false;
        }
        self
    }

    pub fn can_run(&self, verb: Verb) -> bool {
        let shown = match verb {
            Verb::Setup => self.shows_setup,
            Verb::Start => self.shows_start,
        };
        shown && !self.run.as_ref().is_some_and(Run::is_running)
    }
}

/// The runs by device id, and the verbs the daemon knows (all while a runner is set, none after a
/// daemon refused the command).
#[derive(Debug, Clone, Default)]
pub struct Setup {
    pub runs: BTreeMap<String, Run>,
    pub has_runner: bool,
    pub verbs: BTreeSet<Verb>,
}

/// What an ended run asks of the app.
#[derive(Serialize, Debug, Clone, PartialEq, Eq)]
pub struct Ended {
    pub phase: Phase,
    /// Refresh the device list (the run succeeded).
    pub succeeded: bool,
}

impl Setup {
    pub fn set_runner(&mut self, on: bool) {
        self.has_runner = on;
        self.verbs = if on { [Verb::Setup, Verb::Start].into() } else { BTreeSet::new() };
    }

    /// Starts a run; false (and nothing changes) while one is in flight for the device.
    pub fn run(&mut self, verb: Verb, id: &str) -> bool {
        if !self.has_runner || self.runs.get(id).is_some_and(Run::is_running) {
            return false;
        }
        self.runs.insert(id.to_owned(), Run::new(verb));
        true
    }

    pub fn line(&mut self, id: &str, line: Line) -> Option<&Run> {
        let run = self.runs.get_mut(id)?;
        run.take(line);
        Some(run)
    }

    pub fn end(&mut self, id: &str, stop: Option<RunStop>) -> Option<Ended> {
        let run = self.runs.get_mut(id)?;
        run.end(stop);
        let phase = run.phase.clone();
        if phase == Phase::NeedsNewerCmux {
            self.verbs.clear();
        }
        Some(Ended { succeeded: phase == Phase::Succeeded, phase })
    }

    pub fn dismiss(&mut self, id: &str) -> bool {
        self.runs.remove(id).is_some()
    }

    pub fn row(&self, id: &str, is_mac: bool, online: bool) -> SetupRow {
        let verbs = self.has_runner.then_some(&self.verbs);
        SetupRow::make(is_mac, online, verbs, self.runs.get(id).cloned())
    }
}

#[cfg(test)]
mod tests {
    //! Ported from `MacScreenDeviceSetupTests.swift`.
    use super::*;
    use serde_json::json;

    fn both() -> BTreeSet<Verb> {
        [Verb::Setup, Verb::Start].into()
    }

    #[test]
    fn reads_each_step_state() {
        for (word, state) in [
            ("ok", StepState::Ok),
            ("changed", StepState::Changed),
            ("warn", StepState::Warn),
            ("fail", StepState::Fail),
            ("skip", StepState::Skip),
        ] {
            let line = format!(
                r#"{{"device":"studio-mac","step":"launch","state":"{word}","detail":"opened cmux NIGHTLY","fix":""}}"#
            );
            let mut step = Step::new("studio-mac", "launch", state);
            step.detail = "opened cmux NIGHTLY".into();
            assert_eq!(Line::parse(&line), Some(Line::Step(step)));
        }
    }

    #[test]
    fn an_unknown_state_reads_as_a_warning_never_a_pass() {
        let Some(Line::Step(step)) =
            Line::parse(r#"{"device":"m","step":"app","state":"exploded","detail":"d"}"#)
        else {
            panic!("not a step")
        };
        assert_eq!(step.state, StepState::Warn);
        assert_eq!(step.fix, None);
    }

    #[test]
    fn reads_the_fix_of_a_failed_step() {
        let line = r#"{"device":"m","step":"reach","state":"fail","detail":"ssh refused","fix":"Turn on Remote Login on m."}"#;
        let Some(Line::Step(step)) = Line::parse(line) else { panic!("not a step") };
        assert_eq!(step.fix.as_deref(), Some("Turn on Remote Login on m."));
    }

    #[test]
    fn reads_the_summary_line() {
        let line = r#"{"device":"studio-mac","summary":"started","changed":["launch"]}"#;
        assert_eq!(
            Line::parse(line),
            Some(Line::Summary(Summary {
                device: "studio-mac".into(),
                summary: "started".into(),
                changed: vec!["launch".into()]
            }))
        );
    }

    #[test]
    fn skips_what_is_not_a_line() {
        for text in ["", "   ", "starting…", "{not json", r#"{"other":"shape"}"#, "[1,2]"] {
            assert_eq!(Line::parse(text), None, "{text}");
        }
    }

    #[test]
    fn reads_a_step_event_and_the_reply_from_the_daemon() {
        let event = json!({"event": "device-setup-step", "device": "studio-mac", "step": "launch", "state": "changed", "detail": "opened"});
        let mut step = Step::new("studio-mac", "launch", StepState::Changed);
        step.detail = "opened".into();
        assert_eq!(Line::of_value(&event), Some(Line::Step(step)));
        let reply = json!({"device": "studio-mac", "summary": "started", "changed": ["launch"]});
        assert!(
            matches!(Line::of_value(&reply), Some(Line::Summary(s)) if s.changed == ["launch"])
        );
        assert_eq!(Line::of_value(&json!({"ok": true})), None);
    }

    #[test]
    fn an_unknown_command_is_an_older_daemon() {
        for message in [
            "unknown variant `device-setup`, expected one of …",
            "unknown command: device-setup",
            "Unknown cmd device-setup",
        ] {
            assert!(is_unknown_command(message), "{message}");
        }
        assert!(!is_unknown_command("no route to studio-mac"));
    }

    #[test]
    fn an_offline_mac_shows_start() {
        let row = SetupRow::make(true, false, Some(&both()), None);
        assert!(row.shows_start && row.shows_setup && row.can_run(Verb::Start));
    }

    #[test]
    fn an_online_mac_shows_set_up_but_not_start() {
        let row = SetupRow::make(true, true, Some(&both()), None);
        assert!(!row.shows_start && row.shows_setup);
    }

    #[test]
    fn an_unknown_verb_hides_its_button() {
        assert_eq!(SetupRow::make(true, false, Some(&BTreeSet::new()), None), SetupRow::default());
        let only_setup = SetupRow::make(true, false, Some(&[Verb::Setup].into()), None);
        assert!(!only_setup.shows_start && only_setup.shows_setup);
        assert_eq!(SetupRow::make(true, false, None, None), SetupRow::default());
    }

    #[test]
    fn a_phone_shows_no_button() {
        assert_eq!(SetupRow::make(false, false, Some(&both()), None), SetupRow::default());
    }

    #[test]
    fn a_running_start_keeps_its_button_disabled_while_the_mac_comes_online() {
        let row = SetupRow::make(true, true, Some(&both()), Some(Run::new(Verb::Start)));
        assert!(row.shows_start && !row.can_run(Verb::Start) && !row.can_run(Verb::Setup));
    }

    #[test]
    fn a_run_ends_by_its_exit_and_steps() {
        let mut run = Run::new(Verb::Start);
        run.take(Line::Step(Step::new("m", "reach", StepState::Ok)));
        run.take(Line::Step(Step::new("m", "launch", StepState::Changed)));
        run.end(None);
        assert_eq!(run.phase, Phase::Succeeded);

        let mut failed = Run::new(Verb::Setup);
        failed.take(Line::Step(Step::new("m", "reach", StepState::Fail)));
        failed.end(Some(RunStop {
            unknown_command: false,
            message: "device-setup: reach failed".into(),
        }));
        assert_eq!(failed.phase, Phase::Failed(String::new()));

        let mut stopped = Run::new(Verb::Start);
        stopped.end(Some(RunStop { unknown_command: false, message: "no route to m".into() }));
        assert_eq!(stopped.phase, Phase::Failed("no route to m".into()));

        let mut too_old = Run::new(Verb::Start);
        too_old.end(Some(RunStop { unknown_command: true, message: "unknown variant".into() }));
        assert_eq!(too_old.phase, Phase::NeedsNewerCmux);
    }

    #[test]
    fn a_step_that_reports_again_replaces_its_line() {
        let mut run = Run::new(Verb::Setup);
        run.take(Line::Step(Step::new("m", "app", StepState::Warn)));
        run.take(Line::Step(Step::new("m", "app", StepState::Changed)));
        assert_eq!(run.steps.iter().map(|s| s.state).collect::<Vec<_>>(), [StepState::Changed]);
    }

    #[test]
    fn start_runs_and_refreshes_on_success() {
        let mut setup = Setup::default();
        setup.set_runner(true);
        assert!(setup.row("d1", true, false).shows_start);
        assert!(setup.run(Verb::Start, "d1"));
        assert!(!setup.run(Verb::Setup, "d1"), "one run per device at a time");
        setup.line("d1", Line::Step(Step::new("studio-mac", "reach", StepState::Ok)));
        setup.line("d1", Line::Step(Step::new("studio-mac", "launch", StepState::Changed)));
        setup.line(
            "d1",
            Line::Summary(Summary {
                device: "studio-mac".into(),
                summary: "started".into(),
                changed: vec!["launch".into()],
            }),
        );
        let ended = setup.end("d1", None).unwrap();
        assert_eq!(ended, Ended { phase: Phase::Succeeded, succeeded: true });
        let run = &setup.runs["d1"];
        assert_eq!(
            run.steps.iter().map(|s| s.step.as_str()).collect::<Vec<_>>(),
            ["reach", "launch"]
        );
        assert_eq!(run.summary.as_ref().unwrap().changed, ["launch"]);
        assert!(setup.dismiss("d1") && !setup.runs.contains_key("d1"));
    }

    #[test]
    fn a_daemon_that_refuses_the_command_hides_the_buttons() {
        let mut setup = Setup::default();
        setup.set_runner(true);
        setup.run(Verb::Start, "d1");
        let ended = setup
            .end("d1", Some(RunStop { unknown_command: true, message: "unknown variant".into() }));
        assert_eq!(ended.unwrap().phase, Phase::NeedsNewerCmux);
        assert!(!setup.row("d1", true, false).shows_start);
        assert!(!setup.row("d1", true, false).shows_setup);
        assert!(!setup.row("d2", true, true).shows_setup);
    }

    #[test]
    fn a_host_that_blocks_this_mac_offers_no_set_up() {
        let row = SetupRow::make(true, false, Some(&both()), None);
        let blocked = row.clone().blocking(false);
        assert!(!blocked.shows_setup && blocked.shows_start);
        assert_eq!(row.clone().blocking(true), row);
    }

    #[test]
    fn no_daemon_shows_no_button() {
        let mut setup = Setup::default();
        assert_eq!(setup.row("d1", true, false), SetupRow::default());
        assert!(!setup.run(Verb::Start, "d1"));
        setup.set_runner(true);
        assert!(setup.row("d1", true, false).shows_start);
    }
}
