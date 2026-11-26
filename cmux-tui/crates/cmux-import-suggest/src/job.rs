//! One import the person started and its progress across relaunches (`ImportJob`), and the
//! ledger the app saves them in (`ImportJobLedger`). Dates are milliseconds since 1970, as
//! `JSONEncoder.importJobs` writes them.

use serde::{Deserialize, Serialize};

use crate::model::{Counts, DataKind, Family, Finding, SourceKind};
use crate::request::Request;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    #[default]
    Running,
    Paused,
    Done,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Pause {
    /// The app quit or crashed mid-run.
    Interrupted,
    /// The browser asks the person (a Keychain prompt) before the rest can go on.
    NeedsPerson,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Failure {
    Declined,
    SourceGone,
    ImportFailed,
}

/// One profile's share of a job.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Step {
    pub profile: String,
    #[serde(default)]
    pub kinds: Vec<DataKind>,
    #[serde(default)]
    pub into_default: bool,
    #[serde(default)]
    pub done: bool,
}

impl Step {
    pub fn new(profile: impl Into<String>, kinds: Vec<DataKind>, into_default: bool) -> Self {
        Step { profile: profile.into(), kinds, into_default, done: false }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    pub kind: SourceKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub browser: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub site: Option<String>,
    pub steps: Vec<Step>,
    #[serde(default)]
    pub phase: Phase,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pause: Option<Pause>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<Failure>,
    #[serde(default)]
    pub step_fraction: f64,
    #[serde(default)]
    pub counts: Counts,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opened: Option<i64>,
    pub started_at: f64,
    pub updated_at: f64,
}

/// What one click brings from a browser profile: history, bookmarks and cookies, never
/// passwords (those ask the person each time).
pub const ONE_CLICK_KINDS: [DataKind; 3] =
    [DataKind::History, DataKind::Bookmarks, DataKind::Cookies];

impl Job {
    /// A running job; no steps means one step for the whole source.
    pub fn new(
        id: impl Into<String>,
        kind: SourceKind,
        browser: Option<String>,
        site: Option<String>,
        steps: Vec<Step>,
        now: f64,
    ) -> Self {
        let steps = if steps.is_empty() { vec![Step::new("", Vec::new(), true)] } else { steps };
        Job {
            id: id.into(),
            kind,
            browser,
            site,
            steps,
            phase: Phase::Running,
            pause: None,
            failure: None,
            step_fraction: 0.0,
            counts: Counts::default(),
            opened: None,
            started_at: now,
            updated_at: now,
        }
    }

    /// The job a finding's Import starts: a browser gets one step per profile that holds a
    /// one-click kind (the first profile into the default space); any other source, one step.
    pub fn from_finding(finding: &Finding, now: f64) -> Self {
        let browser = finding.kind == SourceKind::Browser;
        let steps = if browser {
            finding
                .profiles
                .iter()
                .enumerate()
                .filter_map(|(index, profile)| {
                    let kinds: Vec<DataKind> = ONE_CLICK_KINDS
                        .into_iter()
                        .filter(|kind| profile.kinds.contains(kind))
                        .collect();
                    (!kinds.is_empty())
                        .then(|| Step::new(profile.directory_name.clone(), kinds, index == 0))
                })
                .collect()
        } else {
            Vec::new()
        };
        Job::new(finding.id.clone(), finding.kind, finding.browser.clone(), None, steps, now)
    }

    /// The job an agent's request starts: one site's cookies from one profile.
    pub fn from_request(request: &Request, profile: &str, now: f64) -> Self {
        Job::new(
            request.id(),
            SourceKind::Browser,
            Some(request.browser.clone()),
            Some(request.site.clone()),
            vec![Step::new(profile, vec![DataKind::Cookies], true)],
            now,
        )
    }

    /// How far it is, 0 to 1.
    pub fn fraction(&self) -> f64 {
        if self.phase == Phase::Done {
            return 1.0;
        }
        let done = self.steps.iter().filter(|step| step.done).count() as f64;
        let total = self.steps.len().max(1) as f64;
        ((done + self.step_fraction.clamp(0.0, 1.0)) / total).min(1.0)
    }

