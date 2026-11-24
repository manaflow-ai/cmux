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
        exit_with_pid: None,
        install_key: None,
        chief_tools_socket: None,
        chief_brains: None,
        websocket: None,
        carried_env: Vec::new(),
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
        &RestoreBound::with(
            now + ENSURE_DEADLINE + Duration::from_secs(5),
            Duration::ZERO,
            Duration::from_secs(10),
            Duration::from_secs(1),
            restore_bound::process_work,
        ),
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

/// A spawned owner that lost the bind to a racing ensure's owner closes its
/// ready pipe with no byte (`wait_for_spawned_owner`), and the winner serves
/// the socket. That winner is not this call's owner: ensure reports it as
/// running, not started, so a caller that stops only the daemon it started
/// (the server uninstall's sweep) leaves the other caller's daemon and its
/// terminals alone. An owner that wrote its byte is this call's while the pid
/// that answers is its own: a successor that replaced it is not, and a first
/// probe that finds it still starting does not take that away. Under the DEV
/// launcher the spawned pid is the launcher's, so the byte alone counts.
#[test]
fn an_owner_this_call_did_not_spawn_is_not_the_one_it_started() {
    use std::io::Read as _;
    // (case, byte written, spawned pid, direct, first probe still starting, own)
    let cases = [
        ("lost the bind", false, 999, true, false, false),
        ("its own owner", true, 999, true, false, true),
        ("its own owner, first probe starting", true, 999, true, true, true),
        ("replaced by a successor", true, 4242, true, false, false),
        ("replaced by a successor, first probe starting", true, 4242, true, true, false),
        ("run under the DEV launcher", true, 4242, false, false, true),
    ];
    for (case, signaled, spawned, direct, starting_first, expected) in cases {
        let dir = tempfile::tempdir_in("/tmp").unwrap();
        let spec = owner_spec(dir.path().join("owner.sock"));
        let listener = UnixListener::bind(&spec.socket).unwrap();
        let server = std::thread::spawn(move || {
            let answers = if starting_first { vec![false, true] } else { vec![true] };
            for lifecycle_ready in answers {
                let (stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream);
                reader.read_line(&mut String::new()).unwrap();
                writeln!(
                    reader.get_mut(),
                    "{}",
                    serde_json::json!({"id":1,"ok":true,"data":{
                        "app":"cmux-tui", "protocol":cmux_tui_core::server::PROTOCOL_VERSION,
                        "lifecycle_ready":lifecycle_ready, "session":"busy-recovery", "pid":999,
                        "generation":"g1"
                    }})
                )
                .unwrap();
                let _ = reader.get_mut().read(&mut [0_u8; 1]);
            }
        });
        let (reader, mut writer) = io::pipe().unwrap();
        if signaled {
            writer.write_all(&[1]).unwrap();
        }
        drop(writer);
        let pipe = std::fs::File::from(std::os::fd::OwnedFd::from(reader));
        let now = Instant::now();
        let Ok(Some((ready, own))) = wait_for_spawned_owner(
            &pipe,
            spawned,
            direct,
            &spec,
            now + ENSURE_DEADLINE,
            &RestoreBound::new(now + ENSURE_DEADLINE + Duration::from_secs(5)),
            &RestoreProgress::silent(),
        ) else {
            panic!("no ready owner ({case})");
        };
        server.join().unwrap();
        assert_eq!(ready.pid, 999, "{case}");
        assert_eq!(own, expected, "{case}");
    }
}
