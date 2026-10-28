//! The app's action tools, held once per app by the shared MCP host
//! (`host.rs`) and read by every client it serves.
//!
//! A server keeps the tools of the last `action.list` it read as an
//! [`ActionCatalog`] behind an `Arc`. In the host, a client hands each list it
//! reads to the [`SharedCatalog`] thread, which keeps one catalog per app
//! control socket and gives back the kept one when the new list is the same,
//! so every client of an app points at one copy (Chromium keeps one copy of
//! shared state in the browser process and hands renderers handles to it).
//! The same thread runs one `action.catalog.changed` watcher per app and
//! wakes each of that app's clients to list the tools again. It never writes
//! to a client: each client's notifier thread writes its own notification, so
//! a client that reads nothing stalls only its own threads, as each per-agent
//! server's watcher thread did before.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, mpsc};

use serde_json::Value;

use super::super::GlobalArgs;
use super::action_tools::{self, ActionTool};
use super::{Exclusion, watch};

/// The tools of one `action.list` answer and the CLI actions it leaves out.
#[derive(Debug, Default, PartialEq)]
pub(super) struct ActionCatalog {
    pub tools: Vec<ActionTool>,
    pub exclusions: Vec<Exclusion>,
}

impl ActionCatalog {
    pub(super) fn parse(list: &Value) -> Self {
        let (tools, exclusions) = action_tools::from_list(list);
        Self { tools, exclusions }
    }

    pub(super) fn find(&self, name: &str) -> Option<&ActionTool> {
        self.tools.iter().find(|tool| tool.name == name)
    }
}

enum Message {
    /// A client read `catalog` from `app`: the kept catalog when equal.
    Intern {
        app: PathBuf,
        catalog: Arc<ActionCatalog>,
        reply: mpsc::Sender<Arc<ActionCatalog>>,
    },
    /// Wake `notify` (the client's notifier thread) when `app`'s actions
    /// change, until `Unwatch`.
    Watch {
        app: PathBuf,
        client: u64,
        notify: mpsc::Sender<()>,
    },
    Unwatch {
        app: PathBuf,
        client: u64,
    },
    /// `app` published `action.catalog.changed` or came back.
    Changed {
        app: PathBuf,
    },
}

/// Starts the watcher of one app, which sends [`Message::Changed`].
type StartWatcher = fn(PathBuf, mpsc::Sender<Message>);

/// The handle every client of the host shares.
#[derive(Clone)]
pub(super) struct SharedCatalog {
    sender: mpsc::Sender<Message>,
}

impl SharedCatalog {
    /// Starts the thread that owns the catalogs and the watchers.
    pub(super) fn start() -> std::io::Result<Self> {
        Self::start_with(start_watcher)
    }

    fn start_with(start_watcher: StartWatcher) -> std::io::Result<Self> {
        let (sender, receiver) = mpsc::channel();
        let watchers = sender.clone();
        cmux_threads::spawn("cmux-mcp-catalog", cmux_threads::ThreadQos::Utility, move || {
            Owner::new(start_watcher).run(&receiver, &watchers);
        })?;
        Ok(Self { sender })
    }

    /// A catalog thread that opens no app socket (tests).
    #[cfg(test)]
    pub(super) fn start_unwatched() -> std::io::Result<Self> {
        Self::start_with(|_, _| {})
    }

    /// As if `app` published `action.catalog.changed` (tests).
    #[cfg(test)]
    pub(super) fn changed(&self, app: PathBuf) {
        let _ = self.sender.send(Message::Changed { app });
    }

    /// The one catalog the host keeps for `app`, equal to `catalog`. With
    /// the owner thread gone, `catalog` itself.
    pub(super) fn intern(&self, app: PathBuf, catalog: Arc<ActionCatalog>) -> Arc<ActionCatalog> {
        let (reply, answer) = mpsc::channel();
        let fallback = catalog.clone();
        if self.sender.send(Message::Intern { app, catalog, reply }).is_err() {
            return fallback;
        }
        cmux_blocking::sync::recv(&answer).unwrap_or(fallback)
    }

