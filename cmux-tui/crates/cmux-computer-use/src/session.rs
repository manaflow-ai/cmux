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
    /// Acting calls, newest last: started (no result yet) or finished.
    calls: VecDeque<CallRecord>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct CallRecord {
    id: String,
    /// Unix seconds when it started.
    at: u64,
    /// The finished call's result; `None` while it runs, or when the worker
    /// stopped before it finished.
    result: Option<String>,
}

/// What a retried `call_id` finds.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Prior {
    /// Never seen: run it.
    New,
    /// Finished: return this result without acting again.
    Finished(String),
    /// Started by an earlier worker that stopped before it answered: it may
    /// have acted, so it is not run again.
    Interrupted,
}

struct Session {
    file: SessionFile,
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

/// The file of a session key: its safe characters (at most 64) and a hash
/// of the whole key, so any key (`remote:mini:abc`, or a hostile one) maps
/// to one plain file name inside the sessions folder.
fn file_name(key: &str) -> String {
    let safe: String = key
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .take(64)
        .collect();
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in key.bytes() {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{safe}-{hash:016x}.json")
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
                .and_then(|d| std::fs::read(d.join("sessions").join(file_name(key))).ok())
                .and_then(|b| serde_json::from_slice(&b).ok())
                .unwrap_or_default();
            Session { file }
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
        let mut files = Vec::new();
        for k in &keys {
            let session = self.session(&mut state, k);
            session.file.grants.clear();
            files.push((k.clone(), session.file.clone()));
        }
        drop(state);
        for (k, file) in &files {
            self.persist(k, file);
        }
        // Sessions this worker has not loaded: their grants go too (their call
        // records stay, so a retried call still never acts twice).
        if key.is_none()
            && let Some(dir) = &self.dir
            && let Ok(entries) = std::fs::read_dir(dir.join("sessions"))
        {
            let loaded: std::collections::HashSet<String> =
                files.iter().map(|(k, _)| file_name(k)).collect();
            for e in entries.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                if loaded.contains(&name) {
                    continue;
                }
                let Ok(bytes) = std::fs::read(e.path()) else { continue };
                let Ok(mut file) = serde_json::from_slice::<SessionFile>(&bytes) else { continue };
                file.grants.clear();
                if let Ok(bytes) = serde_json::to_vec(&file) {
                    write_private(&e.path(), &bytes);
                }
            }
        }
    }

    /// What an earlier attempt of `call_id` left: a result, an interrupted
    /// start (from a worker that stopped), or nothing.
    pub fn prior(&self, key: &str, call_id: &str) -> Prior {
        let mut state = self.lock();
        let session = self.session(&mut state, key);
        let cutoff = now().saturating_sub(CALL_MEMORY.as_secs());
        session.file.calls.retain(|c| c.at >= cutoff);
        match session.file.calls.iter().find(|c| c.id == call_id) {
            None => Prior::New,
            Some(CallRecord { result: Some(result), .. }) => Prior::Finished(result.clone()),
            Some(CallRecord { result: None, .. }) => Prior::Interrupted,
        }
    }

    /// Records, on disk, that an acting call starts, before it acts.
    pub fn begin(&self, key: &str, call_id: &str) {
        self.record(key, call_id, None);
    }

    /// Records, on disk, the finished call's result before it is returned.
    pub fn remember(&self, key: &str, call_id: &str, result: String) {
        self.record(key, call_id, Some(result));
    }

    fn record(&self, key: &str, call_id: &str, result: Option<String>) {
        let mut state = self.lock();
        let session = self.session(&mut state, key);
        session.file.calls.retain(|c| c.id != call_id);
        session.file.calls.push_back(CallRecord { id: call_id.to_string(), at: now(), result });
        while session.file.calls.len() > CALL_MEMORY_MAX {
            session.file.calls.pop_front();
        }
        let file = session.file.clone();
        drop(state);
        self.persist(key, &file);
    }

    fn persist(&self, key: &str, file: &SessionFile) {
        if let Some(dir) = &self.dir
            && let Ok(bytes) = serde_json::to_vec(file)
        {
            write_private(&dir.join("sessions").join(file_name(key)), &bytes);
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
        let d =
            std::env::temp_dir().join(format!("cmux-cu-sessions-{name}-{}", std::process::id()));
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
        assert_eq!(s.prior("a", "c1"), Prior::New);
        s.begin("a", "c1");
        s.remember("a", "c1", "{\"ok\":1}".into());
        assert_eq!(s.prior("a", "c1"), Prior::Finished("{\"ok\":1}".into()));
        assert_eq!(s.prior("b", "c1"), Prior::New);
    }

    #[test]
    fn finished_and_interrupted_calls_survive_a_worker_restart() {
        let dir = tmpdir("calls");
        let first = Sessions::open(Some(&dir));
        first.begin("remote:mini:s1", "done");
        first.remember("remote:mini:s1", "done", "r".into());
        // The worker stops after this one started acting, before it answered.
        first.begin("remote:mini:s1", "cut");
        drop(first);
        let second = Sessions::open(Some(&dir));
        assert_eq!(second.prior("remote:mini:s1", "done"), Prior::Finished("r".into()));
        assert_eq!(second.prior("remote:mini:s1", "cut"), Prior::Interrupted);
        second.revoke_all(None);
        // Revoking grants keeps the call records.
        assert_eq!(Sessions::open(Some(&dir)).prior("remote:mini:s1", "cut"), Prior::Interrupted);
    }

    #[test]
    fn hostile_session_keys_stay_one_file_in_the_sessions_folder() {
        let dir = tmpdir("keys");
        let s = Sessions::open(Some(&dir));
        s.grant("../../etc/x", "a");
        assert!(!dir.join("etc").exists() && !dir.parent().unwrap().join("etc").exists());
        let files: Vec<_> = std::fs::read_dir(dir.join("sessions")).unwrap().flatten().collect();
        assert_eq!(files.len(), 1);
        assert!(!files[0].file_name().to_string_lossy().contains('/'));
        assert!(Sessions::open(Some(&dir)).has_grant("../../etc/x", "a"));
        assert_ne!(file_name("a:b"), file_name("a_b"));
    }
}
