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

use std::collections::HashMap;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

use super::*;

/// The acpmux stand-in's state: own-1's mode, the connections that watch
/// session changes, and each attached connection with its `kinds`.
#[derive(Clone)]
struct FakeAcpmux {
    mode: Arc<Mutex<&'static str>>,
    watchers: Arc<Mutex<Vec<UnixStream>>>,
    attached: Arc<Mutex<HashMap<usize, (UnixStream, Option<Vec<String>>)>>>,
}

/// own-1's record of `kind` at `seq`: an agent `session/update`.
fn record(seq: u64, kind: &str) -> Value {
    json!({"sessionId": "own-1", "seq": seq, "dir": "in", "kind": kind,
           "msg": {"method": "session/update", "params": {"sessionId": "own-1",
                   "update": {"sessionUpdate": kind, "currentModeId": "ask"}}}})
}

/// Whether acpmux's `kinds` filter passes a record of `kind` (`hub/paging.rs`:
/// `transcript` leaves the mode updates out, `wire` every live update).
fn passes(kinds: &Option<Vec<String>>, kind: &str) -> bool {
    let mode = matches!(kind, "current_mode_update" | "config_option_update");
    kinds.as_ref().is_none_or(|kinds| {
        kinds.iter().any(|k| k == "all" || k == kind || (k == "transcript" && !mode))
    })
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

    /// The agent records `kind` for own-1 (a harness `current_mode_update`
    /// when it changes the mode by itself, which is no `session_changed`);
    /// each attached connection whose kinds pass it hears it.
    fn agent_records(&self, seq: u64, kind: &str) {
        let event =
            json!({"jsonrpc": "2.0", "method": "_acpmux/event", "params": record(seq, kind)});
        for (stream, kinds) in self.attached.lock().unwrap().values_mut() {
            if passes(kinds, kind) {
                let _ = stream.write_all(format!("{event}\n").as_bytes());
            }
        }
    }

    /// The `kinds` each attached connection subscribed with.
    fn attach_kinds(&self) -> Vec<Option<Vec<String>>> {
        self.attached.lock().unwrap().values().map(|(_, kinds)| kinds.clone()).collect()
    }
}

