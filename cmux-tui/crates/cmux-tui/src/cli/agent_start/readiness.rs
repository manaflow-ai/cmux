//! When a started agent can take a message: `cmux agent start` waits for it,
//! and `cmux terminal <t> wait --until ready` asks for it.
//!
//! Each look reads the terminal record, its agent records and its screen,
//! and [`assess`] gives one of:
//!
//! - `blocked`: a startup dialog is at the bottom of the screen, where the
//!   input box would be (Claude's folder-trust
//!   question, the bypass-permissions warning, a login or API-key choice,
//!   onboarding, Codex's trust or update prompt), or a fresh hook record
//!   says the agent waits on the person. The dialog's id and a reason come
//!   with it. cmux never answers the dialog.
//! - `ready`: no dialog, and a fresh hook record says the agent is idle (the
//!   `SessionStart` hook) or the screen shows the agent's input box.
//! - `starting`: neither yet.
//! - `exited`: the terminal's process ended.
//!
//! `ready` and `blocked` count only once the screen stood still for the
//! settle time (default 1 s), so a dialog that is still drawing or an input
//! box that a dialog replaces a moment later is not taken.

use std::time::{Duration, Instant};

use serde_json::Value;

use super::super::command::RequestPlan;
use super::Failure;
use super::daemon::Daemon;

/// How long the screen must stand still before `ready` or `blocked` counts.
pub(in crate::cli) const DEFAULT_SETTLE: Duration = Duration::from_secs(1);
/// How often the wait looks.
pub(in crate::cli) const DEFAULT_POLL: Duration = Duration::from_millis(250);
/// How long `agent start` waits by default.
pub(in crate::cli) const DEFAULT_TIMEOUT: Duration = Duration::from_secs(90);

/// A startup dialog that holds the agent before its first message.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::cli) struct Dialog {
    /// Stable id: `folder_trust`, `bypass_permissions_warning`, `login`,
    /// `api_key`, `onboarding`, `update_prompt` or `agent_question`.
    pub id: &'static str,
    /// What the person has to do, in one sentence.
    pub reason: &'static str,
}

/// Screen phrases (lower case) of each dialog, first match wins.
const DIALOGS: &[(Dialog, &[&str])] = &[
    (
        Dialog {
            id: "folder_trust",
            reason: "the agent asks whether you trust this folder; answer it in the terminal \
                     (cmux does not answer it for you)",
        },
        &[
            "do you trust the files in this folder",
            "is this a project you created or one you trust",
            "yes, i trust this folder",
            "do you trust the contents of this directory",
            "allow codex to work in this folder",
        ],
    ),
    (
        Dialog {
            id: "bypass_permissions_warning",
            reason: "the agent shows the bypass-permissions warning; accept or decline it in \
                     the terminal",
        },
        &["running in bypass permissions mode", "yes, i accept"],
    ),
    (
        Dialog {
            id: "api_key",
            reason: "the agent asks whether to use the API key it found in the environment",
        },
        &["detected a custom api key", "do you want to use this api key"],
    ),
    (
        Dialog { id: "login", reason: "the agent is not signed in; sign in in the terminal" },
        &[
            "select login method",
            "claude account with subscription",
            "anthropic console account",
            "sign in with chatgpt",
            "run /login",
            "invalid api key",
        ],
    ),
    (
        Dialog {
            id: "onboarding",
            reason: "the agent shows its first-run setup; finish it in the terminal",
        },
        &["choose the text style", "let's get started", "press enter to continue"],
    ),
    (
        Dialog {
            id: "update_prompt",
            reason: "the agent asks whether to update first; answer it in the terminal",
        },
        &["skip until next version", "update now"],
    ),
];

/// A fresh hook record that says the agent waits on the person.
pub(in crate::cli) const AGENT_QUESTION: Dialog = Dialog {
    id: "agent_question",
    reason: "the agent waits on a question or a permission dialog; read it with screen read",
};

