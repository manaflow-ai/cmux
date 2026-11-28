//! A Cloud machine's part of a send's start trace: on a cmux Cloud VM, a `session/prompt` that
//! carries the client's end-to-end trace id (`params._meta.traceId`, the id #55505's
//! `CMUX_TRACE_FILE` spans carry) becomes two `machine` spans on cmux-platform's start trace
//! (`src/server/cloud/StartTrace.ts`):
//!
//! - `agent_start`: the prompt RPC received here until the prompt is written to the agent process,
//!   including the agent's spawn or resume when none ran (attr `cold`: 1 or 0).
//! - `first_token`: the prompt written until the agent's first model update (a message or thought
//!   chunk, a tool call, a plan) comes back. Its attrs say what the agent did meanwhile
//!   ([`Heard`]): when it first said anything at all, how many messages and stderr lines it sent,
//!   which harness it is, and the model-request retries it reported (`turn_retry.rs`: count, last
//!   HTTP status, last cause). A warm spare's first_token ran to 303.8 s at p95 (census, 2026-11-28,
//!   goal cloud-first-reply-p95) with every hop before it small, and nothing said whether the
//!   agent was silent (wedged), retrying a refused model call, or waiting on the model: these do.
//!
//! They go in one `POST /v1/cloud/start-traces/{traceId}/spans` at the first update, through the
//! machine's platform edge (`https://platform.cmux.internal`, cmux-platform `PlatformEdge.ts`):
//! the edge rule pinned to this VM adds the machine's own token, so the guest holds no
//! credential and none is read or sent from here. The post runs on a spawned task with a 5 s
//! bound, is never retried, and is dropped on any failure; a failure to reach the edge at all
//! (no name, no connection) turns posting off for this process.
//!
//! Each step is also a `tracing` span carrying `trace_id`, so a `CMUX_TRACE_FILE` trace shows it.
//!
//! On by default: a prompt that carries no trace id gets one minted here (32 lowercase hex, a
//! W3C trace id, never all zero), so every real Cloud send is traced whatever client sent it; the
//! platform makes the trace on its first post and joins its `model_request` by machine. A
//! client's own id is kept. `CMUX_SEND_TRACE=off` (read once) turns the whole thing off.
//!
//! Off everywhere else: not a Cloud VM, the switch off, or the edge gone, the prompt path pays
//! one atomic load per prompt and per agent update.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// The machine's platform edge (cmux-platform `PLATFORM_EDGE_DOMAIN`).
pub const EDGE_ORIGIN: &str = "https://platform.cmux.internal";
/// One post's whole bound.
// timeout: a best-effort trace post; past it the trace is dropped and the send goes on.
const POST_TIMEOUT: Duration = Duration::from_secs(5);
/// The most prompts waiting on their first update at once; a fuller map drops the oldest.
const MAX_PENDING: usize = 256;

/// One traced prompt between its arrival and its agent's first update.
struct Pending {
    trace_id: String,
    received_ms: u64,
    /// When the prompt was written to the agent, and whether the agent had to start for it.
    handed: Option<(u64, bool)>,
    /// The open `tracing` span of the step under way (closed at its end, so its layer times it).
    step: tracing::Span,
    /// What the agent sent after the hand-off and before its first model update.
    heard: Heard,
}

/// What an agent sent between a traced prompt's hand-off and its first model update: counts and
/// fixed codes only, never a line's text (the platform refuses anything else, `StartTrace.ts`).
#[derive(Debug, Default, Clone, PartialEq, Eq)]
struct Heard {
    /// When it sent its first message of any kind (a stderr line included), epoch ms.
    first_ms: Option<u64>,
    /// Its messages that were not the model's (bookkeeping, usage, stderr), stderr included.
    msgs: u32,
    /// Its host's stderr lines.
    stderr: u32,
    /// The harness its raw lines name (`claude.*`, `codex.*`), when one did.
    harness: Option<&'static str>,
    /// Model-request retries it reported (`turn_retry.rs`), the last one's HTTP status and cause.
    retries: u32,
    retry_status: Option<u64>,
    retry_cause: Option<String>,
}

