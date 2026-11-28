//! Parked waits (cmuxterm-hq RFD 0063, "The pause policy", step 2): on a Cloud machine under the
//! aggressive pause policy, a tool call that only waits is handed to the platform as a wake
//! source, so the machine pauses while it waits instead of staying awake for a `sleep`.
//!
//! The RFD's measurements: "a `sleep 600` watchdog, a CI poll and a background watcher keep a VM
//! awake today for a session's whole life, and each is a timer or an event, not work." This
//! module does the first of them, a foreground `sleep N` of at least [`MIN_SECS`] in a Claude
//! Code `Bash` call:
//!
//! 1. Claude Code's PreToolUse hook (`bg_hook.rs`) rewrites the call ([`rewrite`]) into this
//!    binary's [`ARG`] with the call's id and the same seconds. The machine's applied
//!    `machine.toml` must say `[idle] policy = "aggressive"` ([`aggressive`]); elsewhere nothing
//!    changes.
//! 2. The waiter ([`main`]) fixes its end on the wall clock, tells the daemon the call is parked
//!    until then (`_acpmux/wait/park`, held in [`Parked`]), sleeps until the wall clock reaches
//!    it ([`sleep_until`]), unparks, and exits 0 with no output, as `sleep` does. A monotonic
//!    sleep (`sleep(1)`'s `nanosleep`) does not advance while the machine is paused, so a paused
//!    `sleep 600` would run up to another 600 s after the wake; a wall-clock end returns on time.
//! 3. The daemon's Cloud activity report (`daemon/cloud_activity.rs`) says the session's turn is
//!    `parked`, with `wake: [{"kind": "timer", "at": ms}]`, while every tool call it has open is
//!    parked: a parked wait is not a running local tool call, so the platform may pause the
//!    machine and hold the timer outside it. Today's Cloud reads any phase but `model-wait` as
//!    awake, so a platform without the wake-source side keeps the machine up as before.
//!
//! The guest-to-platform seam is [`PlatformWaits`]: the daemon's [`Parked`] reports through the
//! activity line, and tests use a fake. CI waits (`gh run watch`, `glaeda-gh wait`) become the
//! next [`Wake`] kind.

use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Mutex as StdMutex;

/// The waiter's first argument.
pub const ARG: &str = "__parked-sleep";
/// The shortest sleep worth a pause: a pause and a resume cost about a second each (RFD 0063,
/// "Resume budget"), and the platform's resume lead must fit inside the wait.
pub const MIN_SECS: f64 = 30.0;

/// What wakes a parked call, held outside the machine by the platform.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Wake {
    /// The wall clock reaches `at_ms` (Unix ms).
    Timer { at_ms: u64 },
}

impl Wake {
    /// As the activity report carries it.
    pub fn to_json(&self) -> Value {
        match self {
            Wake::Timer { at_ms } => json!({"kind": "timer", "at": at_ms}),
        }
    }
}

/// One tool call handed to the platform.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParkedWait {
    pub session: String,
    pub call: String,
    pub wake: Wake,
}

/// The guest-to-platform call: a wait is handed over (`park`) and taken back (`unpark`) once
/// the call ended. The daemon's [`Parked`] reports it on the Cloud activity line; the platform
/// pauses the machine and holds the wake (RFD 0063, "Wake sources").
pub trait PlatformWaits: Send + Sync {
    fn park(&self, wait: ParkedWait);
    fn unpark(&self, session: &str, call: &str);
}

/// Each session's parked calls: `session -> call -> wake`.
pub type ParkedMap = BTreeMap<String, BTreeMap<String, Wake>>;

/// The daemon's parked calls, in memory: a restarted daemon has none, and its tracker reports
/// every session at work `unknown` until it settles anyway.
#[derive(Debug)]
pub struct Parked {
    calls: StdMutex<ParkedMap>,
    changes: tokio::sync::watch::Sender<u64>,
}

impl Default for Parked {
    fn default() -> Self {
        Parked { calls: StdMutex::new(BTreeMap::new()), changes: tokio::sync::watch::channel(0).0 }
    }
}

