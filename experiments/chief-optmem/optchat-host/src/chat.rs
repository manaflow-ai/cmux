//! The thread-safe facade: one `OptChat` per chat directory per machine.

use std::collections::BTreeMap;
use std::fmt;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use optchat_core::{render_view, zoom, Kind, NodeId, RenderedView, Store, ZoomError};

use crate::anthropic::AnthropicModel;
use crate::cap::cap_tool_result;
use crate::clock::{Clock, SystemClock};
use crate::compactor::{drive, Shared, State};
use crate::config::Config;
use crate::db::{self, Appended, Db, NewMessage, StateWrite};
use crate::lines;
use crate::lock::{ChatLock, LockError};
use crate::model::CompactModel;
use crate::report::Report;

#[derive(Debug)]
pub enum Error {
    /// Another process (or another `OptChat` here) holds this chat's lock.
    Locked,
    /// `shutdown` ran.
    Closed,
    /// A write failed earlier; restart to repair and continue.
    Fatal(String),
    Io(io::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Locked => f.write_str("the chat is open in another process"),
            Error::Closed => f.write_str("the chat is shut down"),
            Error::Fatal(e) => write!(f, "the chat stopped writing: {e}"),
            Error::Io(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Error::Io(e)
    }
}

/// A compactor node whose last call failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
    pub node: NodeId,
    /// Its first error (later ones are not kept, as they are not reported).
    pub error: String,
}

/// A snapshot for status lines and dashboards.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    /// Number of messages, T.
    pub messages: u64,
    pub view_lines: usize,
    /// Bytes of the view's line texts (placeholders included).
    pub view_size: usize,
    pub budget: usize,
    /// View lines not summarized yet; a turn waits until this is 0.
    pub unbuilt: usize,
    /// Stored tree nodes.
    pub built: usize,
    /// Nodes with a model call running or waiting to retry.
    pub busy: Vec<NodeId>,
    pub failures: Vec<Failure>,
    pub fatal: Option<String>,
    pub closed: bool,
}

/// A week after the migration, checks the copy of the old files again (a
/// full import into a scratch database, on its own thread so the start
/// does not wait) and deletes it when its counts and hash match the
/// migration's; the record says so in the same write.
fn retire_backup(shared: &Arc<Shared>, record: String, db: PathBuf) {
    let now = chrono::Local::now().fixed_offset();
    let Some(backup) = db::backup_due(&record, now) else {
        return;
    };
    let shared = Arc::downgrade(shared);
    let _ = std::thread::Builder::new()
        .name("optchat-retire-backup".into())
        .spawn(move || {
            let scratch = db.with_file_name("memory-verify.sqlite3");
            let checked = db::verify_backup(&record, &backup, &scratch);
            let Some(shared) = shared.upgrade() else {
                return;
            };
            let mut st = shared.lock();
            if !st.writable() {
                return;
            }
            let report = match checked {
                Ok(imported) => {
                    // Deleted first: a record written before a failed delete
                    // would say the copy is gone while it is not.
                    let deleted = std::fs::remove_dir_all(&backup).and_then(|()| {
                        st.store.put_state(&[(
                            db::MIGRATION_KEY.to_owned(),
                            Some(db::retired_record(&record, &imported)),
                        )])
                    });
                    match deleted {
                        Ok(()) => Report::BackupRetired {
                            backup,
                            messages: imported.messages,
                            nodes: imported.nodes,
                        },
                        Err(e) => Report::BackupKept {
                            backup,
                            why: e.to_string(),
                        },
                    }
                }
                Err(why) => Report::BackupKept { backup, why },
            };
            st.reports.push(report);
            shared.unlock(st);
        });
}

/// Stops a `settle` or `wait_idle` from another thread.
#[derive(Clone)]
pub struct Cancel {
    flag: Arc<AtomicBool>,
    shared: Weak<Shared>,
}

impl Cancel {
    pub fn cancel(&self) {
        self.flag.store(true, Ordering::SeqCst);
        if let Some(sh) = self.shared.upgrade() {
            // Taking the lock orders the flag before the waiter's next check.
            drop(sh.lock());
            sh.changed.notify_all();
        }
    }

    pub fn is_canceled(&self) -> bool {
        self.flag.load(Ordering::SeqCst)
    }
}

/// The database file's name next to the chat directory's contents when the
/// config names none (`Config::db`).
pub const DB_FILE: &str = "memory.sqlite3";

