//! The tree a refresh read, held for the next one: a refresh sends what it holds as `known`
//! (`list-workspaces-known-v1`), so an unchanged tree costs the daemon an O(1) answer and the
//! client no parse, and a changed one is read whole as before.

use std::time::{Duration, Instant};

use super::*;

const KNOWN: &str = "list-workspaces-known-v1";

/// A daemon that answers `list-workspaces` with `known` as list_workspaces_page.rs does.
#[derive(Default)]
struct StubDaemon {
    revision: u64,
    title: String,
    /// Whole trees built and sent.
    whole: usize,
    /// `unchanged` answers.
    unchanged: usize,
    /// Each `list-workspaces` request's `known`, `Value::Null` when it sent none.
    known_sent: Vec<Value>,
    /// Answers `unchanged` to any `known`, even one naming another tree (a broken daemon).
    unchanged_to_any_known: bool,
    /// What building a whole tree costs (the slow read).
    build: Duration,
}

impl StubDaemon {
    fn identity(&self) -> Value {
        json!({
            "registry_id": "registry",
            "generation": "generation",
            "workspace_revision": 1,
            "pane_revision": 1,
            "terminal_revision": 1,
            "tree_revision": format!("boot.{}", self.revision),
        })
    }

    fn list(&mut self, request: &Value) -> Value {
        let known = request.get("known").cloned().unwrap_or(Value::Null);
        self.known_sent.push(known.clone());
        let identity = self.identity();
        if !known.is_null() && (known == identity || self.unchanged_to_any_known) {
            self.unchanged += 1;
            let mut reply = identity;
            reply["unchanged"] = json!(true);
            reply["workspaces"] = json!([]);
            return reply;
        }
        self.whole += 1;
        std::thread::sleep(self.build);
        let mut reply = json!({
            "workspaces": [{
                "id": 1,
                "active": true,
                "screens": [{
                    "id": 2,
                    "active": true,
                    "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "active_tab": 0,
                        "tabs": [
                            {"surface": 4, "kind": "pty", "title": self.title},
                            {"surface": 5, "kind": "pty", "title": "second"},
                        ],
                    }],
                }],
            }],
        });
        for (key, value) in identity.as_object().unwrap() {
            reply[key] = value.clone();
        }
        reply
    }
}

struct StubDaemonWriter {
    session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    daemon: Arc<Mutex<StubDaemon>>,
}

impl RemoteMessageWriter for StubDaemonWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
        let data = match request.get("cmd").and_then(Value::as_str) {
            Some("list-workspaces") => self.daemon.lock().unwrap().list(&request),
            Some("list-agents") => json!({"agents": []}),
            command => {
                return Err(io::Error::other(format!("unexpected command {command:?}")));
            }
        };
        let session = self
            .session
            .lock()
            .unwrap()
            .as_ref()
            .and_then(Weak::upgrade)
            .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
        let pending = session
            .pending
            .lock()
            .unwrap()
            .remove(&id)
            .ok_or_else(|| io::Error::other("remote request was not pending"))?;
        pending
            .response
            .send(json!({"id": id, "ok": true, "data": data}))
            .map_err(|_| io::Error::other("remote response receiver was dropped"))
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn session_with(
    capabilities: &[&str],
    build: Duration,
) -> (Arc<RemoteSession>, Arc<Mutex<StubDaemon>>) {
    let daemon = Arc::new(Mutex::new(StubDaemon {
        title: "first".to_string(),
        build,
        ..StubDaemon::default()
    }));
    let slot = Arc::new(Mutex::new(None));
    let session = test_session_with_provider_context(
        Box::new(StubDaemonWriter { session: slot.clone(), daemon: daemon.clone() }),
        capabilities.iter().map(|capability| capability.to_string()).collect(),
        None,
    );
    *slot.lock().unwrap() = Some(Arc::downgrade(&session));
    (session, daemon)
}

fn tab_titles(tree: &TreeView) -> Vec<(SurfaceId, String)> {
    tree.workspaces()
        .iter()
        .flat_map(|workspace| workspace.screens.iter())
        .flat_map(|screen| screen.panes.iter())
        .flat_map(|pane| pane.tabs.iter())
        .map(|tab| (tab.surface, tab.title.clone()))
        .collect()
}

#[test]
fn a_second_refresh_of_an_unchanged_tree_sends_known_and_reads_no_tree() {
    let (session, daemon) = session_with(&[KNOWN], Duration::ZERO);

    let first = session.refresh_tree().unwrap();
    let second = session.refresh_tree().unwrap();

    let daemon = daemon.lock().unwrap();
    assert!(daemon.known_sent[0].is_null(), "a client that holds no tree sends no known");
    assert_eq!(daemon.known_sent[1], daemon.identity(), "the second refresh sends what it holds");
    assert_eq!((daemon.whole, daemon.unchanged), (1, 1));
    assert_eq!(tab_titles(&second), tab_titles(&first));
    assert_eq!(tab_titles(&session.cached_tree()), tab_titles(&first));
}

