//! A Cloud VM chat's child chats, end to end on one box with real processes
//! (`agent-session-children-v1`): a headless cmux-tui daemon and its own
//! acpmux running the test agent, reached as the app reaches a VM's daemon
//! over the Cloud link (a trusted local connection on its socket).
//!
//! The parent chat's tab is attached; its agent starts a child with
//! `cmux acp new` inside the session (`ACPMUX_SESSION_ID`, which tags the
//! child `spawnedBy`). The attachment hears the child appear as
//! `agent-session-changed`, `agent-session-children` lists exactly that
//! child (never the machine's other chat), and the child opens in a tab of
//! the VM's store that attaches to it, while the other chat is refused.
#![cfg(unix)]

mod journey_support;

use std::collections::VecDeque;
use std::fs;
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::{Value, json};

/// One long-lived control connection to the daemon, as the app's attach client keeps it.
struct Control {
    reader: BufReader<UnixStream>,
    events: VecDeque<Value>,
    next: u64,
}

impl Control {
    fn connect(machine: &Machine) -> Self {
        let stream = UnixStream::connect(&machine.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
        Self { reader: BufReader::new(stream), events: VecDeque::new(), next: 100 }
    }

    fn line(&mut self, deadline: Instant) -> Option<Value> {
        let mut line = String::new();
        while Instant::now() < deadline {
            match self.reader.read_line(&mut line) {
                Ok(0) => panic!("the daemon closed the connection"),
                Ok(_) if line.ends_with('\n') => return Some(serde_json::from_str(&line).unwrap()),
                Ok(_) => continue,
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    continue;
                }
                Err(e) => panic!("read failed: {e}"),
            }
        }
        None
    }

    fn request(&mut self, mut request: Value) -> Value {
        let id = self.next;
        self.next += 1;
        request["id"] = json!(id);
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        let deadline = Instant::now() + Duration::from_secs(60);
        loop {
            let line = self.line(deadline).expect("an answer");
            if line.get("event").is_some() {
                self.events.push_back(line);
            } else if line["id"] == json!(id) {
                return line;
            }
        }
    }

    /// The first `agent-session-changed` about `session`, within `secs`.
    fn changed(&mut self, session: &str, secs: u64) -> Option<Value> {
        let about = |event: &Value| {
            event["event"] == "agent-session-changed"
                && event["change"]["sessionId"] == json!(session)
        };
        if let Some(index) = self.events.iter().position(about) {
            return self.events.remove(index);
        }
        let deadline = Instant::now() + Duration::from_secs(secs);
        while let Some(line) = self.line(deadline) {
            if about(&line) {
                return Some(line);
            }
        }
        None
    }
}

/// An agent tab of `machine`'s store showing `session` (`host` names its machine).
fn chat_tab(machine: &Machine, host: &str, session: &str) -> Value {
    assert_eq!(machine.rpc(json!({"id": 2, "cmd": "new-workspace"}))["ok"], true);
    machine.rpc(json!({"id": 3, "cmd": "new-conversation-tab",
        "agent_session": {"host": host, "session": session, "harness": "fake"}}))
}

