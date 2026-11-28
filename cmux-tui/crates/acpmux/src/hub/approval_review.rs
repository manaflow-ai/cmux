//! Auto-review of permission prompts (RFD 0158 §14): a cheap model answers a routine permission
//! prompt, and only the uncertain ones reach a person.
//!
//! First piece: the hub asks a cheap model (`claude -p --model haiku` by default) about a prompt
//! that would otherwise go to the person, under a policy that asks (ask, approve-reads,
//! approve-edits). The model's only power is to allow once: a clear `ALLOW` answers the prompt
//! with `allow_once`; anything else (`ASK`, no answer, an error, past [`BOUND`]) leaves the prompt
//! to the person, as before. It never denies, never answers allow-always, and never answers a
//! question, an external request, a Web turn, what a rule decided (an `ask` rule included), or
//! a review chat's prompt (review denies at once instead).
//!
//! A trust policy change: off unless `agents.harnessMagic.approvalReview.enabled` is `true`
//! (default-on waits on Leo's list); `ACPMUX_HM_APPROVALREVIEW` `0` turns it off and `1` on,
//! over the setting. The command is `agents.harnessMagic.approvalReview.command` (an argv array).
//! Each verdict is written on the prompt's record (`autoReview`: verdict and ms) and counted
//! ([`counts`]), so its gain and its cost can be read once it is on.

use cmux_process::{Command, Stdio};
use std::io::{Seek, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::config::PermissionPolicy;

/// The harness-magic feature name.
pub(crate) const FEATURE: &str = "approvalReview";
/// The setting that turns it on (off unless `true`).
pub(crate) const SETTING_ENABLED: &str = "agents.harnessMagic.approvalReview.enabled";
/// The setting naming the reviewer's argv.
pub(crate) const SETTING_COMMAND: &str = "agents.harnessMagic.approvalReview.command";
/// The daemon's switch, over the setting.
pub(crate) const KILL_ENV: &str = "ACPMUX_HM_APPROVALREVIEW";
/// How long a verdict may take; past it the prompt goes to the person.
pub(crate) const BOUND: Duration = Duration::from_secs(25);
/// The longest tool input the brief carries, in bytes.
const INPUT_CAP: usize = 6000;
/// The longest title the brief carries, in bytes.
const TITLE_CAP: usize = 500;

/// The model's verdict on one prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Verdict {
    /// Routine: answered `allow_once`.
    Allow,
    /// Uncertain, or no clear answer: the person decides.
    Ask,
}

impl Verdict {
    fn as_str(self) -> &'static str {
        match self {
            Verdict::Allow => "allow",
            Verdict::Ask => "ask",
        }
    }
}

/// One review: its verdict and how long it took.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Review {
    pub verdict: Verdict,
    pub ms: u64,
}

impl Review {
    /// The `autoReview` object on the prompt's record.
    pub(crate) fn record(&self) -> Value {
        json!({"verdict": self.verdict.as_str(), "ms": self.ms})
    }
}

static REVIEWED: AtomicU64 = AtomicU64::new(0);
static ALLOWED: AtomicU64 = AtomicU64::new(0);
static TO_PERSON: AtomicU64 = AtomicU64::new(0);
static MS_TOTAL: AtomicU64 = AtomicU64::new(0);

/// This daemon's counts so far: reviewed, allowed, sent to the person, total ms.
pub(crate) fn counts() -> Value {
    json!({
        "reviewed": REVIEWED.load(Ordering::Relaxed),
        "allowed": ALLOWED.load(Ordering::Relaxed),
        "toPerson": TO_PERSON.load(Ordering::Relaxed),
        "msTotal": MS_TOTAL.load(Ordering::Relaxed),
    })
}

/// Whether the feature is on for `doc` and the switch's value `env`.
pub(crate) fn enabled_with(doc: Option<&Value>, env: Option<&str>) -> bool {
    match env.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
        Some("0" | "false" | "off" | "no") => return false,
        Some("1" | "true" | "on" | "yes") => return true,
        _ => {}
    }
    doc.and_then(|d| crate::user_settings::value(d, SETTING_ENABLED)).and_then(|v| v.as_bool())
        == Some(true)
}

fn settings() -> Option<Value> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    }
}

/// Whether the feature is on now.
pub(crate) fn enabled() -> bool {
    enabled_with(settings().as_ref(), std::env::var(KILL_ENV).ok().as_deref())
}

/// The reviewer's argv from `doc`, else a cheap model's.
pub(crate) fn command_with(doc: Option<&Value>) -> Vec<String> {
    let named: Option<Vec<String>> =
        doc.and_then(|d| crate::user_settings::value(d, SETTING_COMMAND)).and_then(|v| {
            v.as_array().map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        });
    match named {
        Some(argv) if !argv.is_empty() => argv,
        _ => ["claude", "-p", "--model", "haiku", "--output-format", "text"]
            .iter()
            .map(|s| (*s).to_owned())
            .collect(),
    }
}

/// Whether a prompt under `policy` is one the reviewer may look at: one the policy leaves to the
/// person (`policy_answered` false), no rule decided, not a question or external request.
pub(crate) fn eligible(
    policy: PermissionPolicy,
    rule_decided: bool,
    policy_answered: bool,
    needs_person: bool,
) -> bool {
    matches!(
        policy,
        PermissionPolicy::Ask | PermissionPolicy::ApproveReads | PermissionPolicy::ApproveEdits
    ) && !rule_decided
        && !policy_answered
        && !needs_person
}

