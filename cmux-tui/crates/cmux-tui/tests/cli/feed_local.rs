//! The daemon's local feed owner (`feed-local-owner-v1`, plans/cmux-next/
//! feed.md 9.1) at its socket boundary. Each test starts a real daemon with
//! `server ensure --install-key-stdin`, so one connection can prove itself as
//! the cmux app (`client-hello`) the way the app does, and drives
//! `notify`, `ack-tab-notifications`, `feed-local-*` and the tree commands
//! over the socket.

use std::os::unix::net::UnixStream;

use cmux_tui_core::server::frontend_proof::{NONCE_LEN, hello_proof, unhex};
use serde_json::{Value, json};

use super::*;

const KEY_HEX: &str = "8f0e1d2c3b4a59687766554433221100ffeeddccbbaa99887766554433221100";
const INSTALL: &str = "inst_feed_app";

struct Daemon {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Daemon {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-feed-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let daemon = Self { socket: dir.join("mux.sock"), session: format!("feed-{name}"), dir };
        daemon.ensure();
        daemon
    }

    fn server(&self, action: &str) -> Command {
        let mut command = Command::new(bin());
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"));
        command
    }

    /// Start (or restart) the owner holding the app's install key.
    fn ensure(&self) {
        let mut child = self
            .server("ensure")
            .arg("--install-key-stdin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let key = format!("cmuxik1 {INSTALL} {KEY_HEX}\n");
        child.stdin.take().unwrap().write_all(key.as_bytes()).unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "ensure failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    /// Stop the owner and start a new one on the same state; terminal hosts
    /// outlive the owner and are adopted again.
    fn restart(&self) {
        let output = self.server("stop").output().unwrap();
        assert!(
            output.status.success(),
            "stop failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        self.ensure();
    }

    /// A plain local connection (an agent or a script in a pane).
    fn plain(&self) -> Client {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
        Client(BufReader::new(stream))
    }

    /// A connection proven as the cmux app (the `frontend` actor).
    fn app(&self) -> Client {
        let mut client = self.plain();
        let challenge = client
            .rpc(json!({"id": 1, "cmd": "client-hello", "role": "main", "install_id": INSTALL}));
        let nonce = unhex::<NONCE_LEN>(challenge["data"]["nonce"].as_str().unwrap()).unwrap();
        let proof = hello_proof(&unhex::<32>(KEY_HEX).unwrap(), INSTALL, &nonce);
        let proved = client
            .rpc(json!({"id": 2, "cmd": "client-hello", "install_id": INSTALL, "proof": proof}));
        assert_eq!(proved["data"]["verified"], true, "{proved}");
        client
    }

    /// One request on a fresh plain connection; its `data` on success.
    fn ok(&self, request: Value) -> Value {
        let response = self.plain().rpc(request);
        assert_eq!(response["ok"], true, "request failed: {response}");
        response["data"].clone()
    }

    fn tree(&self) -> Value {
        self.ok(json!({"id": "tree", "cmd": "list-workspaces"}))
    }

    fn items(&self) -> Vec<Value> {
        self.ok(json!({"id": "list", "cmd": "feed-local-list"}))["items"]
            .as_array()
            .unwrap()
            .clone()
    }

    fn notify(&self, title: &str, surface: Option<u64>) {
        self.ok(json!({"id": "notify", "cmd": "notify", "title": title, "body": "", "surface": surface}));
    }

    fn registry_file(&self) -> PathBuf {
        let mut stack = vec![self.dir.join("state")];
        while let Some(dir) = stack.pop() {
            for entry in fs::read_dir(&dir).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    stack.push(path);
                } else if path.file_name().is_some_and(|name| name == "workspace-registry.sqlite3")
                {
                    return path;
                }
            }
        }
        panic!("no workspace registry under {}", self.dir.display());
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.server("stop").arg("--end-terminals").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

struct Client(BufReader<UnixStream>);

impl Client {
    /// One request; event lines that arrive first are skipped.
    fn rpc(&mut self, request: Value) -> Value {
        writeln!(self.0.get_mut(), "{request}").unwrap();
        loop {
            let response = self.line();
            if response.get("event").is_none() {
                return response;
            }
        }
    }

    fn line(&mut self) -> Value {
        let mut line = String::new();
        assert_ne!(self.0.read_line(&mut line).unwrap(), 0, "the daemon closed the connection");
        serde_json::from_str(&line).unwrap()
    }
}

fn tabs(tree: &Value) -> Vec<(Value, Value)> {
    let array = |value: &Value, key: &str| value[key].as_array().cloned().unwrap_or_default();
    let mut found = Vec::new();
    for workspace in array(tree, "workspaces") {
        for screen in array(&workspace, "screens") {
            for pane in array(&screen, "panes") {
                for tab in array(&pane, "tabs") {
                    found.push((pane.clone(), tab));
                }
            }
        }
    }
    found
}

fn tab(tree: &Value, surface: u64) -> (Value, Value) {
    tabs(tree)
        .into_iter()
        .find(|(_, tab)| tab["surface"].as_u64() == Some(surface))
        .unwrap_or_else(|| panic!("surface {surface} is not in the tree: {tree}"))
}

fn unread(tree: &Value, surface: u64) -> bool {
    tab(tree, surface).1["notification"]["unread"] == true
}

fn new_workspace(daemon: &Daemon) -> u64 {
    daemon.ok(json!({"id": "ws", "cmd": "new-workspace"}))["surface"].as_u64().unwrap()
}

fn new_tab(daemon: &Daemon, beside: u64) -> u64 {
    let pane = tab(&daemon.tree(), beside).0["id"].clone();
    daemon.ok(json!({"id": "tab", "cmd": "new-tab", "pane": pane}))["surface"].as_u64().unwrap()
}

fn item_titled(daemon: &Daemon, title: &str) -> Value {
    daemon
        .items()
        .into_iter()
        .find(|item| item["title"] == title)
        .unwrap_or_else(|| panic!("no local item {title:?}: {:?}", daemon.items()))
}

fn is_unread(item: &Value) -> bool {
    item["read_at_ms"].is_null()
}

/// Selecting a tab no longer clears its unread marker or its local item;
/// `ack-tab-notifications` clears both.
#[test]
fn cmux_next_feed_selecting_a_tab_keeps_unread_and_the_ack_clears_it() {
    let daemon = Daemon::start("select");
    let first = new_workspace(&daemon);
    let second = new_tab(&daemon, first);
    daemon.notify("build done", Some(first));
    assert!(unread(&daemon.tree(), first));
    let pane = tab(&daemon.tree(), first).0["id"].clone();
    daemon.ok(json!({"id": "select", "cmd": "select-tab", "pane": pane, "index": 0}));
    daemon.ok(json!({"id": "select", "cmd": "select-tab", "pane": pane, "index": 1}));
    assert!(unread(&daemon.tree(), first), "selection never clears unread");
    assert!(is_unread(&item_titled(&daemon, "build done")));

    let ack = daemon.ok(json!({"id": "ack", "cmd": "ack-tab-notifications", "surface": first}));
    assert_eq!(ack["cleared"], true, "{ack}");
    assert!(!unread(&daemon.tree(), first));
    assert!(!is_unread(&item_titled(&daemon, "build done")));
    assert!(!unread(&daemon.tree(), second));
}

/// A tab ack that leaves an item unread (moved to the cloud owner) keeps
/// the ring, and a restart keeps it too.
#[test]
fn cmux_next_feed_a_ring_kept_by_a_partial_ack_survives_a_restart() {
    let daemon = Daemon::start("restart");
    let surface = new_workspace(&daemon);
    let terminal = tab(&daemon.tree(), surface).1["terminal_id"].as_str().unwrap().to_string();
    daemon.notify("agent waiting", Some(surface));
    let item = item_titled(&daemon, "agent waiting")["id"].clone();
    let mut app = daemon.app();
    let begun = app.rpc(json!({"id": 3, "cmd": "feed-local-handoff-begin", "item": item}));
    assert_eq!(begun["data"]["item"]["state"], "handing_off", "{begun}");
    let moved =
        app.rpc(json!({"id": 4, "cmd": "feed-local-handoff-done", "item": item, "home": "cloud"}));
    assert_eq!(moved["data"]["item"]["state"], "moved", "{moved}");

    let ack = daemon.ok(json!({"id": "ack", "cmd": "ack-tab-notifications", "surface": surface}));
    assert_eq!(ack["refused"][0]["code"], "owner.unreachable", "{ack}");
    assert_eq!(ack["cleared"], false, "{ack}");
    assert!(unread(&daemon.tree(), surface));
    let read = daemon.plain().rpc(json!({"id": "read", "cmd": "feed-local-read", "items": [item]}));
    assert_eq!(read["error_code"], "owner.unreachable", "{read}");

    daemon.restart();
    let tree = daemon.tree();
    let (_, restored) = tabs(&tree)
        .into_iter()
        .find(|(_, tab)| tab["terminal_id"] == terminal.as_str())
        .unwrap_or_else(|| panic!("terminal {terminal} came back without a tab: {tree}"));
    assert_eq!(restored["notification"]["unread"], true, "the ring was lost: {restored}");
}

/// Closing a terminal, or a browser tab (a tab without a terminal), reads
/// its open local items.
#[test]
fn cmux_next_feed_closing_a_terminal_or_a_browser_tab_reads_its_items() {
    let daemon = Daemon::start("close");
    let first = new_workspace(&daemon);
    let second = new_tab(&daemon, first);
    daemon.notify("terminal done", Some(second));
    let (_, closing) = tab(&daemon.tree(), second);
    daemon.ok(json!({
        "id": "close-terminal",
        "cmd": "close-terminal",
        "terminal_id": closing["terminal_id"],
        "terminal_incarnation": closing["terminal_incarnation"],
    }));
    assert!(!is_unread(&item_titled(&daemon, "terminal done")));

    let pane = tab(&daemon.tree(), first).0["id"].clone();
    let browser = daemon.ok(json!({
        "id": "browser",
        "cmd": "new-frontend-browser-tab",
        "url": "https://example.com/start",
        "engine": "webkit",
        "pane": pane,
    }))["surface"]
        .as_u64()
        .unwrap();
    daemon.notify("page done", Some(browser));
    let page = item_titled(&daemon, "page done");
    assert!(is_unread(&page) && page["context"]["tab"].is_string(), "{page}");
    daemon.ok(json!({"id": "close", "cmd": "close-surface", "surface": browser}));
    assert!(!is_unread(&item_titled(&daemon, "page done")));

    daemon.restart();
    assert!(daemon.items().iter().all(|item| !is_unread(item)), "{:?}", daemon.items());
}

/// The handoff steps change which owner holds an item: a connection that is
/// not the cmux app gets `forbidden`; reads and lists stay open to it.
#[test]
fn cmux_next_feed_a_handoff_from_a_connection_that_is_not_the_app_is_forbidden() {
    let daemon = Daemon::start("forbidden");
    let surface = new_workspace(&daemon);
    daemon.notify("done", Some(surface));
    let item = item_titled(&daemon, "done")["id"].clone();
    for (cmd, extra) in [
        ("feed-local-handoff-begin", json!({})),
        ("feed-local-handoff-abort", json!({})),
        ("feed-local-handoff-done", json!({"home": "cloud"})),
    ] {
        let mut request = json!({"id": cmd, "cmd": cmd, "item": item});
        if let Some(home) = extra.get("home") {
            request["home"] = home.clone();
        }
        let refused = daemon.plain().rpc(request);
        assert_eq!(refused["ok"], false, "{refused}");
        assert_eq!(refused["error_code"], "forbidden", "{refused}");
    }
    let read = daemon.ok(json!({"id": "read", "cmd": "feed-local-read", "items": [item]}));
    assert_eq!(read["items"][0]["state"], "open", "{read}");
}

/// The first start of the new daemon turns the retained notification
/// ledger of a registry written without the local owner into local items:
/// a terminal's notice keeps its tab, one with no terminal migrates read.
#[test]
fn cmux_next_feed_the_first_start_migrates_the_notification_ledger() {
    let daemon = Daemon::start("migrate");
    let surface = new_workspace(&daemon);
    daemon.notify("on a tab", Some(surface));
    daemon.notify("plain", None);
    let live = item_titled(&daemon, "on a tab");
    let output = daemon.server("stop").output().unwrap();
    assert!(output.status.success());
    // The registry as a daemon without the local owner left it.
    let db = rusqlite::Connection::open(daemon.registry_file()).unwrap();
    db.execute_batch(
        "DELETE FROM feed_local_items; DELETE FROM feed_local_folded;
         DELETE FROM meta WHERE key LIKE 'feed_local_%';",
    )
    .unwrap();
    drop(db);

    daemon.ensure();
    let migrated = item_titled(&daemon, "on a tab");
    assert!(is_unread(&migrated), "{migrated}");
    assert_eq!(migrated["context"], live["context"], "the migration keeps the tab context");
    assert!(!is_unread(&item_titled(&daemon, "plain")), "a notice with no tab migrates read");
    assert_eq!(daemon.items().len(), 2, "{:?}", daemon.items());
    daemon.restart();
    assert_eq!(daemon.items().len(), 2, "a second start adds nothing");
}

/// An app acknowledges a tab when the `notification` event says its pane
/// is in view. The event follows the commit, so that ack reads the item and
/// clears the ring every time.
#[test]
fn cmux_next_feed_an_ack_sent_on_the_notification_event_clears_the_ring() {
    let daemon = Daemon::start("event");
    let surface = new_workspace(&daemon);
    let mut events = daemon.plain();
    writeln!(events.0.get_mut(), "{}", json!({"id": "sub", "cmd": "subscribe"})).unwrap();
    assert_eq!(events.line()["ok"], true);
    for round in 0..10 {
        let title = format!("round {round}");
        daemon.notify(&title, Some(surface));
        loop {
            let event = events.line();
            if event["event"] == "notification" && event["title"] == title.as_str() {
                daemon.ok(json!({"id": "ack", "cmd": "ack-tab-notifications", "surface": surface}));
                break;
            }
        }
        assert!(!unread(&daemon.tree(), surface), "round {round}: the ring stayed");
        assert!(!is_unread(&item_titled(&daemon, &title)), "round {round}: the item stayed unread");
    }
}