    /// Writes `notifications/tools/list_changed` to `output` each time
    /// `app`'s actions change, from a notifier thread of this client's own.
    pub(super) fn watch(&self, app: PathBuf, client: u64, output: watch::Output) {
        match spawn_notifier(output) {
            Ok(notify) => {
                let _ = self.sender.send(Message::Watch { app, client, notify });
            }
            Err(error) => eprintln!("cmux mcp host: cannot watch the app's actions: {error}"),
        }
    }

    pub(super) fn unwatch(&self, app: PathBuf, client: u64) {
        let _ = self.sender.send(Message::Unwatch { app, client });
    }
}

/// The owner thread's state: one catalog and one watcher per app socket.
struct Owner {
    catalogs: HashMap<PathBuf, Arc<ActionCatalog>>,
    /// Each client's notifier, by the app it watches.
    clients: HashMap<PathBuf, Vec<(u64, mpsc::Sender<()>)>>,
    /// The apps whose watcher runs.
    watched: HashSet<PathBuf>,
    start_watcher: StartWatcher,
}

impl Owner {
    fn new(start_watcher: StartWatcher) -> Self {
        Self {
            catalogs: HashMap::new(),
            clients: HashMap::new(),
            watched: HashSet::new(),
            start_watcher,
        }
    }

    fn run(mut self, receiver: &mpsc::Receiver<Message>, watchers: &mpsc::Sender<Message>) {
        for message in receiver {
            match message {
                Message::Intern { app, catalog, reply } => {
                    let _ = reply.send(self.intern(app, catalog));
                }
                Message::Watch { app, client, notify } => {
                    if self.watched.insert(app.clone()) {
                        (self.start_watcher)(app.clone(), watchers.clone());
                    }
                    self.clients.entry(app).or_default().push((client, notify));
                }
                Message::Unwatch { app, client } => {
                    if let Some(clients) = self.clients.get_mut(&app) {
                        clients.retain(|(id, _)| *id != client);
                    }
                }
                Message::Changed { app } => {
                    // A send never blocks; a notifier that ended (its client
                    // stopped reading for good) leaves the list.
                    if let Some(clients) = self.clients.get_mut(&app) {
                        clients.retain(|(_, notify)| notify.send(()).is_ok());
                    }
                }
            }
        }
    }

    fn intern(&mut self, app: PathBuf, catalog: Arc<ActionCatalog>) -> Arc<ActionCatalog> {
        match self.catalogs.get(&app) {
            Some(kept) if **kept == *catalog => kept.clone(),
            _ => {
                self.catalogs.insert(app, catalog.clone());
                catalog
            }
        }
    }
}

/// A client's notifier thread: one notification for each wake, and one for
/// all the wakes that came while it wrote. It ends when the owner drops its
/// sender (the client's `Unwatch`) or a write fails (the client is gone).
fn spawn_notifier(output: watch::Output) -> std::io::Result<mpsc::Sender<()>> {
    let (notify, changes) = mpsc::channel::<()>();
    cmux_threads::spawn("cmux-mcp-client-notes", cmux_threads::ThreadQos::Utility, move || {
        while cmux_blocking::sync::recv(&changes).is_ok() {
            while changes.try_recv().is_ok() {}
            if output.tools_changed().is_err() {
                return;
            }
        }
    })?;
    Ok(notify)
}