fn ids(reply: &Value) -> Vec<String> {
    reply["data"]["sessions"]
        .as_array()
        .unwrap_or_else(|| panic!("a session list: {reply}"))
        .iter()
        .map(|summary| summary["sessionId"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn session_children_journey_lists_follows_and_opens_a_vm_chats_child() {
    // A socket path must stay under SUN_LEN: a short folder under /tmp.
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("vcs-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());
    let vm = Machine::start(&root, "vm", Vec::new());
    let identity = vm.rpc(json!({"id": 1, "cmd": "identify"}));
    let capabilities = identity["data"]["capabilities"].as_array().unwrap();
    assert!(capabilities.contains(&json!("agent-session-children-v1")), "{identity}");
    let store = format!("registry:{}", identity["data"]["session_id"].as_str().unwrap());
    let cwd = vm.home().join("work");

    // The parent chat and another chat of the machine.
    let mut acpmux = vm.acpmux();
    let new = |acpmux: &mut Acpmux| {
        let created = acpmux.call("session/new", json!({"cwd": cwd, "mcpServers": []}));
        created["sessionId"].as_str().unwrap().to_owned()
    };
    let parent = new(&mut acpmux);
    let other = new(&mut acpmux);

    // The app shows the parent: its tab, attached on a connection of its own.
    let tab = chat_tab(&vm, "install:vm-child-journey", &parent);
    assert_eq!(tab["ok"], true, "{tab}");
    let surface = tab["data"]["surface"].as_u64().unwrap();
    let mut app = Control::connect(&vm);
    let attached = app.request(json!({"cmd": "agent-session-attach", "surface": surface,
                                      "limit": 50, "kinds": ["transcript"]}));
    assert_eq!(attached["ok"], true, "{attached}");
    assert!(
        ids(&app.request(json!({"cmd": "agent-session-children", "surface": surface}))).is_empty()
    );

    // The parent's agent starts a child inside its session, with the env
    // acpmux gave that agent: its session id and the caller token that
    // proves it (an unproven ACPMUX_SESSION_ID makes a root, no child).
    let mut agent_env = |name: &str| {
        acpmux.call("session/prompt", prompt(&parent, &format!("env: {name}"), name));
        let said = format!("{name}=");
        acpmux
            .events(&parent)
            .iter()
            .filter_map(|event| event["msg"].pointer(AGENT_TEXT)?.as_str()?.strip_prefix(&said))
            .find(|value| !value.is_empty())
            .unwrap_or_else(|| panic!("the parent's agent has {name}"))
            .to_owned()
    };
    let token = agent_env("ACPMUX_SESSION_TOKEN");
    let token_socket = agent_env("ACPMUX_SESSION_TOKEN_SOCKET");
    let started = vm
        .command()
        .args(["acp", "new", "--detach", "--name", "child-one", "--cwd"])
        .arg(&cwd)
        .env("ACPMUX_SESSION_ID", &parent)
        .env("ACPMUX_SESSION_TOKEN", token)
        .env("ACPMUX_SESSION_TOKEN_SOCKET", token_socket)
        .output()
        .unwrap();
    assert!(started.status.success(), "acp new: {}", String::from_utf8_lossy(&started.stderr));
    let child = wait_until(30, "the child tagged under its parent", || {
        let sessions = acpmux.call("_acpmux/sessions", json!({}));
        sessions["sessions"].as_array()?.iter().find_map(|summary| {
            (summary["spawnedBy"] == json!(parent))
                .then(|| summary["sessionId"].as_str().unwrap().to_owned())
        })
    });

    // The attachment heard it appear, and the list the app reads names it.
    let heard = app.changed(&child, 30).expect("the child's change on the parent's attachment");
    assert_eq!(heard["surface"], json!(surface));
    let listed = app.request(json!({"cmd": "agent-session-children", "surface": surface}));
    assert_eq!(listed["ok"], true, "{listed}");
    assert_eq!(
        ids(&listed),
        std::slice::from_ref(&child),
        "only the parent's child, never {other}"
    );
    assert_eq!(listed["data"]["sessions"][0]["spawnedBy"], json!(parent));
    assert!(app.changed(&other, 1).is_none(), "another chat's changes stay on the machine");

    // The child opens in a tab of the VM's store that shows it; the other chat does not.
    let opened = chat_tab(&vm, &store, &child);
    assert_eq!(opened["ok"], true, "{opened}");
    let child_surface = opened["data"]["surface"].as_u64().unwrap();
    let mut child_app = Control::connect(&vm);
    let page = child_app.request(json!({"cmd": "agent-session-attach", "surface": child_surface,
                                        "limit": 50, "kinds": ["transcript"]}));
    assert_eq!(page["ok"], true, "{page}");
    assert_eq!(page["data"]["session"]["sessionId"], json!(child));
    let refused = chat_tab(&vm, &store, &other);
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error_code"], json!("conversation_tab.machine_mismatch"), "{refused}");
}
