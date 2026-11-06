//! Agent sessions as the worker sees them, kept across worker restarts so
//! an agent never loses its grants or repeats an action because the worker
//! went away under it.
//!
//! - The session key comes from acpmux (the agent session id), not from the
//!   connection: a reconnect after a worker restart resumes the same session.
//! - "Allow for this session" grants and saved approvals are written to the
//!   state directory before the answer returns.
//! - Every acting call carries a `call_id`; its result is kept for
//!   [`CALL_MEMORY`] so a call the bridge retries after a dropped connection
//!   returns the first result instead of clicking twice.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::policy::SavedApprovals;

/// How long a finished call's result is kept for a retry.
pub const CALL_MEMORY: Duration = Duration::from_secs(600);
/// How many finished calls are kept per session.
const CALL_MEMORY_MAX: usize = 64;
/// A session grant lasts this long after its last use.
pub const SESSION_GRANT_IDLE: Duration = Duration::from_secs(8 * 3600);

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
struct SessionFile {
    /// app id -> last use, unix seconds.
    grants: HashMap<String, u64>,
}

struct Session {
    file: SessionFile,
    finished: VecDeque<(String, u64, String)>,
}

/// The sessions and saved approvals of one machine.
pub struct Sessions {
    dir: Option<PathBuf>,
    state: Mutex<State>,
}

struct State {
    saved: SavedApprovals,
    sessions: HashMap<String, Session>,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn valid_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 128
        && key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
        && !key.starts_with('.')
}

impl Sessions {
    /// `dir`: where state is kept (0700); `None` keeps it in memory (tests).
    pub fn open(dir: Option<&Path>) -> Self {
        let saved = dir
            .and_then(|d| std::fs::read(d.join("approvals.json")).ok())
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        if let Some(d) = dir {
            create_private_dir(&d.join("sessions"));
        }
        Self {
            dir: dir.map(Path::to_path_buf),
            state: Mutex::new(State { saved, sessions: HashMap::new() }),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn saved(&self) -> SavedApprovals {
        self.lock().saved.clone()
    }

    pub fn update_saved(&self, f: impl FnOnce(&mut SavedApprovals)) {
        let mut state = self.lock();
        f(&mut state.saved);
        if let Some(dir) = &self.dir
            && let Ok(bytes) = serde_json::to_vec_pretty(&state.saved)
        {
            write_private(&dir.join("approvals.json"), &bytes);
        }
    }

    fn session<'a>(&self, state: &'a mut State, key: &str) -> &'a mut Session {
        state.sessions.entry(key.to_string()).or_insert_with(|| {
            let file = self
                .dir
                .as_ref()
                .filter(|_| valid_key(key))
                .and_then(|d| std::fs::read(d.join("sessions").join(format!("{key}.json"))).ok())
                .and_then(|b| serde_json::from_slice(&b).ok())
                .unwrap_or_default();
            Session { file, finished: VecDeque::new() }
        })
    }

    pub fn has_grant(&self, key: &str, app_id: &str) -> bool {
        let mut state = self.lock();
        let session = self.session(&mut state, key);
        let idle = SESSION_GRANT_IDLE.as_secs();
        let now = now();
        session
            .file
            .grants
            .get(&app_id.to_ascii_lowercase())
            .is_some_and(|last| now.saturating_sub(*last) < idle)
    }

    pub fn grant(&self, key: &str, app_id: &str) {
        let mut state = self.lock();
        let session = self.session(&mut state, key);
        session.file.grants.insert(app_id.to_ascii_lowercase(), now());
        let file = session.file.clone();
        drop(state);
        self.persist(key, &file);
    }

    /// Refreshes the grant's idle clock after a use.
    pub fn touch(&self, key: &str, app_id: &str) {
        let mut state = self.lock();
        let session = self.session(&mut state, key);
        if let Some(t) = session.file.grants.get_mut(&app_id.to_ascii_lowercase()) {
            *t = now();
        }
    }

    pub fn revoke_all(&self, key: Option<&str>) {
        let mut state = self.lock();
        let keys: Vec<String> = match key {
            Some(k) => vec![k.to_string()],
            None => state.sessions.keys().cloned().collect(),
        };
        for k in &keys {
            self.session(&mut state, k).file.grants.clear();
        }
        drop(state);
        for k in keys {
            self.persist(&k, &SessionFile::default());
        }
        if key.is_none()
            && let Some(dir) = &self.dir
            && let Ok(entries) = std::fs::read_dir(dir.join("sessions"))
        {
            for e in entries.flatten() {
                let _ = std::fs::remove_file(e.path());
            }
        }
    }

    /// The result of a call already finished in this session, when the
    /// bridge retries the same `call_id`.
    pub fn finished(&self, key: &str, call_id: &str) -> Option<String> {
        let mut state = self.lock();
        let session = self.session(&mut state, key);
        let cutoff = now().saturating_sub(CALL_MEMORY.as_secs());
        session.finished.retain(|(_, t, _)| *t >= cutoff);
        session.finished.iter().find(|(id, _, _)| id == call_id).map(|(_, _, r)| r.clone())
    }

    pub fn remember(&self, key: &str, call_id: &str, result: String) {
        let mut state = self.lock();
        let session = self.session(&mut state, key);
        session.finished.push_back((call_id.to_string(), now(), result));
        while session.finished.len() > CALL_MEMORY_MAX {
            session.finished.pop_front();
        }
    }

    fn persist(&self, key: &str, file: &SessionFile) {
        if !valid_key(key) {
            return;
        }
        if let Some(dir) = &self.dir
            && let Ok(bytes) = serde_json::to_vec(file)
        {
            write_private(&dir.join("sessions").join(format!("{key}.json")), &bytes);
        }
    }
}

fn create_private_dir(path: &Path) {
    let _ = std::fs::create_dir_all(path);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
    }
}

/// Writes through a temp file and a rename, 0600.
pub(crate) fn write_private(path: &Path, bytes: &[u8]) {
    let tmp = path.with_extension("tmp");
    let written = {
        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&tmp)
                .and_then(|mut f| f.write_all(bytes))
        }
        #[cfg(not(unix))]
        {
            std::fs::write(&tmp, bytes)
        }
    };
    if written.is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("cmux-cu-sessions-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn grants_survive_a_worker_restart() {
        let dir = tmpdir("restart");
        let first = Sessions::open(Some(&dir));
        first.grant("agent-1", "com.apple.Safari");
        first.update_saved(|s| s.set_always("org.mozilla.firefox"));
        drop(first);
        let second = Sessions::open(Some(&dir));
        assert!(second.has_grant("agent-1", "com.apple.safari"));
        assert!(!second.has_grant("agent-2", "com.apple.Safari"));
        assert!(second.saved().is_always("org.mozilla.firefox"));
        second.revoke_all(None);
        assert!(!Sessions::open(Some(&dir)).has_grant("agent-1", "com.apple.Safari"));
    }

    #[test]
    fn a_retried_call_returns_the_first_result() {
        let s = Sessions::open(None);
        assert!(s.finished("a", "c1").is_none());
        s.remember("a", "c1", "{\"ok\":1}".into());
        assert_eq!(s.finished("a", "c1").as_deref(), Some("{\"ok\":1}"));
        assert!(s.finished("b", "c1").is_none());
    }

    #[test]
    fn hostile_session_keys_never_touch_the_filesystem() {
        let dir = tmpdir("keys");
        let s = Sessions::open(Some(&dir));
        s.grant("../../etc/x", "a");
        assert!(!dir.join("etc").exists());
        assert!(s.has_grant("../../etc/x", "a"));
    }
}
