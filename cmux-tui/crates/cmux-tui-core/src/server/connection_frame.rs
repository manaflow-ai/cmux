//! One frame of a connection: authentication and pairing frames, a request's
//! dispatch with its cancellation, and the VT-state command reply. Moved out of
//! server.rs unchanged (cx-6so.3).

#[cfg(unix)]
mod machine_catalog;

use super::*;
use crate::event_cause::{EventCause, EventCauseScope};

/// [`handle_connection_frame_at`] for a line that arrives now (tests).
#[cfg(test)]
pub(super) fn handle_connection_frame(
    mux: &Arc<Mux>,
    client: u64,
    transport: ClientTransport,
    message: &str,
    writer: &MessageWriter,
    scheduler: &Arc<ConnectionSurfaceScheduler>,
) -> bool {
    handle_connection_frame_at(mux, client, transport, message, writer, scheduler, Instant::now())
}

/// One frame of a connection, read at `arrived` (the reader stamps it as
/// its read returns; a line already buffered behind an inline request is
/// stamped when the reader reaches it). `transport` is the connection's own
/// value (not a registry lookup), so a remote-entry connection always takes
/// the remote path, also after its registry record is gone.
pub(super) fn handle_connection_frame_at(
    mux: &Arc<Mux>,
    client: u64,
    transport: ClientTransport,
    message: &str,
    writer: &MessageWriter,
    scheduler: &Arc<ConnectionSurfaceScheduler>,
    arrived: Instant,
) -> bool {
    // Every handler this frame reaches runs on the reader's request path
    // (`crate::request_path`): its blocking work is counted at its caller.
    let _request_path = crate::request_path::RequestPathScope::enter(mux.request_path_stats());
    // Every frame is watched on this thread until its handler returns: past
    // 250 ms it lands in server-stats `slow_requests` (request_watchdog.rs),
    // named by the handler it is in. A `Command` handed to the scheduler is
    // watched again where it runs.
    let watched = mux.request_watchdog.begin(client, WatchedMethod::frame(FrameStage::Route));
    let watch = |method: WatchedMethod| {
        if let Some(scope) = &watched {
            scope.set_method(method);
        }
    };
    let stage = |stage: FrameStage| watch(WatchedMethod::frame(stage));
    // Keep an idle shutdown requester connected until owner cleanup closes
    // the transport, so lifecycle clients receive authoritative completion.
    // A pipelined message after the acknowledgement must not reach parsing or
    // dispatch; returning false makes the connection loop close that client.
    if mux.daemon_shutdown_requested() || mux.daemon_handoff_committed() {
        return false;
    }
    // Every event this frame sets off, here or on a thread it hands work
    // to, carries the connection's cause (crate::event_cause).
    let (remote, cause) = mux.frame_client(client);
    let _cause = EventCauseScope::enter(cause);
    if matches!(transport, ClientTransport::Remote) || remote {
        return remote_relay::handle_watched_frame(
            mux,
            client,
            message,
            writer,
            arrived,
            watched.as_ref(),
        );
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
    // An older client's line, upgraded to this daemon's API revision before
    // any parse (server/api_revision_wire.rs); borrowed unchanged otherwise.
    let upgraded = writer.api_revision.upgrade_request(message);
    let message: &str = &upgraded;
    let stats = mux.request_stats();
    if let Some(request) = crate::resource_router::parse_resource_line(message) {
        match &request {
            Ok(envelope) => watch(WatchedMethod::resource(envelope.operation)),
            Err(_) => stage(FrameStage::PageRouter),
        }
        // An envelope's `origin` claim may only narrow the cause, as it
        // only narrows the origin; the origin gate still checks the claim.
        let _claimed =
            request.as_ref().ok().and_then(|envelope| envelope.origin.as_ref()).map(|claim| {
                EventCauseScope::enter(EventCause::current().narrowed_by(claim.claim.event_cause()))
            });
        let arrival = RequestArrival::parsed_now(arrived);
        let mut span = match &request {
            Ok(envelope) => RequestSpan::open_method(
                stats,
                RequestMethod::of_resource(envelope.operation),
                request_id_hash(Some(&envelope.id)),
                arrival,
            ),
            Err(_) => RequestHead::parse(message).open(stats, arrival),
        };
        // A v2 line the catalog parse refuses may name a routed namespace
        // operation (page-router-v1): the same JSON parse decides, so every
        // spelling of the line gets one answer.
        if request.is_err()
            && let Some(keep_open) = page_router::try_handle(mux, client, message, writer)
        {
            return span.answered(keep_open);
        }
        // Debug timing marks of a resource create, from the arrival of its
        // line to its reply (`CMUX_TUI_DEBUG_SPANS`; cx-b4sjc).
        let trace_label = request.as_ref().ok().and_then(|envelope| match envelope.operation {
            ResourceOperation::WorkspaceCreate => Some("resource:workspace.create"),
            ResourceOperation::TabCreateTerminal => Some("resource:tab.create_terminal"),
            ResourceOperation::PaneSplit => Some("resource:pane.split"),
            ResourceOperation::PaneCreate => Some("resource:pane.create"),
            ResourceOperation::WorkspaceEnsureHome => Some("resource:workspace.ensure_home"),
            _ => None,
        });
        let traced = trace_label
            .and_then(|label| crate::debug_spans::Trace::start(label, arrived))
            .is_some_and(|trace| {
                crate::debug_spans::install(Some(trace));
                true
            });
        let keep_open = origin_gate::handle_resource_line(mux, client, message, request, writer);
        if traced {
            crate::debug_spans::mark("reply.sent");
            crate::debug_spans::finish(crate::debug_spans::take());
        }
        return span.answered(keep_open);
    }
    // A line whose `cmd` names no `Command` belongs to a feature route: its
    // span covers the route. A `Command` line opens its span at its handler.
    let head = RequestHead::parse(message);
    let mut routed =
        (!head.is_command()).then(|| head.open(stats, RequestArrival::parsed_now(arrived)));
    if let Some(keep_open) = route_line(mux, client, message, writer, &stage) {
        return match routed.as_mut() {
            Some(span) => span.answered(keep_open),
            None => keep_open,
        };
    }
    stage(FrameStage::Route);
    let request = match serde_json::from_str::<Request>(message) {
        Ok(request) => request,
        Err(error) => {
            let mut span =
                routed.unwrap_or_else(|| head.open(stats, RequestArrival::parsed_now(arrived)));
            return span.reply(|| send_bad_request(writer, message, &error));
        }
    };
    watch(WatchedMethod::command(&request.cmd));
    // Only a `cmd` the table names parses as a `Command`
    // (command_names_tests), so no route span is open here.
    drop(routed);
    let arrival = RequestArrival::parsed_now(arrived);
    let mut pending = Some(request);
    match scheduler.dispatch_at(
        mux.clone(),
        client,
        &mut pending,
        arrival,
        message.len(),
        writer.clone(),
    ) {
        Some(keep_open) => keep_open,
        None => match pending.take() {
            Some(request) => {
                if let Some(scope) = &watched {
                    scope.command(&request.cmd);
                }
                handle_request_with_cancellation(mux, client, request, arrival, writer, None)
            }
            None => true,
        },
    }
}

/// The feature routes that answer a line before the `Command` parse.
/// `stage` names each route on the frame's request watch as it is tried.
fn route_line(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
    stage: &dyn Fn(FrameStage),
) -> Option<bool> {
    #[cfg(any(debug_assertions, feature = "oracle"))]
    if let Some(keep_open) = oracle_state_command::try_handle(mux, client, message, writer) {
        return Some(keep_open);
    }
    stage(FrameStage::LoopbackForward);
    if let Some(keep_open) = loopback_forward::try_handle(mux, client, message, writer) {
        return Some(keep_open);
    }
    #[cfg(unix)]
    {
        stage(FrameStage::BrowserRuntime);
        browser_runtime::try_handle(mux, client, message, writer)
            .or_else(|| {
                stage(FrameStage::AgentSession);
                agent_session_attach::try_handle(mux, client, message, writer)
            })
            .or_else(|| {
                stage(FrameStage::AgentTransfer);
                agent_transfer::try_handle(mux, client, message, writer)
            })
            .or_else(|| {
                stage(FrameStage::AgentInventory);
                agent_inventory::try_handle(mux, client, message, writer)
            })
            .or_else(|| {
                stage(FrameStage::AgentCliJob);
                agent_cli_job::try_handle(mux, client, message, writer)
            })
            .or_else(|| {
                stage(FrameStage::AgentCliIntents);
                agent_cli_intents::try_handle(mux, client, message, writer)
            })
            .or_else(|| {
                stage(FrameStage::AgentInventoryWatch);
                agent_inventory::watch::try_handle(mux, client, message, writer)
            })
            .or_else(|| {
                stage(FrameStage::MachineCatalog);
                machine_catalog::try_handle(mux, client, message, writer)
            })
            .or_else(|| {
                stage(FrameStage::Apps);
                apps::try_handle(mux, client, message, writer)
            })
            .or_else(|| {
                stage(FrameStage::Scripts);
                scripts::try_handle(mux, client, message, writer)
            })
            .or_else(|| {
                stage(FrameStage::Fs);
                fs_wire::try_handle(mux, client, message, writer)
            })
    }
    #[cfg(not(unix))]
    None
}

/// A request made in process (tests): it arrives as its handler starts.
#[cfg(test)]
pub(super) fn handle_request(
    mux: &Arc<Mux>,
    client: u64,
    request: Request,
    writer: &MessageWriter,
) -> bool {
    handle_request_with_cancellation(mux, client, request, RequestArrival::now(), writer, None)
}

pub(super) fn handle_request_with_cancellation(
    mux: &Arc<Mux>,
    client: u64,
    request: Request,
    arrival: RequestArrival,
    writer: &MessageWriter,
    cancellation: Option<&ConnectionCancellation>,
) -> bool {
    let Request { id, cmd } = request;
    // A panic in the handler names its command (cmux-panic-log crash keys, this thread's own).
    let _crash_key = cmux_panic_log::crash_keys::scoped_thread(
        cmux_panic_log::crash_keys::Key::ActionId,
        cmux_panic_log::crash_keys::stable_key(cmd.wire_name()),
    );
    let mut span = RequestSpan::open(mux.request_stats(), &cmd, id.as_ref(), arrival);
    if let Command::UrlOpen { terminal_id, url } = cmd {
        return url_open::start(mux, client, id, terminal_id, url, span.start_async(), writer);
    }
    if let Command::ChiefInspect(params) = cmd {
        return chief_inspect::start(mux, client, id, params, span.start_async(), writer);
    }
    if cloud_conversations::is_network(&cmd) {
        return cloud_conversations::start(mux, client, id, cmd, span.start_async(), writer);
    }
    if let Some(target) = cloud_conversations::subscribe_target(mux, &cmd) {
        return cloud_conversations::subscribe_then_announce(
            mux, client, id, cmd, target, &mut span, writer,
        );
    }
    if matches!(&cmd, Command::ShutdownDaemon { .. } | Command::ReloadConfig)
        && !mux.server_lifecycle_ready()
    {
        return span.reply(|| send_request_error(writer, id, "server lifecycle is not ready"));
    }
    if let Command::VtState { surface } = &cmd {
        let reply = vt_state_command_reply(mux, id.as_ref(), *surface, writer);
        return span.reply(|| {
            match reply.and_then(|text| Ok(writer.send_serialized_control(text)?)) {
                Ok(()) => true,
                Err(error) => send_request_error(writer, id, &error.to_string()),
            }
        });
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
    let sent = span.reply(|| {
        responses::send_response_with_details(writer, response, reason, retryable, details)
    });
    // The reply is out; the request's registry commits (already in the WAL)
    // go to disk now, in one flush that none of them waited for.
    mux.request_registry_flush();
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

/// The `vt-state` reply of `surface`, serialized and not yet queued.
fn vt_state_command_reply(
    mux: &Mux,
    id: Option<&Value>,
    surface: SurfaceId,
    writer: &MessageWriter,
) -> anyhow::Result<Arc<BudgetedText>> {
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
        id,
        cols,
        rows,
        &replay.self_contained_bytes(),
        &replay.kitty_image_aliases,
        replay.kitty_state,
    )?;
    Ok(output.finish())
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

#[cfg(test)]
#[path = "event_cause_tests.rs"]
mod event_cause_tests;
