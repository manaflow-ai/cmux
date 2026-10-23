//! `agent-session-adopt` (agent-session-adopt-v1): the app opens a chat that
//! already runs in this machine's acpmux (one an agent or `cmux agent open`
//! started there) in an agent tab of this machine, as a workspace of its
//! sidebar. The daemon binds the session only when this machine's own acpmux
//! lists it: never a chat mirrored from a peer, never the Home Chief's, never
//! an id acpmux does not know. A session in a mode that does not ask is
//! adopted too, on an enrolled host only (the start's host gate), and the
//! answer says so (`asking: false`) for the app's bypass badge.

use std::os::unix::net::UnixListener;

use serde_json::{Value, json};

use super::*;

/// An acpmux stand-in that lists one chat of this machine in a bypass mode,
/// one mirrored from a peer and one of the Home Chief.
fn listing_acpmux(socket: PathBuf) {
    let listener = UnixListener::bind(&socket).unwrap();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
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
                                        "mode": "bypassPermissions"},
                        }),
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
}

impl Daemon {
    fn adopt(&self, surface: u64, session: &str) -> Value {
        self.rpc(json!({"id": 21, "cmd": "agent-session-adopt", "surface": surface,
                        "session": session}))
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
