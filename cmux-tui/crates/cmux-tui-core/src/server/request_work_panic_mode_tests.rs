//! Requests on an accepted Unix connection in the detector's panic mode, the
//! Debug default. A connection's reader (`mux-conn`, which ran each
//! `cmux.protocol/2` line inline) and its dispatcher (`mux-control-dispatch`,
//! which ran each `cmd` line) disallow blocking, and most requests read or
//! commit the SQLite workspace registry, the conversation store or the
//! Chief registry. A handler on either thread panicked at its first
//! blocking call, and the client got the end of the stream for its reply:
//! the largest groups of the terminal suite's remaining failures (MQ-13).

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Value, json};

use crate::server::*;

struct Served {
    mux: Arc<Mux>,
    path: PathBuf,
}

impl Served {
    fn new(label: &str) -> Self {
        cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Panic);
        let mux =
            Mux::new_for_test(format!("request-work-{label}"), crate::SurfaceOptions::default());
        let path = serve(mux.clone(), None).unwrap();
        Served { mux, path }
    }

    /// The reply to `request` (events skipped), or why there is none.
    fn ask(&self, request: &Value) -> Result<Value, String> {
        let mut socket = UnixStream::connect(&self.path).unwrap();
        let read_half = socket.try_clone().unwrap();
        read_half.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut replies = BufReader::new(read_half);
        socket.write_all(format!("{request}\n").as_bytes()).unwrap();
        loop {
            let mut line = String::new();
            match replies.read_line(&mut line) {
                Ok(0) => {
                    return Err(format!(
                        "the daemon closed the connection before replying to {request}"
                    ));
                }
                Ok(_) => {}
                Err(error) => return Err(format!("no reply to {request}: {error}")),
            }
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("event").is_none() {
                return Ok(value);
            }
        }
    }
}

impl Drop for Served {
    fn drop(&mut self) {
        cleanup(&self.path);
    }
}

fn v2(operation: &str, params: Value, key: Option<&str>) -> Value {
    let mut request = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": operation,
        "operation": operation, "params": params,
    });
    if let Some(key) = key {
        request["idempotency_key"] = json!(key);
    }
    request
}

/// `identify` reads the terminal registry's revision from SQLite
/// (cmd_server.rs `identify`); every CLI command and `server stop` starts
/// with it. 76 tests of the suite failed here.
#[test]
fn identify_is_answered_in_panic_mode() {
    let served = Served::new("identify");
    let reply = served.ask(&json!({"id": 1, "cmd": "identify"})).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    assert!(reply["data"]["terminal_revision"].is_u64(), "{reply}");
}

/// A v2 topology mutation commits the registry
/// (resource_router/topology.rs); it ran inline on the reader. 65 tests.
#[test]
fn a_v2_workspace_create_is_answered_in_panic_mode() {
    let served = Served::new("workspace-create");
    let params = json!({"machine": "current", "session": "current", "initial_content": "empty"});
    let reply = served.ask(&v2("workspace.create", params, Some("panic-mode-1"))).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
}

/// `conversation-create` commits the conversation store
/// (server/conversations.rs). 22 tests.
#[test]
fn a_conversation_create_is_answered_in_panic_mode() {
    let served = Served::new("conversation-create");
    let request = json!({"id": 1, "cmd": "conversation-create", "idempotency_key": "panic-mode-1",
        "title": "panic mode", "participants": [
            {"id": "user_local", "kind": "human", "display_name": "Me"},
            {"id": "agent_mux", "kind": "agent", "display_name": "mux", "agent_class": "mux"}]});
    let reply = served.ask(&request).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
}

/// A v2 Chief registry read opens the Chief store
/// (server/chief_registry_resource.rs); it ran inline on the reader. 22 tests.
#[test]
fn a_v2_chief_profile_list_is_answered_in_panic_mode() {
    let served = Served::new("chief-list");
    let params = json!({"machine": "current", "session": "current"});
    let reply = served.ask(&v2("chief.profile.list", params, None)).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
}

/// A terminal create (a process spawn and registry commits) goes to the
/// terminal work pool, and with the pool full its caller runs it inline.
/// That caller was the connection's control worker (`mux-seq-control`),
/// which disallows blocking: under load the create panicked there at its
/// first blocking call, and the client never got its reply. A connection's
/// requests run where they may block on every path and at every load.
#[test]
fn blocking_cascade_a_create_with_the_terminal_pool_full_is_answered_in_panic_mode() {
    let served = Served::new("create-pool-full");
    let _full = served.mux.fill_terminal_work_for_test();
    let reply = served.ask(&json!({"id": 1, "cmd": "new-workspace"})).unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
}