/// What the agent's message was, for [`agent_said`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Said<'a> {
    /// A line its host wrote to stderr.
    Stderr,
    /// Any other message of the agent's that is not the model's, by method when it has one.
    Other(Option<&'a str>),
}

/// The harness a raw line's method names.
fn harness_of(method: &str) -> Option<&'static str> {
    if method.starts_with("claude.") {
        Some("claude")
    } else if method.starts_with("codex.") {
        Some("codex")
    } else {
        None
    }
}

/// `raw` as a fixed code the platform takes (`^[A-Za-z0-9_.:-]{0,64}$`), or None.
fn code_of(raw: &str) -> Option<String> {
    let ok = !raw.is_empty()
        && raw.len() <= 64
        && raw.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'));
    ok.then(|| raw.to_owned())
}

/// Traced prompts by session id; [`PENDING_COUNT`] lets every untraced call skip the lock.
static PENDING: LazyLock<Mutex<HashMap<String, Pending>>> = LazyLock::new(Default::default);
static PENDING_COUNT: AtomicUsize = AtomicUsize::new(0);
/// Set when the edge could not be reached: no more posts from this process.
static EDGE_DOWN: AtomicBool = AtomicBool::new(false);

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

/// The trace id a prompt carries, when it is one the platform takes
/// (`StartTraceRoute.ts`: `^[A-Za-z0-9_-]{8,80}$`; the clients send 32 lowercase hex).
pub fn trace_id_of(params: &Value) -> Option<&str> {
    let id = params.pointer("/_meta/traceId")?.as_str()?;
    let ok = (8..=80).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
    ok.then_some(id)
}

/// This machine's id as the platform writes it into the guest, when it has the platform's shape
/// (`^vm_[a-z0-9]{20}$`); the edge's token names the machine either way.
fn machine_id() -> Option<String> {
    static ID: LazyLock<Option<String>> = LazyLock::new(|| {
        ["CMUX_PLATFORM_MACHINE_ID", "CMUX_VM_ID"]
            .into_iter()
            .filter_map(|k| std::env::var(k).ok())
            .map(|v| v.trim().to_owned())
            .find(|v| is_machine_id(v))
    });
    ID.clone()
}

fn is_machine_id(v: &str) -> bool {
    v.strip_prefix("vm_").is_some_and(|rest| {
        rest.len() == 20 && rest.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    })
}

/// Whether `CMUX_SEND_TRACE`'s value turns send traces off (`off`, `0`, `false`, `no`).
fn switch_off(v: Option<&str>) -> bool {
    v.is_some_and(|v| {
        matches!(v.trim().to_ascii_lowercase().as_str(), "off" | "0" | "false" | "no")
    })
}

fn enabled() -> bool {
    static OFF: LazyLock<bool> =
        LazyLock::new(|| switch_off(std::env::var("CMUX_SEND_TRACE").ok().as_deref()));
    !EDGE_DOWN.load(Ordering::Relaxed) && !*OFF && crate::cloud_host::is_cloud_vm()
}

/// A fresh W3C trace id: 16 random bytes as 32 lowercase hex, never all zero (W3C's invalid id).
pub fn mint_trace_id() -> String {
    loop {
        let mut b = [0u8; 16];
        if getrandom::fill(&mut b).is_err() {
            b = uuid::Uuid::now_v7().into_bytes();
        }
        if b != [0u8; 16] {
            return b.iter().map(|x| format!("{x:02x}")).collect();
        }
    }
}