    pub fn next_step(&self) -> Option<usize> {
        self.steps.iter().position(|step| !step.done)
    }

    pub fn is_active(&self) -> bool {
        self.phase == Phase::Running
    }

    /// The rest can run after a relaunch without asking anyone: a browser job whose steps
    /// left need no Keychain (no passwords, no Chromium cookies). `family` is the job's
    /// browser's, from the registry; nil when the registry does not know it.
    pub fn resumes_quietly(&self, family: Option<Family>) -> bool {
        let (SourceKind::Browser, Some(_), Some(family)) = (self.kind, &self.browser, family)
        else {
            return false;
        };
        let left: Vec<DataKind> = self
            .steps
            .iter()
            .filter(|step| !step.done)
            .flat_map(|step| step.kinds.iter().copied())
            .collect();
        let needs_keychain = left.contains(&DataKind::Passwords)
            || (family == Family::Chromium && left.contains(&DataKind::Cookies));
        !needs_keychain
    }

    pub fn progressed(&mut self, fraction: f64, now: f64) {
        self.step_fraction = fraction;
        self.updated_at = now;
    }

    pub fn finished_step(&mut self, index: usize, added: Counts, now: f64) {
        let Some(step) = self.steps.get_mut(index) else { return };
        step.done = true;
        self.counts = self.counts + added;
        self.step_fraction = 0.0;
        self.updated_at = now;
        if self.next_step().is_none() {
            self.phase = Phase::Done;
            self.pause = None;
        }
    }

    pub fn imported_classic(&mut self, workspaces: i64, now: f64) {
        self.opened = Some(workspaces);
        self.finished_step(0, Counts::default(), now);
    }

    pub fn paused(&mut self, reason: Pause, now: f64) {
        if self.phase != Phase::Running {
            return;
        }
        self.phase = Phase::Paused;
        self.pause = Some(reason);
        self.updated_at = now;
    }

    /// Back to running from paused or failed; the step starts over, so its progress does too.
    pub fn resumed(&mut self, now: f64) {
        if !matches!(self.phase, Phase::Paused | Phase::Failed) {
            return;
        }
        self.phase = Phase::Running;
        self.pause = None;
        self.failure = None;
        self.step_fraction = 0.0;
        self.updated_at = now;
    }

    pub fn failed(&mut self, reason: Failure, now: f64) {
        self.phase = Phase::Failed;
        self.failure = Some(reason);
        self.pause = None;
        self.updated_at = now;
    }
}

/// The ledger's schema; a file with another one reads as empty.
pub const CURRENT_SCHEMA: i64 = 1;
/// A finished job's card stays two weeks, in milliseconds.
pub const KEEP_FINISHED_MS: f64 = 14.0 * 24.0 * 3600.0 * 1000.0;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ledger {
    #[serde(default = "current_schema")]
    pub schema: i64,
    #[serde(default)]
    pub jobs: Vec<Job>,
}

fn current_schema() -> i64 {
    CURRENT_SCHEMA
}

impl Default for Ledger {
    fn default() -> Self {
        Ledger { schema: CURRENT_SCHEMA, jobs: Vec::new() }
    }
}

impl Ledger {
    /// The ledger in a saved file's bytes, or an empty one when they are not this schema's.
    pub fn read(bytes: &[u8]) -> Ledger {
        serde_json::from_slice::<Ledger>(bytes)
            .ok()
            .filter(|ledger| ledger.schema == CURRENT_SCHEMA)
            .unwrap_or_default()
    }

    pub fn job(&self, id: &str) -> Option<&Job> {
        self.jobs.iter().find(|job| job.id == id)
    }

    pub fn put(&mut self, job: Job) {
        match self.jobs.iter_mut().find(|kept| kept.id == job.id) {
            Some(kept) => *kept = job,
            None => self.jobs.push(job),
        }
    }

    pub fn update(&mut self, id: &str, change: impl FnOnce(&mut Job)) {
        if let Some(job) = self.jobs.iter_mut().find(|job| job.id == id) {
            change(job);
        }
    }

    pub fn remove(&mut self, id: &str) {
        self.jobs.retain(|job| job.id != id);
    }

