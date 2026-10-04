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
    let client = mux.control_clients.register(transport, writer.clone());
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
            continue;
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
                    client_hello::Peer { key: stream.peer_process_key(), token: stream.peer_token() }
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
