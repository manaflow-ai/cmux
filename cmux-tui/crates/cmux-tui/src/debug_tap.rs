//! Passive instrumentation for debugging the scoped attach client inside a
//! real app environment. Disabled unless `CMUX_TUI_DEBUG_TAP` names a
//! directory. Every record is appended (O_APPEND) to a per-pid file so
//! concurrent attach clients never interleave partial lines, and nothing is
//! ever written to stdout or stderr (both belong to the host terminal).

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

struct Tap {
    file: Mutex<File>,
    deduped: Mutex<HashMap<&'static str, String>>,
}

static TAP: OnceLock<Option<Tap>> = OnceLock::new();

fn tap() -> Option<&'static Tap> {
    TAP.get_or_init(|| {
        let dir = PathBuf::from(std::env::var_os("CMUX_TUI_DEBUG_TAP")?);
        std::fs::create_dir_all(&dir).ok()?;
        let path = dir.join(format!("client-{}.log", std::process::id()));
        let mut file = OpenOptions::new().create(true).append(true).open(path).ok()?;
        let argv: Vec<String> = std::env::args().collect();
        let _ =
            writeln!(file, "{} [tap] open pid={} argv={:?}", now_ms(), std::process::id(), argv);
        Some(Tap { file: Mutex::new(file), deduped: Mutex::new(HashMap::new()) })
    })
    .as_ref()
}

fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
}

#[inline]
pub(crate) fn enabled() -> bool {
    tap().is_some()
}

/// Appends one timestamped record. No-op unless the tap is enabled.
pub(crate) fn line(message: impl AsRef<str>) {
    let Some(tap) = tap() else { return };
    let thread = std::thread::current();
    let name = thread.name().unwrap_or("?").to_owned();
    if let Ok(mut file) = tap.file.lock() {
        let _ = writeln!(file, "{} [{}] {}", now_ms(), name, message.as_ref());
    }
}

/// Appends a record only when `message` differs from the last one logged
/// under `key`, so per-frame call sites stay quiet while state is stable.
pub(crate) fn changed(key: &'static str, message: impl Into<String>) {
    let Some(tap) = tap() else { return };
    let message = message.into();
    {
        let Ok(mut deduped) = tap.deduped.lock() else { return };
        if deduped.get(key).is_some_and(|last| *last == message) {
            return;
        }
        deduped.insert(key, message.clone());
    }
    line(format!("{key} {message}"));
}

pub(crate) fn hex_string(bytes: &[u8], max: usize) -> String {
    let mut out = String::with_capacity(bytes.len().min(max) * 2 + 1);
    for byte in bytes.iter().take(max) {
        out.push_str(&format!("{byte:02x}"));
    }
    if bytes.len() > max {
        out.push('+');
    }
    out
}
