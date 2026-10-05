//! One turn (section 7): a fresh acpmux session in the constant session
//! directory, the prompt `[view, new messages]`, and everything the session
//! does folded into the log as it happens. The brain has already settled the
//! view, rendered it and logged the new messages; this runs on its own thread
//! so the brain keeps reading the conversation while the turn works.

use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{RecvTimeoutError, Sender, TryRecvError, channel};
use std::time::{Duration, Instant};

use optchat_host::OptChat;
use serde_json::Value;

use crate::acpmux::{AgentPort, SessionSpec, TurnSignal};
use crate::fold::{Entry, TurnFold, Usage, answer_usage, is_cancelled, stop_error};

/// How often a stop for a newer message is sent again while the turn has
/// not ended: a `session/cancel` that reaches acpmux before the prompt does
/// is lost (audit round 2), and nothing acknowledges it but the turn's end.
pub const CANCEL_RESEND: Duration = Duration::from_secs(1);

/// How long a turn whose `turn_end` is folded waits for the prompt's answer,
/// which acpmux sends after it and which alone carries the token use.
pub const ANSWER_WAIT: Duration = Duration::from_secs(10);

/// A human message arrived during the turn (decision 2026-10-04: interrupt
/// at once, even mid-thinking; a running tool call finishes first). The
/// brain requests it; the turn's runner acts on it.
#[derive(Default)]
pub struct Interrupt {
    wanted: AtomicBool,
    /// The running acpmux turn's signals, woken on a request.
    wake: Mutex<Option<Sender<TurnSignal>>>,
}

impl Interrupt {
    pub fn new() -> Interrupt {
        Interrupt::default()
    }

    pub fn request(&self) {
        self.wanted.store(true, Ordering::SeqCst);
        if let Some(tx) = self.wake.lock().expect("wake").as_ref() {
            let _ = tx.send(TurnSignal::Changed);
        }
    }

    pub fn is_set(&self) -> bool {
        self.wanted.load(Ordering::SeqCst)
    }

    /// The queued messages were delivered (native engine).
    pub fn clear(&self) {
        self.wanted.store(false, Ordering::SeqCst);
    }

    fn wake_with(&self, tx: Option<Sender<TurnSignal>>) {
        *self.wake.lock().expect("wake") = tx;
    }
}

/// Everything a turn needs, decided by the brain.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TurnStart {
    /// The reply's idempotency key: `turn:optchat:<first new message id>`.
    pub key: String,
    /// The acpmux promptId (acpmux runs one id once).
    pub prompt_id: String,
    pub session: SessionSpec,
    /// The view pieces, then the new messages (prompt::turn_blocks), or the
    /// cached layout's blocks (prompt::cached_layout).
    pub blocks: Vec<Value>,
    /// The cached layout (Claude harnesses): the text the session's preset
    /// (`session.preset`) gets as its system prompt before the session
    /// starts. None: the session starts with what its preset holds.
    pub system_prompt: Option<String>,
    /// Longest a turn may run; past it the session is removed and the turn
    /// fails, so a turn that hangs in the harness cannot block every later
    /// message. None: no limit.
    pub limit: Option<Duration>,
}

