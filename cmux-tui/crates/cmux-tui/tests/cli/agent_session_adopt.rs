//! `agent-session-adopt` (agent-session-adopt-v1): the app opens a chat that
//! already runs in this machine's acpmux (one an agent or `cmux agent open`
//! started there) in an agent tab of this machine, as a workspace of its
//! sidebar. The daemon binds the session only when this machine's own acpmux
//! lists it: never a chat mirrored from a peer, never the Home Chief's, never
//! an id acpmux does not know. A session in a mode that does not ask is
//! adopted too, on an enrolled host only (the start's host gate), and the
//! answer says so (`asking: false`) for the app's bypass badge. The badge
//! follows the chat's mode afterwards: `agent-session-mode` reads it for a
//! tab, the attach reply carries it, and an attachment that asked for
//! `mode_events` hears `agent-session-mode` when the mode changes.

use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

use super::*;

/// The acpmux stand-in's state: own-1's mode, and the connections that
/// watch session changes.
#[derive(Clone)]
struct FakeAcpmux {
    mode: Arc<Mutex<&'static str>>,
    watchers: Arc<Mutex<Vec<UnixStream>>>,
}

impl FakeAcpmux {
    /// own-1 switches to `mode`; watchers hear it as acpmux sends a mux
    /// `mode` record (`_acpmux/session_changed` kind `mode`).
    fn switch_mode(&self, mode: &'static str) {
        *self.mode.lock().unwrap() = mode;
        let notice = json!({"jsonrpc": "2.0", "method": "_acpmux/session_changed", "params": {
            "sessionId": "own-1", "kind": "mode", "recordKind": "mode",
            "session": {"sessionId": "own-1"}}});
        for watcher in self.watchers.lock().unwrap().iter_mut() {
            let _ = watcher.write_all(format!("{notice}\n").as_bytes());
        }
    }
}

/// An acpmux stand-in that lists one chat of this machine in a bypass mode,
/// one mirrored from a peer and one of the Home Chief.
fn listing_acpmux(socket: PathBuf) -> FakeAcpmux {
    let listener = UnixListener::bind(&socket).unwrap();
    let fake =
        FakeAcpmux { mode: Arc::new(Mutex::new("bypassPermissions")), watchers: Arc::default() };
    let state = fake.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let state = state.clone();
            std::thread::spawn(move || {
                let mut writer = stream.try_clone().unwrap();
                for line in BufReader::new(stream).lines() {
                    let Ok(line) = line else { return };
                    let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
                    let Some(id) = message.get("id").cloned() else { continue };
                    let result = match message["method"].as_str().unwrap_or_default() {
                        "_acpmux/sessions" => json!({"sessions": [
                            {"sessionId": "own-1", "status": "ready", "peer": null,
                             "harness": "fake", "name": "lane", "tags": {}},
                            {"sessionId": "peer-1", "status": "ready", "peer": "mac-a",
                             "harness": "fake", "tags": {}},
                            {"sessionId": "chief-1", "status": "ready", "peer": null,
                             "harness": "fake", "tags": {"cmux.chief": "home"}},
                        ]}),
                        "_acpmux/web_modes" => json!({
                            "refusedFamilies": [], "families": {"fake": ["ask"]},
                            "session": {"sessionId": "own-1", "family": "fake",
                                        "mode": *state.mode.lock().unwrap()},
                        }),
                        "_acpmux/attach" => json!({"session": {
                            "sessionId": "own-1", "name": "lane", "pending": []}, "events": []}),
                        "_acpmux/watch" => {
                            state.watchers.lock().unwrap().push(writer.try_clone().unwrap());
                            json!({"sessions": []})
                        }
                        _ => json!({}),
                    };
                    let reply = json!({"jsonrpc": "2.0", "id": id, "result": result});
                    if writer.write_all(format!("{reply}\n").as_bytes()).is_err() {
                        return;
                    }
                }
            });
        }
    });
    fake
}

impl Daemon {
    fn adopt(&self, surface: u64, session: &str) -> Value {
        self.rpc(json!({"id": 21, "cmd": "agent-session-adopt", "surface": surface,
                        "session": session}))
    }

