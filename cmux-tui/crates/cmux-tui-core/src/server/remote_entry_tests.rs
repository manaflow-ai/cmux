//! The remote entry admits only the link, reads the peer stamp only there,
//! and refuses every frame its gate does not allow.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

use super::super::*;
use super::*;

const STAMP: &str = r#"{"link_peer":{"install":"inst_1","user":"42","team":"team_a"}}"#;

struct AdmitAll;

impl RemoteGate for AdmitAll {
    fn admit(&self, _peer: &RemotePeer, _frame: &str) -> bool {
        true
    }
}

/// Field order matters: the server drops (and removes its socket) before
/// the directory goes away.
struct Entry {
    server: RemoteEntryServer,
    mux: Arc<Mux>,
    _directory: cmux_unix_socket::TestDir,
}

fn entry(verifier_accepts: bool, gate: Arc<dyn RemoteGate>) -> Entry {
    let directory = cmux_unix_socket::short_test_dir("rentry");
    let path = cmux_link::entry_path::remote_entry_socket_path(&directory.path().join("s.sock"));
    let mux = Mux::new_for_test("remote-entry", crate::SurfaceOptions::default());
    let verifier: LinkVerifier = Arc::new(move |_stream: &UnixStream| {
        if verifier_accepts {
            Ok(())
        } else {
            Err(std::io::Error::new(std::io::ErrorKind::PermissionDenied, "not the link"))
        }
    });
    let server = serve_remote_entry(mux.clone(), &path, verifier, gate).unwrap();
    Entry { server, mux, _directory: directory }
}

fn connect(entry: &Entry) -> (UnixStream, BufReader<UnixStream>) {
    let stream = UnixStream::connect(entry.server.path()).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let reader = BufReader::new(stream.try_clone().unwrap());
    (stream, reader)
}

fn send(stream: &mut UnixStream, line: &str) {
    stream.write_all(line.as_bytes()).unwrap();
    stream.write_all(b"\n").unwrap();
}

fn response(reader: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    let read = reader.read_line(&mut line).expect("a response before the timeout");
    assert!(read > 0, "the entry closed the connection");
    serde_json::from_str(&line).unwrap()
}

fn remote_clients(mux: &Mux) -> Vec<u64> {
    let state = mux.control_clients.state.lock().unwrap();
    state
        .clients
        .iter()
        .filter(|(_, record)| matches!(record.transport, ClientTransport::Remote))
        .map(|(client, _)| *client)
        .collect()
}

