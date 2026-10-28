//! `debug-panic` on the wire and its three crashes: the trusted local
//! connection gets a reply and the crash, WebSocket and remote clients and bad
//! lines get a refusal and no crash, other lines are left alone, and each kind
//! ends its thread or the process the way it says.

use std::cell::Cell;
use std::sync::Arc;

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::server::{BoundedOutbound, ClientTransport, Command, QueuedSink, routes};

/// The child process's kind: set only by [`crash_in_child`].
const CHILD_ENV: &str = "CMUX_TEST_DEBUG_CRASH_KIND";

struct Connection {
    client: u64,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
}

fn connection(mux: &Arc<Mux>, transport: ClientTransport) -> Connection {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(transport, writer.clone());
    Connection { client, outbound, writer }
}

/// The reply to `request` and the kinds handed to the crash.
fn reply_to(mux: &Arc<Mux>, conn: &Connection, request: Value) -> (Value, Vec<CrashKind>) {
    let fired = Cell::new(Vec::new());
    let crash = |kind| {
        fired.set([fired.take(), vec![kind]].concat());
        Ok(())
    };
    let handled = try_handle(mux, conn.client, &request.to_string(), &conn.writer, crash);
    assert_eq!(handled, Some(true), "{request}");
    let reply = serde_json::from_str(&conn.outbound.try_pop().expect("reply")).unwrap();
    (reply, fired.take())
}

#[test]
fn debug_crash_inject_fires_each_kind_for_the_trusted_local_connection() {
    let mux = Mux::new_for_test("debug-crash-inject-local", SurfaceOptions::default());
    let local = connection(&mux, ClientTransport::Unix);
    for (id, kind) in CrashKind::ALL.into_iter().enumerate() {
        let request = json!({"id": id, "cmd": COMMAND, "kind": kind.wire_name()});
        let (reply, fired) = reply_to(&mux, &local, request);
        assert_eq!(reply["ok"], true, "{reply}");
        assert_eq!(reply["id"], id, "{reply}");
        assert_eq!(reply["data"]["kind"], kind.wire_name(), "{reply}");
        assert_eq!(reply["data"]["pid"], std::process::id(), "{reply}");
        assert_eq!(fired, [kind]);
    }
}

#[test]
fn debug_crash_inject_refuses_websocket_and_remote_clients() {
    let mux = Mux::new_for_test("debug-crash-inject-remote", SurfaceOptions::default());
    for (name, transport) in
        [("websocket", ClientTransport::WebSocket), ("remote", ClientTransport::Remote)]
    {
        let conn = connection(&mux, transport);
        let (reply, fired) =
            reply_to(&mux, &conn, json!({"id": 1, "cmd": COMMAND, "kind": "abort"}));
        assert_eq!(reply["ok"], false, "{reply}");
        assert_eq!(reply["error"], DebugPanicRefused::NotLocal.to_string(), "{reply}");
        assert!(fired.is_empty(), "{name} crashed the daemon");
    }
}

#[test]
fn debug_crash_inject_refuses_bad_lines_without_crashing() {
    let mux = Mux::new_for_test("debug-crash-inject-bad", SurfaceOptions::default());
    let local = connection(&mux, ClientTransport::Unix);
    for (request, refused) in [
        (json!({"id": 1, "cmd": COMMAND}), DebugPanicRefused::BadKind),
        (json!({"id": 2, "cmd": COMMAND, "kind": "hang"}), DebugPanicRefused::BadKind),
        (json!({"id": 3, "cmd": COMMAND, "kind": 1}), DebugPanicRefused::BadKind),
        (
            json!({"id": 4, "cmd": COMMAND, "kind": "panic", "path": "/tmp/x"}),
            DebugPanicRefused::UnknownField("path".into()),
        ),
    ] {
        let (reply, fired) = reply_to(&mux, &local, request.clone());
        assert_eq!(reply["ok"], false, "{reply}");
        assert_eq!(reply["error"], refused.to_string(), "{request}");
        assert!(fired.is_empty(), "{request}");
    }
}

#[test]
fn debug_crash_inject_reports_a_crash_thread_that_did_not_start() {
    let mux = Mux::new_for_test("debug-crash-inject-spawn", SurfaceOptions::default());
    let local = connection(&mux, ClientTransport::Unix);
    let request = json!({"id": 5, "cmd": COMMAND, "kind": "panic"}).to_string();
    let refused = || Err(DebugPanicRefused::Spawn("no threads".into()));
    let handled = try_handle(&mux, local.client, &request, &local.writer, |_| refused());
    assert_eq!(handled, Some(true));
    let reply: Value = serde_json::from_str(&local.outbound.try_pop().expect("reply")).unwrap();
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply["error"].as_str().unwrap().contains("no threads"), "{reply}");
}

#[test]
fn debug_crash_inject_leaves_other_lines_and_has_its_route() {
    let mux = Mux::new_for_test("debug-crash-inject-other", SurfaceOptions::default());
    let local = connection(&mux, ClientTransport::Unix);
    for line in [
        json!({"id": 1, "cmd": "ping"}).to_string(),
        json!({"id": 2, "cmd": "notify", "title": COMMAND}).to_string(),
        "not json debug-panic".to_string(),
    ] {
        let handled = try_handle(&mux, local.client, &line, &local.writer, |kind| {
            panic!("{line} fired {kind:?}")
        });
        assert_eq!(handled, None, "{line}");
    }
    assert!(local.outbound.try_pop().is_none());
    assert!(serde_json::from_value::<Command>(json!({"cmd": COMMAND})).is_err());
    let route = routes::find(COMMAND).expect("debug-panic route");
    assert_eq!(
        route.names.iter().flat_map(|name| name.exact()).copied().collect::<Vec<_>>(),
        [COMMAND]
    );
}

#[test]
fn debug_crash_inject_panic_ends_only_its_named_thread() {
    let payload = fire(CrashKind::Panic).unwrap().join().expect_err("the thread panics");
    let message = payload.downcast_ref::<&str>().copied().unwrap_or_default();
    assert_eq!(message, "debug-panic: injected daemon panic");
}

/// Run in a child process by [`debug_crash_inject_abort_and_segv_end_the_process`]:
/// crash as [`CHILD_ENV`] says. Does nothing in an ordinary test run.
#[test]
fn debug_crash_inject_child() {
    let Ok(name) = std::env::var(CHILD_ENV) else { return };
    let kind = CrashKind::parse(&name).expect("a crash kind");
    let ended = fire(kind).unwrap().join();
    panic!("{name} returned: {ended:?}");
}

/// The exit status of this test binary running [`debug_crash_inject_child`]
/// with `kind`.
#[cfg(unix)]
fn crash_in_child(kind: CrashKind) -> std::process::ExitStatus {
    let module = module_path!().split_once("::").map_or(module_path!(), |(_, path)| path);
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([&format!("{module}::debug_crash_inject_child"), "--exact", "--test-threads=1"])
        .env(CHILD_ENV, kind.wire_name())
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("debug_crash_inject_child"), "the child ran no test: {stdout}");
    output.status
}

#[cfg(unix)]
#[test]
fn debug_crash_inject_abort_and_segv_end_the_process() {
    use std::os::unix::process::ExitStatusExt;
    assert_eq!(crash_in_child(CrashKind::Abort).signal(), Some(libc::SIGABRT));
    assert_eq!(crash_in_child(CrashKind::Segv).signal(), Some(libc::SIGSEGV));
}
