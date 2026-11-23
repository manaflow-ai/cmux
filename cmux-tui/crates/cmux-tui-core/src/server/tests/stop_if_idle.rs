//! `shutdown-daemon` with `if_idle` (`daemon stop --if-idle`, the Rex
//! docs' `server stop --if-idle`): the daemon stops only while no other
//! client is connected and no terminal is live. The check runs inside the
//! handoff reservation, which refuses every new client, so nothing can
//! start work between the check and the stop. A refusal stops nothing,
//! says what uses the daemon and releases the reservation.

use super::*;
use crate::workspace_registry::TerminalLifecycle;

fn stop_if_idle(mux: &Arc<Mux>, requester: u64, writer: &MessageWriter, id: u64) {
    let (_, generation) = mux.registry_identity();
    let request = json!({
        "id": id,
        "cmd": "shutdown-daemon",
        "pid": std::process::id(),
        "generation": generation,
        "if_idle": true,
    });
    assert!(handle_message(mux, requester, &request.to_string(), writer));
}

fn live_terminals(mux: &Mux) -> usize {
    mux.terminal_registry_snapshot()
        .unwrap()
        .terminals
        .iter()
        .filter(|terminal| {
            matches!(
                terminal.lifecycle,
                TerminalLifecycle::Launching
                    | TerminalLifecycle::Adopting
                    | TerminalLifecycle::Running
            )
        })
        .count()
}

#[test]
fn identify_advertises_stop_if_idle() {
    let mux = test_mux();
    assert!(identify_capabilities(&mux).contains(&"daemon-stop-if-idle-v1"));
}

#[test]
fn stop_if_idle_stops_a_daemon_nobody_uses() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    assert_eq!(live_terminals(&mux), 0);
    let (writer, outbound) = captured_writer();
    let requester = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    stop_if_idle(&mux, requester, &writer, 1);
    assert!(mux.daemon_shutdown_requested());
    let response = pop_json(&outbound);
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["data"]["accepted"], true, "{response}");
}

#[test]
fn stop_if_idle_refuses_while_another_client_is_connected() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let (writer, outbound) = captured_writer();
    let requester = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let (tui_writer, _tui_outbound) = captured_writer();
    let tui = mux.control_clients.register(ClientTransport::Unix, tui_writer);
    mux.control_clients.set_info(tui, Some("laptop".into()), Some("tui".into()), None).unwrap();

    stop_if_idle(&mux, requester, &writer, 2);
    let response = pop_json(&outbound);
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error_code"], "daemon_busy", "{response}");
    let error = response["error"].as_str().unwrap();
    assert!(error.contains("1 other client") && error.contains("laptop"), "{error}");
    assert_eq!(response["error_details"]["clients"][0]["kind"], "tui", "{response}");
    assert_eq!(response["error_details"]["clients"][0]["name"], "laptop", "{response}");
    assert_eq!(response["error_details"]["terminals"], 0, "{response}");
    assert!(!mux.daemon_shutdown_requested());
    assert!(mux.control_clients.contains(tui));

    // The refusal released the reservation: a plain stop still works.
    let (_, generation) = mux.registry_identity();
    let plain = json!({
        "id": 3,
        "cmd": "shutdown-daemon",
        "pid": std::process::id(),
        "generation": generation,
    });
    assert!(handle_message(&mux, requester, &plain.to_string(), &writer));
    assert!(mux.daemon_shutdown_requested());
    assert_eq!(pop_json(&outbound)["ok"], true);
}

#[test]
fn stop_if_idle_refuses_while_a_terminal_is_live() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    mux.new_workspace(None, None).unwrap();
    let live = live_terminals(&mux);
    assert!(live > 0, "the test needs a live terminal");
    let (writer, outbound) = captured_writer();
    let requester = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    stop_if_idle(&mux, requester, &writer, 4);
    let response = pop_json(&outbound);
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error_code"], "daemon_busy", "{response}");
    assert_eq!(response["error_details"]["terminals"], live, "{response}");
    assert_eq!(response["error_details"]["clients"], json!([]), "{response}");
    assert!(!mux.daemon_shutdown_requested());
    mux.shutdown();
}

/// The owner's own journal plugin (the bundled screen detector connects
/// back at start and stays) is not a client that uses the daemon: an
/// otherwise idle daemon still stops.
#[test]
fn stop_if_idle_does_not_count_the_owners_own_plugin() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let (writer, outbound) = captured_writer();
    let requester = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let (plugin_writer, _plugin_outbound) = captured_writer();
    let _plugin =
        mux.control_clients.register_classified(ClientTransport::Unix, plugin_writer, true);
    stop_if_idle(&mux, requester, &writer, 5);
    let response = pop_json(&outbound);
    assert_eq!(response["ok"], true, "{response}");
    assert!(mux.daemon_shutdown_requested());
}

/// Once the idle check passed, no terminal may become live before the stop
/// (a creation queued before the check that commits after it): the
/// registry refuses it. Cancelling the handoff lowers the fence again.
#[test]
fn an_idle_stop_fences_new_terminals_until_its_handoff_is_cancelled() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let writer = test_writer();
    let requester = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let (_, generation) = mux.registry_identity();
    // The reservation stays pending: `handle_command` does not commit it.
    handle_command(
        &mux,
        requester,
        Command::ShutdownDaemon {
            pid: std::process::id(),
            generation,
            force: false,
            end_terminals: false,
            keep_layout: false,
            restart: Some(false),
            if_idle: true,
        },
        &writer,
    )
    .unwrap();
    // The creation is refused at the write of its terminal row, which comes
    // before its host starts: no row and no host. (Its caller hears that
    // the effect may have run: the creation records its outcome only after.)
    mux.new_workspace(None, None).unwrap_err();
    assert!(mux.terminal_registry_snapshot().unwrap().terminals.is_empty());

    mux.cancel_daemon_handoff(requester);
    mux.new_workspace(None, None).unwrap();
    assert_eq!(live_terminals(&mux), 1);
    mux.shutdown();
}