    /// At launch: finished jobs older than two weeks go; a job that was running is paused as
    /// interrupted (the app quit under it).
    pub fn relaunched(&mut self, now: f64) {
        self.jobs
            .retain(|job| !(job.phase == Phase::Done && now - job.updated_at > KEEP_FINISHED_MS));
        for job in &mut self.jobs {
            if job.phase == Phase::Running {
                job.paused(Pause::Interrupted, now);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Profile;

    fn chrome() -> Finding {
        let mut finding = Finding::new("browser.chrome", SourceKind::Browser, "Chrome");
        finding.browser = Some("chrome".into());
        finding.profiles = vec![
            Profile::new(
                "Default",
                vec![
                    DataKind::Bookmarks,
                    DataKind::History,
                    DataKind::Cookies,
                    DataKind::Passwords,
                ],
            ),
            Profile::new("Profile 1", vec![DataKind::History]),
            Profile::new("Profile 2", vec![DataKind::Passwords]),
        ];
        finding
    }

    #[test]
    fn a_browser_job_takes_one_step_per_profile_with_one_click_kinds() {
        let job = Job::from_finding(&chrome(), 5.0);
        assert_eq!(
            job.steps.iter().map(|step| step.profile.as_str()).collect::<Vec<_>>(),
            ["Default", "Profile 1"]
        );
        assert_eq!(
            job.steps.iter().map(|step| step.kinds.clone()).collect::<Vec<_>>(),
            [
                vec![DataKind::History, DataKind::Bookmarks, DataKind::Cookies],
                vec![DataKind::History]
            ]
        );
        assert_eq!(
            job.steps.iter().map(|step| step.into_default).collect::<Vec<_>>(),
            [true, false]
        );
        assert_eq!((job.phase, job.started_at, job.updated_at), (Phase::Running, 5.0, 5.0));
    }

    #[test]
    fn other_sources_take_one_step() {
        let mut classic = Finding::new("cmux.classic", SourceKind::CmuxClassic, "cmux Classic");
        classic.profiles = vec![Profile::new("x", vec![])];
        let job = Job::from_finding(&classic, 0.0);
        assert_eq!(job.steps, vec![Step::new("", vec![], true)]);
    }

    #[test]
    fn progress_counts_finished_steps_and_the_current_one() {
        let mut job = Job::from_finding(&chrome(), 0.0);
        job.progressed(0.5, 1.0);
        assert_eq!(job.fraction(), 0.25);
        job.finished_step(0, Counts { history: 3, ..Counts::default() }, 2.0);
        assert_eq!(job.fraction(), 0.5);
        assert_eq!(job.next_step(), Some(1));
        job.progressed(7.0, 3.0);
        assert_eq!(job.fraction(), 1.0);
        job.finished_step(9, Counts::default(), 4.0);
        assert_eq!(job.updated_at, 3.0);
        job.finished_step(1, Counts { history: 2, cookies: 1, ..Counts::default() }, 5.0);
        assert_eq!(
            (job.phase, job.counts.history, job.counts.cookies, job.fraction()),
            (Phase::Done, 5, 1, 1.0)
        );
    }

    #[test]
    fn pause_resume_and_fail_follow_the_phase_rules() {
        let mut job = Job::from_finding(&chrome(), 0.0);
        job.progressed(0.4, 1.0);
        job.paused(Pause::NeedsPerson, 2.0);
        assert_eq!((job.phase, job.pause), (Phase::Paused, Some(Pause::NeedsPerson)));
        job.paused(Pause::Interrupted, 3.0);
        assert_eq!((job.pause, job.updated_at), (Some(Pause::NeedsPerson), 2.0));
        job.resumed(4.0);
        assert_eq!((job.phase, job.pause, job.step_fraction), (Phase::Running, None, 0.0));
        job.resumed(5.0);
        assert_eq!(job.updated_at, 4.0);
        job.failed(Failure::Declined, 6.0);
        assert_eq!((job.phase, job.failure), (Phase::Failed, Some(Failure::Declined)));
        job.resumed(7.0);
        assert_eq!((job.phase, job.failure), (Phase::Running, None));
    }

    #[test]
    fn only_keychain_free_browser_jobs_resume_quietly() {
        let job = Job::from_finding(&chrome(), 0.0);
        assert!(!job.resumes_quietly(Some(Family::Chromium)));
        assert!(job.resumes_quietly(Some(Family::Firefox)));
        assert!(!job.resumes_quietly(None));
        let mut history = job.clone();
        history.finished_step(0, Counts::default(), 1.0);
        assert!(history.resumes_quietly(Some(Family::Chromium)));
        let mut passwords = job;
        passwords.steps[0].kinds.push(DataKind::Passwords);
        assert!(!passwords.resumes_quietly(Some(Family::Firefox)));
        let agents =
            Job::from_finding(&Finding::new("agents.codex", SourceKind::Codex, "Codex"), 0.0);
        assert!(!agents.resumes_quietly(Some(Family::Firefox)));
    }

    #[test]
    fn classic_records_what_it_opened() {
        let mut job = Job::from_finding(
            &Finding::new("cmux.classic", SourceKind::CmuxClassic, "cmux Classic"),
            0.0,
        );
        job.imported_classic(4, 1.0);
        assert_eq!((job.opened, job.phase), (Some(4), Phase::Done));
    }

    #[test]
    fn a_request_job_brings_one_sites_cookies() {
        let request = Request::new("arc", "linear.app", "sign in", 0.0);
        let job = Job::from_request(&request, "Default", 9.0);
        assert_eq!(job.id, "request.cookies.arc.linear.app");
        assert_eq!(job.site.as_deref(), Some("linear.app"));
        assert_eq!(job.steps, vec![Step::new("Default", vec![DataKind::Cookies], true)]);
    }

    #[test]
    fn a_relaunch_pauses_running_jobs_and_forgets_old_finished_ones() {
        let mut ledger = Ledger::default();
        let mut old = Job::new("old", SourceKind::Codex, None, None, vec![], 0.0);
        old.finished_step(0, Counts::default(), 0.0);
        let mut recent = Job::new("recent", SourceKind::Codex, None, None, vec![], 0.0);
        recent.finished_step(0, Counts::default(), KEEP_FINISHED_MS);
        let running = Job::new("running", SourceKind::Codex, None, None, vec![], 0.0);
        ledger.put(old);
        ledger.put(recent);
        ledger.put(running.clone());
        ledger.put(running);
        assert_eq!(ledger.jobs.len(), 3);
        ledger.relaunched(KEEP_FINISHED_MS + 1.0);
        assert!(ledger.job("old").is_none());
        assert_eq!(ledger.job("recent").map(|job| job.phase), Some(Phase::Done));
        assert_eq!(ledger.job("running").and_then(|job| job.pause), Some(Pause::Interrupted));
        ledger.update("recent", |job| job.opened = Some(1));
        assert_eq!(ledger.job("recent").and_then(|job| job.opened), Some(1));
        ledger.remove("recent");
        assert_eq!(ledger.jobs.len(), 1);
    }

    #[test]
    fn the_ledger_reads_its_own_schema_only() {
        let saved = serde_json::to_vec(&Ledger {
            schema: 1,
            jobs: vec![Job::new("a", SourceKind::Codex, None, None, vec![], 1.0)],
        })
        .unwrap();
        assert_eq!(Ledger::read(&saved).jobs.len(), 1);
        assert!(Ledger::read(br#"{"schema":2,"jobs":[]}"#).jobs.is_empty());
        assert!(Ledger::read(b"nope").jobs.is_empty());
        let swift = br#"{"jobs":[{"counts":{"bookmarks":0,"cookies":0,"extensions":0,"history":4,"openTabs":0,"passwords":0,"searchEngines":0},"id":"browser.chrome","kind":"browser","browser":"chrome","phase":"paused","pause":"interrupted","startedAt":1700000000000,"stepFraction":0,"steps":[{"done":false,"intoDefault":true,"kinds":["history"],"profile":"Default"}],"updatedAt":1700000000500}],"schema":1}"#;
        let ledger = Ledger::read(swift);
        assert_eq!(ledger.jobs[0].counts.history, 4);
        assert_eq!(ledger.jobs[0].pause, Some(Pause::Interrupted));
    }
}
