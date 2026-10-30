//! A Chief's live run frames on the local conversation owner (`chief-live-v1`,
//! the "Live frames" contract shared with the Cloud brain): while its run is
//! running, the Chief streams its reply's and thought's text (`step.delta`)
//! and a compact "working on" line (`run.activity`). The owner keeps the text
//! so far in memory only, so a page that joins or reconnects mid-run reads it
//! (`run.live`); the run's end frees it. Never stored: not a message, not a
//! run step, not in a snapshot of the log.

use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::conversation_store::runs::{RunRejected, valid_key};
use cmux_json::JsonSet as _;

/// `conversation-live-publish`, `conversation-live` and the
/// `conversation-live` event on `subscribe` for a connection that echoes
/// this capability in `set-client-info`.
pub const CHIEF_LIVE_CAPABILITY: &str = "chief-live-v1";

/// Most characters of one `step.delta`.
pub(crate) const MAX_DELTA_CHARS: usize = 4096;
/// Most characters of a "working on" line.
pub(crate) const MAX_LINE_CHARS: usize = 80;
/// Most bytes of one step's text the owner keeps (the tail).
pub(crate) const MAX_STEP_BYTES: usize = 64 * 1024;
/// Most streamed steps of one run the owner keeps.
pub(crate) const MAX_RUN_STEPS: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum LiveKind {
    Talk,
    Thought,
}

impl LiveKind {
    const fn name(self) -> &'static str {
        match self {
            Self::Talk => "talk",
            Self::Thought => "thought",
        }
    }
}

/// One frame a Chief publishes.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "type", deny_unknown_fields)]
pub(crate) enum LiveFrame {
    /// Text appended to a talk or thought step; `final` ends the step (its
    /// step row with the whole text follows on the run).
    #[serde(rename = "step.delta")]
    StepDelta {
        conversation: String,
        run: String,
        step: String,
        kind: LiveKind,
        seq: u64,
        text: String,
        #[serde(default, rename = "final")]
        last: Option<bool>,
        /// Ignored: the owner stamps the run's agent.
        #[serde(default)]
        author: Option<String>,
        /// The Cloud socket's frame key (= `type`); ignored, the owner sets it.
        #[serde(default)]
        t: Option<String>,
    },
    /// What the run works on now: the newest wins, the run's end clears it.
    #[serde(rename = "run.activity")]
    RunActivity {
        conversation: String,
        run: String,
        line: String,
        since: u64,
        at: u64,
        /// Ignored: the owner stamps the run's agent.
        #[serde(default)]
        author: Option<String>,
        /// The Cloud socket's frame key (= `type`); ignored, the owner sets it.
        #[serde(default)]
        t: Option<String>,
    },
}

fn invalid() -> anyhow::Error {
    RunRejected("invalid_live").into()
}

impl LiveFrame {
    pub(crate) fn run(&self) -> &str {
        match self {
            Self::StepDelta { run, .. } | Self::RunActivity { run, .. } => run,
        }
    }

    /// The frame's own checks: its conversation, keys, text and line.
    pub(crate) fn validate(&self, conversation: &str) -> anyhow::Result<()> {
        let ok = match self {
            Self::StepDelta { conversation: of, run, step, text, .. } => {
                of == conversation
                    && valid_key(run)
                    && valid_key(step)
                    && (1..=MAX_DELTA_CHARS).contains(&text.chars().count())
            }
            Self::RunActivity { conversation: of, run, line, since, at, .. } => {
                of == conversation
                    && valid_key(run)
                    && (1..=MAX_LINE_CHARS).contains(&line.chars().count())
                    && !line.chars().any(char::is_control)
                    && !line.trim().is_empty()
                    && since <= at
            }
        };
        if ok { Ok(()) } else { Err(invalid()) }
    }