#[test]
fn a_tree_change_after_a_held_tree_reads_the_whole_tree() {
    let (session, daemon) = session_with(&[KNOWN], Duration::ZERO);
    session.refresh_tree().unwrap();
    {
        let mut daemon = daemon.lock().unwrap();
        daemon.revision += 1;
        daemon.title = "renamed".to_string();
    }
    session.handle_line(json!({"event": "tree-changed"}));

    let tree = session.refresh_tree().unwrap();

    assert_eq!(tab_titles(&tree)[0], (4, "renamed".to_string()));
    let daemon = daemon.lock().unwrap();
    assert_eq!((daemon.whole, daemon.unchanged), (2, 0));
}

#[test]
fn an_unchanged_refresh_still_drops_a_surface_retired_since_the_held_read() {
    let (session, daemon) = session_with(&[KNOWN], Duration::ZERO);
    session.refresh_tree().unwrap();
    session.retired_surfaces.lock().unwrap().insert(5);

    let tree = session.refresh_tree().unwrap();

    assert_eq!(daemon.lock().unwrap().unchanged, 1);
    assert_eq!(tab_titles(&tree), vec![(4, "first".to_string())]);
}

#[test]
fn a_daemon_without_the_capability_is_never_sent_known() {
    let (session, daemon) = session_with(&[], Duration::ZERO);

    session.refresh_tree().unwrap();
    session.refresh_tree().unwrap();

    let daemon = daemon.lock().unwrap();
    assert!(daemon.known_sent.iter().all(Value::is_null), "{:?}", daemon.known_sent);
    assert_eq!(daemon.whole, 2);
}

/// Bench-style: ten refreshes of a tree whose whole read costs 25 ms. Before the held tree each
/// refresh read the whole tree (10 reads, about 250 ms); with it only the first one does.
#[test]
fn refreshes_of_an_unchanged_tree_do_not_wait_for_the_whole_read() {
    const REFRESHES: usize = 10;
    let build = Duration::from_millis(25);
    let (session, daemon) = session_with(&[KNOWN], build);

    let started = Instant::now();
    for _ in 0..REFRESHES {
        session.refresh_tree().unwrap();
    }
    let elapsed = started.elapsed();

    let daemon = daemon.lock().unwrap();
    eprintln!(
        "held tree bench: {REFRESHES} refreshes, {} whole reads, {} unchanged, {elapsed:?}",
        daemon.whole, daemon.unchanged
    );
    assert_eq!(daemon.whole, 1, "only the first refresh reads the whole tree");
    assert_eq!(daemon.unchanged, REFRESHES - 1);
    assert!(elapsed < build * 5, "{REFRESHES} refreshes took {elapsed:?}");
}

#[test]
fn a_tree_event_marks_the_held_tree_stale_and_the_next_read_holds_it_fresh() {
    let (session, daemon) = session_with(&[KNOWN], Duration::ZERO);
    assert_eq!(session.held_tree_state(), None);
    session.refresh_tree().unwrap();
    assert_eq!(session.held_tree_state(), Some(true));

    for event in [
        json!({"event": "tree-changed"}),
        json!({"event": "layout-changed"}),
        json!({"event": "surface-exited", "surface": 5}),
    ] {
        session.handle_line(event.clone());
        assert_eq!(session.held_tree_state(), Some(false), "{event}");
        // A held tree the client knows changed is read whole, with no `known`.
        session.refresh_tree().unwrap();
        assert!(daemon.lock().unwrap().known_sent.last().unwrap().is_null(), "{event}");
        assert_eq!(session.held_tree_state(), Some(true), "{event}");
    }
    session.invalidate_tree();
    assert_eq!(session.held_tree_state(), Some(false));
}

#[test]
fn an_unchanged_answer_that_names_another_tree_is_refused_and_keeps_the_cached_tree() {
    let (session, daemon) = session_with(&[KNOWN], Duration::ZERO);
    let first = session.refresh_tree().unwrap();
    {
        let mut daemon = daemon.lock().unwrap();
        daemon.revision += 1;
        daemon.unchanged_to_any_known = true;
    }

    let Err(error) = session.refresh_tree() else {
        panic!("an unchanged answer naming another tree was accepted");
    };

    assert!(error.to_string().contains("unchanged"), "{error}");
    assert_eq!(tab_titles(&session.cached_tree()), tab_titles(&first));
    assert_eq!(session.held_tree_state(), None, "the held tree is dropped");
    assert!(session.tree_is_stale(), "the refresh is retried");
    // The retry holds no tree, sends no known and reads the whole tree.
    daemon.lock().unwrap().unchanged_to_any_known = false;
    session.refresh_tree().unwrap();
    assert!(daemon.lock().unwrap().known_sent.last().unwrap().is_null());
}