/// An acpmux stand-in that lists one chat of this machine in a bypass mode,
/// one mirrored from a peer and one of the Home Chief.
fn listing_acpmux(socket: PathBuf) -> FakeAcpmux {
    let listener = UnixListener::bind(&socket).unwrap();
    let fake = FakeAcpmux {
        mode: Arc::new(Mutex::new("bypassPermissions")),
        watchers: Arc::default(),
        attached: Arc::default(),
    };
    let state = fake.clone();
    std::thread::spawn(move || {
        for (connection, stream) in listener.incoming().enumerate() {
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
                        // acpmux resolves an id, a name or a unique prefix of either.
                        "_acpmux/web_modes" => {
                            let key = message["params"]["sessionId"].as_str().unwrap_or("");
                            let known =
                                !key.is_empty() && ("own-1".starts_with(key) || key == "lane");
                            let mut table =
                                json!({"refusedFamilies": [], "families": {"fake": ["ask"]}});
                            if known {
                                table["session"] = json!({"sessionId": "own-1", "family": "fake",
                                                          "mode": *state.mode.lock().unwrap()});
                            }
                            table
                        }
                        "_acpmux/attach" => {
                            let kinds: Option<Vec<String>> =
                                serde_json::from_value(message["params"]["kinds"].clone()).unwrap();
                            let events: Vec<Value> =
                                [(1, "agent_message_chunk"), (2, "current_mode_update")]
                                    .into_iter()
                                    .filter(|(_, kind)| passes(&kinds, kind))
                                    .map(|(seq, kind)| record(seq, kind))
                                    .collect();
                            let stream = writer.try_clone().unwrap();
                            state.attached.lock().unwrap().insert(connection, (stream, kinds));
                            json!({"session": {"sessionId": "own-1", "name": "lane", "pending": []},
                                   "events": events, "hasMore": false})
                        }
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
        self.events_until(event).pop().unwrap()
    }

    /// The pushed events on this connection up to the next `event`, with it.
    fn events_until(&mut self, event: &str) -> Vec<Value> {
        let mut seen = Vec::new();
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let message: Value = serde_json::from_str(&line).unwrap();
            let done = message["event"] == event;
            seen.push(message);
            if done {
                return seen;
            }
        }
    }
}

/// The record kinds of an attach reply's page.
fn page_kinds(reply: &Value) -> Vec<String> {
    let events = reply["data"]["events"].as_array().cloned().unwrap_or_default();
    events.iter().map(|event| event["kind"].as_str().unwrap_or_default().to_owned()).collect()
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

/// The app's attach asks for the transcript and config records only, yet the
/// agent changing the mode by itself (a `current_mode_update`, which acpmux
/// announces as no `session_changed`) still moves the badge: the daemon
/// subscribes to the mode records for its `agent-session-mode` pushes and
/// keeps them out of the client's page and stream. A second attach on the same
/// connection carries the mode too.
#[test]
fn agent_session_mode_pushes_an_agent_mode_change_under_transcript_kinds() {
    let daemon = Daemon::start_with("adopt-kinds", None, None);
    let acpmux = listing_acpmux(daemon.dir.join("acpmux/acpmux.sock"));
    let surface = daemon.own_agent_tab();
    assert_eq!(daemon.adopt(surface, "own-1")["ok"], true);
    let mut app = daemon.client();
    let attach = json!({"cmd": "agent-session-attach", "surface": surface, "mode_events": true,
                        "kinds": ["transcript", "config_option_update"]});
    let attached = app.rpc(attach.clone());
    assert_eq!(attached["ok"], true, "{attached}");
    assert_eq!(page_kinds(&attached), ["agent_message_chunk"], "{attached}");
    let subscribed = acpmux.attach_kinds();
    assert!(
        subscribed.iter().flatten().any(|kinds| kinds.iter().any(|k| k == "current_mode_update")),
        "{subscribed:?}"
    );
    let again = app.rpc(attach);
    assert_eq!(again["ok"], true, "{again}");
    assert_eq!(page_kinds(&again), ["agent_message_chunk"], "{again}");
    assert_eq!(again["data"]["agentMode"]["session"], "own-1", "{again}");
    assert_eq!(again["data"]["agentMode"]["asking"], false, "{again}");
    *acpmux.mode.lock().unwrap() = "ask";
    acpmux.agent_records(3, "current_mode_update");
    let seen = app.events_until("agent-session-mode");
    let changed = seen.last().unwrap();
    assert_eq!(changed["mode"]["mode"], "ask", "{changed}");
    assert_eq!(changed["mode"]["asking"], true, "{changed}");
    acpmux.agent_records(4, "agent_message_chunk");
    let seen = [seen, app.events_until("agent-session-record")].concat();
    let records: Vec<&Value> =
        seen.iter().filter(|event| event["event"] == "agent-session-record").collect();
    assert_eq!(records.len(), 1, "{seen:?}");
    assert_eq!(records[0]["record"]["kind"], "agent_message_chunk", "{seen:?}");
    let _ = fs::remove_file(daemon.dir.join("acpmux/acpmux.sock"));
}

/// A tab whose record holds the chat's full name (attach accepts it) reads
/// its mode, keyed by that name as the app files it; a record acpmux only
/// resolves as a prefix of another chat is refused.
#[test]
fn agent_session_mode_reads_a_tab_that_records_the_chats_full_name() {
    let daemon = Daemon::start_with("adopt-name", None, None);
    listing_acpmux(daemon.dir.join("acpmux/acpmux.sock"));
    let tab = |session: &str| {
        let tab = daemon.rpc(json!({"id": 30, "cmd": "new-conversation-tab",
                                    "agent_session": {"host": "install:mac-test"}}));
        let surface = tab["data"]["surface"].as_u64().unwrap();
        let bound = daemon.rpc(json!({"id": 31, "cmd": "bind-conversation-tab-session",
                                      "surface": surface, "session": session,
                                      "expected_session": null}));
        assert_eq!(bound["ok"], true, "{bound}");
        surface
    };
    assert_eq!(daemon.rpc(json!({"id": 29, "cmd": "new-workspace"}))["ok"], true);
    let named = tab("lane");
    let read = daemon.mode(named);
    assert_eq!(read["ok"], true, "{read}");
    assert_eq!(read["data"]["session"], "lane", "{read}");
    assert_eq!(read["data"]["asking"], false, "{read}");
    let mut app = daemon.client();
    let attached =
        app.rpc(json!({"cmd": "agent-session-attach", "surface": named, "mode_events": true}));
    assert_eq!(attached["ok"], true, "{attached}");
    assert_eq!(attached["data"]["agentMode"]["session"], "lane", "{attached}");
    let prefix = tab("own");
    let refused = daemon.mode(prefix);
    assert_eq!(refused["error_code"], "agent_session.unknown_session", "{refused}");
    let _ = fs::remove_file(daemon.dir.join("acpmux/acpmux.sock"));
}