impl Parked {
    /// Every session's parked calls now.
    pub fn snapshot(&self) -> ParkedMap {
        self.calls.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Forgets the sessions not in `keep` (no longer at work): a waiter killed before its
    /// unpark leaves nothing behind past its turn.
    pub fn retain_sessions(&self, keep: &std::collections::BTreeSet<&str>) {
        let mut calls = self.calls.lock().unwrap_or_else(|e| e.into_inner());
        let before = calls.len();
        calls.retain(|sid, _| keep.contains(sid.as_str()));
        if calls.len() != before {
            drop(calls);
            self.changes.send_modify(|n| *n += 1);
        }
    }

    /// Changes each time a call is parked or unparked.
    pub fn subscribe(&self) -> tokio::sync::watch::Receiver<u64> {
        self.changes.subscribe()
    }
}

impl PlatformWaits for Parked {
    fn park(&self, wait: ParkedWait) {
        let mut calls = self.calls.lock().unwrap_or_else(|e| e.into_inner());
        calls.entry(wait.session).or_default().insert(wait.call, wait.wake);
        drop(calls);
        self.changes.send_modify(|n| *n += 1);
    }

    fn unpark(&self, session: &str, call: &str) {
        let mut calls = self.calls.lock().unwrap_or_else(|e| e.into_inner());
        let Some(set) = calls.get_mut(session) else { return };
        if set.remove(call).is_none() {
            return;
        }
        if set.is_empty() {
            calls.remove(session);
        }
        drop(calls);
        self.changes.send_modify(|n| *n += 1);
    }
}

/// Whether the machine runs the aggressive pause policy: the `machine.toml` its applier applied
/// last, under `root` (`/` on a machine), says `[idle] policy = "aggressive"` (cmux-cloud-start-core
/// `machine_config/idle.rs`). No file, a file that does not read, or any other value: off.
pub fn aggressive(root: &std::path::Path) -> bool {
    use cmux_cloud_start_core::machine_config::{MAX_BYTES, idle::applied_path};
    let path = root.join(applied_path().trim_start_matches('/'));
    let Ok(meta) = std::fs::symlink_metadata(&path) else { return false };
    if !meta.is_file() || meta.len() > MAX_BYTES as u64 {
        return false;
    }
    let Ok(text) = std::fs::read_to_string(&path) else { return false };
    let Ok(doc) = text.parse::<toml::Table>() else { return false };
    doc.get("idle").and_then(|i| i.get("policy")).and_then(toml::Value::as_str)
        == Some("aggressive")
}

/// The seconds a `Bash` command waits, when it is exactly one `sleep` with plain durations
/// (`sleep 600`, `sleep 5m`, `sleep 1m 30s`, as GNU sleep adds them) totalling at least
/// [`MIN_SECS`], else None. Anything else (a pipeline, a `&&`, a variable, a quote, a redirect,
/// a comment) runs as asked: the waiter must give exactly what `sleep` would.
pub fn sleep_seconds(command: &str) -> Option<f64> {
    let mut words = command.split_ascii_whitespace();
    if words.next()? != "sleep" {
        return None;
    }
    let mut total = 0.0;
    let mut any = false;
    for word in words {
        total += duration(word)?;
        any = true;
    }
    (any && total.is_finite() && total >= MIN_SECS).then_some(total)
}

/// One GNU sleep duration: digits with at most one `.`, then at most one of `s m h d`.
fn duration(word: &str) -> Option<f64> {
    let (number, unit) = [('s', 1.0), ('m', 60.0), ('h', 3600.0), ('d', 86_400.0)]
        .into_iter()
        .find_map(|(suffix, unit)| word.strip_suffix(suffix).map(|number| (number, unit)))
        .unwrap_or((word, 1.0));
    let plain = !number.is_empty()
        && number.bytes().all(|b| b.is_ascii_digit() || b == b'.')
        && number.bytes().filter(|b| *b == b'.').count() <= 1
        && number != ".";
    plain.then(|| number.parse::<f64>().ok()).flatten().map(|n| n * unit)
}

/// The hook's answer to one PreToolUse `input`, or None: a foreground `sleep N` ([`sleep_seconds`])
/// in a `Bash` call is rewritten (`updatedInput`, no permission decision) into `words` (this
/// binary) with [`ARG`], the call's id and the seconds. The caller checks [`aggressive`].
pub fn rewrite(input: &Value, words: &[String]) -> Option<Value> {
    if input.get("tool_name").and_then(Value::as_str) != Some("Bash") {
        return None;
    }
    if input.pointer("/tool_input/run_in_background") == Some(&json!(true)) {
        return None;
    }
    let command = input.pointer("/tool_input/command")?.as_str()?;
    let seconds = sleep_seconds(command)?;
    let call = input.get("tool_use_id").and_then(Value::as_str).filter(|c| !c.is_empty())?;
    let mut argv = words.to_vec();
    argv.extend([ARG, "--call", call, "--seconds"].map(str::to_owned));
    argv.push(seconds.to_string());
    let mut tool_input = input.get("tool_input").filter(|t| t.is_object())?.clone();
    cmux_json::JsonSet::set(&mut tool_input, "command", json!(crate::agent_tools::quoted(&argv)));
    Some(json!({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "updatedInput": tool_input,
    }}))
}

