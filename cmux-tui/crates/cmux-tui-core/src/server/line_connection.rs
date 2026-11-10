//! The JSON-lines connection loop shared by the local socket and the remote
//! entry: one message per line, every line seen by the connection's
//! admission before anything parses or dispatches it.

use super::*;

pub(super) fn handle_connection_with_permit(
    mux: Arc<Mux>,
    stream: Box<dyn transport::Stream>,
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
) {
    serve_line_connection(
        mux,
        stream,
        render_service,
        connection_permit,
        ClientTransport::Unix,
        &admission::LocalAdmission,
    );
}

/// One JSON line per message. `admission` sees every line before anything
/// parses or dispatches it, and may answer it instead (the remote entry).
pub(super) fn serve_line_connection(
    mux: Arc<Mux>,
    stream: Box<dyn transport::Stream>,
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
    transport: ClientTransport,
    admission: &dyn admission::LineAdmission,
) {
    let Ok(mut write_half) = stream.try_clone_box() else { return };
    let Ok(control) = write_half.try_clone_box() else { return };
    if write_half.set_write_timeout(Some(STREAM_WRITE_TIMEOUT)).is_err() {
        return;
    }
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new_with_render_service(
        QueuedSink { outbound: outbound.clone(), control: Some(SinkControl::Unix(control)) },
        render_service,
    );
    let writer_outbound = outbound;
    let writer_close = writer.clone();
    let Ok(writer_thread) =
        std::thread::Builder::new().name("mux-line-out".into()).spawn(move || {
            while let Some(item) = writer_outbound.recv() {
                writer_close.input_lane.raise_this_thread_if_marked();
                input_qos::note_thread_qos("mux-line-out");
                if write_line_outbound_item(&mut *write_half, item).is_err() {
                    writer_outbound.close();
                    let _ = write_half.shutdown(Shutdown::Both);
                    break;
                }
            }
            writer_close.close();
            let _ = write_half.shutdown(Shutdown::Both);
        })
    else {
        writer.close();
        return;
    };
    let peer_key = stream.peer_process_key();
    let peer_token = stream.peer_token();
    // Before it registers, so the orphan exit never sees the owner's own
    // plugin as a client (orphan_shutdown.rs).
    let owner_plugin = orphan_shutdown::is_owner_plugin_peer(&mux, peer_key.as_deref());
    let client = mux.control_clients.register_classified(transport, writer.clone(), owner_plugin);
    origin_gate::set_peer_identity_at_accept(&mux, client, peer_key, peer_token);
    if !admission.registered(&mux, client) {
        // Refused before its first frame (the remote entry's revocation
        // limits): nothing is read or dispatched.
        disconnect_client(&mux, client, false);
        let _ = writer_thread.join();
        return;
    }
    let mut hello = client_hello::HelloGate::new(transport);
    let surface_scheduler = Arc::new(ConnectionSurfaceScheduler::new_inner(
        mux.surface_operation_admission.clone(),
        connection_permit.clone(),
    ));
    let mut reader = BufReader::new(stream);
    let mut drain_accepted = true;
    #[cfg(unix)]
    let mut first_line_done = false;
    // A local connection the accept loop took for an outside client: its
    // first line may say that an agent hook sent it (`hook_lane_refusal`).
    let mut lane_open = matches!(transport, ClientTransport::Unix);
    loop {
        let mut line = String::new();
        // read_line includes the trailing LF. Read one byte beyond the largest
        // valid payload plus its delimiter so an oversized payload is visible.
        let read = match reader.by_ref().take((MAX_JSON_LINE_BYTES + 2) as u64).read_line(&mut line)
        {
            Ok(read) => read,
            Err(_) => {
                drain_accepted = false;
                break;
            }
        };
        if read == 0 {
            break;
        }
        if json_line_payload_len(&line) > MAX_JSON_LINE_BYTES {
            drain_accepted = false;
            break;
        }
        if line.trim().is_empty() {
            zeroize_string(&mut line);
            // A blank line is a line too: a proxy's bind must be the very first.
            #[cfg(unix)]
            if !first_line_done {
                first_line_done = true;
                mux.control_clients.agent_sessions.first_line_done(client);
            }
            continue;
        }
        writer.input_lane.raise_this_thread_if_marked();
        input_qos::note_thread_qos("mux-conn");
        if std::mem::take(&mut lane_open)
            && let Some(permit) = &connection_permit
            && let Some(refusal) = hook_lane_refusal(&mux, permit, &line)
        {
            // Nothing of the line is read further or dispatched: the hook
            // keeps its report and sends it again (`server.busy`).
            let _ = writer.send_control(&refusal);
            zeroize_string(&mut line);
            drain_accepted = false;
            break;
        }
        let keep_open = match admission.refusal(&line) {
            Some(refusal) => {
                // A refused line still counts as a line: the window closes.
                hello.close();
                writer.send_control(&refusal).is_ok()
            }
            None => {
                let peer = || {
                    let stream = reader.get_ref();
                    client_hello::Peer {
                        key: stream.peer_process_key(),
                        token: stream.peer_token(),
                    }
                };
                match hello.observe(&mux, client, &line, peer) {
                    Some(reply) => writer.send_control(&reply).is_ok(),
                    None => handle_connection_frame(
                        &mux,
                        client,
                        transport,
                        &line,
                        &writer,
                        &surface_scheduler,
                    ),
                }
            }
        };
        zeroize_string(&mut line);
        // A host proxy binds a teammate only on its first line (agent_session_proxy.rs).
        #[cfg(unix)]
        if !first_line_done {
            first_line_done = true;
            mux.control_clients.agent_sessions.first_line_done(client);
        }
        if !keep_open {
            drain_accepted = false;
            break;
        }
    }
    if drain_accepted {
        surface_scheduler.finish_and_wait();
    } else {
        let _ = surface_scheduler.close_and_wait(CONNECTION_SURFACE_SHUTDOWN_TIMEOUT);
    }
    disconnect_client(&mux, client, false);
    let _ = writer_thread.join();
    drop(connection_permit);
}

/// Places a connection whose first line is an agent hook's report in the
/// terminal lane (#27698: the terminals' processes hold at most
/// `MAX_TERMINAL_CONNECTIONS`, the rest stay for the app). The accept loop
/// places a terminal's processes by their process session, and the hook's
/// sending child has left it (terminal_sessions.rs), so without this a burst
/// of agent reports took every connection of the daemon.
///
/// `Some(busy line)` when the lane has no room: the connection is refused as
/// one refused at accept is. Any other first line changes nothing.
fn hook_lane_refusal(mux: &Mux, permit: &ConnectionPermit, line: &str) -> Option<Value> {
    let terminal = terminal_sessions::hook_report_terminal(line)?;
    let client = terminal.and_then(|id| terminal_sessions::session_of_terminal(mux, &id));
    (!permit.enter_terminal_lane(client)).then(listen::refused_busy_message)
}
