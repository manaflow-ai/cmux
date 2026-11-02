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

/// A fake owner on `listener` that answers `identify` as ready and
/// `server-stats` with a registry holder of `held_for_us`, until `stopped`.
pub(super) fn serve_owner_with_registry_hold(
    listener: UnixListener,
    held_for_us: u64,
    stopped: mpsc::Receiver<()>,
) {
    loop {
        let (stream, _) = listener.accept().unwrap();
        if stopped.try_recv().is_ok() {
            break;
        }
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        if reader.read_line(&mut line).is_err() {
            continue;
        }
        let request: serde_json::Value = serde_json::from_str(&line).unwrap();
        let data = match request["cmd"].as_str() {
            Some("identify") => serde_json::json!({
                "app":"cmux-tui", "protocol":cmux_tui_core::server::PROTOCOL_VERSION,
                "lifecycle_ready":true, "session":"busy-recovery",
                "pid":std::process::id(), "generation":"g1"
            }),
            Some("server-stats") => serde_json::json!({
                "registry_lock": {"holder": {
                    "site":"crates/cmux-tui-core/src/mux/terminal_host_link.rs:43:24",
                    "held_for_us": held_for_us
                }}
            }),
            other => panic!("unexpected request {other:?}"),
        };
        let _ = writeln!(reader.get_mut(), "{}", serde_json::json!({"id":1,"ok":true,"data":data}));
    }
}

/// https://github.com/manaflow-ai/cmux/issues/32621: an owner deadlocked on
/// its registry lock still answers `identify`; ensure must not reuse it.
#[test]
fn ensure_reports_an_owner_with_a_wedged_registry_lock_unavailable() {
    let dir = tempfile::tempdir_in("/tmp").unwrap();
    let spec = owner_spec(dir.path().join("owner.sock"));
    let listener = UnixListener::bind(&spec.socket).unwrap();
    let (stop, stopped) = mpsc::channel();
    // 3.95 hours, as the nightly server reported.
    let held = 14_220_000_000_u64;
    let server = std::thread::spawn(move || serve_owner_with_registry_hold(listener, held, stopped));
    let result = attempt(&spec, Some(&spec.session), Instant::now() + ENSURE_DEADLINE);
    stop.send(()).unwrap();
    let _ = UnixStream::connect(&spec.socket);
    server.join().unwrap();
    assert!(matches!(result, Ok(Attempt::Wedged)), "a wedged owner must not read as ready");
}

#[test]
fn ensure_keeps_an_owner_whose_registry_lock_is_briefly_held() {
    let dir = tempfile::tempdir_in("/tmp").unwrap();
    let spec = owner_spec(dir.path().join("owner.sock"));
    let listener = UnixListener::bind(&spec.socket).unwrap();
    let (stop, stopped) = mpsc::channel();
    let server =
        std::thread::spawn(move || serve_owner_with_registry_hold(listener, 40_000, stopped));
    let result = attempt(&spec, Some(&spec.session), Instant::now() + ENSURE_DEADLINE);
    stop.send(()).unwrap();
    let _ = UnixStream::connect(&spec.socket);
    server.join().unwrap();
    assert!(matches!(result, Ok(Attempt::Ready(_))), "a busy owner stays in use");
}