/// A `session/prompt` for `session` arrived with `params`: on a Cloud VM, start its trace under
/// the id it carries, or a minted one when it carries none. A newer prompt of the same session
/// replaces an older one.
pub fn received(session: &str, params: &Value) {
    if !enabled() {
        return;
    }
    let id = trace_id_of(params).map_or_else(mint_trace_id, str::to_owned);
    let step = tracing::info_span!(parent: None, "send_trace.agent_start", trace_id = %id, session = %session, cold = tracing::field::Empty);
    let pending = Pending {
        trace_id: id,
        received_ms: now_ms(),
        handed: None,
        step,
        heard: Heard::default(),
    };
    let Ok(mut map) = PENDING.lock() else { return };
    if map.len() >= MAX_PENDING && !map.contains_key(session) {
        let oldest = map.iter().min_by_key(|(_, p)| p.received_ms).map(|(k, _)| k.clone());
        if let Some(k) = oldest {
            map.remove(&k);
        }
    }
    map.insert(session.to_owned(), pending);
    PENDING_COUNT.store(map.len(), Ordering::Relaxed);
}

/// Whether `session` has a traced prompt waiting (one atomic load when none is anywhere).
pub fn waiting(session: &str) -> bool {
    PENDING_COUNT.load(Ordering::Relaxed) != 0
        && PENDING.lock().is_ok_and(|m| m.get(session).is_some_and(|p| p.handed.is_none()))
}

/// The prompt of `session` was written to its agent; `cold` when the agent was started for it.
pub fn handed(session: &str, cold: bool) {
    if PENDING_COUNT.load(Ordering::Relaxed) == 0 {
        return;
    }
    let Ok(mut map) = PENDING.lock() else { return };
    let Some(p) = map.get_mut(session) else { return };
    if p.handed.is_some() {
        return;
    }
    p.handed = Some((now_ms(), cold));
    p.step.record("cold", u64::from(cold));
    // Closing the agent_start span and opening first_token's.
    p.step = tracing::info_span!(parent: None, "send_trace.first_token", trace_id = %p.trace_id, session = %session);
}

/// The handed prompt of `session` waiting on its first model update, when there is one.
fn with_handed(session: &str, f: impl FnOnce(&mut Heard)) {
    if PENDING_COUNT.load(Ordering::Relaxed) == 0 {
        return;
    }
    let Ok(mut map) = PENDING.lock() else { return };
    if let Some(p) = map.get_mut(session).filter(|p| p.handed.is_some()) {
        f(&mut p.heard);
    }
}

/// The agent of `session` sent a message that is not its model's (one atomic load when no
/// prompt is traced anywhere): counted on the first_token span of a prompt it was handed.
pub fn agent_said(session: &str, said: Said<'_>) {
    with_handed(session, |h| {
        h.first_ms.get_or_insert_with(now_ms);
        h.msgs = h.msgs.saturating_add(1);
        match said {
            Said::Stderr => h.stderr = h.stderr.saturating_add(1),
            Said::Other(Some(method)) => {
                if h.harness.is_none() {
                    h.harness = harness_of(method);
                }
            }
            Said::Other(None) => {}
        }
    });
}

/// The agent of `session` reported a model-request retry (`turn_retry.rs`'s `turn_retrying`
/// record: `source`, `errorStatus`, `cause`): counted on the first_token span of a prompt it was
/// handed, with the last one's status and cause.
pub fn retried(session: &str, retry: &Value) {
    with_handed(session, |h| {
        h.first_ms.get_or_insert_with(now_ms);
        h.retries = h.retries.saturating_add(1);
        if let Some(status) = retry.get("errorStatus").and_then(Value::as_u64) {
            h.retry_status = Some(status);
        }
        let cause = retry.get("cause").or_else(|| retry.get("source")).and_then(Value::as_str);
        if let Some(code) = cause.and_then(code_of) {
            h.retry_cause = Some(code);
        }
        if h.harness.is_none() {
            h.harness = match retry.get("source").and_then(Value::as_str) {
                Some("claude") => Some("claude"),
                Some("codex") => Some("codex"),
                _ => None,
            };
        }
    });
}

