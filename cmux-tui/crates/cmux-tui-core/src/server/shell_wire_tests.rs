//! `shell-run`, `shell-read`, `shell-stop` on the wire: the owner's connection runs a command on
//! this machine and reads it to its exit; a read that waits holds no other request; every other
//! connection is refused before anything runs.

use super::super::bounded_outbound::OutboundItem;
use super::super::*;

/// A folder of its own, removed after the test.
struct Folder(PathBuf);

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn folder() -> (PathBuf, Folder) {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).unwrap();
    let name = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
    let path = std::env::temp_dir().join(format!("cmux-shell-wire-{name}"));
    std::fs::create_dir_all(&path).unwrap();
    (path.clone(), Folder(path))
}

/// The answer to `request` on its own writer; the call blocks until it is written.
fn reply(mux: &Arc<Mux>, client: u64, request: Value) -> Value {
    let (writer, outbound) = captured_writer();
    let request: Request = serde_json::from_value(request).unwrap();
    assert!(handle_request(mux, client, request, &writer));
    loop {
        match outbound.recv() {
            Some(OutboundItem::Text(text)) => return serde_json::from_str(&text.to_string()).unwrap(),
            Some(OutboundItem::Flush(flushed)) => {
                let _ = flushed.send(());
            }
            None => panic!("the writer closed with no reply"),
        }
    }
}

#[test]
fn the_owner_runs_a_command_in_its_folder_and_reads_it_to_its_exit() {
    let mux = Mux::new_for_test("shell-wire", crate::SurfaceOptions::default());
    let owner = mux.local_test_client(41);
    let (cwd, _gone) = folder();
    let started = reply(
        &mux,
        owner,
        json!({"id":1,"cmd":"shell-run","command":"pwd; echo hi; exit 4","cwd":cwd,"scope":"pane-1"}),
    );
    assert_eq!(started["ok"], true, "{started}");
    let id = started["data"]["run"].as_str().unwrap().to_owned();
    let mut after = 0;
    let mut output = String::new();
    let exit = loop {
        let read = reply(&mux, owner, json!({"id":2,"cmd":"shell-read","run":id,"after":after}));
        assert_eq!(read["ok"], true, "{read}");
        output.push_str(read["data"]["output"].as_str().unwrap());
        after = read["data"]["next"].as_u64().unwrap();
        if let Some(exit) = read["data"].get("exit") {
            break exit.clone();
        }
    };
    let canonical = cwd.canonicalize().unwrap();
    assert!(output.contains(canonical.to_str().unwrap()) && output.ends_with("hi\n"), "{output}");
    assert_eq!(exit, json!({"code": 4}));
}

#[test]
fn a_waiting_read_does_not_hold_the_connection() {
    let mux = Mux::new_for_test("shell-wire", crate::SurfaceOptions::default());
    let owner = mux.local_test_client(42);
    let (cwd, _gone) = folder();
    let started = reply(&mux, owner, json!({"cmd":"shell-run","command":"sleep 30","cwd":cwd}));
    let id = started["data"]["run"].as_str().unwrap().to_owned();
    let (writer, outbound) = captured_writer();
    let read: Request = serde_json::from_value(json!({"cmd":"shell-read","run":id,"after":0})).unwrap();
    // Returns at once: the wait is on a thread of its own.
    assert!(handle_request(&mux, owner, read, &writer));
    assert!(outbound.try_pop().is_none(), "nothing to read yet");
    let stopped = reply(&mux, owner, json!({"cmd":"shell-stop","run":id}));
    assert_eq!(stopped["data"], json!({}), "{stopped}");
    // The waiting read answers once the stopped command ends.
    let answer = loop {
        match outbound.recv() {
            Some(OutboundItem::Text(text)) => break serde_json::from_str::<Value>(&text.to_string()).unwrap(),
            Some(OutboundItem::Flush(flushed)) => drop(flushed.send(())),
            None => panic!("closed"),
        }
    };
    assert_eq!(answer["ok"], true, "{answer}");
}

#[test]
fn refusals_are_answers_with_their_code() {
    let mux = Mux::new_for_test("shell-wire", crate::SurfaceOptions::default());
    let owner = mux.local_test_client(43);
    let missing = reply(&mux, owner, json!({"cmd":"shell-run","command":"true","cwd":"/no/such/folder"}));
    assert_eq!(missing["data"], json!({"refused": "folder_missing"}), "{missing}");
    let unknown = reply(&mux, owner, json!({"cmd":"shell-read","run":"run_nope","after":0}));
    assert_eq!(unknown["data"], json!({"refused": "unknown_run"}), "{unknown}");
    let stop = reply(&mux, owner, json!({"cmd":"shell-stop","run":"run_nope"}));
    assert_eq!(stop["data"], json!({"refused": "unknown_run"}), "{stop}");
}

#[test]
fn a_relayed_web_or_unregistered_connection_runs_nothing() {
    let mux = Mux::new_for_test("shell-wire", crate::SurfaceOptions::default());
    let (cwd, _gone) = folder();
    let marker = cwd.join("ran");
    let command = format!("touch {}", marker.display());
    let remote = mux.control_clients.register(ClientTransport::Remote, captured_writer().0);
    let socket = mux.control_clients.register(ClientTransport::WebSocket, captured_writer().0);
    for client in [remote, socket, 9_999] {
        let run = reply(&mux, client, json!({"cmd":"shell-run","command":command,"cwd":cwd}));
        assert_eq!(run["ok"], false, "{run}");
        let read = reply(&mux, client, json!({"cmd":"shell-read","run":"run_x","after":0}));
        assert_eq!(read["ok"], false, "{read}");
    }
    assert!(!marker.exists(), "nothing ran");
    let gate = remote_relay::gate::ALLOWED_COMMANDS;
    assert!(!gate.iter().any(|(name, _)| name.starts_with("shell-")));
}

#[test]
fn the_native_owner_link_carries_the_commands_and_their_capability() {
    for command in ["shell-run", "shell-read", "shell-stop"] {
        assert!(native_owner::commands().contains(&command), "{command}");
    }
    assert!(native_owner::carries(crate::shell_runs::CAPABILITY));
    let mux = Mux::new_for_test("shell-wire", crate::SurfaceOptions::default());
    assert!(identify_capabilities(&mux).contains(&crate::shell_runs::CAPABILITY));
}