/// RED (security): the stamp is trusted only from the link. A process the
/// verifier refuses gets no byte back and never becomes a client, even with
/// a well-formed stamp.
#[test]
fn a_process_that_is_not_the_link_gets_nothing_and_registers_no_client() {
    let entry = entry(false, Arc::new(AdmitAll));
    let (mut stream, mut reader) = connect(&entry);
    send(&mut stream, STAMP);
    send(&mut stream, r#"{"id":1,"cmd":"ping"}"#);
    let mut line = String::new();
    let read = reader.read_line(&mut line).unwrap_or(0);
    assert_eq!(read, 0, "a refused process must get no reply, got {line:?}");
    assert!(remote_clients(&entry.mux).is_empty());
}

/// RED (security): with the default gate every daemon command is refused
/// with `remote_denied` and no detail, including commands added later
/// (the list comes from the spec), resource-protocol frames, a second
/// stamp, and malformed lines.
#[test]
fn every_daemon_command_is_refused_by_the_default_gate() {
    let entry = entry(true, Arc::new(DenyAllGate));
    let (mut stream, mut reader) = connect(&entry);
    send(&mut stream, STAMP);
    let schema: Value =
        serde_json::from_str(include_str!("../../../../spec/sdk-schema.json")).unwrap();
    let commands = schema["commands"].as_object().expect("the spec lists commands");
    assert!(commands.len() > 100, "the spec command list looks truncated");
    let mut frames: Vec<String> =
        commands.keys().map(|name| json!({"cmd": name}).to_string()).collect();
    frames.push(r#"{"cmd":"new-workspace","initial_command":"sh"}"#.to_string());
    frames.push(json!({"v":2,"op":"workspace.list"}).to_string());
    frames.push(STAMP.to_string());
    frames.push("not json".to_string());
    for (index, frame) in frames.iter().enumerate() {
        let mut framed: Value = serde_json::from_str(frame).unwrap_or(Value::Null);
        if let Some(object) = framed.as_object_mut() {
            object.insert("id".into(), json!(index));
            send(&mut stream, &framed.to_string());
        } else {
            send(&mut stream, frame);
        }
        let reply = response(&mut reader);
        assert_eq!(reply["ok"], json!(false), "{frame}: {reply}");
        assert_eq!(reply["error_code"], json!("remote_denied"), "{frame}: {reply}");
        assert_eq!(reply["error"], json!("remote_denied"), "{frame}: no detail: {reply}");
        if framed.is_object() {
            assert_eq!(reply["id"], json!(index), "{frame}");
        }
    }
    assert_eq!(remote_clients(&entry.mux).len(), 1);
}

/// RED (security): a remote client never acts as the server's local user;
/// it is the participant of its paired install.
#[test]
fn a_remote_client_acts_as_its_peer_user_never_the_local_user() {
    let entry = entry(true, Arc::new(DenyAllGate));
    let (mut stream, mut reader) = connect(&entry);
    send(&mut stream, STAMP);
    send(&mut stream, r#"{"id":1,"cmd":"ping"}"#);
    let _ = response(&mut reader);
    let clients = remote_clients(&entry.mux);
    assert_eq!(clients.len(), 1);
    let principal = entry.mux.conversation_principal(clients[0]);
    assert_eq!(principal, "remote_inst_1");
    assert_ne!(principal, crate::conversation_store::LOCAL_USER);
    assert!(!entry.mux.control_clients.is_unix(clients[0]));
}

/// The stamp must come first; anything else closes the connection.
#[test]
fn a_missing_or_malformed_stamp_closes_the_connection() {
    let entry = entry(true, Arc::new(AdmitAll));
    for first in
        [r#"{"id":1,"cmd":"ping"}"#, r#"{"link_peer":{"install":"../x","user":"u","team":"t"}}"#]
    {
        let (mut stream, mut reader) = connect(&entry);
        send(&mut stream, first);
        send(&mut stream, r#"{"id":2,"cmd":"ping"}"#);
        let mut line = String::new();
        assert_eq!(reader.read_line(&mut line).unwrap_or(0), 0, "{first}: {line:?}");
    }
    assert!(remote_clients(&entry.mux).is_empty());
}

/// A gate that admits a frame lets it reach normal dispatch.
#[test]
fn an_admitted_frame_reaches_dispatch() {
    let entry = entry(true, Arc::new(AdmitAll));
    let (mut stream, mut reader) = connect(&entry);
    send(&mut stream, STAMP);
    send(&mut stream, r#"{"id":7,"cmd":"ping"}"#);
    let reply = response(&mut reader);
    assert_eq!(reply["id"], json!(7));
    assert_eq!(reply["ok"], json!(true), "{reply}");
}

/// A stamp sent to the local socket is not a stamp there: it is an unknown
/// command, and the connection stays the local user's.
#[test]
fn a_stamp_on_the_local_socket_binds_no_peer() {
    let mux = Mux::new_for_test("remote-entry-local", crate::SurfaceOptions::default());
    let (server, mut client) = UnixStream::pair().unwrap();
    let handler = {
        let mux = mux.clone();
        std::thread::spawn(move || handle_connection(mux, Box::new(server)))
    };
    client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut reader = BufReader::new(client.try_clone().unwrap());
    send(&mut client, STAMP);
    let reply = response(&mut reader);
    assert_eq!(reply["ok"], json!(false), "{reply}");
    assert!(remote_clients(&mux).is_empty());
    client.shutdown(Shutdown::Both).unwrap();
    handler.join().unwrap();
}

#[test]
fn the_entry_socket_is_private_and_removed_on_drop() {
    use std::os::unix::fs::PermissionsExt;
    let entry = entry(true, Arc::new(DenyAllGate));
    let path = entry.server.path().to_path_buf();
    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    drop(entry);
    assert!(!path.exists());
}
