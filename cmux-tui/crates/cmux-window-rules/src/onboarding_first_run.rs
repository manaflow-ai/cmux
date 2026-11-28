//! The first run's rules, moved out of the app's Swift (`AgentProjectScan`,
//! `RecentProjectScan`, `FirstRunSetup`, `MakeItYoursStepModel` and the
//! classic migration's run in `AppOnboardingServices+ClassicMigration`):
//! which agent session folders are projects and how they rank, which recent
//! projects a path query completes to, whether a launch starts the Set Up
//! card, which card Chief's chat shows, the Opacity slider's step, and what
//! the classic migration does after each daemon answer. Pure: the app reads
//! the session files, probes the folders (never inside a privacy-protected
//! one), reads its defaults and the daemon's replies, and asks here.
//!
//! The footer, the Import step and the Computer Use and Agents steps are the
//! `onboarding` and `onboarding_steps` modules'.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

// MARK: - Projects

/// A coding agent whose session files name the folders it worked in, in
/// Swift `AgentApp`'s declaration order (the order its projects list them).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentApp {
    ClaudeCode,
    Codex,
    Pi,
    Opencode,
}

/// One session file's recorded folder (already standardized by the app) and
/// when it was last written, in seconds since the reference date.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub path: String,
    pub modified: f64,
    pub app: AgentApp,
}

/// A project: a folder, its session count, when it was last active and the
/// agents that worked in it (Swift `AgentProject`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub path: String,
    #[serde(default)]
    pub sessions: u64,
    /// Seconds since the reference date; `None` for a repository that has no
    /// session: the app reads its folder's modification date.
    #[serde(default)]
    pub last_active: Option<f64>,
    #[serde(default)]
    pub apps: Vec<AgentApp>,
}

/// Swift's `Date.distantPast`, as seconds since the reference date.
pub const DISTANT_PAST: f64 = -63_114_076_800.0;

/// The temporary folders outside home that are never a project.
pub const TEMPORARY_FOLDERS: [&str; 4] =
    ["/tmp", "/private/tmp", "/private/var/folders", "/var/folders"];

/// Groups the sessions by folder, then adds each repository found under the
/// Projects roots that no session names, with no sessions and its date left
/// for the app to read (`last_active: None`). Each project's agents are in
/// `AgentApp` order. The order of the list is the folders'.
pub fn group_sessions(sessions: &[Session], repositories: &[String]) -> Vec<Project> {
    let mut by_folder: BTreeMap<&str, Project> = BTreeMap::new();
    for session in sessions {
        let project = by_folder.entry(&session.path).or_insert_with(|| Project {
            path: session.path.clone(),
            sessions: 0,
            last_active: Some(DISTANT_PAST),
            apps: Vec::new(),
        });
        project.sessions += 1;
        project.last_active =
            Some(project.last_active.unwrap_or(DISTANT_PAST).max(session.modified));
        if !project.apps.contains(&session.app) {
            project.apps.push(session.app);
        }
    }
    for repository in repositories {
        by_folder.entry(repository).or_insert_with(|| Project {
            path: repository.clone(),
            sessions: 0,
            last_active: None,
            apps: Vec::new(),
        });
    }
    by_folder
        .into_values()
        .map(|mut project| {
            project.apps.sort();
            project
        })
        .collect()
}

/// What a folder's spelling alone says about keeping it as a project.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FolderVerdict {
    /// The root, the home folder, a relative path, a temporary folder outside
    /// home or a folder inside an agent's own data: never a project.
    Drop,
    /// Kept if it is privacy-protected (kept unlooked-at) or an existing
    /// folder: the app probes in that order.
    Probe,
}

/// Swift `AgentProjectScan.keeps(folder:)`'s spelling rules: `path` and the
/// folders are standardized paths; `agent_homes` are the agents' and cmux's
/// own agent-home folders.
pub fn folder_verdict(path: &str, home: &str, agent_homes: &[String]) -> FolderVerdict {
    if path == "/" || path == home || !path.starts_with('/') {
        return FolderVerdict::Drop;
    }
    let in_home = path.starts_with(&format!("{home}/"));
    if !in_home
        && TEMPORARY_FOLDERS
            .iter()
            .any(|temporary| path == *temporary || path.starts_with(&format!("{temporary}/")))
    {
        return FolderVerdict::Drop;
    }
    if agent_homes.iter().any(|agent| path.starts_with(&format!("{agent}/"))) {
        return FolderVerdict::Drop;
    }
    FolderVerdict::Probe
}

