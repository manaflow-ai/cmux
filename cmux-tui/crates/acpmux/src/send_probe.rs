//! Temporary: where the first prompt after a daemon restart spends its time (probe branch only).

use std::sync::Mutex;
use std::time::Instant;

static START: Mutex<Option<Instant>> = Mutex::new(None);

/// A prompt came: stages after this log their time since it.
pub fn start(what: &str) {
    *START.lock().unwrap_or_else(|e| e.into_inner()) = Some(Instant::now());
    tracing::warn!("send-probe start {what}");
}

/// One stage of the prompt, within 3 s of its start.
pub fn at(stage: &str) {
    let Some(t) = *START.lock().unwrap_or_else(|e| e.into_inner()) else { return };
    let us = t.elapsed().as_micros();
    if us < 3_000_000 {
        tracing::warn!("send-probe {stage} {us}us {}", mem());
    }
}

/// Times `f` as `stage`, logged when it took over 300 us (any time, not only in a prompt).
pub fn timed<T>(stage: &str, f: impl FnOnce() -> T) -> T {
    let t = Instant::now();
    let out = f();
    let us = t.elapsed().as_micros();
    if us > 300 {
        tracing::warn!("send-probe timed {stage} {us}us {}", mem());
    }
    out
}

/// VmRSS and VmHWM in MB, from /proc (Linux).
fn mem() -> String {
    let status = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    let field = |name: &str| {
        status
            .lines()
            .find(|l| l.starts_with(name))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|kb| kb.parse::<u64>().ok())
            .map_or(0, |kb| kb / 1024)
    };
    format!("rss={}MB hwm={}MB", field("VmRSS:"), field("VmHWM:"))
}