/// One open chat: the lock, the store, the memory and the compactor.
pub struct OptChat {
    shared: Arc<Shared>,
    lock: Mutex<Option<ChatLock>>,
    loaded: db::checkpoint::Loaded,
}

impl OptChat {
    /// Opens `dir` with the Anthropic compactor model (and its refusal
    /// fallback, when configured) and real time.
    pub fn open(dir: impl AsRef<Path>, config: Config) -> Result<OptChat, Error> {
        let model = Arc::new(AnthropicModel::new(&config));
        let fallback = config
            .fallback_model
            .as_deref()
            .map(|m| Arc::new(AnthropicModel::with_model(&config, m)) as Arc<dyn CompactModel>);
        OptChat::open_with_fallback(dir, config, model, fallback, Arc::new(SystemClock))
    }

    /// `open_with` without a refusal fallback.
    pub fn open_with(
        dir: impl AsRef<Path>,
        config: Config,
        model: Arc<dyn CompactModel>,
        clock: Arc<dyn Clock>,
    ) -> Result<OptChat, Error> {
        OptChat::open_with_fallback(dir, config, model, None, clock)
    }

    /// Opens `dir`: takes the lock (a socket in `dir`), opens the database
    /// (`config.db`, else `dir/memory.sqlite3`), imports the old JSONL
    /// files under `dir` once if the database is new (`db::migrate_legacy`),
    /// folds the view again from message 0 (section 5.2) and starts the
    /// compactor. `fallback` builds the nodes `model` declines. `dir` is also
    /// where the text export goes (`db::Exporter`).
    pub fn open_with_fallback(
        dir: impl AsRef<Path>,
        config: Config,
        model: Arc<dyn CompactModel>,
        fallback: Option<Arc<dyn CompactModel>>,
        clock: Arc<dyn Clock>,
    ) -> Result<OptChat, Error> {
        let dir = dir.as_ref();
        db::private_dir(dir)?;
        let lock = match ChatLock::acquire(dir) {
            Ok(l) => l,
            Err(LockError::Held) => return Err(Error::Locked),
            Err(LockError::Io(e)) => return Err(Error::Io(e)),
        };
        let path = config.db.clone().unwrap_or_else(|| dir.join(DB_FILE));
        let mut reports = Vec::new();
        let loaded = Db::open(&path).and_then(|mut store| {
            let built = db::migrate_legacy(&mut store, dir, &mut reports)?.map(|(_, b)| b);
            let (memory, how) = db::checkpoint::load(&mut store, built, config.budget)?;
            Ok((store, memory, how))
        });
        for r in &reports {
            (config.reporter)(r);
        }
        let (store, memory, loaded) = loaded?;
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                memory,
                store,
                appended: 0,
                failing: BTreeMap::new(),
                closed: false,
                fatal: None,
                reports: Vec::new(),
            }),
            changed: Condvar::new(),
            model,
            fallback,
            clock,
            system: config.prompt.text(&config.agent),
            retry: config.retry,
            reporter: config.reporter.clone(),
        });
        let mut st = shared.lock();
        drive(&shared, &mut st);
        let record = st.store.state(db::MIGRATION_KEY).ok().flatten();
        shared.unlock(st);
        if let Some(record) = record {
            retire_backup(&shared, record, path);
        }
        Ok(OptChat {
            shared,
            lock: Mutex::new(Some(lock)),
            loaded,
        })
    }

    /// How the memory was loaded at open: from its checkpoint, or folded
    /// from message 0 (the first start after an import or an upgrade).
    pub fn loaded(&self) -> db::checkpoint::Loaded {
        self.loaded
    }

    /// Logs one message (on disk when it returns) and returns its id. Tool
    /// results (`Echo`) are capped at `CAP` characters first (section 7).
    pub fn append(&self, kind: Kind, text: &str) -> Result<u64, Error> {
        let done = self.append_with(&[NewMessage::new(kind, text)], |_| Vec::new())?;
        Ok(done.ids[0])
    }

    /// Logs an imported message with the ISO (RFC 3339) time it was first
    /// written (section 10: old chats imported as messages), so `date(id)`
    /// tells when it was said, not when it was imported. Any other date is
    /// refused and nothing is logged.
    pub fn append_dated(&self, kind: Kind, text: &str, date: &str) -> Result<u64, Error> {
        if !lines::is_iso(date) {
            return Err(Error::Io(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("not an RFC 3339 date: {date:?}"),
            )));
        }
        let message = NewMessage {
            date: Some(date),
            ..NewMessage::new(kind, text)
        };
        let done = self.append_with(&[message], |_| Vec::new())?;
        Ok(done.ids[0])
    }

    /// Logs `messages` and writes the state `state` returns in ONE
    /// transaction (section 7's bookkeeping moves with the log: a crash
    /// leaves both or neither). `state` runs under the chat's lock with the
    /// ids and dates, and must not call back into the chat. A message whose
    /// key is already logged is not logged again (`Appended::fresh`).
    pub fn append_with(
        &self,
        messages: &[NewMessage<'_>],
        state: impl FnOnce(&Appended) -> Vec<StateWrite>,
    ) -> Result<Appended, Error> {
        let capped: Vec<std::borrow::Cow<'_, str>> = messages
            .iter()
            .map(|m| {
                if m.kind == Kind::Echo {
                    cap_tool_result(m.text)
                } else {
                    m.text.into()
                }
            })
            .collect();
        let messages: Vec<NewMessage<'_>> = messages
            .iter()
            .zip(&capped)
            .map(|(m, text)| NewMessage {
                kind: m.kind,
                text: text.as_ref(),
                key: m.key.clone(),
                date: m.date,
            })
            .collect();
        let mut st = self.shared.lock();
        if st.closed {
            return Err(Error::Closed);
        }
        if let Some(e) = &st.fatal {
            return Err(Error::Fatal(e.clone()));
        }
        let done = match st.store.append(&messages, state) {
            Ok(done) => done,
            Err(e) => {
                st.set_fatal(format!("writing messages: {e}"));
                self.shared.changed.notify_all();
                self.shared.unlock(st);
                return Err(Error::Io(e));
            }
        };
        {
            let st = &mut *st;
            for (id, fresh) in done.ids.iter().zip(&done.fresh) {
                if *fresh {
                    let in_memory = st.memory.append_in(&st.store);
                    debug_assert_eq!(*id, in_memory);
                    st.appended += 1;
                }
            }
            if st.appended >= db::checkpoint::EVERY {
                st.save_checkpoint();
            }
        }
        drive(&self.shared, &mut st);
        self.shared.unlock(st);
        Ok(done)
    }

    /// Writes state keys (one transaction).
    pub fn put_state(&self, writes: &[StateWrite]) -> Result<(), Error> {
        let mut st = self.shared.lock();
        if st.closed {
            return Err(Error::Closed);
        }
        let result = st.store.put_state(writes).map_err(Error::Io);
        self.shared.unlock(st);
        result
    }

    /// One state value.
    pub fn state(&self, key: &str) -> Result<Option<String>, Error> {
        let st = self.shared.lock();
        st.store.state(key).map_err(Error::Io)
    }

    /// Every state key that starts with `prefix`, in key order.
    pub fn state_prefix(&self, prefix: &str) -> Result<Vec<(String, String)>, Error> {
        let st = self.shared.lock();
        st.store.state_prefix(prefix).map_err(Error::Io)
    }

    /// Imports a JSONL layout (an old home's `main/` and `tree/`, or a text
    /// export) into this chat, which must be empty, in one verified
    /// transaction (`db::import_legacy`); the view is folded again.
    pub fn import_jsonl(&self, from: &Path) -> Result<db::Imported, Error> {
        let mut st = self.shared.lock();
        if !st.writable() {
            let e = if st.closed {
                Error::Closed
            } else {
                Error::Fatal(st.fatal.clone().unwrap_or_default())
            };
            self.shared.unlock(st);
            return Err(e);
        }
        let mut reports = Vec::new();
        let result = db::import_legacy(&mut st.store, from, &mut reports, None);
        st.reports.extend(reports);
        let result = match result {
            Ok((imported, built)) => {
                let budget = st.memory.budget();
                match db::checkpoint::load(&mut st.store, Some(built), budget) {
                    Ok((memory, _)) => {
                        st.memory = memory;
                        drive(&self.shared, &mut st);
                        Ok(imported)
                    }
                    Err(e) => Err(Error::Io(e)),
                }
            }
            Err(e) => Err(Error::Io(e)),
        };
        self.shared.unlock(st);
        result
    }

    /// The database file.
    pub fn db_path(&self) -> PathBuf {
        let st = self.shared.lock();
        st.store.path().to_owned()
    }

    /// A cancel handle for `settle` and `wait_idle`.
    pub fn cancel_handle(&self) -> Cancel {
        Cancel {
            flag: Arc::new(AtomicBool::new(false)),
            shared: Arc::downgrade(&self.shared),
        }
    }

    /// Blocks until every view line is a summary (section 6), woken on every
    /// change. False if canceled, timed out, shut down or stopped by a failed write.
    pub fn settle(&self, cancel: Option<&Cancel>, timeout: Option<Duration>) -> bool {
        self.wait(cancel, timeout, |st| st.memory.settled())
    }

    /// Blocks until the compactor has nothing running or waiting to retry and
    /// the view is settled: everything buildable now is built.
    pub fn wait_idle(&self, cancel: Option<&Cancel>, timeout: Option<Duration>) -> bool {
        self.wait(cancel, timeout, |st| {
            st.memory.settled() && st.memory.busy().next().is_none()
        })
    }

    fn wait(
        &self,
        cancel: Option<&Cancel>,
        timeout: Option<Duration>,
        done: impl Fn(&State) -> bool,
    ) -> bool {
        let end = timeout.map(|t| Instant::now() + t);
        let mut st = self.shared.lock();
        loop {
            if done(&st) {
                return true;
            }
            if !st.writable() || cancel.is_some_and(Cancel::is_canceled) {
                return false;
            }
            st = match end {
                None => self
                    .shared
                    .changed
                    .wait(st)
                    .expect("optchat state poisoned"),
                Some(end) => {
                    let left = end.saturating_duration_since(Instant::now());
                    if left.is_zero() {
                        return false;
                    }
                    self.shared
                        .changed
                        .wait_timeout(st, left)
                        .expect("optchat state poisoned")
                        .0
                }
            };
        }
    }

    /// The view as the agent reads it, with its cache marks (sections 5.1, 8).
    pub fn render_view(&self) -> RenderedView {
        let st = self.shared.lock();
        render_view(&st.memory, &st.store)
    }

    /// The agent's `zoom(id, n)` tool (section 7.1).
    pub fn zoom(&self, id: u64, n: u64) -> Result<String, ZoomError> {
        let st = self.shared.lock();
        zoom(&st.memory, &st.store, id, n)
    }

    /// The agent's `date(id)` tool: local date and time of message `id`.
    pub fn date(&self, id: u64) -> Option<String> {
        let st = self.shared.lock();
        st.store.date(id).map(|iso| lines::local_date(&iso))
    }

    /// The stored ISO time of message `id` (millisecond precision, local
    /// offset), as written when it was logged. It tells two messages with the
    /// same id apart across a memory reset or a restored backup.
    pub fn stamp(&self, id: u64) -> Option<String> {
        let st = self.shared.lock();
        st.store.date(id)
    }

    /// The text of node `id`, if it is built (for browsing the tree, section 10).
    pub fn node(&self, id: NodeId) -> Option<String> {
        let st = self.shared.lock();
        st.store.node(id)
    }

    /// Kind and whole text of message `id`, if it exists.
    pub fn message(&self, id: u64) -> Option<(Kind, String)> {
        let st = self.shared.lock();
        (id < st.store.len()).then(|| st.store.message(id))
    }

    pub fn status(&self) -> Status {
        let st = self.shared.lock();
        let memory = &st.memory;
        let mut busy: Vec<NodeId> = memory.busy().copied().collect();
        busy.sort();
        Status {
            messages: memory.len(),
            view_lines: memory.view().len(),
            view_size: memory.view_size(),
            budget: memory.budget(),
            unbuilt: memory
                .view()
                .iter()
                .filter(|p| !memory.is_built(**p))
                .count(),
            built: st.store.node_count(),
            busy,
            failures: st
                .failing
                .iter()
                .map(|(node, error)| Failure {
                    node: *node,
                    error: error.clone(),
                })
                .collect(),
            fatal: st.fatal.clone(),
            closed: st.closed,
        }
    }

    /// Stops writing and releases the lock. Model calls still running finish
    /// in their threads and are dropped: every write checks `closed` under the
    /// same mutex, and the lock is released only after `closed` is set, so no
    /// write can follow another process taking the chat. Idempotent.
    pub fn shutdown(&self) {
        let mut st = self.shared.lock();
        if st.writable() && st.appended > 0 {
            st.save_checkpoint();
        }
        st.closed = true;
        self.shared.changed.notify_all();
        self.shared.unlock(st);
        drop(self.lock.lock().expect("optchat lock poisoned").take());
    }
}

impl Drop for OptChat {
    fn drop(&mut self) {
        self.shutdown();
    }
}
