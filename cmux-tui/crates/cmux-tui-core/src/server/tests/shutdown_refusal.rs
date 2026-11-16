//! A request that reaches a daemon after its shutdown began (SIGTERM at an
//! update, logout or reboot, or an accepted `shutdown-daemon`) is not run.
//! The connection used to close with no answer: the client saw a broken
//! connection and could not tell whether its input reached the terminal
//! (the update drill counts 2-3 such sends per swap). It now gets the same
//! refusal a pending handoff answers (`daemon_shutdown_pending`, "request was
//! not executed") before the close, so it can send again to the next daemon
//! without typing anything twice.

use super::*;

#[test]
fn a_request_after_the_shutdown_began_is_refused_as_not_executed() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    mux.request_daemon_shutdown();
    assert!(mux.daemon_shutdown_requested());

    let keep_open = handle_connection_frame(
        &mux,
        client,
        ClientTransport::Unix,
        r#"{"id":7,"cmd":"send","terminal_id":"0123456789abcdef0123456789abcdef","text":"x"}"#,
        &writer,
        &scheduler,
    );
    assert!(!keep_open, "a connection of a daemon that shuts down must close");
    let reply = outbound.try_pop().expect("the request got no answer before the close");
    let reply: Value = serde_json::from_str(&reply).unwrap();
    assert_eq!(reply["id"], 7, "{reply}");
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error_code"], DAEMON_SHUTDOWN_PENDING_CODE, "{reply}");
    mux.shutdown();
}
