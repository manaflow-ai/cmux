//! One frame of a connection: authentication and pairing frames, a request's
//! dispatch with its cancellation, and the VT-state command reply. Moved out of
//! server.rs unchanged (cx-6so.3).

use super::*;

/// One frame of a connection. `transport` is the connection's own value
/// (not a registry lookup), so a remote-entry connection always takes the
/// remote path, also after its registry record is gone.
pub(super) fn handle_connection_frame(
    mux: &Arc<Mux>,
    client: u64,
    transport: ClientTransport,
    message: &str,
    writer: &MessageWriter,
    scheduler: &Arc<ConnectionSurfaceScheduler>,
) -> bool {
    // Keep an idle shutdown requester connected until owner cleanup closes
    // the transport, so lifecycle clients receive authoritative completion.
    // A pipelined message after the acknowledgement must not reach parsing or
    // dispatch; returning false makes the connection loop close that client.
    if mux.daemon_shutdown_requested() || mux.daemon_handoff_committed() {
        return false;
    }
    if matches!(transport, ClientTransport::Remote) || mux.is_remote_client(client) {
        return remote_relay::handle_frame(mux, client, message, writer);
    }
    // Before the acknowledgement the handoff can still fail (for example
    // while `end_terminals` awaits every host) and this daemon keeps
    // serving. Closing here would drop the requester's pending
    // `shutdown-daemon` reply along with its connection, so a message that
    // arrives meanwhile (a subscriber's snapshot refresh) is refused
    // without being executed and the connection stays open.
    if mux.daemon_handoff_in_progress() {
        return pending_handoff::reject_message_during_pending_handoff(message, writer);
    }
    if let Some(request) = crate::resource_router::parse_resource_line(message) {
        // A v2 line the catalog parse refuses may name a routed namespace
        // operation (page-router-v1): the same JSON parse decides, so every
        // spelling of the line gets one answer.
        if request.is_err()
            && let Some(keep_open) = page_router::try_handle(mux, client, message, writer)
        {
            return keep_open;
        }
        return origin_gate::handle_resource_line(mux, client, message, request, writer);
    }
    if let Some(keep_open) = loopback_forward::try_handle(mux, client, message, writer) {
        return keep_open;
    }
    #[cfg(unix)]
    if let Some(keep_open) = browser_runtime::try_handle(mux, client, message, writer) {
        return keep_open;
    }
    #[cfg(unix)]
    if let Some(keep_open) = agent_session_attach::try_handle(mux, client, message, writer)
        .or_else(|| agent_transfer::try_handle(mux, client, message, writer))
    {
        return keep_open;
    }
    #[cfg(unix)]
    if let Some(keep_open) = apps::try_handle(mux, client, message, writer) {
        return keep_open;
    }
    #[cfg(unix)]
    if let Some(keep_open) = scripts::try_handle(mux, client, message, writer) {
        return keep_open;
    }
    #[cfg(unix)]
    if let Some(keep_open) = fs_wire::try_handle(mux, client, message, writer) {
        return keep_open;
    }
    let request = match serde_json::from_str::<Request>(message) {
        Ok(request) => request,
        Err(error) => return send_bad_request(writer, message, &error),
    };
    let mut pending = Some(request);
    match scheduler.dispatch(mux.clone(), client, &mut pending, message.len(), writer.clone()) {
        Some(keep_open) => keep_open,
        None => handle_request(mux, client, pending.take().unwrap(), writer),
    }
}

pub(super) fn handle_request(
    mux: &Arc<Mux>,
    client: u64,
    request: Request,
    writer: &MessageWriter,
) -> bool {
    handle_request_with_cancellation(mux, client, request, writer, None)
}