/// A turn session that kept running after its acpmux connection was lost:
/// its later events are folded into the log, and it is removed, once acpmux
/// is back (section 7: everything the agent does is logged).
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Orphan {
    pub session: String,
    /// The last event seq already folded.
    pub after: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TurnOutcome {
    /// The turn's final assistant text.
    pub reply: Option<String>,
    pub error: Option<String>,
    pub orphan: Option<Orphan>,
    /// The turn ended with stop reason `cancelled` (stopped for a newer message).
    pub cancelled: bool,
}

/// Runs the turn to its end; never panics on a port failure (it becomes the
/// outcome's error, and the brain posts it). `progress` hears the session id
/// once it exists and the fold position after each fetch that moved it.
pub fn run(
    agents: &dyn AgentPort,
    chat: &OptChat,
    start: &TurnStart,
    interrupt: &Interrupt,
    log: &dyn Fn(&str),
    progress: &dyn Fn(&str, u64),
) -> TurnOutcome {
    // The limit covers the session's start too: a harness that never
    // initializes must not hold the turn (and every later message) forever.
    let deadline = start.limit.map(|limit| Instant::now() + limit);
    let mut fold = TurnFold::new();
    let append = |entries: Vec<Entry>| {
        for entry in entries {
            if let Err(e) = chat.append(entry.kind, &entry.text) {
                log(&format!(
                    "logging a {} entry failed: {e}",
                    entry.kind.as_str()
                ));
            }
        }
    };
    // A session of this name is left from a host that stopped mid-turn.
    if let Ok(Some(old)) = agents.find(&start.session.name) {
        let _ = agents.end_session(&old);
    }
    // The cached layout: the stable prefix (system text and view head) is
    // the preset's system prompt, which acpmux writes into its own preset
    // directory and checks by sha256 when the session starts.
    if let Some(text) = &start.system_prompt {
        let set = match &start.session.preset {
            Some(preset) => agents.set_system_prompt(preset, text),
            None => Err("the cached layout needs the turn preset".to_owned()),
        };
        if let Err(e) = set {
            return TurnOutcome {
                error: Some(format!("setting the turn's system prompt: {e}")),
                ..TurnOutcome::default()
            };
        }
    }
    let session = match agents.new_session(&start.session) {
        Ok(id) => id,
        Err(e) => {
            return TurnOutcome {
                error: Some(e),
                ..TurnOutcome::default()
            };
        }
    };
    progress(&session, 0);
    let (tx, rx) = channel();
    interrupt.wake_with(Some(tx.clone()));
    if let Err(e) = agents.start_prompt(&session, start.blocks.clone(), &start.prompt_id, tx) {
        interrupt.wake_with(None);
        let _ = agents.end_session(&session);
        return TurnOutcome {
            error: Some(e),
            ..TurnOutcome::default()
        };
    }
    let fetch = |fold: &mut TurnFold| -> Result<(), String> {
        let before = fold.seq();
        for event in agents.events(&session, fold.seq())? {
            append(fold.apply(&event));
        }
        if fold.seq() != before {
            progress(&session, fold.seq());
        }
        Ok(())
    };
    let mut orphan = None;
    let mut totals = None;
    // The prompt's answer arrived (or never will: lost, past the limit).
    let mut answered = false;
    let mut last_cancel: Option<Instant> = None;
    loop {
        // A newer human message: stop the model at once, but let a running
        // tool call finish (Claude Code's interrupt would abort it), and
        // send the stop again until the turn ends. Read the newest events
        // first: a tool may have started since the last fetch.
        if interrupt.is_set()
            && last_cancel.is_none()
            && fold.ended().is_none()
            && let Err(e) = fetch(&mut fold)
        {
            log(&format!("turn {}: {e}", start.key));
        }
        let stopping = interrupt.is_set() && fold.ended().is_none() && !fold.tool_running();
        if stopping && last_cancel.is_none_or(|t| t.elapsed() >= CANCEL_RESEND) {
            if last_cancel.is_none() {
                log(&format!(
                    "turn {}: a new message arrived; interrupting session {session}",
                    start.key
                ));
            }
            if let Err(e) = agents.cancel(&session) {
                log(&format!("turn {}: interrupting: {e}", start.key));
            }
            last_cancel = Some(Instant::now());
        }
        let resend = last_cancel.filter(|_| stopping).map(|t| t + CANCEL_RESEND);
        let wake = match (deadline, resend) {
            (Some(d), Some(r)) => Some(d.min(r)),
            (d, r) => d.or(r),
        };
        let signal = match wake {
            None => rx.recv().unwrap_or(TurnSignal::Lost),
            Some(at) => match rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                Ok(signal) => signal,
                Err(RecvTimeoutError::Timeout) if deadline.is_none_or(|d| Instant::now() < d) => {
                    continue;
                }
                Err(RecvTimeoutError::Timeout) => {
                    answered = true;
                    let _ = fetch(&mut fold);
                    let limit = start.limit.unwrap_or_default();
                    append(fold.finish(Some(format!(
                        "the turn ran past its limit of {} minutes and was stopped",
                        limit.as_secs() / 60
                    ))));
                    break;
                }
                Err(RecvTimeoutError::Disconnected) => TurnSignal::Lost,
            },
        };
        // Coalesce a burst of change signals into one fetch.
        let signal = match signal {
            TurnSignal::Changed => {
                let mut last = TurnSignal::Changed;
                loop {
                    match rx.try_recv() {
                        Ok(TurnSignal::Changed) => {}
                        Ok(other) => {
                            last = other;
                            break;
                        }
                        Err(TryRecvError::Empty | TryRecvError::Disconnected) => break,
                    }
                }
                last
            }
            other => other,
        };
        match signal {
            TurnSignal::Changed => {
                if let Err(e) = fetch(&mut fold) {
                    log(&format!("turn {}: {e}", start.key));
                }
                if fold.ended().is_some() {
                    break;
                }
            }
            TurnSignal::Done(answer) => {
                answered = true;
                totals = answer.as_ref().ok().and_then(answer_usage);
                let stopped = answer
                    .as_ref()
                    .ok()
                    .and_then(|v| v.get("stopReason"))
                    .and_then(Value::as_str)
                    .and_then(stop_error);
                let fetched = fetch(&mut fold);
                let error = answer.err().or_else(|| fetched.err()).or(stopped);
                append(fold.finish(error));
                break;
            }
            TurnSignal::Lost => {
                answered = true;
                // The session may still run and act: it cannot be ended now
                // (no connection), so the brain keeps it as an orphan. What
                // can still be read is folded now (a fetch fails harmlessly
                // when the connection is really gone).
                let _ = fetch(&mut fold);
                orphan = Some(Orphan {
                    session: session.clone(),
                    after: fold.seq(),
                });
                append(fold.finish(Some(
                    "the acpmux connection was lost during the turn".into(),
                )));
                break;
            }
        }
    }
    // The fold ended on `turn_end`: the answer with the token use follows.
    let until = Instant::now() + ANSWER_WAIT;
    while !answered {
        match rx.recv_timeout(until.saturating_duration_since(Instant::now())) {
            Ok(TurnSignal::Changed) => {}
            Ok(TurnSignal::Done(answer)) => {
                totals = answer.as_ref().ok().and_then(answer_usage);
                answered = true;
            }
            Ok(TurnSignal::Lost) | Err(_) => answered = true,
        }
    }
    interrupt.wake_with(None);
    log(&usage_line(&start.key, fold.first_usage(), totals));
    if orphan.is_none()
        && let Err(e) = agents.end_session(&session)
    {
        log(&format!("ending turn session {}: {e}", start.session.name));
    }
    let error = fold.ended().and_then(|e| e.error.clone());
    TurnOutcome {
        reply: fold.final_text().map(str::to_owned),
        cancelled: is_cancelled(error.as_deref()),
        error,
        orphan,
    }
}