/// Recency first, with session count as weight: a project used daily
/// outranks one used heavily months ago (Swift `AgentProjectScan.score`).
pub fn score(project: &Project, now: f64) -> f64 {
    let last = project.last_active.unwrap_or(DISTANT_PAST);
    let days = ((now - last) / 86_400.0).max(0.0);
    (1.0 + project.sessions as f64).log2() - days / 14.0
}

fn by_score(a: &Project, b: &Project, now: f64) -> std::cmp::Ordering {
    let (sa, sb) = (score(a, now), score(b, now));
    if sa == sb {
        a.path.cmp(&b.path)
    } else {
        sb.partial_cmp(&sa).unwrap_or(std::cmp::Ordering::Equal)
    }
}

/// The scan's projects, best first: those with a session before those
/// without, then by score, then by path (Swift `AgentProjectScan.run`).
pub fn rank(mut projects: Vec<Project>, now: f64) -> Vec<Project> {
    projects.sort_by(|a, b| {
        let (ha, hb) = (a.sessions > 0, b.sessions > 0);
        if ha != hb {
            return hb.cmp(&ha);
        }
        by_score(a, b, now)
    });
    projects
}

/// A repository under one of the recent scan's roots, kept and dated by the app.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Repository {
    pub path: String,
    pub modified: f64,
}

/// Swift `RecentProjectScan.run`: the scan's projects, then each kept cwd
/// hint no project names (active `now`), then each kept repository (a
/// project's date moves up to its folder's, a new one is added), ranked by
/// score then path alone, at most `limit` (at least one).
pub fn recent(
    projects: Vec<Project>,
    hints: &[String],
    repositories: &[Repository],
    now: f64,
    limit: usize,
) -> Vec<Project> {
    let mut by_path: BTreeMap<String, Project> = BTreeMap::new();
    for project in projects {
        // Uniquely keyed in Swift; the last one of a path wins there too.
        by_path.insert(project.path.clone(), project);
    }
    for hint in hints {
        by_path.entry(hint.clone()).or_insert_with(|| Project {
            path: hint.clone(),
            sessions: 0,
            last_active: Some(now),
            apps: Vec::new(),
        });
    }
    for repository in repositories {
        match by_path.get_mut(&repository.path) {
            Some(existing) => {
                existing.last_active =
                    Some(existing.last_active.unwrap_or(DISTANT_PAST).max(repository.modified));
            }
            None => {
                by_path.insert(
                    repository.path.clone(),
                    Project {
                        path: repository.path.clone(),
                        sessions: 0,
                        last_active: Some(repository.modified),
                        apps: Vec::new(),
                    },
                );
            }
        }
    }
    let mut ranked: Vec<Project> = by_path.into_values().collect();
    ranked.sort_by(|a, b| by_score(a, b, now));
    ranked.truncate(limit.max(1));
    ranked
}

/// Swift `RecentProjectScan.complete`: the paths (best first) that start
/// with the expanded query or contain the raw one, ignoring case, at most
/// `limit`. `raw` is the trimmed query, `expanded` its tilde-expanded,
/// standardized form; an empty `raw` matches every path.
pub fn complete(paths: &[String], raw: &str, expanded: &str, limit: usize) -> Vec<String> {
    let folded_raw = raw.to_lowercase();
    let folded_expanded = expanded.to_lowercase();
    paths
        .iter()
        .filter(|path| {
            let folded = path.to_lowercase();
            raw.is_empty() || folded.starts_with(&folded_expanded) || folded.contains(&folded_raw)
        })
        .take(limit)
        .cloned()
        .collect()
}

// MARK: - The Set Up card

/// `home.firstRun.setupCard` as the app's defaults hold it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CardState {
    Pending,
    Reopened,
    Ended,
}

/// What a launch reads before its first-run steps.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LaunchFacts {
    /// The card's stored state; `None`: no card ever started. An unknown
    /// stored string is `None` too.
    pub state: Option<CardState>,
    pub is_first_run: bool,
    pub screen_reader: bool,
    pub skips_onboarding: bool,
    /// The first-run Agents window already showed on this channel.
    pub agents_shown: bool,
}

/// A launch's first-run route (Swift `FirstRunSetup.Route`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Route {
    /// Start the card now: mark the windows it replaces shown, store `pending`.
    StartCard,
    /// A card started on an earlier launch owns the first-run steps.
    CardOwns,
    /// No card ever started: run the first-run windows.
    Windows,
}