/// A refused idle stop raises no fence: terminals start as before.
#[test]
fn a_refused_idle_stop_leaves_terminals_free_to_start() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let (writer, outbound) = captured_writer();
    let requester = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let _other = mux.control_clients.register(ClientTransport::Unix, test_writer());
    stop_if_idle(&mux, requester, &writer, 6);
    assert_eq!(pop_json(&outbound)["error_code"], "daemon_busy");
    mux.new_workspace(None, None).unwrap();
    assert_eq!(live_terminals(&mux), 1);
    mux.shutdown();
}

/// A requester that disconnects after its idle check passed (its handoff
/// still pending) takes the fence with it: terminals start again.
#[test]
fn an_idle_stop_fence_ends_when_its_requester_disconnects() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let writer = test_writer();
    let requester = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let (_, generation) = mux.registry_identity();
    handle_command(
        &mux,
        requester,
        Command::ShutdownDaemon {
            pid: std::process::id(),
            generation,
            force: false,
            end_terminals: false,
            keep_layout: false,
            restart: Some(false),
            if_idle: true,
        },
        &writer,
    )
    .unwrap();
    assert!(mux.new_workspace(None, None).is_err(), "the fence is raised");

    assert!(disconnect_client(&mux, requester, false));
    assert!(!mux.daemon_handoff_in_progress());
    mux.new_workspace(None, None).unwrap();
    assert_eq!(live_terminals(&mux), 1);
    mux.shutdown();
}

/// The race Codex found (r27c): the requester's reservation goes (its
/// connection closed after the scheduler gave up on it) between the client
/// count and the terminal count. The idle check then raises no fence, so
/// nothing is left to refuse new terminals.
#[test]
fn an_idle_check_whose_reservation_is_gone_raises_no_fence() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let requester = mux.control_clients.register(ClientTransport::Unix, test_writer());
    mux.control_clients.begin_daemon_handoff(requester, false).unwrap();
    assert!(mux.control_clients.cancel_daemon_handoff(requester));
    let error = super::super::stop_if_idle::check(&mux, requester).unwrap_err();
    assert!(format!("{error:#}").contains("cancelled"), "{error:#}");
    assert_eq!(mux.workspace_registry.lock().unwrap().idle_stop_fence_owner(), None);
    mux.new_workspace(None, None).unwrap();
    mux.shutdown();
}

/// A release of another reservation, or a settle while the stop still holds
/// its own, leaves the fence of that stop raised.
#[test]
fn the_fence_stays_while_its_own_reservation_is_held() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let requester = mux.control_clients.register(ClientTransport::Unix, test_writer());
    let other = mux.control_clients.register(ClientTransport::Unix, test_writer());
    mux.control_clients.begin_daemon_handoff(requester, false).unwrap();
    super::super::stop_if_idle::check(&mux, requester).unwrap_err();
    // `other` is connected: busy, no fence. Once it leaves, the check passes.
    assert!(disconnect_client(&mux, other, false));
    super::super::stop_if_idle::check(&mux, requester).unwrap();
    assert_eq!(mux.workspace_registry.lock().unwrap().idle_stop_fence_owner(), Some(requester));

    mux.cancel_daemon_handoff(other);
    mux.settle_idle_stop_fence();
    assert!(mux.new_workspace(None, None).is_err(), "the fence of a held reservation stays");

    mux.cancel_daemon_handoff(requester);
    assert_eq!(mux.workspace_registry.lock().unwrap().idle_stop_fence_owner(), None);
    mux.new_workspace(None, None).unwrap();
    mux.shutdown();
}

/// Closing the last workspace leaves its terminal live for the reap grace
/// (Reopen Closed attaches to it within that time), so the stop still
/// refuses. With no workspace left, "1 live terminal" alone reads like a
/// shell nobody can see: the refusal says these only wait out the grace,
/// but only while a reaper runs to end them.
#[test]
fn stop_if_idle_names_the_terminals_of_closed_tabs() {
    let mux = test_mux();
    mux.mark_server_lifecycle_ready();
    let surface = mux.new_workspace(None, None).unwrap();
    let workspace = mux.surface_workspace(surface.id).unwrap();
    assert!(mux.close_workspace_at_revision(workspace, None).unwrap().is_some());
    assert_eq!(live_terminals(&mux), 1, "the closed tab's terminal waits out the reap grace");
    let (writer, outbound) = captured_writer();
    let requester = mux.control_clients.register(ClientTransport::Unix, writer.clone());

    // No reaper: nothing ends it, so it is not said to end on its own.
    stop_if_idle(&mux, requester, &writer, 8);
    let response = pop_json(&outbound);
    assert_eq!(response["error_code"], "daemon_busy", "{response}");
    assert_eq!(response["error_details"]["closed_tabs"], 0, "{response}");
    assert!(!response["error"].as_str().unwrap().contains("reap grace"), "{response}");

    let reaper = crate::mux::start_terminal_reaper(&mux).unwrap();
    stop_if_idle(&mux, requester, &writer, 9);
    let response = pop_json(&outbound);
    assert_eq!(response["error_code"], "daemon_busy", "{response}");
    assert_eq!(response["error_details"]["terminals"], 1, "{response}");
    assert_eq!(response["error_details"]["closed_tabs"], 1, "{response}");
    let error = response["error"].as_str().unwrap();
    assert!(error.contains("closed tab") && error.contains("reap grace"), "{error}");
    assert!(!mux.daemon_shutdown_requested());
    drop(reaper);
    mux.shutdown();
}