/// One host.log line per turn with its cache use (section 8: verify with the
/// usage fields). The first request shows what this turn read of the view
/// another turn cached; the totals cover the whole tool loop.
pub fn usage_line(
    key: &str,
    first: Option<Usage>,
    totals: Option<(Usage, &'static str)>,
) -> String {
    let show = |u: Option<Usage>| match u {
        Some(u) => format!(
            "read {} written {} uncached {} output {}",
            u.cache_read, u.cache_write, u.input, u.output
        ),
        None => "not reported".to_owned(),
    };
    let (scope, totals) = match totals {
        Some((u, scope)) => (scope, Some(u)),
        None => ("turn total", None),
    };
    format!(
        "turn {key} cache: first request {}; {scope} {}",
        show(first),
        show(totals)
    )
}

/// Folds the rest of an orphaned turn into the log, then removes its
/// session. Err leaves the orphan for the next connect.
pub fn adopt_orphan(
    agents: &dyn AgentPort,
    chat: &OptChat,
    orphan: &Orphan,
    log: &dyn Fn(&str),
) -> Result<(), String> {
    let mut fold = TurnFold::after(orphan.after);
    for event in agents.events(&orphan.session, orphan.after)? {
        for entry in fold.apply(&event) {
            if let Err(e) = chat.append(entry.kind, &entry.text) {
                log(&format!(
                    "logging an orphan's {} entry failed: {e}",
                    entry.kind.as_str()
                ));
            }
        }
    }
    // Whatever it was still saying when it was removed.
    for entry in fold.finish(None) {
        if let Err(e) = chat.append(entry.kind, &entry.text) {
            log(&format!(
                "logging an orphan's {} entry failed: {e}",
                entry.kind.as_str()
            ));
        }
    }
    agents.end_session(&orphan.session)
}