/// Whether `policy` answers a prompt of `kind` with no person (the policy table in
/// `permissions.rs`, without the shell-reads probe, which is judged apart).
pub(crate) fn policy_answers(policy: PermissionPolicy, kind: &str) -> bool {
    match policy {
        PermissionPolicy::ApproveAll | PermissionPolicy::DenyAll => true,
        PermissionPolicy::ApproveReads | PermissionPolicy::Review => {
            matches!(kind, "read" | "search" | "fetch" | "think")
        }
        PermissionPolicy::ApproveEdits => {
            matches!(kind, "read" | "search" | "fetch" | "think" | "edit")
        }
        PermissionPolicy::Ask => false,
    }
}

/// Whether `request` offers `allow_once` (the only answer the reviewer gives).
pub(crate) fn offers_allow_once(request: &Value) -> bool {
    request.get("options").and_then(Value::as_array).is_some_and(|o| {
        o.iter().any(|o| o.get("kind").and_then(Value::as_str) == Some("allow_once"))
    })
}

/// `text`, cut to at most `max` bytes on a character boundary.
fn cap(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_owned();
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{} …(cut)", &text[..end])
}

/// The reviewer's brief for `request`, run in `cwd`.
pub(crate) fn brief(request: &Value, cwd: &Path) -> String {
    let cwd = cwd.display();
    let call = request.get("toolCall").cloned().unwrap_or(Value::Null);
    let title = cap(call.get("title").and_then(Value::as_str).unwrap_or(""), TITLE_CAP);
    let kind = call.get("kind").and_then(Value::as_str).unwrap_or("");
    let tool = call.pointer("/_meta/claude/tool").and_then(Value::as_str).unwrap_or("");
    let input = cap(&call.get("rawInput").map(Value::to_string).unwrap_or_default(), INPUT_CAP);
    format!(
        "You review one permission prompt from a coding agent working in {cwd}.\n\
         Answer ALLOW only when the call is routine for a coding agent in that project and \
         clearly safe: it reads, builds, tests, formats or edits files inside the project, and \
         nothing it does is destructive, leaves the project, sends data to an outside service, \
         changes credentials, git history or remote state, or installs software. Answer ASK \
         for anything else, and whenever you are unsure.\n\
         Reply with exactly one word, ALLOW or ASK.\n\n\
         tool: {tool}\nkind: {kind}\ntitle: {title}\ninput: {input}\n"
    )
}

/// The verdict in the reviewer's `text`: `Allow` only when its last non-empty line is exactly
/// `ALLOW` (case and a trailing period aside); anything else is `Ask`.
pub(crate) fn parse(text: &str) -> Verdict {
    let last = text.lines().map(str::trim).rfind(|l| !l.is_empty()).unwrap_or("");
    let word = last.trim_matches(|c: char| c == '.' || c == '*' || c == '`').trim();
    if word.eq_ignore_ascii_case("allow") { Verdict::Allow } else { Verdict::Ask }
}

/// Runs `argv` with `stdin` in `dir`, bounded by `bound`: its stdout, or `None` (failed, slow).
fn run_blocking(dir: &Path, argv: &[String], stdin: &str, bound: Duration) -> Option<String> {
    let (prog, args) = argv.split_first()?;
    let mut input = tempfile::tempfile().ok()?;
    input.write_all(stdin.as_bytes()).ok()?;
    input.rewind().ok()?;
    let out = tempfile::NamedTempFile::new().ok()?;
    let mut cmd = Command::new(prog);
    cmd.args(args)
        .env("NO_COLOR", "1")
        // The reviewer's own prompts are never reviewed.
        .env(KILL_ENV, "0")
        .stdin(input)
        .stdout(out.reopen().ok()?)
        .stderr(Stdio::null())
        .process_group(0);
    if dir.is_dir() {
        cmd.current_dir(dir);
    }
    let mut child = cmd.spawn().ok()?;
    match child.wait_timeout(bound) {
        Ok(Some(status)) if status.success() => {
            Some(String::from_utf8_lossy(&std::fs::read(out.path()).ok()?).into_owned())
        }
        Ok(Some(_)) | Err(_) => None,
        Ok(None) => {
            // SAFETY: signals the process group this call made (`process_group(0)`); its pid is
            // not reaped yet, so the id is still this run's.
            #[cfg(unix)]
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL)
            };
            #[cfg(not(unix))]
            let _ = child.kill();
            let _ = child.wait();
            None
        }
    }
}

/// Reviews `request` (run in `cwd`) with `argv`: the verdict, counted.
pub(crate) async fn review_with(argv: Vec<String>, request: &Value, cwd: &Path) -> Review {
    let stdin = brief(request, cwd);
    let dir = cwd.to_path_buf();
    let start = Instant::now();
    let text = tokio::task::spawn_blocking(move || run_blocking(&dir, &argv, &stdin, BOUND))
        .await
        .ok()
        .flatten();
    let verdict = text.as_deref().map_or(Verdict::Ask, parse);
    let ms = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
    REVIEWED.fetch_add(1, Ordering::Relaxed);
    MS_TOTAL.fetch_add(ms, Ordering::Relaxed);
    match verdict {
        Verdict::Allow => ALLOWED.fetch_add(1, Ordering::Relaxed),
        Verdict::Ask => TO_PERSON.fetch_add(1, Ordering::Relaxed),
    };
    tracing::info!(verdict = verdict.as_str(), ms, "approvalReview judged a permission prompt");
    Review { verdict, ms }
}

/// Reviews `request` (run in `cwd`) with the configured command.
pub(crate) async fn review(request: &Value, cwd: &Path) -> Review {
    review_with(command_with(settings().as_ref()), request, cwd).await
}