    fn mode(&self, surface: u64) -> Value {
        self.rpc(json!({"id": 22, "cmd": "agent-session-mode", "surface": surface}))
    }
}

impl Conn {
    /// The next pushed `event` on this connection.
    fn next_event(&mut self, event: &str) -> Value {
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["event"] == event {
                return message;
            }
        }
    }
}

#[test]
fn agent_session_adopt_binds_a_chat_of_this_machine_and_names_its_bypass_mode() {
    let daemon = Daemon::start_with("adopt", None, None);
    listing_acpmux(daemon.dir.join("acpmux/acpmux.sock"));
    let identity = daemon.rpc(json!({"id": 1, "cmd": "identify"}));
    assert!(identity["data"]["capabilities"].to_string().contains("agent-session-adopt-v1"));
    let surface = daemon.own_agent_tab();
    for session in ["peer-1", "chief-1", "nope-1"] {
        let refused = daemon.adopt(surface, session);
        assert_eq!(refused["error_code"], "agent_session.unknown_session", "{session}: {refused}");
    }
    let adopted = daemon.adopt(surface, "own-1");
    assert_eq!(adopted["ok"], true, "{adopted}");
    assert_eq!(adopted["data"]["session"], "own-1", "{adopted}");
    assert_eq!(adopted["data"]["asking"], false, "{adopted}");
    assert_eq!(adopted["data"]["mode"], "bypassPermissions", "{adopted}");
    assert_eq!(adopted["data"]["conversation"]["agent_session"]["session"], "own-1", "{adopted}");
    let again = daemon.adopt(surface, "own-1");
    assert_eq!(again["error_code"], "agent_session.bound", "{again}");
    let _ = fs::remove_file(daemon.dir.join("acpmux/acpmux.sock"));
}

#[test]
fn agent_session_adopt_is_refused_on_a_team_vm() {
    let daemon = Daemon::start_with("adopt-team", Some("team-vm"), None);
    listing_acpmux(daemon.dir.join("acpmux/acpmux.sock"));
    let surface = daemon.own_agent_tab();
    let refused = daemon.adopt(surface, "own-1");
    assert_eq!(refused["error_code"], "agent_session.team_vm_blocked", "{refused}");
    let _ = fs::remove_file(daemon.dir.join("acpmux/acpmux.sock"));
}

#[test]
fn agent_session_mode_follows_an_adopted_chat_through_reads_attach_and_changes() {
    let daemon = Daemon::start_with("adopt-mode", None, None);
    let acpmux = listing_acpmux(daemon.dir.join("acpmux/acpmux.sock"));
    let surface = daemon.own_agent_tab();
    let unbound = daemon.mode(surface);
    assert_eq!(unbound["error_code"], "agent_session.unknown_tab", "{unbound}");
    assert_eq!(daemon.adopt(surface, "own-1")["ok"], true);
    // A restored tab the app does not show: one read.
    let read = daemon.mode(surface);
    assert_eq!(read["data"]["session"], "own-1", "{read}");
    assert_eq!(read["data"]["mode"], "bypassPermissions", "{read}");
    assert_eq!(read["data"]["asking"], false, "{read}");
    // A shown tab: the attach reply, then each change.
    let mut app = daemon.client();
    let attached =
        app.rpc(json!({"cmd": "agent-session-attach", "surface": surface, "mode_events": true}));
    assert_eq!(attached["ok"], true, "{attached}");
    assert_eq!(attached["data"]["agentMode"]["asking"], false, "{attached}");
    assert_eq!(attached["data"]["agentMode"]["session"], "own-1", "{attached}");
    acpmux.switch_mode("ask");
    let changed = app.next_event("agent-session-mode");
    assert_eq!(changed["surface"], surface, "{changed}");
    assert_eq!(changed["mode"]["session"], "own-1", "{changed}");
    assert_eq!(changed["mode"]["mode"], "ask", "{changed}");
    assert_eq!(changed["mode"]["asking"], true, "{changed}");
    let _ = fs::remove_file(daemon.dir.join("acpmux/acpmux.sock"));
}
