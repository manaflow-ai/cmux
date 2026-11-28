//! Part of `Hub`; see `hub/mod.rs`. RFD 0158 §5: a fresh-context reviewer before "done".
//!
//! Leo, 2026-11-25: "Ok well we can't be letting important rfds like that take breaks unless I
//! put in fleet wide pauses, esp when this is stuff that materially improves the app".
//!
//! A person's prompt opens a task: its ask and the folder's `HEAD` then ([`Hub::fresh_review_note_ask`]).
//! When a turn of that task completes with a diff against that `HEAD` (commits and uncommitted
//! edits), one reviewer that shares none of the writer's context reads the ask and the diff
//! ([`brief`]) and answers `BLOCKING: <finding>` lines or `NO BLOCKING FINDINGS`. Its blocking
//! findings go back to the writer once, as a notice turn that runs only while the chat still
//! ends on the reviewed turn (`after_turn`). That turn is acpmux's own, so it opens no task and
//! its end is not reviewed again: one writer, one reviewer, no debate. A turn with no diff keeps
//! the task open for the next one.
//!
//! The reviewer is a command run in the session's folder with the brief on its stdin:
//! `agents.harnessMagic.freshReview.command` (an argv array), else `claude -p`. It runs as its
//! own process group, bounded by [`REVIEW_BOUND`]; past it, or on any failure, nothing is sent.
//! Every run logs a `fresh_review` event: its verdict, findings, time and diff size.
//!
//! Off unless `agents.harnessMagic.freshReview.enabled` is `true` (it spends a model call on
//! every reviewed task); `ACPMUX_HM_FRESHREVIEW=0` turns it off.

use super::*;
use std::collections::HashMap;
use std::io::{Seek, Write};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex as StdMutex};
use std::time::{Duration, Instant};

pub(crate) const FEATURE: &str = "freshReview";
pub(crate) const SETTING_ENABLED: &str = "agents.harnessMagic.freshReview.enabled";
const SETTING_COMMAND: &str = "agents.harnessMagic.freshReview.command";
const KILL_ENV: &str = "ACPMUX_HM_FRESHREVIEW";
/// The notice's sender, as the transcript shows it.
const SENDER: &str = "acpmux review";
/// How long a `git` read may run.
const GIT_BOUND: Duration = Duration::from_secs(10);
/// How long the reviewer may run.
pub(crate) const REVIEW_BOUND: Duration = Duration::from_secs(240);
/// The diff the brief carries, at most, in characters.
pub(crate) const MAX_DIFF_CHARS: usize = 60_000;
/// The ask the brief carries, at most, in characters.
pub(crate) const MAX_ASK_CHARS: usize = 8_000;
/// Findings sent back, at most, and each one's length.
pub(crate) const MAX_FINDINGS: usize = 8;
const MAX_FINDING_CHARS: usize = 400;
/// The line a reviewer with nothing blocking answers.
pub(crate) const CLEAN: &str = "NO BLOCKING FINDINGS";

/// A person's open task in one session: what was asked and where the folder stood.
#[derive(Clone, Debug, Default)]
struct Task {
    ask: String,
    cwd: PathBuf,
    /// The folder's `HEAD` when the task opened; `None` until read (or no git there).
    base: Option<String>,
}

static TASKS: LazyLock<StdMutex<HashMap<String, Task>>> = LazyLock::new(Default::default);

fn tasks() -> std::sync::MutexGuard<'static, HashMap<String, Task>> {
    TASKS.lock().unwrap_or_else(|e| e.into_inner())
}

/// Whether the feature is on: the kill switch, then the settings key (off unless `true`).
pub(crate) fn enabled_with(doc: Option<&Value>, env: Option<&str>) -> bool {
    if env.is_some_and(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "0" | "false" | "off"))
    {
        return false;
    }
    doc.and_then(|d| crate::user_settings::value(d, SETTING_ENABLED))
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
}

fn settings_doc() -> Option<Value> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    }
}

pub(crate) fn enabled() -> bool {
    enabled_with(settings_doc().as_ref(), std::env::var(KILL_ENV).ok().as_deref())
}

/// The reviewer's argv: the setting's non-empty string array, else `claude -p`.
pub(crate) fn command_with(doc: Option<&Value>) -> Vec<String> {
    let named: Option<Vec<String>> = doc
        .and_then(|d| crate::user_settings::value(d, SETTING_COMMAND))
        .and_then(|v| v.as_array().cloned())
        .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect());
    match named {
        Some(argv) if argv.first().is_some_and(|a| !a.trim().is_empty()) => argv,
        _ => vec!["claude".into(), "-p".into(), "--output-format".into(), "text".into()],
    }
}