/// Whether Home shows the card when the setup is made: a pending or
/// reopened card, unless this launch skips onboarding.
pub fn shows_at_start(facts: &LaunchFacts) -> bool {
    !facts.skips_onboarding && matches!(facts.state, Some(CardState::Pending | CardState::Reopened))
}

/// Swift `FirstRunSetup.begin`: a first run with no card yet, no screen
/// reader, no skip and no Agents window shown starts the card.
pub fn begins(facts: &LaunchFacts) -> bool {
    facts.is_first_run
        && !facts.screen_reader
        && !facts.skips_onboarding
        && facts.state.is_none()
        && !facts.agents_shown
}

/// Swift `FirstRunSetup.route`, for the facts read before `begin` wrote.
pub fn route(facts: &LaunchFacts) -> Route {
    if begins(facts) {
        Route::StartCard
    } else if facts.state.is_none() {
        Route::Windows
    } else {
        Route::CardOwns
    }
}

/// Hide or first-run completion ends the card unless it already ended;
/// completion leaves a reopened card for review (Swift `end`, `complete`).
pub fn ends(state: Option<CardState>, completion: bool) -> bool {
    match state {
        Some(CardState::Ended) => false,
        Some(CardState::Reopened) => !completion,
        _ => true,
    }
}

/// A Claude Code sign-in as the Agents step reads it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Auth {
    SignedIn,
    SignedOut,
    Expired,
    Unknown,
}

/// What Chief's card reads of the shared agents model.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChiefFacts {
    /// Whether the whole card shows (`FirstRunSetup.shows`).
    pub shows: bool,
    /// Hide on the Chief card this launch.
    pub hidden: bool,
    /// The agents model exists and its first read answered.
    pub loaded: bool,
    /// A configured Claude route answers Chief.
    pub uses_route: bool,
    /// Claude Code is offered for install (acpmux answered, not installed).
    pub installable: bool,
    /// Claude Code's sign-in, when acpmux lists it.
    pub auth: Option<Auth>,
    /// Its login opened here waits to be confirmed.
    pub awaits_confirmation: bool,
}

/// Which Set Up card Chief's chat shows (Swift `FirstRunSetup.CardForm`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CardForm {
    Full,
    Chief,
}

/// Swift `FirstRunSetup.needsChiefAgent`: only on evidence Chief cannot answer.
pub fn needs_chief_agent(facts: &ChiefFacts) -> bool {
    if facts.hidden || !facts.loaded || facts.uses_route {
        return false;
    }
    if facts.installable {
        return true;
    }
    match facts.auth {
        None => false,
        Some(auth) => matches!(auth, Auth::SignedOut | Auth::Expired) || facts.awaits_confirmation,
    }
}

/// Swift `FirstRunSetup.cardForm`.
pub fn card_form(facts: &ChiefFacts) -> Option<CardForm> {
    if facts.shows {
        Some(CardForm::Full)
    } else if needs_chief_agent(facts) {
        Some(CardForm::Chief)
    } else {
        None
    }
}

// MARK: - Make cmux Yours

/// The Opacity slider's value as the step keeps it: refused outside 0...1
/// (or not finite), else rounded to the hundredth (Swift `setOpacity`).
pub fn stepped_opacity(value: f64) -> Option<f64> {
    if !value.is_finite() || !(0.0..=1.0).contains(&value) {
        return None;
    }
    // Swift's `rounded()` rounds half away from zero, as `f64::round` does.
    Some((value * 100.0).round() / 100.0)
}

/// `FirstRunChoices.opacity` as it is stored: clamped to 0...1.
pub fn clamped_opacity(value: f64) -> f64 {
    value.clamp(0.0, 1.0)
}

// MARK: - Classic migration

/// The bundle ids whose launch runs the classic migration by itself.
pub const SHIPPING_BUNDLES: [&str; 5] = [
    "com.cmuxterm.app",
    "com.cmuxterm.app.nightly",
    "com.cmuxterm.app.rc",
    "com.cmuxterm.app.staging",
    "com.cmuxterm.app.nightly.cmux-next",
];

/// Swift `classicMigrationRunsAtLaunch`: a test's seam wins, then
/// `CMUX_NEXT_CLASSIC_MIGRATION` (`0` off, `1` on), else shipping builds.
pub fn classic_runs_at_launch(
    seam: Option<bool>,
    environment: Option<&str>,
    bundle_id: Option<&str>,
) -> bool {
    if let Some(seam) = seam {
        return seam;
    }
    match environment {
        Some("0") => false,
        Some("1") => true,
        _ => bundle_id.is_some_and(|bundle| SHIPPING_BUNDLES.contains(&bundle)),
    }
}

