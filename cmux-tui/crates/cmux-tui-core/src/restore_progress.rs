//! The restore heartbeat: proof, for a supervisor, that an owner which holds
//! its connections unanswered is still restoring and not stuck.
//!
//! Leo 2026-11-09: a nightly's owner spent minutes in its restore (a roster
//! replay of the whole journal after a reducer version change), `server
//! ensure` killed it at its restore bound, and the next ensure started the
//! same restore over; no start ever finished. A restoring owner parks every
//! connection unread (`server::restoring`), so a probe cannot tell it from a
//! wedged one. While the socket is restoring, the owner writes
//! `<socket>.restore-progress` (its pid, how many steps it finished, the time)
//! whenever restore work finishes a step, at most once per
//! `WRITE_INTERVAL`. A supervisor keeps an owner whose file is fresh
//! ([`progressing`]). Attach (or a failed restore) removes the file, so no
//! write happens outside a restore and nothing runs on a timer.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The longest a restore may go without finishing a step and still count as
/// progressing. A roster replay page or a registry open step takes well
/// under a second; 30 s covers a cold disk under load.
pub const STALL_BOUND: Duration = Duration::from_secs(30);

/// At most one write per interval: a restore step can be a few ms.
const WRITE_INTERVAL: Duration = Duration::from_secs(1);

const SUFFIX: &str = ".restore-progress";

struct Active {
    path: PathBuf,
    last_write: Option<Instant>,
}

static ACTIVE: Mutex<Option<Active>> = Mutex::new(None);
static STEPS: AtomicU64 = AtomicU64::new(0);

/// The heartbeat file of the owner on `socket`.
pub fn path_for(socket: &Path) -> PathBuf {
    let mut name = socket.as_os_str().to_owned();
    name.push(SUFFIX);
    PathBuf::from(name)
}

/// Starts the heartbeat for the owner on `socket` and writes its first beat.
pub(crate) fn begin(socket: &Path) {
    let mut active = ACTIVE.lock().unwrap_or_else(PoisonError::into_inner);
    *active = Some(Active { path: path_for(socket), last_write: None });
    write(active.as_mut().expect("just set"), Instant::now());
}

/// Ends the heartbeat and removes its file (the restore finished or failed).
pub(crate) fn end() {
    if let Some(active) = ACTIVE.lock().unwrap_or_else(PoisonError::into_inner).take() {
        let _ = std::fs::remove_file(&active.path);
    }
}

/// A restore step finished. Cheap outside a restore (one atomic and an
/// uncontended lock) and rate limited inside one.
pub fn note() {
    STEPS.fetch_add(1, Ordering::Relaxed);
    let mut active = ACTIVE.lock().unwrap_or_else(PoisonError::into_inner);
    let Some(active) = active.as_mut() else { return };
    let now = Instant::now();
    if active.last_write.is_some_and(|last| now.duration_since(last) < WRITE_INTERVAL) {
        return;
    }
    write(active, now);
}

fn write(active: &mut Active, now: Instant) {
    active.last_write = Some(now);
    let body = serde_json::json!({
        "pid": std::process::id(),
        "steps": STEPS.load(Ordering::Relaxed),
        "at_ms": unix_ms(SystemTime::now()),
    });
    // Write then rename: a reader never sees half a file.
    let mut staged = active.path.as_os_str().to_owned();
    staged.push(".tmp");
    let staged = PathBuf::from(staged);
    if std::fs::write(&staged, body.to_string()).is_ok() {
        let _ = std::fs::rename(&staged, &active.path);
    }
}

fn unix_ms(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH).map_or(0, |since| since.as_millis() as u64)
}

/// Whether the owner `pid` on `socket` finished a restore step within
/// `STALL_BOUND`, by its heartbeat file. False for no file, another pid's
/// file, or an unreadable one.
pub fn progressing(socket: &Path, pid: u32) -> bool {
    progressing_at(socket, pid, SystemTime::now(), STALL_BOUND)
}

pub fn progressing_at(socket: &Path, pid: u32, now: SystemTime, bound: Duration) -> bool {
    let Ok(text) = std::fs::read_to_string(path_for(socket)) else { return false };
    let Ok(beat) = serde_json::from_str::<serde_json::Value>(&text) else { return false };
    if beat.get("pid").and_then(serde_json::Value::as_u64) != Some(u64::from(pid)) {
        return false;
    }
    let Some(at_ms) = beat.get("at_ms").and_then(serde_json::Value::as_u64) else { return false };
    unix_ms(now).saturating_sub(at_ms) <= bound.as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fresh_beat_of_the_same_pid_is_progress_and_a_stale_or_foreign_one_is_not() {
        let dir = std::env::temp_dir()
            .join(format!("cmux-restore-progress-{}", crate::workspace_registry::new_uuid_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("owner.sock");
        let pid = std::process::id();
        assert!(!progressing(&socket, pid), "no file is no progress");
        let now = SystemTime::now();
        let at_ms = unix_ms(now);
        std::fs::write(path_for(&socket), format!(r#"{{"pid":{pid},"steps":3,"at_ms":{at_ms}}}"#))
            .unwrap();
        assert!(progressing_at(&socket, pid, now, STALL_BOUND));
        assert!(!progressing_at(&socket, pid + 1, now, STALL_BOUND), "another owner's beat");
        assert!(
            !progressing_at(&socket, pid, now + STALL_BOUND + Duration::from_secs(1), STALL_BOUND),
            "a beat older than the stall bound"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
