//! The chat-index project sources (plans/cmux-next/projects.md section 3).
//! acpmux owns this machine's chat index and groups it into each harness's
//! project folders (`_acpmux/chat_projects`: every absolute chat folder with
//! the time of its newest chat). The daemon reads that list itself and
//! imports each harness whose list changed as one complete source
//! (`claude-code`, `codex`, ...), under the rules of `project.observe`: the
//! reducer normalizes and merges the paths and keeps the user's overlay. No
//! other process relays the list (layer-ownership.md L2: one writer path into
//! the project store).
//!
//! One connection follows the index (`_acpmux/chats_watch` with a one-chat
//! page: the watch is only the change signal). The watch's answer, each index
//! change (a chat added, changed or removed; not a chat's activity) and each
//! lag read the grouped list again, one read at a time: changes that come
//! during a read fold into one more read. Nothing is imported while acpmux's
//! index has not started, chats are off or the read failed: a partial list
//! imported as complete would drop the harness from its projects. A harness
//! imported before that lists no folder now gets an empty complete list.
//!
//! The thread starts with the agent chat watch (`agent_chat_notices.rs`) and
//! connects each time that watch reaches acpmux, so it shares that watch's
//! socket watch and never wakes on a timer. A connection that ends waits for
//! the next time the chat watch reaches acpmux. While the daemon runs, each
//! harness's last imported list is kept, so a reconnect imports only what
//! changed.

use std::collections::{BTreeMap, HashMap};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::sync::{Arc, Mutex, MutexGuard, Weak};

use serde_json::{Value, json};

use super::Mux;
use crate::state::projects::Observation;

/// The id of the index watch request on each connection.
const WATCH_ID: u64 = 2;

/// Each harness's last imported list, by harness id.
type Imported = HashMap<String, Vec<Observation>>;

/// The thread's wake and the live connection, so it ends with its mux:
/// taking the sender ends a thread that waits for a wake, and shutting the
/// connection ends one that waits on acpmux's next line.
#[derive(Default)]
pub(super) struct ProjectChatsWake(Mutex<Wakes>);

#[derive(Default)]
struct Wakes {
    wake: Option<SyncSender<()>>,
    connection: Option<UnixStream>,
    stopped: bool,
}

impl Wakes {
    fn stop(&mut self) {
        self.stopped = true;
        self.wake = None;
        if let Some(connection) = self.connection.take() {
            let _ = connection.shutdown(std::net::Shutdown::Both);
        }
    }
}

impl ProjectChatsWake {
    fn lock(&self) -> MutexGuard<'_, Wakes> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Drop for ProjectChatsWake {
    fn drop(&mut self) {
        self.lock().stop();
    }
}

impl Mux {
    /// Starts the chat-index import of acpmux at `socket` (once) and tries a
    /// first connection at once.
    pub(super) fn start_project_chats(self: &Arc<Self>, socket: PathBuf) {
        let (wake, woken) = sync_channel(1);
        {
            let mut wakes = self.project_chats.lock();
            if wakes.stopped || wakes.wake.is_some() {
                return;
            }
            wakes.wake = Some(wake);
        }
        let mux = Arc::downgrade(self);
        let spawned = std::thread::Builder::new()
            .name("mux-project-chats".into())
            .stack_size(256 * 1024)
            .spawn(move || run(&mux, &socket, &woken));
        if spawned.is_err() {
            self.report_internal_diagnostic("chat project import not started");
            return;
        }
        self.wake_project_chats();
    }

    /// acpmux listens (again): connect when no connection is up. Wakes that
    /// come during a connection fold into one try after it.
    pub(super) fn wake_project_chats(&self) {
        if let Some(wake) = &self.project_chats.lock().wake {
            let _ = wake.try_send(());
        }
    }

    /// Ends the thread, whether it waits for a wake or for acpmux (shutdown).
    pub(super) fn stop_project_chats(&self) {
        self.project_chats.lock().stop();
    }

    /// Keeps a clone of the live connection so a stop can end its read; false
    /// when the import already stopped.
    fn hold_project_chats_connection(&self, stream: &UnixStream) -> bool {
        let mut wakes = self.project_chats.lock();
        if wakes.stopped {
            return false;
        }
        wakes.connection = stream.try_clone().ok();
        true
    }

    fn release_project_chats_connection(&self) {
        self.project_chats.lock().connection = None;
    }
}

fn daemon_runs(mux: &Weak<Mux>) -> bool {
    mux.upgrade().is_some_and(|live| !live.shutting_down.load(std::sync::atomic::Ordering::Acquire))
}

fn run(mux: &Weak<Mux>, socket: &Path, woken: &Receiver<()>) {
    let mut imported = Imported::new();
    while woken.recv().is_ok() {
        if !daemon_runs(mux) {
            return;
        }
        // Nothing listens: the chat watch wakes this thread when acpmux does.
        let Ok(stream) = UnixStream::connect(socket) else { continue };
        {
            let Some(live) = mux.upgrade() else { return };
            if !live.hold_project_chats_connection(&stream) {
                return;
            }
        }
        if let Err(error) = follow(mux, stream, &mut imported) {
            eprintln!("cmux-tui: chat project import connection ended: {error}");
        }
        if let Some(live) = mux.upgrade() {
            live.release_project_chats_connection();
        }
    }
}

/// What one line from acpmux means for the import.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Signal {
    /// The watch is on, the index changed or the watch lagged: read the list.
    Changed,
    /// The answer to the read in flight (an error answer imports nothing).
    Projects,
    Other,
}

