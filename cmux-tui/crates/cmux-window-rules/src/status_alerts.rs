//! The app's side of two status notifications: an OSC 7501 alert and a
//! finished `cmux status run`. Moved from the app's
//! `ProgramStatusNotification`, `FinishedStatusRunTracker` and
//! `StatusBehaviorSettings.notifies`.
//!
//! An OSC 7501 alert: when a record starts waiting on the user or fails (and
//! once it finishes) the session host posts "<title, else app, else A
//! program> <verb>" with the record's message as the body, `warning` for a
//! wait, `error` for a failure, `info` for done (cmux-tui-core
//! `program_status::raise_alert`). The app finds the record again among the
//! terminal's `extra.program_status` for the banner's badge and the
//! done-visibility rule (cx-kxa2). The wording here is the daemon's, pinned
//! by this module's tests: cmux-tui-core is not a dependency of these rules.
//!
//! A status run: the CLI writes its `run:<pid>` workspace status entry busy,
//! then success or error with the command's exit code and duration. A run
//! counts only when this client saw it busy first, so a finished entry that
//! is already there (a relaunch, a reconnect while its badge shows) is not
//! news, and one that stays (another entry of its workspace changed) counts
//! once. A run whose entry goes away while busy (its CLI was killed) never
//! counts.

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

/// The daemon's notification title limit, in characters (terminal_metadata.rs).
pub const TITLE_LIMIT: usize = 256;
/// The daemon's notification body limit, in characters.
pub const BODY_LIMIT: usize = 1024;

/// An OSC 7501 record's state.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
}

/// Why a blocked program waits.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Permission,
    Question,
    Auth,
}

/// A notification's level.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Level {
    Info,
    Warning,
    Error,
}

/// What a status badge draws.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Indicator {
    Waiting,
    Error,
    Success,
}

/// Why a program notified: the banner's reason line and badge.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Reason {
    Permission,
    Question,
    Auth,
    /// Blocked without a kind.
    Input,
    Failed,
    Done,
}

impl Reason {
    pub const ALL: [Self; 6] =
        [Self::Permission, Self::Question, Self::Auth, Self::Input, Self::Failed, Self::Done];

    /// The record's reason; None for a working or idle record, which never alerts.
    pub fn of(state: State, kind: Option<Kind>) -> Option<Self> {
        match state {
            State::Blocked => Some(match kind {
                Some(Kind::Permission) => Self::Permission,
                Some(Kind::Question) => Self::Question,
                Some(Kind::Auth) => Self::Auth,
                None => Self::Input,
            }),
            State::Error => Some(Self::Failed),
            State::Done => Some(Self::Done),
            State::Working | State::Idle => None,
        }
    }

    /// The level the daemon posts it at.
    pub fn level(self) -> Level {
        match self {
            Self::Permission | Self::Question | Self::Auth | Self::Input => Level::Warning,
            Self::Failed => Level::Error,
            Self::Done => Level::Info,
        }
    }

    /// The daemon's wording (program_status.rs `raise_alert`).
    pub fn verb(self) -> &'static str {
        match self {
            Self::Permission => "needs approval",
            Self::Question => "asks a question",
            Self::Auth => "needs sign-in",
            Self::Input => "needs input",
            Self::Failed => "failed",
            Self::Done => "is done",
        }
    }

    /// The indicator state the badge draws.
    pub fn indicator(self) -> Indicator {
        match self {
            Self::Permission | Self::Question | Self::Auth | Self::Input => Indicator::Waiting,
            Self::Failed => Indicator::Error,
            Self::Done => Indicator::Success,
        }
    }

    /// The record's blocked kind, None for every other reason.
    pub fn kind(self) -> Option<Kind> {
        match self {
            Self::Permission => Some(Kind::Permission),
            Self::Question => Some(Kind::Question),
            Self::Auth => Some(Kind::Auth),
            Self::Input | Self::Failed | Self::Done => None,
        }
    }
}

/// One OSC 7501 record of the terminal, as much of it as the match reads.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub state: State,
    #[serde(default)]
    pub kind: Option<Kind>,
    #[serde(default)]
    pub app: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub msg: Option<String>,
    #[serde(default)]
    pub updated_seq: u64,
}

/// The record a terminal notification was posted for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Alert {
    /// Its index in the records asked about.
    pub index: usize,
    pub reason: Reason,
    pub indicator: Indicator,
    pub kind: Option<Kind>,
}

/// The record a notification with `title`, `body` and `level` was posted
/// for, None for any other terminal notification (OSC 9, 777, 99). Among
/// several matches the newest report wins (the first of equals).
pub fn alert(title: &str, body: &str, level: Level, records: &[Record]) -> Option<Alert> {
    let mut best: Option<(usize, Reason, u64)> = None;
    for (index, record) in records.iter().enumerate() {
        let Some(reason) = Reason::of(record.state, record.kind) else { continue };
        if reason.level() != level {
            continue;
        }
        let name = record.title.as_deref().or(record.app.as_deref()).unwrap_or("A program");
        let posted = format!("{name} {}", reason.verb());
        if clipped(&posted, TITLE_LIMIT) != title
            || clipped(record.msg.as_deref().unwrap_or(""), BODY_LIMIT) != body
        {
            continue;
        }
        if best.is_none_or(|(_, _, seq)| record.updated_seq > seq) {
            best = Some((index, reason, record.updated_seq));
        }
    }
    best.map(|(index, reason, _)| Alert {
        index,
        reason,
        indicator: reason.indicator(),
        kind: reason.kind(),
    })
}