    /// The frame as every client receives it, with its run's agent.
    pub(crate) fn wire(&self, author: &str) -> Value {
        match self {
            Self::StepDelta { conversation, run, step, kind, seq, text, last, .. } => {
                let mut value = json!({
                    "type": "step.delta",
                    "t": "step.delta",
                    "conversation": conversation,
                    "run": run,
                    "author": author,
                    "step": step,
                    "kind": kind.name(),
                    "seq": seq,
                    "text": text,
                });
                if *last == Some(true) {
                    value.set("final", json!(true));
                }
                value
            }
            Self::RunActivity { conversation, run, line, since, at, .. } => json!({
                "type": "run.activity",
                "t": "run.activity",
                "conversation": conversation,
                "run": run,
                "author": author,
                "line": line,
                "since": since,
                "at": at,
            }),
        }
    }
}

#[derive(Debug)]
struct LiveStep {
    step: String,
    kind: LiveKind,
    seq: u64,
    text: String,
    ended: bool,
}

#[derive(Debug)]
struct Activity {
    line: String,
    since: u64,
    at: u64,
}

#[derive(Debug)]
struct LiveRun {
    /// The run's agent (stamped on every frame and snapshot entry: Cloud run
    /// ids repeat across Chiefs, so clients key live state by author too).
    author: String,
    steps: Vec<LiveStep>,
    activity: Option<Activity>,
    /// Steps whose row was written after their last frame: freed, and any
    /// later frame of them is refused (a late frame never reopens the text).
    freed: BTreeSet<String>,
    /// The last frame (a run that stopped streaming goes after [`STALE_LIVE`]).
    touched: Instant,
}

/// A running run whose agent sent no frame for this long is dropped from the
/// buffer (a Chief that crashed leaves its run `running`).
pub(crate) const STALE_LIVE: Duration = Duration::from_secs(30 * 60);
/// Most streaming runs one conversation keeps (the least recent goes first).
pub(crate) const MAX_CONVERSATION_RUNS: usize = 16;

/// What an accepted frame does.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Applied {
    /// Send the frame to the clients.
    Frame,
    /// A step began again at `seq` 0 (its producer retried): its text was
    /// replaced, and the clients get the conversation's `run.live` instead.
    Reset,
}

/// The text so far of every running run that streamed, by conversation and
/// run (memory only).
#[derive(Debug, Default)]
pub(crate) struct LiveBuffers {
    runs: BTreeMap<(String, String), LiveRun>,
}

impl LiveBuffers {
    /// Applies a validated frame of `author`'s running run: a delta follows
    /// its step's last frame (`seq` +1, from 0) and comes before the step's
    /// end; `seq` 0 on a streaming step starts it again ([`Applied::Reset`]).
    pub(crate) fn apply(
        &mut self,
        conversation: &str,
        author: &str,
        frame: &LiveFrame,
        now: Instant,
    ) -> anyhow::Result<Applied> {
        self.runs.retain(|_, run| now.saturating_duration_since(run.touched) < STALE_LIVE);
        let key = (conversation.to_owned(), frame.run().to_owned());
        if !self.runs.contains_key(&key) {
            let mut held: Vec<_> =
                self.runs.iter().filter(|((of, _), _)| of == conversation).collect();
            if held.len() >= MAX_CONVERSATION_RUNS {
                held.sort_by_key(|(_, run)| run.touched);
                let oldest = held[0].0.clone();
                self.runs.remove(&oldest);
            }
        }
        let (applied, empty) = {
            let run = self.runs.entry(key.clone()).or_insert_with(|| LiveRun {
                author: author.to_owned(),
                steps: Vec::new(),
                activity: None,
                freed: BTreeSet::new(),
                touched: now,
            });
            let applied = apply_to(run, frame);
            if applied.is_ok() {
                run.touched = now;
            }
            (applied, run.steps.is_empty() && run.activity.is_none() && run.freed.is_empty())
        };
        // A refused first frame leaves no empty run behind.
        if empty {
            self.runs.remove(&key);
        }
        applied
    }

    /// The run ended: its live text goes.
    pub(crate) fn end(&mut self, conversation: &str, run: &str) {
        self.runs.remove(&(conversation.to_owned(), run.to_owned()));
    }

