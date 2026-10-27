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
//! tells each of that app's clients to list the tools again.

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
    /// Tell `output` when `app`'s actions change, until `Unwatch`.
    Watch {
        app: PathBuf,
        client: u64,
        output: watch::Output,
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

/// The handle every client of the host shares.
#[derive(Clone)]
pub(super) struct SharedCatalog {
    sender: mpsc::Sender<Message>,
}

impl SharedCatalog {
    /// Starts the thread that owns the catalogs and the watchers.
    pub(super) fn start() -> std::io::Result<Self> {
        let (sender, receiver) = mpsc::channel();
        let watchers = sender.clone();
        cmux_threads::spawn("cmux-mcp-catalog", cmux_threads::ThreadQos::Utility, move || {
            Owner::default().run(&receiver, &watchers);
        })?;
        Ok(Self { sender })
    }

    /// The one catalog the host keeps for `app`, equal to `catalog`. With
    /// the owner thread gone, `catalog` itself.
    pub(super) fn intern(&self, app: PathBuf, catalog: Arc<ActionCatalog>) -> Arc<ActionCatalog> {
        let (reply, answer) = mpsc::channel();
        let fallback = catalog.clone();
        if self.sender.send(Message::Intern { app, catalog, reply }).is_err() {
            return fallback;
        }
        answer.recv().unwrap_or(fallback)
    }

    pub(super) fn watch(&self, app: PathBuf, client: u64, output: watch::Output) {
        let _ = self.sender.send(Message::Watch { app, client, output });
    }

    pub(super) fn unwatch(&self, app: PathBuf, client: u64) {
        let _ = self.sender.send(Message::Unwatch { app, client });
    }
}

/// The owner thread's state: one catalog and one watcher per app socket.
#[derive(Default)]
struct Owner {
    catalogs: HashMap<PathBuf, Arc<ActionCatalog>>,
    clients: HashMap<PathBuf, Vec<(u64, watch::Output)>>,
    /// The apps whose watcher runs.
    watched: HashSet<PathBuf>,
}

impl Owner {
    fn run(mut self, receiver: &mpsc::Receiver<Message>, watchers: &mpsc::Sender<Message>) {
        for message in receiver {
            match message {
                Message::Intern { app, catalog, reply } => {
                    let _ = reply.send(self.intern(app, catalog));
                }
                Message::Watch { app, client, output } => {
                    if self.watched.insert(app.clone()) {
                        start_watcher(app.clone(), watchers.clone());
                    }
                    self.clients.entry(app).or_default().push((client, output));
                }
                Message::Unwatch { app, client } => {
                    if let Some(clients) = self.clients.get_mut(&app) {
                        clients.retain(|(id, _)| *id != client);
                    }
                }
                Message::Changed { app } => {
                    for (_, output) in self.clients.get(&app).into_iter().flatten() {
                        let _ = output.tools_changed();
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

    #[test]
    fn clients_of_one_app_share_one_catalog() {
        let shared = SharedCatalog::start().unwrap();
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
        let (sender, receiver) = mpsc::channel();
        let mut owner = Owner::default();
        let app = PathBuf::from("/tmp/app-a.sock");
        let other = PathBuf::from("/tmp/app-b.sock");
        let buffers = (0..3).map(|_| Buffer::default()).collect::<Vec<_>>();
        let outputs = buffers
            .iter()
            .map(|buffer| {
                let output = watch::Output::new(buffer.clone());
                output.set_ready();
                output
            })
            .collect::<Vec<_>>();
        // The watchers are marked started so the test opens no app socket.
        owner.watched.insert(app.clone());
        owner.watched.insert(other.clone());
        for (client, (target, output)) in
            [(&app, &outputs[0]), (&app, &outputs[1]), (&other, &outputs[2])]
                .into_iter()
                .enumerate()
        {
            sender
                .send(Message::Watch {
                    app: target.clone(),
                    client: client as u64,
                    output: output.clone(),
                })
                .unwrap();
        }
        sender.send(Message::Unwatch { app: app.clone(), client: 1 }).unwrap();
        sender.send(Message::Changed { app }).unwrap();
        drop(sender);
        let (unused, _) = mpsc::channel();
        owner.run(&receiver, &unused);
        let notes = buffers.iter().map(Buffer::text).collect::<Vec<_>>();
        assert!(notes[0].contains("notifications/tools/list_changed"));
        assert!(notes[1].is_empty(), "a client that left hears nothing");
        assert!(notes[2].is_empty(), "another app's client hears nothing");
    }

    #[derive(Clone, Default)]
    struct Buffer(Arc<std::sync::Mutex<Vec<u8>>>);

    impl Buffer {
        fn text(&self) -> String {
            String::from_utf8(self.0.lock().unwrap().clone()).unwrap()
        }
    }

    impl std::io::Write for Buffer {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
}
