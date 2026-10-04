//! The thread-safe facade: one `OptChat` per chat directory per machine.

use std::collections::BTreeMap;
use std::fmt;
use std::io;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use optchat_core::{render_view, zoom, Kind, Memory, NodeId, RenderedView, Store, ZoomError};

use crate::anthropic::AnthropicModel;
use crate::cap::cap_tool_result;
use crate::clock::{Clock, SystemClock};
use crate::compactor::{drive, Shared, State};
use crate::config::Config;
use crate::files::FileStore;
use crate::lines;
use crate::lock::{ChatLock, LockError};
use crate::model::CompactModel;

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

/// One open chat: the lock, the store, the memory and the compactor.
pub struct OptChat {
    shared: Arc<Shared>,
    lock: Mutex<Option<ChatLock>>,
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

    /// Opens `dir`: takes the lock, loads the store (reporting torn lines),
    /// folds the view again from message 0 (section 5.2) and starts the
    /// compactor. `fallback` builds the nodes `model` declines.
    pub fn open_with_fallback(
        dir: impl AsRef<Path>,
        config: Config,
        model: Arc<dyn CompactModel>,
        fallback: Option<Arc<dyn CompactModel>>,
        clock: Arc<dyn Clock>,
    ) -> Result<OptChat, Error> {
        let dir = dir.as_ref();
        crate::files::private_dir(dir)?;
        let lock = match ChatLock::acquire(dir) {
            Ok(l) => l,
            Err(LockError::Held) => return Err(Error::Locked),
            Err(LockError::Io(e)) => return Err(Error::Io(e)),
        };
        let mut reports = Vec::new();
        let loaded = FileStore::open(dir, &mut reports);
        for r in &reports {
            (config.reporter)(r);
        }
        let (store, built) = loaded?;
        let memory = Memory::load(store.len(), built, config.budget);
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                memory,
                store,
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
        shared.unlock(st);
        Ok(OptChat {
            shared,
            lock: Mutex::new(Some(lock)),
        })
    }

    /// Logs one message (fsynced) and returns its id. Tool results (`Echo`)
    /// are capped at `CAP` characters first (section 7).
    pub fn append(&self, kind: Kind, text: &str) -> Result<u64, Error> {
        let text = if kind == Kind::Echo {
            cap_tool_result(text)
        } else {
            text.into()
        };
        let mut st = self.shared.lock();
        if st.closed {
            return Err(Error::Closed);
        }
        if let Some(e) = &st.fatal {
            return Err(Error::Fatal(e.clone()));
        }
        let id = match st.store.append_message(kind, &text) {
            Ok(id) => id,
            Err(e) => {
                st.set_fatal(format!("writing message: {e}"));
                self.shared.changed.notify_all();
                self.shared.unlock(st);
                return Err(Error::Io(e));
            }
        };
        let in_memory = st.memory.append();
        debug_assert_eq!(id, in_memory);
        drive(&self.shared, &mut st);
        self.shared.unlock(st);
        Ok(id)
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