pub(super) fn handle_request_with_cancellation(
    mux: &Arc<Mux>,
    client: u64,
    request: Request,
    writer: &MessageWriter,
    cancellation: Option<&ConnectionCancellation>,
) -> bool {
    let Request { id, cmd } = request;
    if let Command::UrlOpen { terminal_id, url } = cmd {
        return url_open::start(mux, client, id, terminal_id, url, writer);
    }
    if let Command::ChiefInspect(params) = cmd {
        return chief_inspect::start(mux, client, id, params, writer);
    }
    if cloud_conversations::is_network(&cmd) {
        return cloud_conversations::start(mux, client, id, cmd, writer);
    }
    if let Some(target) = cloud_conversations::subscribe_target(mux, &cmd) {
        return cloud_conversations::subscribe_then_announce(mux, client, id, cmd, target, writer);
    }
    if matches!(&cmd, Command::ShutdownDaemon { .. } | Command::ReloadConfig)
        && !mux.server_lifecycle_ready()
    {
        return send_request_error(writer, id, "server lifecycle is not ready");
    }
    if let Command::VtState { surface } = &cmd {
        return match send_vt_state_command_response(mux, id.clone(), *surface, writer) {
            Ok(()) => true,
            Err(error) => send_request_error(writer, id, &error.to_string()),
        };
    }

    let detach_self = match &cmd {
        Command::DetachClient { client: target, by, surface }
            if target.whole_client() == Some(client)
                && own_view_detach_target(mux, target, *surface).is_none() =>
        {
            Some(detach_actor(mux, client, by.clone()))
        }
        _ => None,
    };
    let shutdown_daemon = matches!(&cmd, Command::ShutdownDaemon { .. });
    let (mut reason, mut retryable, mut details) = (None, None, None);
    let response = match handle_command_with_cancellation(mux, client, cmd, writer, cancellation) {
        Ok(data) => Response {
            id,
            ok: true,
            data: Some(data),
            error: None,
            error_code: None,
            error_delivery: None,
        },
        Err(error) => {
            reason = conversations::error_reason(&error)
                .or_else(|| cloud_conversations::error_reason(&error));
            retryable = cloud_conversations::error_retryable(&error);
            details = renderer_grant::error_details(&error)
                .or_else(|| conversations::error_details(&error));
            let error_code = response_error_code(&error);
            let error_delivery =
                error.downcast_ref::<DeliveryClassifiedError>().map(|error| error.delivery);
            Response {
                id,
                ok: false,
                data: None,
                error: Some(error.to_string()),
                error_code,
                error_delivery,
            }
        }
    };
    let (response, reason) = remote_relay::redact_response(mux, client, response, reason);
    let details = details.filter(|_| !mux.is_remote_client(client));
    let response_ok = response.ok;
    let sent = responses::send_response_with_details(writer, response, reason, retryable, details);
    // Flush the successful acknowledgement before making the owning loop
    // leave, so process teardown cannot race the response writer.
    if shutdown_daemon && response_ok {
        if sent {
            return complete_daemon_shutdown_after_ack(mux, client, writer);
        } else {
            mux.cancel_daemon_handoff(client);
        }
    }
    if let Some(by) = detach_self
        && response_ok
        && sent
    {
        kick_client(mux, client, by);
        return false;
    }
    sent
}

fn send_vt_state_command_response(
    mux: &Mux,
    id: Option<Value>,
    surface: SurfaceId,
    writer: &MessageWriter,
) -> anyhow::Result<()> {
    // Reserve the entire wire-frame allowance before copying a replay or
    // starting its base64 encoder. The writer allocates only for actual
    // output and releases unused logical quota before the response is queued.
    let mut output = writer.render_service.reserved_control_writer()?;
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    let (cols, rows, replay) = surface.try_with_terminal(|terminal| {
        terminal
            .vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES)
            .map(|replay| (terminal.cols(), terminal.rows(), replay))
    })??;

    write_vt_state_command_json(
        &mut output,
        id.as_ref(),
        cols,
        rows,
        &replay.self_contained_bytes(),
        &replay.kitty_image_aliases,
        replay.kitty_state,
    )?;
    writer.send_serialized_control(output.finish())?;
    Ok(())
}

pub(super) fn write_vt_state_command_json(
    output: &mut BudgetedJsonWriter,
    id: Option<&Value>,
    cols: u16,
    rows: u16,
    replay: &[u8],
    kitty_image_aliases: &[ghostty_vt::KittyImageAlias],
    kitty_state: KittyReplayState,
) -> std::io::Result<()> {
    output.write_all(b"{")?;
    if let Some(id) = id {
        output.write_all(b"\"id\":")?;
        serde_json::to_writer(&mut *output, id).map_err(json_error_to_io)?;
        output.write_all(b",")?;
    }
    write!(output, "\"ok\":true,\"data\":{{\"cols\":{cols},\"rows\":{rows},\"data\":\"")?;
    {
        let mut encoder = base64::write::EncoderWriter::new(
            &mut *output,
            &base64::engine::general_purpose::STANDARD,
        );
        encoder.write_all(replay)?;
        encoder.finish()?;
    }
    output.write_all(b"\",\"kitty_image_aliases\":")?;
    write_kitty_image_aliases_json(output, kitty_image_aliases)?;
    output.write_all(b",\"kitty_graphics_state\":")?;
    write_kitty_replay_state_json(output, kitty_state)?;
    output.write_all(b"}}")?;
    Ok(())
}

pub(super) fn auth_token(message: &str) -> Option<String> {
    let value: Value = serde_json::from_str(message).ok()?;
    let object = value.as_object()?;
    if object.len() != 1 {
        return None;
    }
    let auth = object.get("auth")?.as_object()?;
    if auth.len() != 1 {
        return None;
    }
    auth.get("token")?.as_str().map(str::to_string)
}

pub(super) fn pairing_request(message: &str) -> bool {
    let Ok(value) = serde_json::from_str::<Value>(message) else { return false };
    let Some(object) = value.as_object() else { return false };
    if object.len() != 1 {
        return false;
    }
    let Some(pair) = object.get("pair").and_then(Value::as_object) else { return false };
    pair.len() == 1 && pair.get("request").and_then(Value::as_bool) == Some(true)
}

pub(super) fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    let mut difference = a.len() ^ b.len();
    let length = a.len().max(b.len());
    for index in 0..length {
        difference |=
            usize::from(a.get(index).copied().unwrap_or(0) ^ b.get(index).copied().unwrap_or(0));
    }
    difference == 0
}

pub(super) fn zeroize_string(value: &mut str) {
    // NUL remains valid UTF-8, so decoded control frames can be cleared in
    // place immediately after dispatch.
    value.zeroize();
}