/// `s` cut to at most `max` characters, on a character boundary, marked when cut.
pub(crate) fn cap(s: &str, max: usize) -> String {
    match s.char_indices().nth(max) {
        None => s.to_owned(),
        Some((at, _)) => format!("{}\n[... cut at {max} characters]", s.get(..at).unwrap_or(s)),
    }
}

/// What the reviewer reads: the ask and the diff, and nothing of the writer's context.
pub(crate) fn brief(ask: &str, diff: &str) -> String {
    format!(
        "You review a change another agent made. You did not write it and see none of its \
         reasoning: only what was asked and the diff.\n\
         Report only blocking problems: a bug, data loss, a security hole, the ask not done, or a \
         change that breaks something else. Not style, naming or taste.\n\
         Answer one line per problem, `BLOCKING: <file:line> <what is wrong and why>`, or the one \
         line `{CLEAN}`. No other text.\n\n\
         ## What was asked\n{}\n\n## The diff\n```diff\n{}\n```\n",
        cap(ask.trim(), MAX_ASK_CHARS),
        cap(diff, MAX_DIFF_CHARS),
    )
}

/// The reviewer's blocking findings: its `BLOCKING:` lines (a list marker or emphasis before it
/// is fine), each capped, at most [`MAX_FINDINGS`]. `None` when the answer says neither that
/// nor [`CLEAN`]: an answer it cannot read sends nothing.
pub(crate) fn findings(output: &str) -> Option<Vec<String>> {
    let mut out = Vec::new();
    let mut clean = false;
    for line in output.lines() {
        let t = line.trim().trim_start_matches(['-', '*', '_', '•', ' ', '`']).trim_start();
        let upper = t.to_ascii_uppercase();
        // `BLOCKING:`, also bolded or quoted (`**BLOCKING:**`, `**BLOCKING**:`): the markup is
        // not part of the finding.
        let marked = upper.strip_prefix("BLOCKING").and_then(|after| {
            let after = after.trim_start_matches(['*', '_', '`']);
            after.strip_prefix(':').and_then(|rest| t.get(t.len().saturating_sub(rest.len())..))
        });
        if let Some(rest) = marked {
            let rest = rest.trim().trim_matches(['*', '_', '`']).trim();
            if !rest.is_empty() && out.len() < MAX_FINDINGS {
                out.push(cap(rest, MAX_FINDING_CHARS));
            }
        } else if upper.trim_end_matches(['.', '`', '*']).trim() == CLEAN {
            clean = true;
        }
    }
    (clean || !out.is_empty()).then_some(out)
}

/// The text the writer gets back.
pub(crate) fn steer_text(found: &[String]) -> String {
    let mut text = String::from(
        "A reviewer with none of your context read the ask and your diff and found these \
         blocking problems. Fix the real ones; say plainly why any is wrong.\n",
    );
    for f in found {
        text.push_str("- ");
        text.push_str(f);
        text.push('\n');
    }
    text
}

struct Ran {
    ok: bool,
    text: String,
    slow: bool,
}

/// `argv` in `dir`, `stdin` on its stdin, its output in a file, as its own process group killed
/// past `bound`.
fn run_blocking(dir: &Path, argv: &[String], stdin: &str, bound: Duration) -> Option<Ran> {
    let (prog, args) = argv.split_first()?;
    let mut input = tempfile::tempfile().ok()?;
    input.write_all(stdin.as_bytes()).ok()?;
    input.rewind().ok()?;
    let out = tempfile::NamedTempFile::new().ok()?;
    let mut child = cmux_process::Command::new(prog)
        .args(args)
        .current_dir(dir)
        .env("NO_COLOR", "1")
        .env(KILL_ENV, "0")
        .stdin(input)
        .stdout(out.reopen().ok()?)
        .stderr(cmux_process::Stdio::null())
        .process_group(0)
        .spawn()
        .ok()?;
    match child.wait_timeout(bound) {
        Ok(Some(status)) => {
            let text = String::from_utf8_lossy(&std::fs::read(out.path()).ok()?).into_owned();
            Some(Ran { ok: status.success(), text, slow: false })
        }
        Ok(None) => {
            #[cfg(unix)]
            if let Some(group) = i32::try_from(child.id()).ok().and_then(i32::checked_neg) {
                // SAFETY: signals the process group this call made (`process_group(0)`); its pid
                // is not reaped yet, so the id is still this run's.
                unsafe { libc::kill(group, libc::SIGKILL) };
            }
            #[cfg(not(unix))]
            let _ = child.kill();
            let _ = child.wait();
            Some(Ran { ok: false, text: String::new(), slow: true })
        }
        Err(_) => None,
    }
}

async fn run(dir: &Path, argv: Vec<String>, stdin: String, bound: Duration) -> Option<Ran> {
    let dir = dir.to_path_buf();
    tokio::task::spawn_blocking(move || run_blocking(&dir, &argv, &stdin, bound)).await.ok()?
}

