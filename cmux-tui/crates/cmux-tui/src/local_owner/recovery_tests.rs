//! Exercise the socket exchange used when a spawned owner has no ready pipe.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc;

use super::*;

pub(super) fn owner_spec(socket: PathBuf) -> OwnerSpec {
    OwnerSpec {
        session: "busy-recovery".into(),
        socket,
        socket_is_derived: false,
        state: None,
        term: None,
        initial_host_colors: None,
        terminal_reap_grace: None,
        install_key: None,
        chief_tools_socket: None,
        chief_brains: None,
        websocket: None,
    }
}

#[test]
fn connection_limit_after_starting_has_its_own_busy_deadline() {
    let dir = tempfile::tempdir_in("/tmp").unwrap();
    let spec = owner_spec(dir.path().join("owner.sock"));
    let listener = UnixListener::bind(&spec.socket).unwrap();
    let (stop, stopped) = mpsc::channel();
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream);
        reader.read_line(&mut String::new()).unwrap();
        writeln!(
            reader.get_mut(),
            "{}",
            serde_json::json!({"id":1,"ok":true,"data":{
                "app":"cmux-tui", "protocol":cmux_tui_core::server::PROTOCOL_VERSION,
                "lifecycle_ready":false,"pid":std::process::id()
            }})
        )
        .unwrap();
        drop(reader);
        loop {
            let (mut stream, _) = listener.accept().unwrap();
            if stopped.try_recv().is_ok() {
                break;
            }
            // The real server sends this before reading the client's request.
            let _ = writeln!(
                stream,
                r#"{{"protocol":"cmux.protocol/2","type":"refused","code":"server.busy"}}"#
            );
        }
    });
    let now = Instant::now();
    let result = wait_until_ready(
        &spec,
        Some(&spec.session),
        &|| false,
        now + ENSURE_DEADLINE,
        now + ENSURE_DEADLINE + Duration::from_secs(5),
        &RestoreProgress::silent(),
    );
    stop.send(()).unwrap();
    let _ = UnixStream::connect(&spec.socket);
    server.join().unwrap();
    assert!(
        matches!(result, Err(EnsureError::Busy)),
        "continuous refusals must report busy even after a starting response"
    );
}