/// Screen text of an agent's input box (lower case).
const COMPOSER_HINTS: &[&str] = &[
    "? for shortcuts",
    "for shortcuts",
    "context left",
    "⏎ send",
    "ctrl+j newline",
    "bypass permissions on",
    "accept edits on",
    "plan mode on",
];

/// How many of the screen's last non-blank rows a startup dialog fills at most.
const DIALOG_ROWS: usize = 16;

/// The startup dialog on `screen`, if any. A dialog is the last thing an
/// agent draws, in place of its input box, so only the last [`DIALOG_ROWS`]
/// non-blank rows count, and only when they show no input box: a running
/// agent whose output says "update now" is not held by a dialog.
pub(in crate::cli) fn startup_dialog(screen: &str) -> Option<Dialog> {
    let rows: Vec<&str> = screen.lines().filter(|row| !row.trim().is_empty()).collect();
    let bottom = rows.iter().skip(rows.len().saturating_sub(DIALOG_ROWS)).copied();
    let bottom = bottom.collect::<Vec<_>>().join("\n");
    if composer_visible(&bottom) {
        return None;
    }
    let bottom = fold(&bottom);
    DIALOGS
        .iter()
        .find(|(_, phrases)| phrases.iter().any(|phrase| bottom.contains(phrase)))
        .map(|(dialog, _)| *dialog)
}

/// Lower case with each run of whitespace one space, so a phrase matches
/// across the screen's padding.
fn fold(screen: &str) -> String {
    screen.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// Whether `screen` shows an agent's input box: a footer hint, or a prompt
/// mark (`>`, `❯`, `›`) at the start of a line with a horizontal rule above
/// or below it.
pub(in crate::cli) fn composer_visible(screen: &str) -> bool {
    let folded = fold(screen);
    if COMPOSER_HINTS.iter().any(|hint| folded.contains(hint)) {
        return true;
    }
    let lines: Vec<&str> = screen.lines().collect();
    let rule = |line: &str| line.chars().filter(|character| *character == '─').count() >= 10;
    lines.iter().enumerate().any(|(index, line)| {
        let line = line
            .trim_start_matches(|character: char| character.is_whitespace() || character == '│');
        let prompt = ['>', '❯', '›'].iter().any(|mark| {
            line.strip_prefix(*mark)
                .is_some_and(|rest| rest.is_empty() || rest.starts_with(char::is_whitespace))
        });
        let near = |offset: isize| {
            index
                .checked_add_signed(offset)
                .and_then(|other| lines.get(other).copied())
                .is_some_and(rule)
        };
        prompt && (near(-1) || near(1))
    })
}

/// What one look found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Readiness {
    Starting,
    Ready,
    Blocked(Dialog),
    Exited,
}

impl Readiness {
    pub(in crate::cli) fn as_str(self) -> &'static str {
        match self {
            Self::Starting => "starting",
            Self::Ready => "ready",
            Self::Blocked(_) => "blocked",
            Self::Exited => "exited",
        }
    }
}

/// One look at the terminal.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) struct Look<'a> {
    pub screen: &'a str,
    pub exited: bool,
    /// The state of the newest agent record written since the wait began.
    pub hook_state: Option<&'a str>,
}

/// The readiness one look shows (see the module docs).
pub(in crate::cli) fn assess(look: &Look<'_>) -> Readiness {
    if look.exited {
        return Readiness::Exited;
    }
    if let Some(dialog) = startup_dialog(look.screen) {
        return Readiness::Blocked(dialog);
    }
    match look.hook_state {
        Some("blocked") => Readiness::Blocked(AGENT_QUESTION),
        Some("working") => Readiness::Starting,
        Some("idle") => Readiness::Ready,
        _ if composer_visible(look.screen) => Readiness::Ready,
        _ => Readiness::Starting,
    }
}

/// Holds `ready` and `blocked` back until the screen stood still.
#[derive(Debug)]
pub(in crate::cli) struct Gate {
    settle: Duration,
    last_screen: Option<String>,
    changed_at: Instant,
}

impl Gate {
    pub(in crate::cli) fn new(settle: Duration, started: Instant) -> Self {
        Self { settle, last_screen: None, changed_at: started }
    }