fn git(args: &[&str]) -> Vec<String> {
    std::iter::once("git").chain(args.iter().copied()).map(str::to_owned).collect()
}

/// The folder's `HEAD`, or `None` outside a repository.
async fn head(dir: &Path) -> Option<String> {
    let ran = run(dir, git(&["rev-parse", "--verify", "HEAD"]), String::new(), GIT_BOUND).await?;
    let sha = ran.text.trim().to_owned();
    (ran.ok && sha.len() >= 40 && sha.chars().all(|c| c.is_ascii_hexdigit())).then_some(sha)
}

impl Hub {
    /// A person's prompt to `session`: it opens a task (or adds to the open one) whose turn ends
    /// are reviewed. Read before the prompt runs, so the base is the folder before its edits.
    pub(super) fn fresh_review_note_ask(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: &[Value],
    ) {
        if !enabled() {
            return;
        }
        let ask = prompt_text(blocks);
        if ask.trim().is_empty() {
            return;
        }
        let cwd = session.meta().cwd;
        let fresh = {
            let mut all = tasks();
            match all.get_mut(&session.id) {
                Some(t) => {
                    t.ask = cap(&format!("{}\n\n{}", t.ask, ask.trim()), MAX_ASK_CHARS);
                    false
                }
                None => {
                    all.insert(
                        session.id.clone(),
                        Task { ask: cap(ask.trim(), MAX_ASK_CHARS), cwd: cwd.clone(), base: None },
                    );
                    true
                }
            }
        };
        if !fresh || tokio::runtime::Handle::try_current().is_err() {
            return;
        }
        let id = session.id.clone();
        self.scope.spawn_named("fresh-review-base", async move {
            let base = head(&cwd).await;
            if let Some(t) = tasks().get_mut(&id) {
                t.base = base;
            }
        });
    }

    /// `turn_id` of `session` completed: the open task's diff, reviewed once when there is one.
    pub(super) fn fresh_review_turn_end(self: &Arc<Self>, session: &Arc<Session>, turn_id: &str) {
        if !enabled() || tokio::runtime::Handle::try_current().is_err() {
            return;
        }
        let Some(task) = tasks().get(&session.id).filter(|t| t.base.is_some()).cloned() else {
            return;
        };
        let (hub, session, turn_id) = (Arc::clone(self), Arc::clone(session), turn_id.to_owned());
        self.scope.spawn_named("fresh-review", async move {
            hub.fresh_review_run(&session, &turn_id, task).await;
        });
    }

    async fn fresh_review_run(self: &Arc<Self>, session: &Arc<Session>, turn_id: &str, task: Task) {
        let Some(base) = task.base.as_deref() else { return };
        let diff = match run(
            &task.cwd,
            git(&["diff", "--no-color", base]),
            String::new(),
            GIT_BOUND,
        )
        .await
        {
            Some(r) if r.ok => r.text,
            _ => return,
        };
        if diff.trim().is_empty() {
            // Nothing changed yet: the task stays open for its next turn.
            return;
        }
        // Reviewed now: the next person's prompt opens a new task.
        tasks().remove(&session.id);
        let argv = command_with(settings_doc().as_ref());
        let started = Instant::now();
        let ran = run(&task.cwd, argv, brief(&task.ask, &diff), REVIEW_BOUND).await;
        let ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
        let (verdict, found) = match &ran {
            None => ("failed", Vec::new()),
            Some(r) if r.slow => ("slow", Vec::new()),
            Some(r) if !r.ok => ("failed", Vec::new()),
            Some(r) => match findings(&r.text) {
                None => ("unread", Vec::new()),
                Some(f) if f.is_empty() => ("clean", f),
                Some(f) => ("blocking", f),
            },
        };
        self.append(
            session,
            "mux",
            "fresh_review",
            json!({
                "turnId": turn_id, "verdict": verdict, "findings": found, "ms": ms,
                "diffChars": diff.chars().count(),
            }),
        );
        if found.is_empty() {
            return;
        }
        let notice =
            json!({"sender": SENDER, "severity": "warn", "title": "Blocking review findings"});
        let text = crate::prompt_provenance::notice_text(&notice, &steer_text(&found));
        let opts = PromptOptions {
            prompt_id: Some(format!("fresh-review-{}", uuid::Uuid::now_v7())),
            provenance: Some(crate::prompt_provenance::notice(&notice, &session.id)),
            agent: Some(SENDER.to_owned()),
            class: Some(crate::prompt_class::PromptClass::Block),
            after_turn: Some(turn_id.to_owned()),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": text})];
        if let Err(e) = self.prompt_with(session, blocks, "acpmux", false, opts).await {
            tracing::info!(session = %session.id, error = ?e, "fresh review findings not sent");
        }
    }
}

#[cfg(test)]
#[path = "fresh_review_tests.rs"]
mod tests;