/// One watcher for the app at `app` (its control socket), for the host's life.
fn start_watcher(app: PathBuf, watchers: mpsc::Sender<Message>) {
    let global = GlobalArgs { app_socket: Some(app.clone()), ..GlobalArgs::default() };
    watch::spawn(global, move || {
        let _ = watchers.send(Message::Changed { app: app.clone() });
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
    use std::os::unix::net::UnixStream;
    use std::time::Duration;

    fn list(titles: &[&str]) -> Value {
        let actions = titles
            .iter()
            .enumerate()
            .map(|(index, title)| {
                json!({"id": format!("a{index}"), "cli_name": format!("app action-{index}"),
                       "title": title, "cli": true,
                       "surfaces": {"cli": "offered", "mcp": "offered"}, "arguments": []})
            })
            .collect::<Vec<_>>();
        json!({ "actions": actions })
    }

    /// A client's output over a socket, and the agent's end of it.
    fn client() -> (watch::Output, UnixStream) {
        let (host, agent) = UnixStream::pair().unwrap();
        let output = watch::Output::new(host);
        output.set_ready();
        (output, agent)
    }

    #[test]
    fn clients_of_one_app_share_one_catalog() {
        let shared = SharedCatalog::start_unwatched().unwrap();
        let app = PathBuf::from("/tmp/app-a.sock");
        let first = shared.intern(app.clone(), Arc::new(ActionCatalog::parse(&list(&["One"]))));
        let second = shared.intern(app.clone(), Arc::new(ActionCatalog::parse(&list(&["One"]))));
        assert!(Arc::ptr_eq(&first, &second), "an equal list must reuse the kept catalog");
        assert_eq!(first.tools.len(), 1);
        let changed = shared.intern(app, Arc::new(ActionCatalog::parse(&list(&["Two"]))));
        assert!(!Arc::ptr_eq(&first, &changed), "a changed list replaces the catalog");
        let other = shared.intern(
            PathBuf::from("/tmp/app-b.sock"),
            Arc::new(ActionCatalog::parse(&list(&["Two"]))),
        );
        assert!(!Arc::ptr_eq(&changed, &other), "each app keeps its own catalog");
    }

    #[test]
    fn a_change_reaches_every_client_of_that_app_only() {
        let shared = SharedCatalog::start_unwatched().unwrap();
        let app = PathBuf::from("/tmp/app-a.sock");
        let other = PathBuf::from("/tmp/app-b.sock");
        let clients = (0..3).map(|_| client()).collect::<Vec<_>>();
        for (index, (target, (output, _))) in
            [&app, &app, &other].into_iter().zip(&clients).enumerate()
        {
            shared.watch(target.clone(), index as u64, output.clone());
        }
        shared.unwatch(app.clone(), 1);
        shared.changed(app);
        let agent = &clients[0].1;
        agent.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut note = String::new();
        BufReader::new(agent).read_line(&mut note).unwrap();
        assert!(note.contains("notifications/tools/list_changed"), "{note}");
        // The owner handles its messages in order: the unwatch and the other
        // app's client were settled before the change woke client 0.
        for (index, (_, agent)) in clients.iter().enumerate().skip(1) {
            agent.set_nonblocking(true).unwrap();
            let read = (&*agent).read(&mut [0u8; 64]);
            assert!(
                matches!(&read, Err(error) if error.kind() == ErrorKind::WouldBlock),
                "client {index} heard {read:?}"
            );
        }
    }

    #[test]
    fn a_client_that_never_reads_holds_up_no_other_client() {
        let shared = SharedCatalog::start_unwatched().unwrap();
        let app = PathBuf::from("/tmp/app-a.sock");
        // The stuck agent's socket is full, so the next write to it blocks.
        let (host, agent) = UnixStream::pair().unwrap();
        fill(&host);
        let stuck = watch::Output::new(host);
        stuck.set_ready();
        shared.watch(app.clone(), 1, stuck);
        for _ in 0..3 {
            shared.changed(app.clone());
        }
        let (answered, answer) = mpsc::channel();
        let other = shared;
        std::thread::spawn(move || {
            let kept = other.intern(app, Arc::new(ActionCatalog::parse(&list(&["One"]))));
            let _ = answered.send(kept.tools.len());
        });
        assert_eq!(
            answer.recv_timeout(Duration::from_secs(5)),
            Ok(1),
            "another client's tools/list waited on a client that reads nothing"
        );
        // The blocked notifier's write fails once the agent is gone.
        drop(agent);
    }

    /// Writes into `stream` until its socket buffer is full.
    fn fill(mut stream: &UnixStream) {
        stream.set_nonblocking(true).unwrap();
        let chunk = [b' '; 4096];
        loop {
            match stream.write(&chunk) {
                Ok(_) => {}
                Err(error) if error.kind() == ErrorKind::WouldBlock => break,
                Err(error) => panic!("fill: {error}"),
            }
        }
        stream.set_nonblocking(false).unwrap();
    }
}
