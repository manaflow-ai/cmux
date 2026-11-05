//! Test-only (#35971): a store that holds one blocking call at a seam, and a runtime with one
//! worker.
//!
//! `Store::flush_session` syncs a chat's log and its folders (with the journal store it may also
//! write the chat's `session.json` and wait for its record), and `Store::scan` reads the chat's
//! log: blocking disk work. A caller that runs such a call on a runtime worker holds that worker
//! for as long as the disk takes. On a runtime with one worker no other task runs meanwhile.
//!
//! [`assert_off_worker`] runs a caller on such a runtime and holds the store call at the seam.
//! When the call arrives, it starts a second task on the same runtime that only sends a note, and
//! it waits for that note before it lets the call go on. The note comes only when the call runs
//! off the worker (`tokio::task::spawn_blocking`).

use crate::store::{EventRecord, MemoryStore, RecordHead, SessionMeta, Store};
use anyhow::Result;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// A failure bound only, never an ordering timer: how long a test waits for the held call to
/// arrive, and then for the note.
pub(crate) const WAIT: Duration = Duration::from_secs(10);

/// The store call the seam holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Call {
    /// `flush_session`: the syncs of a chat's log and folders.
    Flush,
    /// `scan`: a read of a chat's log (the other reads go past the seam).
    Scan,
}

/// The next `call` after `pass` more of them: it says it arrived (with its chat's id), then
/// waits for the release.
struct Hold {
    call: Call,
    pass: usize,
    arrived: Sender<String>,
    release: Receiver<()>,
}

/// A memory store whose next `flush_session` or `scan` can be held ([`Seam::hold`]).
#[derive(Default)]
pub(crate) struct SeamStore {
    inner: MemoryStore,
    hold: Arc<Mutex<Option<Hold>>>,
}

/// The test's side of a [`SeamStore`]'s seam, kept after the store went into its hub.
pub(crate) struct Seam(Arc<Mutex<Option<Hold>>>);

/// One held call, from the test's side.
pub(crate) struct Held {
    arrived: Receiver<String>,
    release: Sender<()>,
}

impl SeamStore {
    pub(crate) fn new() -> (Self, Seam) {
        let store = Self::default();
        let seam = Seam(store.hold.clone());
        (store, seam)
    }

    /// Waits here when the seam holds this `call`.
    fn seam(&self, call: Call, id: &str) {
        let mut hold = self.hold.lock().unwrap_or_else(|e| e.into_inner());
        let Some(next) = hold.as_mut().filter(|next| next.call == call) else { return };
        if next.pass > 0 {
            next.pass -= 1;
            return;
        }
        let Some(held) = hold.take() else { return };
        drop(hold);
        let _ = held.arrived.send(id.to_owned());
        // A test that ended or failed dropped its side: the call goes on.
        let _ = held.release.recv();
    }
}

impl Seam {
    /// Holds the next `call` after `pass` more of them.
    pub(crate) fn hold(&self, call: Call, pass: usize) -> Held {
        let (arrived_tx, arrived) = channel();
        let (release, release_rx) = channel();
        let next = Hold { call, pass, arrived: arrived_tx, release: release_rx };
        *self.0.lock().unwrap_or_else(|e| e.into_inner()) = Some(next);
        Held { arrived, release }
    }
}

impl Held {
    /// The chat of the held call, once a caller reached it.
    fn arrived(&self) -> String {
        self.arrived.recv_timeout(WAIT).expect("no caller reached the held store call")
    }

    /// Whether a new task on `runtime` runs while the call is held: its note comes within
    /// [`WAIT`]. Then the held call goes on.
    fn worker_stays_free(self, runtime: &tokio::runtime::Runtime) -> bool {
        let (note, noted) = channel();
        runtime.spawn(async move {
            let _ = note.send(());
        });
        let free = noted.recv_timeout(WAIT).is_ok();
        let _ = self.release.send(());
        free
    }
}

/// A runtime with one worker: a blocking call on that worker stops every other task.
pub(crate) fn one_worker() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()
        .expect("a runtime with one worker")
}

/// Runs `caller` on `runtime` (from [`one_worker`]) and holds the store's next `call` (after
/// `pass` more) at the seam. Asserts that a second task on the runtime runs while the call is
/// held; `what` names the caller in the failure. Returns the held call's chat and what `caller`
/// returned.
pub(crate) fn assert_off_worker<T: Send + 'static>(
    runtime: &tokio::runtime::Runtime,
    seam: &Seam,
    call: Call,
    pass: usize,
    what: &str,
    caller: impl Future<Output = T> + Send + 'static,
) -> (String, T) {
    let held = seam.hold(call, pass);
    let task = runtime.spawn(caller);
    let chat = held.arrived();
    let free = held.worker_stays_free(runtime);
    assert!(
        free,
        "{what}: its {call:?} of chat {chat} ran on the runtime's only worker, and no other task \
         ran until it ended"
    );
    (chat, runtime.block_on(task).expect("the caller panicked"))
}

impl Store for SeamStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        self.inner.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        self.inner.append(id, record)
    }
    fn flush_session(&self, id: &str) -> Result<()> {
        self.seam(Call::Flush, id);
        self.inner.flush_session(id)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        self.inner.events(id, after, limit)
    }
    fn scan(&self, id: &str, after: u64, visit: &mut dyn FnMut(EventRecord) -> bool) -> Result<()> {
        self.seam(Call::Scan, id);
        self.inner.scan(id, after, visit)
    }
    // Every other read goes to the memory store, past the seam.
    fn scan_strict(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.inner.scan_strict(id, after, visit)
    }
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.inner.scan_back(id, after, before, skip, visit)
    }
    fn tail_after(&self, id: &str, after: u64) -> Result<(u64, u64)> {
        self.inner.tail_after(id, after)
    }
    fn scan_kinds(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.inner.scan_kinds(id, kinds, visit)
    }
    fn scan_kinds_strict(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.inner.scan_kinds_strict(id, kinds, visit)
    }
    fn scan_heads(&self, id: &str, visit: &mut dyn FnMut(&RecordHead<'_>) -> bool) -> Result<()> {
        self.inner.scan_heads(id, visit)
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.inner.delete(id)
    }
}