/// The first_token span's attrs: what the agent did before its first model update ([`Heard`]).
fn first_token_attrs(h: &Heard, handed_ms: u64, first_ms: u64) -> Value {
    let mut a = serde_json::Map::new();
    if let Some(at) = h.first_ms {
        a.insert("agent_first_ms".into(), json!(at.clamp(handed_ms, first_ms) - handed_ms));
    }
    a.insert("agent_msgs".into(), json!(h.msgs));
    a.insert("stderr_lines".into(), json!(h.stderr));
    a.insert("retries".into(), json!(h.retries));
    if let Some(s) = h.retry_status {
        a.insert("retry_status".into(), json!(s));
    }
    if let Some(c) = &h.retry_cause {
        a.insert("retry_cause".into(), json!(c));
    }
    if let Some(name) = h.harness {
        a.insert("harness".into(), json!(name));
    }
    Value::Object(a)
}

/// The agent of `session` sent its first model update: post the trace's spans.
pub fn first_update(session: &str) {
    if PENDING_COUNT.load(Ordering::Relaxed) == 0 {
        return;
    }
    let p = {
        let Ok(mut map) = PENDING.lock() else { return };
        if map.get(session).is_none_or(|p| p.handed.is_none()) {
            return;
        }
        let p = map.remove(session);
        PENDING_COUNT.store(map.len(), Ordering::Relaxed);
        p
    };
    let Some(p) = p else { return };
    let end_ms = now_ms();
    let body = body(&p, end_ms, machine_id());
    // Closing the first_token span; the trace id outlives it for the post.
    let Pending { trace_id, step, .. } = p;
    drop(step);
    let Some(body) = body else { return };
    let Ok(rt) = tokio::runtime::Handle::try_current() else { return };
    rt.spawn(post(trace_id, body));
}

/// The post's body (cmux-platform `StartTrace.ts` parseSpans): the two spans, `source:
/// "machine"`, epoch ms, `cold` as a number; `None` before the prompt was handed.
fn body(p: &Pending, first_ms: u64, machine: Option<String>) -> Option<Value> {
    let (handed_ms, cold) = p.handed?;
    let handed_ms = handed_ms.max(p.received_ms);
    let first_ms = first_ms.max(handed_ms);
    let mut out = json!({"spans": [
        {"hop": "agent_start", "start_ms": p.received_ms, "end_ms": handed_ms, "source": "machine",
         "attrs": {"cold": u8::from(cold)}},
        {"hop": "first_token", "start_ms": handed_ms, "end_ms": first_ms, "source": "machine",
         "attrs": first_token_attrs(&p.heard, handed_ms, first_ms)},
    ]});
    if let Some(m) = machine {
        out["machine"] = Value::String(m);
    }
    Some(out)
}

/// The spans endpoint of `trace_id` on the edge.
pub fn spans_url(trace_id: &str) -> String {
    format!("{EDGE_ORIGIN}/v1/cloud/start-traces/{trace_id}/spans")
}

async fn post(trace_id: String, body: Value) {
    static CLIENT: LazyLock<Option<reqwest::Client>> = LazyLock::new(|| {
        cmux_egress::client_builder("acpmux::send_trace")
            .timeout(POST_TIMEOUT)
            .connect_timeout(POST_TIMEOUT)
            .build()
            .ok()
    });
    let Some(client) = CLIENT.as_ref() else { return };
    let span = tracing::info_span!("send_trace.post", trace_id = %trace_id);
    let _enter = span.enter();
    let sent =
        tokio::time::timeout(POST_TIMEOUT, client.post(spans_url(&trace_id)).json(&body).send())
            .await;
    match sent {
        Ok(Ok(r)) if r.status().is_success() => {}
        Ok(Ok(r)) => tracing::debug!(status = r.status().as_u16(), "start trace post refused"),
        Ok(Err(e)) if e.is_connect() => {
            EDGE_DOWN.store(true, Ordering::Relaxed);
            tracing::debug!("platform edge unreachable; start traces off");
        }
        Ok(Err(_)) | Err(_) => tracing::debug!("start trace post failed"),
    }
}

#[cfg(test)]
#[path = "send_trace_tests.rs"]
mod tests;