    /// The run's rows of these talk and thought steps were written: a step
    /// whose stream ended (`final`) is freed, and later frames of it are refused.
    pub(crate) fn rows_written(&mut self, conversation: &str, run: &str, steps: &[String]) {
        let Some(live) = self.runs.get_mut(&(conversation.to_owned(), run.to_owned())) else {
            return;
        };
        for id in steps {
            if let Some(index) = live.steps.iter().position(|step| step.step == *id && step.ended) {
                live.steps.remove(index);
                live.freed.insert(id.clone());
            }
        }
    }

    /// The runs of `conversation` that streamed.
    pub(crate) fn runs_of(&self, conversation: &str) -> Vec<String> {
        self.runs.keys().filter(|(of, _)| of == conversation).map(|(_, run)| run.clone()).collect()
    }

    /// The `run.live` snapshot of `conversation`: of `listed` (the runs asked
    /// about), those still running (`running`), by run id; the text of a
    /// listed run that is not running goes.
    pub(crate) fn snapshot(
        &mut self,
        conversation: &str,
        listed: &[String],
        running: &BTreeSet<String>,
    ) -> Value {
        self.runs.retain(|(of, run), _| {
            of != conversation || !listed.contains(run) || running.contains(run)
        });
        let runs: Vec<Value> = self
            .runs
            .iter()
            .filter(|((of, run), _)| of == conversation && running.contains(run))
            .map(|((_, run), live)| {
                let steps: Vec<Value> = live
                    .steps
                    .iter()
                    .map(|step| {
                        let mut value = json!({
                            "step": step.step,
                            "kind": step.kind.name(),
                            "seq": step.seq,
                            "text": step.text,
                        });
                        if step.ended {
                            value.set("final", json!(true));
                        }
                        value
                    })
                    .collect();
                let mut value = json!({"run": run, "author": live.author, "steps": steps});
                if let Some(activity) = &live.activity {
                    value.set(
                        "activity",
                        json!({
                            "line": activity.line,
                            "since": activity.since,
                            "at": activity.at,
                        }),
                    );
                }
                value
            })
            .collect();
        json!({"type": "run.live", "t": "run.live", "conversation": conversation, "runs": runs})
    }
}

fn apply_to(run: &mut LiveRun, frame: &LiveFrame) -> anyhow::Result<Applied> {
    match frame {
        LiveFrame::StepDelta { step, kind, seq, text, last, .. } => {
            if run.freed.contains(step) {
                return Err(RunRejected("step_final").into());
            }
            let ended = *last == Some(true);
            match run.steps.iter().position(|live| live.step == *step) {
                None => {
                    if *seq != 0 {
                        return Err(RunRejected("seq_gap").into());
                    }
                    if run.steps.len() >= MAX_RUN_STEPS {
                        return Err(RunRejected("too_many_live_steps").into());
                    }
                    run.steps.push(LiveStep {
                        step: step.clone(),
                        kind: *kind,
                        seq: 0,
                        text: text.clone(),
                        ended,
                    });
                    Ok(Applied::Frame)
                }
                Some(index) => {
                    let live = &mut run.steps[index];
                    if live.ended {
                        return Err(RunRejected("step_final").into());
                    }
                    if live.kind != *kind {
                        return Err(invalid());
                    }
                    if *seq == 0 {
                        live.seq = 0;
                        live.text = text.clone();
                        live.ended = ended;
                        return Ok(Applied::Reset);
                    }
                    if *seq != live.seq + 1 {
                        return Err(RunRejected("seq_gap").into());
                    }
                    live.seq = *seq;
                    live.text.push_str(text);
                    live.ended = ended;
                    keep_tail(&mut live.text);
                    Ok(Applied::Frame)
                }
            }
        }
        LiveFrame::RunActivity { line, since, at, .. } => {
            run.activity = Some(Activity { line: line.clone(), since: *since, at: *at });
            Ok(Applied::Frame)
        }
    }
}

/// Keeps the last [`MAX_STEP_BYTES`] of `text`, cut at a character boundary.
fn keep_tail(text: &mut String) {
    if text.len() <= MAX_STEP_BYTES {
        return;
    }
    let mut cut = text.len() - MAX_STEP_BYTES;
    while !text.is_char_boundary(cut) {
        cut += 1;
    }
    text.drain(..cut);
}