    /// The final readiness once it holds; `None` while the wait goes on.
    pub(in crate::cli) fn observe(
        &mut self,
        screen_key: &str,
        readiness: Readiness,
        now: Instant,
    ) -> Option<Readiness> {
        if self.last_screen.as_deref() != Some(screen_key) {
            self.last_screen = Some(screen_key.to_owned());
            self.changed_at = now;
        }
        match readiness {
            Readiness::Exited => Some(readiness),
            Readiness::Starting => None,
            Readiness::Ready | Readiness::Blocked(_)
                if now.saturating_duration_since(self.changed_at) >= self.settle =>
            {
                Some(readiness)
            }
            Readiness::Ready | Readiness::Blocked(_) => None,
        }
    }
}

/// How a wait runs.
#[derive(Clone, Copy, Debug)]
pub(in crate::cli) struct WaitOptions {
    pub timeout: Duration,
    pub settle: Duration,
    pub poll: Duration,
    /// Agent records older than this (Unix ms) do not count.
    pub since_ms: u64,
}

impl WaitOptions {
    pub(in crate::cli) fn new(timeout: Duration, since_ms: u64) -> Self {
        Self { timeout, settle: DEFAULT_SETTLE, poll: DEFAULT_POLL, since_ms }
    }
}

/// How a wait ended: `readiness` is `None` when the timeout passed first.
#[derive(Clone, Debug, PartialEq)]
pub(in crate::cli) struct Outcome {
    pub readiness: Option<Readiness>,
    /// The last readiness seen (`starting` when nothing else was).
    pub last: Readiness,
    pub waited: Duration,
}

fn number(value: &Value) -> Option<u64> {
    value.as_u64().or_else(|| value.as_str().and_then(|text| text.parse().ok()))
}

/// The state of the newest agent record of `records` written at or after
/// `since_ms`.
pub(in crate::cli) fn fresh_hook_state(records: &Value, since_ms: u64) -> Option<&str> {
    records
        .as_array()?
        .iter()
        .filter(|record| number(&record["updated_at_ms"]).is_some_and(|ms| ms >= since_ms))
        .max_by_key(|record| number(&record["updated_at_ms"]).unwrap_or(0))
        .and_then(|record| record["state"].as_str())
}

/// The three reads of one look.
pub(in crate::cli) struct Reads {
    pub show: RequestPlan,
    pub agents: RequestPlan,
    pub screen: RequestPlan,
}

/// Looks at `terminal` until it is ready, blocked or exited, or the timeout
/// passes. `now` and `sleep` are the clock (tests pass a fake one).
pub(in crate::cli) fn wait<D, N, S>(
    daemon: &D,
    reads: &Reads,
    options: WaitOptions,
    now: &N,
    sleep: &mut S,
) -> Result<Outcome, Failure>
where
    D: Daemon + ?Sized,
    N: Fn() -> Instant + ?Sized,
    S: FnMut(Duration) + ?Sized,
{
    let started = now();
    let deadline = started + options.timeout;
    let mut gate = Gate::new(options.settle, started);
    loop {
        let terminal = daemon.request(None, reads.show.clone())?;
        // An older daemon without agent records leaves the screen to decide.
        let records = daemon.request(None, reads.agents.clone()).unwrap_or(Value::Null);
        let shown = daemon.request(None, reads.screen.clone())?;
        let screen = shown.get("text").and_then(Value::as_str).unwrap_or_default();
        let look = Look {
            screen,
            exited: terminal.get("lifecycle").is_some_and(|lifecycle| lifecycle == "exited"),
            hook_state: fresh_hook_state(&records, options.since_ms),
        };
        let last = assess(&look);
        let at = now();
        if let Some(done) = gate.observe(screen, last, at) {
            return Ok(Outcome { readiness: Some(done), last, waited: at - started });
        }
        if at >= deadline {
            return Ok(Outcome { readiness: None, last, waited: at - started });
        }
        sleep(options.poll.min(deadline.saturating_duration_since(at)));
    }
}