/// The wall clock, Unix ms.
pub fn wall_ms() -> u64 {
    crate::store::now_ms()
}

/// Sleeps until `wall()` reaches `end_ms`. `nap(ms)` waits about that long; a nap that comes back
/// early (a signal, a clock change) or late (the machine paused under it) is followed by another
/// look at the wall clock, so the wait ends at the first look at or past `end_ms`.
pub fn sleep_until(end_ms: u64, wall: &mut dyn FnMut() -> u64, nap: &mut dyn FnMut(u64, u64)) {
    loop {
        let now = wall();
        if now >= end_ms {
            return;
        }
        nap(end_ms, end_ms - now);
    }
}

/// One nap towards `end_ms`: on Linux an absolute `CLOCK_REALTIME` sleep, which the kernel ends
/// when the wall clock passes `end_ms`, also when a resumed guest's clock is stepped forward
/// past it; elsewhere a plain sleep of `left_ms` (no Cloud machine runs there).
fn nap(end_ms: u64, left_ms: u64) {
    #[cfg(target_os = "linux")]
    {
        let _ = left_ms;
        let ts = libc::timespec {
            tv_sec: (end_ms / 1000) as libc::time_t,
            tv_nsec: ((end_ms % 1000) * 1_000_000) as libc::c_long,
        };
        // SAFETY: a valid timespec; the remainder is unused with TIMER_ABSTIME.
        unsafe {
            libc::clock_nanosleep(
                libc::CLOCK_REALTIME,
                libc::TIMER_ABSTIME,
                &ts,
                std::ptr::null_mut(),
            )
        };
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = end_ms;
        std::thread::sleep(std::time::Duration::from_millis(left_ms));
    }
}

/// How long a park or unpark may hold the waiter: a daemon that does not answer never delays
/// the sleep's own end.
const TELL_BUDGET: std::time::Duration = std::time::Duration::from_secs(2);

/// Tells the chat's daemon (`method`, best effort, bounded by [`TELL_BUDGET`]).
async fn tell(method: &str, params: Value) {
    let ask = async {
        let client = match std::env::var(crate::person_tokens::CALLER_SOCKET_ENV) {
            Ok(socket) => crate::client::Client::connect(std::path::Path::new(&socket)).await?,
            Err(_) => crate::daemon::connect(false).await?,
        };
        client.request(method, params).await
    };
    let _ = tokio::time::timeout(TELL_BUDGET, ask).await;
}

/// The waiter: `ARG --call ID --seconds S`. Prints nothing and exits 0, as `sleep S` does; a
/// signal ends it as it ends `sleep`.
pub fn main(args: &[String]) -> anyhow::Result<()> {
    let value = |name: &str| {
        args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(String::as_str)
    };
    let seconds: f64 = value("--seconds")
        .and_then(|s| s.parse().ok())
        .filter(|s: &f64| s.is_finite() && *s >= 0.0)
        .ok_or_else(|| anyhow::anyhow!("{ARG}: --seconds S is required"))?;
    let end_ms = wall_ms().saturating_add((seconds * 1000.0).ceil() as u64);
    let session = std::env::var(crate::acpmux_mcp_names::SESSION_ENV).ok();
    let call = value("--call").map(str::to_owned);
    let ids = session.zip(call);
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().ok();
    if let (Some(rt), Some((session, call))) = (&runtime, &ids) {
        let params = json!({"sessionId": session, "toolCallId": call, "wakeAt": end_ms});
        rt.block_on(tell(crate::rpc::method::MUX_WAIT_PARK, params));
    }
    sleep_until(end_ms, &mut wall_ms, &mut nap);
    if let (Some(rt), Some((session, call))) = (&runtime, &ids) {
        let params = json!({"sessionId": session, "toolCallId": call});
        rt.block_on(tell(crate::rpc::method::MUX_WAIT_UNPARK, params));
    }
    Ok(())
}

#[cfg(test)]
#[path = "parked_wait_tests.rs"]
mod tests;