/// Whether a terminal notification reads like an OSC 7501 alert ("<name>
/// <verb>" at the verb's level) whose record may not have arrived yet: the
/// session events stream can deliver the record after the notification, so
/// the app waits briefly for it before the banner.
pub fn looks_like_alert(title: &str, level: Level) -> bool {
    Reason::ALL.iter().any(|reason| {
        let suffix = format!(" {}", reason.verb());
        reason.level() == level
            && title.ends_with(&suffix)
            && title.graphemes(true).count() > suffix.graphemes(true).count()
    })
}

fn clipped(text: &str, limit: usize) -> &str {
    match text.grapheme_indices(true).nth(limit) {
        Some((end, _)) => text.get(..end).unwrap_or(text),
        None => text,
    }
}

/// Where a terminal is, as the client sees it (Lawrence's visibility rule).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Visibility {
    /// The terminal's tab is the selected tab of its pane.
    pub tab_selected: bool,
    /// Its pane is on screen in its window (not scrolled off the strip).
    pub pane_on_screen: bool,
    /// Its window is key, or at least not occluded.
    pub window_shown: bool,
    /// cmux is the active app.
    pub app_active: bool,
}

impl Visibility {
    /// The user can see the terminal now.
    pub fn is_visible(self) -> bool {
        self.tab_selected && self.pane_on_screen && self.window_shown && self.app_active
    }
}

/// Whether an alert shows at all: `done` only for a terminal the user cannot
/// see (Lawrence, cx-kxa2); the rest follow the normal notification rules.
pub fn alert_notifies(reason: Reason, visibility: Visibility) -> bool {
    reason != Reason::Done || !visibility.is_visible()
}

/// The key prefix of the entries `cmux status run` writes (`run:<pid>`).
pub const RUN_KEY_PREFIX: &str = "run:";

/// A run this client saw busy.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Run {
    pub workspace: String,
    pub key: String,
}

/// One workspace status entry.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub key: String,
    #[serde(default)]
    pub state: Option<String>,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub target_terminal: Option<String>,
    #[serde(default)]
    pub exit_code: Option<i64>,
    #[serde(default)]
    pub duration_ms: Option<u64>,
}

/// One workspace's status.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceStatus {
    pub workspace: String,
    #[serde(default)]
    pub entries: Vec<Entry>,
}

/// A run that this client saw running and then saw finish.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FinishedRun {
    pub workspace: String,
    /// The entry's key (`run:<pid>`).
    pub key: String,
    /// The run's label (`--label`, else the command).
    pub label: String,
    /// The terminal the run is about, None for a run started outside cmux.
    pub terminal: Option<String>,
    /// The command exited 0.
    pub succeeded: bool,
    /// The command's exit status (128 + the signal for a signal).
    pub exit_code: Option<i64>,
    /// How long the command ran, None when the CLI sent none (it could not start).
    pub duration_ms: Option<u64>,
}

/// One look at the statuses: what finished since the last, and what is busy now.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunUpdate {
    /// The runs this update shows finished, in the statuses' order.
    pub finished: Vec<FinishedRun>,
    /// The runs busy now, for the next update.
    pub running: Vec<Run>,
}

/// The runs that finished between the last look (`running`, its busy runs)
/// and `statuses`, every workspace's status now.
pub fn update_runs(running: &[Run], statuses: &[WorkspaceStatus]) -> RunUpdate {
    let was = |workspace: &str, key: &str| {
        running.iter().any(|run| run.workspace == workspace && run.key == key)
    };
    let mut update = RunUpdate::default();
    for status in statuses {
        for entry in status.entries.iter().filter(|entry| entry.key.starts_with(RUN_KEY_PREFIX)) {
            match entry.state.as_deref() {
                Some("busy") => {
                    let run = Run { workspace: status.workspace.clone(), key: entry.key.clone() };
                    if !update.running.contains(&run) {
                        update.running.push(run);
                    }
                }
                Some(state @ ("success" | "error")) if was(&status.workspace, &entry.key) => {
                    update.finished.push(FinishedRun {
                        workspace: status.workspace.clone(),
                        key: entry.key.clone(),
                        label: entry.text.clone(),
                        terminal: entry.target_terminal.clone(),
                        succeeded: state == "success",
                        exit_code: entry.exit_code,
                        duration_ms: entry.duration_ms,
                    });
                }
                _ => {}
            }
        }
    }
    update
}

/// The `status.runNotify*` settings.
#[derive(Clone, Copy, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RunBehavior {
    pub run_notify_minimum_seconds: f64,
    pub run_notify_when_visible: bool,
}

impl Default for RunBehavior {
    fn default() -> Self {
        Self { run_notify_minimum_seconds: 10.0, run_notify_when_visible: false }
    }
}

/// Whether a finished run notifies: it ran at least the minimum, and its
/// terminal is not visible unless `run_notify_when_visible` is on. A run
/// with no duration (its command could not start) counts as instant.
pub fn run_notifies(
    duration_ms: Option<u64>,
    behavior: RunBehavior,
    visibility: Visibility,
) -> bool {
    #[allow(clippy::cast_precision_loss, reason = "a duration in ms is far below 2^53")]
    let seconds = duration_ms.unwrap_or(0) as f64 / 1000.0;
    if seconds < behavior.run_notify_minimum_seconds {
        return false;
    }
    behavior.run_notify_when_visible || !visibility.is_visible()
}

#[cfg(test)]
#[path = "status_alerts_tests.rs"]
mod tests;