/// A migration run's mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    Automatic,
    Manual,
}

/// What the daemon's probe said.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProbeFacts {
    pub mode: Mode,
    /// The ledger is `none`: this tree never saw a classic save.
    pub ledger_none: bool,
    /// Launch landed on a workspace for an empty tree.
    pub first_workspace: bool,
    /// A classic save is there to import.
    pub available: bool,
    /// The daemon's decision skips (`None`: it made none).
    pub skips: Option<bool>,
    /// The probe failed.
    pub error: bool,
}

/// What follows the probe.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProbeStep {
    /// Automatic and the ledger is `none`.
    pub first_contact: bool,
    pub action: ProbeAction,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum ProbeAction {
    /// The daemon read no plan: the run fails.
    Fail,
    /// Record the save's identity beside an existing tree, decide
    /// `skip`/`in_use_before`, and tell the person when one was available.
    Baseline { notice: bool },
    /// Nothing to ask: record `seen` when this is first contact.
    Stop { record_seen: bool },
    /// Ask the person.
    Confirm,
}

/// Swift `runClassicMigration`, up to the confirmation.
pub fn classic_probe(facts: &ProbeFacts) -> ProbeStep {
    let first_contact = facts.mode == Mode::Automatic && facts.ledger_none;
    let action = if facts.error {
        ProbeAction::Fail
    } else if first_contact && !facts.first_workspace {
        ProbeAction::Baseline { notice: facts.available }
    } else if facts.mode == Mode::Manual || (facts.available && facts.skips == Some(false)) {
        ProbeAction::Confirm
    } else {
        ProbeAction::Stop { record_seen: first_contact }
    };
    ProbeStep { first_contact, action }
}

/// The person's answer to the import preview.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Answer {
    Accepted,
    Declined,
    Unanswered,
}

/// What follows the answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum AnswerAction {
    /// Plan and import.
    Import,
    /// Stop, unconfirmed: a manual decline records nothing.
    Stop { record_seen: bool },
    /// An automatic decline: record it and tell the person it was not imported.
    Decline,
}

/// Swift `runClassicMigration`'s answer switch.
pub fn classic_answer(mode: Mode, first_contact: bool, answer: Answer) -> AnswerAction {
    match answer {
        Answer::Accepted => AnswerAction::Import,
        Answer::Declined if mode == Mode::Automatic => AnswerAction::Decline,
        Answer::Declined => AnswerAction::Stop { record_seen: false },
        Answer::Unanswered => AnswerAction::Stop { record_seen: first_contact },
    }
}

/// What the plan reply said.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ReplyFacts {
    /// The decision's reason, if it made one.
    pub reason: Option<String>,
    /// The reply carries a plan and its source.
    pub has_plan: bool,
    pub settings_only: bool,
    /// The plan has nothing to make.
    pub plan_empty: bool,
    pub first_contact: bool,
    /// Classic's bundle id, when the reply names it.
    pub source_bundle: bool,
}

/// What `restoreClassicWorkspaces` does with the plan reply.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum ReplyAction {
    /// Classic is open: record `seen` on first contact, tell the person when
    /// the reply names the classic app.
    ClassicOpen { record_seen: bool, notice: bool },
    /// Only settings came: finish with no source, the summary says so.
    SettingsOnly,
    /// Nothing changed or there is no classic session: finish with the source.
    Finish,
    /// Finish with the plan's source and Cloud VM keys: it made nothing.
    FinishEmpty,
    /// Nothing to finish: record `seen` on first contact.
    Stop { record_seen: bool },
    /// Make the plan's workspaces.
    Restore,
}

/// Swift `restoreClassicWorkspaces`, up to making the workspaces.
pub fn classic_reply(facts: &ReplyFacts) -> ReplyAction {
    let reason = facts.reason.as_deref();
    if reason == Some("classic_running") {
        return ReplyAction::ClassicOpen {
            record_seen: facts.first_contact,
            notice: facts.source_bundle,
        };
    }
    if !facts.has_plan {
        return if facts.settings_only {
            ReplyAction::SettingsOnly
        } else if matches!(reason, Some("unchanged" | "no_classic_session")) {
            ReplyAction::Finish
        } else {
            ReplyAction::Stop { record_seen: facts.first_contact }
        };
    }
    if facts.plan_empty { ReplyAction::FinishEmpty } else { ReplyAction::Restore }
}

#[cfg(test)]
#[path = "onboarding_first_run_tests.rs"]
mod tests;