/// `asked` is the id of the `_acpmux/chat_projects` read in flight.
fn signal(message: &Value, asked: Option<u64>) -> Signal {
    if let Some(id) = message.get("id").and_then(Value::as_u64) {
        return if Some(id) == asked {
            Signal::Projects
        } else if id == WATCH_ID && message.get("result").is_some_and(Value::is_object) {
            Signal::Changed
        } else {
            Signal::Other
        };
    }
    let params = message.get("params");
    let param = |name: &str| params.and_then(|params| params.get(name)).and_then(Value::as_str);
    match message.get("method").and_then(Value::as_str) {
        // A chat's activity (attention, preview) changes no folder.
        Some("_acpmux/chat_changed") if param("kind") != Some("activity") => Signal::Changed,
        // A message past one frame never fits: asking again would send it again forever.
        Some("_acpmux/lagged") if param("reason") == Some("message_too_large") => Signal::Other,
        Some("_acpmux/chats_lagged" | "_acpmux/lagged") => Signal::Changed,
        _ => Signal::Other,
    }
}

/// The harness lists of a `_acpmux/chat_projects` answer to import, leaving
/// out each one equal to its `imported` list. A harness in `imported` with no
/// folder left gets an empty complete list. By harness id, entries by path.
/// Nothing while the index is not ready or chats are off.
fn batches(result: &Value, imported: &Imported) -> Vec<(String, Vec<Observation>)> {
    let ready = result.get("ready").and_then(Value::as_bool).unwrap_or(false);
    let enabled = result.get("enabled").and_then(Value::as_bool).unwrap_or(true);
    if !ready || !enabled {
        return Vec::new();
    }
    let mut by_source: BTreeMap<String, Vec<Observation>> = BTreeMap::new();
    let rows = result.get("projects").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
    for row in rows {
        let field = |name: &str| row.get(name);
        let time = field("lastUsedMs");
        let last_used_ms = time
            .and_then(Value::as_i64)
            .or_else(|| time.and_then(Value::as_f64).map(|ms| ms as i64));
        let (Some(harness), Some(path), Some(last_used_ms)) = (
            field("harness").and_then(Value::as_str),
            field("path").and_then(Value::as_str),
            last_used_ms,
        ) else {
            continue;
        };
        by_source
            .entry(harness.to_owned())
            .or_default()
            .push(Observation { path: path.to_owned(), last_used_ms });
    }
    for source in imported.keys() {
        by_source.entry(source.clone()).or_default();
    }
    by_source
        .into_iter()
        .filter_map(|(source, mut entries)| {
            entries.sort_by(|a, b| a.path.cmp(&b.path));
            (imported.get(&source) != Some(&entries)).then_some((source, entries))
        })
        .collect()
}

/// Imports each changed harness list as its own commit, so a list the store
/// refuses (a bad harness id, too many folders) holds up no other harness.
fn import(mux: &Mux, result: &Value, imported: &mut Imported) {
    for (source, entries) in batches(result, imported) {
        match mux.state_project_import_lists(&[(source.as_str(), entries.as_slice())]) {
            Ok(_) => {
                imported.insert(source, entries);
            }
            Err(error) => eprintln!("cmux-tui: chat project import of {source} failed: {error}"),
        }
    }
}

/// The reads of one connection: at most one in flight, and whether a change
/// came during it.
struct Reads {
    asked: Option<u64>,
    again: bool,
    next_id: u64,
}

impl Reads {
    fn ask(&mut self, writer: &mut impl Write) -> std::io::Result<()> {
        if self.asked.is_some() {
            self.again = true;
            return Ok(());
        }
        let id = self.next_id;
        self.next_id += 1;
        let read =
            json!({"jsonrpc": "2.0", "id": id, "method": "_acpmux/chat_projects", "params": {}});
        writer.write_all(format!("{read}\n").as_bytes())?;
        self.asked = Some(id);
        Ok(())
    }
}

/// One connection, followed until it ends.
fn follow(mux: &Weak<Mux>, stream: UnixStream, imported: &mut Imported) -> std::io::Result<()> {
    let mut writer = stream.try_clone()?;
    let initialize = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": 1,
        "clientInfo": {"name": "cmux-tui-project-chats", "version": "1"},
        "clientCapabilities": {},
    }});
    let watch = json!({"jsonrpc": "2.0", "id": WATCH_ID, "method": "_acpmux/chats_watch",
        "params": {"enabled": true, "limit": 1}});
    writer.write_all(format!("{initialize}\n{watch}\n").as_bytes())?;
    let mut reader = BufReader::new(stream);
    let mut reads = Reads { asked: None, again: false, next_id: WATCH_ID + 1 };
    loop {
        // A whole line however long: the grouped list has one row per chat folder.
        let mut line = Vec::new();
        if reader.read_until(b'\n', &mut line)? == 0 {
            return Ok(());
        }
        if line.last() != Some(&b'\n') {
            return Err(std::io::Error::other("acpmux cut a line short"));
        }
        let Ok(message) = serde_json::from_slice::<Value>(&line) else { continue };
        match signal(&message, reads.asked) {
            Signal::Changed => reads.ask(&mut writer)?,
            Signal::Projects => {
                reads.asked = None;
                let Some(live) = mux.upgrade() else { return Ok(()) };
                import(&live, message.get("result").unwrap_or(&Value::Null), imported);
                if std::mem::take(&mut reads.again) {
                    reads.ask(&mut writer)?;
                }
            }
            Signal::Other => {}
        }
    }
}

#[cfg(test)]
#[path = "project_chats_tests.rs"]
mod tests;
