//! Attach and detach command handlers: attach-surface (terminal, render and
//! browser attach with view leases and initial replay), reattach-view,
//! detach-client and detach-attached-view. Each function is one `Command`
//! arm of `handle_command_with_cancellation`.

use super::size_state_for_client;

use super::AttachWireShape;
use super::AttachWorkerCommit;
use super::DetachClientTarget;
use super::DetachNotice;
use super::GUARDED_BROWSER_POINTER_CAPABILITY;
use super::MarkedClientAttach;
use super::MessageWriter;
use super::RenderClientState;
use super::TERMINAL_COLOR_OVERRIDES_CAPABILITY;
use super::TERMINAL_PENDING_SEQUENCE_CAPABILITY;
use super::VtStateMessage;
use super::attach_overflow_json;
use super::attach_response;
use super::browser_state_message;
use super::commit_client_attach_and_start_worker;
use super::detach_actor;
use super::detach_committed_attach;
use super::detach_own_view;
use super::detached_event_json;
use super::get_surface;
use super::handle_attach_send_error;
use super::kick_client;
use super::mark_client_attached;
use super::own_view_detach_target;
use super::render_state_message;
use super::report_attach_overflow;
use super::require_pty;
use super::rollback_failed_attach;
use super::send_browser_attach_update;
use super::spawn_attach_notification_stream;
use super::terminal_colors_json;
use super::terminal_snapshot;
use super::wait_for_initial_browser_resize;
use crate::Mux;
use crate::RenderAttachFrame;
use crate::SurfaceId;
use crate::SurfaceKind;
use crate::browser::BrowserPointerOwner;
use crate::resource::TerminalPublicId;
use crate::sizing_policy::TerminalDetachActor;
use crate::sizing_policy::detach_reason;
use crate::stream_interrupt::StreamInterrupt;
use crate::surface::AttachLifecycle;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(super) fn detach_client(
    mux: &Arc<Mux>,
    client: u64,
    target: DetachClientTarget,
    by: Option<TerminalDetachActor>,
    surface: Option<SurfaceId>,
) -> anyhow::Result<Value> {
    let by = detach_actor(mux, client, by);
    if let Some((owner, placement)) = own_view_detach_target(mux, &target, surface) {
        // The view leaves; the connection, its stream and its relay
        // sub-views stay (docs/shared-terminal-sizing.md).
        detach_own_view(mux, owner, placement, by);
        return Ok(json!({"scope": "view"}));
    }
    if let DetachClientTarget::Participant(participant) = &target
        && let Some((relay, placement, Some(view))) = match surface {
            Some(surface) => mux.terminal_participant_member_on(surface, participant),
            None => mux.terminal_participant_member(participant),
        }
    {
        // A relay sub-view leaves alone; its relay stays attached and
        // forwards the notice to that leaf only.
        mux.detach_terminal_sub_view(placement, relay, &view);
        let notice = DetachNotice { reason: detach_reason::DISCONNECTED_BY, by: Some(by) };
        mux.control_clients.send_surface_event(
            relay,
            placement,
            None,
            &detached_event_json(placement, &notice, Some(&view)),
        );
        return Ok(json!({}));
    }
    let target_client = match &target {
        DetachClientTarget::Client(target) => Some(*target),
        DetachClientTarget::Participant(participant) => target
            .whole_client()
            .or_else(|| mux.terminal_participant_member(participant).map(|member| member.0)),
    };
    let Some(target_client) = target_client else {
        match target {
            DetachClientTarget::Participant(participant) => {
                anyhow::bail!("unknown participant {participant}")
            }
            DetachClientTarget::Client(target) => anyhow::bail!("unknown client {target}"),
        }
    };
    if target_client == client {
        if !mux.control_clients.contains(target_client) {
            anyhow::bail!("unknown client {target_client}");
        }
    } else if !kick_client(mux, target_client, by) {
        anyhow::bail!("unknown client {target_client}");
    }
    Ok(json!({}))
}

pub(super) fn reattach_view(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    counts: Option<bool>,
) -> anyhow::Result<Value> {
    get_surface(mux, surface)?;
    let participant = mux.reattach_terminal_own_view(surface, client, counts)?;
    let state = mux
        .terminal_size_state(surface)
        .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a terminal"))?;
    Ok(json!({
        "participant": participant,
        "state": size_state_for_client(mux, client, &state),
    }))
}

pub(super) fn detach_attached_view(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    lease: Option<String>,
    view: Option<String>,
) -> anyhow::Result<Value> {
    let lease = match (lease, view) {
        (Some(lease), None) => lease,
        (None, Some(view)) => {
            return Ok(match mux.detach_terminal_sub_view(surface, client, &view) {
                Some(_) => json!({"outcome": "applied"}),
                None => json!({"outcome": "superseded"}),
            });
        }
        _ => anyhow::bail!("bad request: detach-attached-view needs exactly one of lease or view"),
    };
    let Some((stream, outbound)) = mux.control_clients.view_stream(client, surface, &lease)? else {
        return Ok(json!({"outcome": "superseded"}));
    };
    // Closing the stream stops every producer immediately. Removing
    // its attachment state synchronously makes the command response a
    // cleanup fence; the attach worker's eventual duplicate detach is
    // intentionally idempotent.
    outbound.close();
    detach_committed_attach(mux, client, surface, stream);
    Ok(json!({"outcome": "applied"}))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn attach_surface(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    surface_id: Option<SurfaceId>,
    mode: Option<String>,
    cols: Option<u16>,
    rows: Option<u16>,
    expected_generation: Option<String>,
    expected_terminal_id: Option<String>,
    snapshot: terminal_snapshot::SnapshotAttachParams,
) -> anyhow::Result<Value> {
    let initial_size = match (cols, rows) {
        (Some(cols), Some(rows)) => Some((cols, rows)),
        (None, None) => None,
        _ => anyhow::bail!("attach-surface cols and rows must be supplied together"),
    };
    let surface_id = match surface_id {
        Some(surface) => surface,
        None => {
            let generation = expected_generation.as_deref().ok_or_else(|| {
                anyhow::anyhow!("attachment identity requires generation and terminal together")
            })?;
            anyhow::ensure!(
                mux.registry_identity().1 == generation,
                "attachment_generation_mismatch"
            );
            let terminal = expected_terminal_id.as_deref().ok_or_else(|| {
                anyhow::anyhow!("attachment identity requires generation and terminal together")
            })?;
            let terminal = TerminalPublicId::parse(terminal)
                .map_err(|_| anyhow::anyhow!("attachment_terminal_mismatch"))?;
            mux.resource_surface_for_terminal(&terminal)
                .ok_or_else(|| anyhow::anyhow!("attachment_terminal_mismatch"))?
        }
    };
    let surface = get_surface(mux, surface_id)?;
    anyhow::ensure!(
        !mux.is_frontend_browser_surface(&surface),
        "surface {surface_id} is a frontend-rendered browser and has no daemon stream"
    );
    match (expected_generation, expected_terminal_id) {
        (Some(generation), Some(terminal)) => {
            anyhow::ensure!(
                mux.registry_identity().1 == generation,
                "attachment_generation_mismatch"
            );
            anyhow::ensure!(
                surface.terminal_public_id().map(|id| id.as_str()) == Some(terminal.as_str()),
                "attachment_terminal_mismatch"
            );
        }
        (None, None) => {}
        _ => anyhow::bail!("attachment identity requires generation and terminal together"),
    }
    if surface.kind() == SurfaceKind::Browser {
        let guarded_owner =
            mux.control_clients.supports_capability(client, GUARDED_BROWSER_POINTER_CAPABILITY)
                && mux.control_clients.browser_pointer_owner(client)?
                    == BrowserPointerOwner::Client(client);
        if !guarded_owner {
            anyhow::bail!(
                "browser attach requires client capability \
                 {GUARDED_BROWSER_POINTER_CAPABILITY} before the first browser pointer \
                 command; upgrade or restart the cmux-tui client"
            );
        }
    }
    if surface.kind() == SurfaceKind::Pty
        && mode.as_deref().unwrap_or("bytes") == "bytes"
        && snapshot.wants_snapshot()?
    {
        return snapshot.attach(mux, client, surface, writer, initial_size);
    }
    let lifecycle = AttachLifecycle::default();
    let outbound_stream = writer.start_stream(&attach_overflow_json(surface_id))?;
    let render_mode = match mode.as_deref().unwrap_or("bytes") {
        "bytes" => false,
        "render" => true,
        other => anyhow::bail!("bad attach mode {other}"),
    };
    if render_mode {
        require_pty(&surface)?;
        let MarkedClientAttach { lease, size_rollback, client_changed, .. } =
            mark_client_attached(mux, client, surface_id, outbound_stream.clone(), initial_size)?;
        let attach = match surface.attach_render_stream() {
            Ok(attach) => attach,
            Err(error) => {
                rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
                return Err(error.into());
            }
        };
        if let Err(error) = writer.send_initial(
            &render_state_message(&writer.render_service, surface_id, &attach.initial),
            &outbound_stream,
        ) {
            handle_attach_send_error(&lifecycle, &error);
            rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
            return Err(error.into());
        }
        let worker_writer = writer.clone();
        let worker_mux = mux.clone();
        let worker_lifecycle = lifecycle.clone();
        let worker_stream = outbound_stream.clone();
        let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
        let spawned =
            std::thread::Builder::new().name("mux-render-attach-out".into()).spawn(move || {
                let writer = worker_writer;
                let mux = worker_mux;
                let lifecycle = worker_lifecycle;
                let outbound_stream = worker_stream;
                if worker_committed.recv().is_err() {
                    return;
                }
                let mut state =
                    RenderClientState::new(writer.render_service.clone(), &attach.initial);
                let interrupt = StreamInterrupt::new();
                writer.register_interrupt(&interrupt);
                outbound_stream.register_interrupt(&interrupt);
                lifecycle.register_interrupt(&interrupt);
                attach.stream.wake_on(&interrupt);
                while writer.is_open() && outbound_stream.is_open() && !lifecycle.is_canceled() {
                    let send_result = match attach.stream.recv_until_interrupted(&interrupt) {
                        Ok(RenderAttachFrame::Frame(frame)) => {
                            let message = state.delta_message(surface_id, &frame);
                            writer.send_stream_backpressured(&message, &outbound_stream)
                        }
                        Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom }) => writer
                            .send_stream_backpressured(
                                &json!({
                                    "event": "scroll-changed",
                                    "surface": surface_id,
                                    "offset": offset,
                                    "at_bottom": at_bottom,
                                }),
                                &outbound_stream,
                            ),
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    };
                    if let Err(error) = send_result {
                        handle_attach_send_error(&lifecycle, &error);
                        break;
                    }
                }
                if writer.is_open() && !lifecycle.overflowed() {
                    let _ = writer.send_stream_backpressured(
                        &json!({"event": "detached", "surface": surface_id}),
                        &outbound_stream,
                    );
                }
                report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
                detach_committed_attach(&mux, client, surface_id, outbound_stream.id);
            });
        if let Err(error) = spawned {
            lifecycle.cancel();
            rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
            return Err(error.into());
        }
        commit_client_attach_and_start_worker(
            mux,
            client,
            surface_id,
            outbound_stream.id,
            AttachWorkerCommit {
                start: worker_start,
                lifecycle,
                changed: client_changed,
                size_rollback,
            },
        )?;
        return Ok(attach_response(mux, surface_id, client, lease));
    }
    if surface.kind() == SurfaceKind::Browser {
        let MarkedClientAttach {
            lease,
            size_rollback,
            client_changed,
            resize_reservation,
            resize_completion,
        } = mark_client_attached(mux, client, surface_id, outbound_stream.clone(), initial_size)?;
        if let Some(reservation) = resize_reservation
            && let Err(error) = wait_for_initial_browser_resize(
                resize_completion.as_ref().expect("sized browser attach has a completion receiver"),
                surface_id,
                reservation,
            )
        {
            lifecycle.cancel();
            rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
            return Err(error);
        }
        let (state, frames) = match surface.attach_frames() {
            Ok(attach) => attach,
            Err(error) => {
                lifecycle.cancel();
                rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
                return Err(error);
            }
        };
        if let Err(error) =
            writer.send_initial(&browser_state_message(surface_id, &state, true), &outbound_stream)
        {
            handle_attach_send_error(&lifecycle, &error);
            rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
            return Err(error.into());
        }
        if let Err(error) = spawn_attach_notification_stream(
            mux.clone(),
            surface_id,
            writer.clone(),
            lifecycle.clone(),
            outbound_stream.clone(),
        ) {
            lifecycle.cancel();
            rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
            return Err(error.into());
        }
        let worker_writer = writer.clone();
        let worker_mux = mux.clone();
        let worker_lifecycle = lifecycle.clone();
        let worker_stream = outbound_stream.clone();
        let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
        let spawned = std::thread::Builder::new().name("mux-attach-out".into()).spawn(move || {
            let writer = worker_writer;
            let mux = worker_mux;
            let lifecycle = worker_lifecycle;
            let outbound_stream = worker_stream;
            if worker_committed.recv().is_err() {
                return;
            }
            let interrupt = StreamInterrupt::new();
            writer.register_interrupt(&interrupt);
            outbound_stream.register_interrupt(&interrupt);
            lifecycle.register_interrupt(&interrupt);
            frames.notify.wake_on(&interrupt);
            while writer.is_open() && outbound_stream.is_open() && !lifecycle.is_canceled() {
                match frames.notify.recv_until_interrupted(&interrupt) {
                    Ok(()) => {}
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                        lifecycle.cancel();
                        if writer.is_open() {
                            let _ = writer.send_stream_backpressured(
                                &json!({"event": "detached", "surface": surface_id}),
                                &outbound_stream,
                            );
                        }
                        break;
                    }
                }
                let update = std::mem::take(&mut *frames.slot.lock().unwrap());
                // A frame event applies its bitmap and authority
                // atomically. Publish it before a paired state
                // snapshot can expose the same positive token.
                if let Err(error) =
                    send_browser_attach_update(&writer, surface_id, update, &outbound_stream)
                {
                    handle_attach_send_error(&lifecycle, &error);
                    break;
                }
            }
            report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
            detach_committed_attach(&mux, client, surface_id, outbound_stream.id);
        });
        if let Err(error) = spawned {
            lifecycle.cancel();
            rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
            return Err(error.into());
        }
        commit_client_attach_and_start_worker(
            mux,
            client,
            surface_id,
            outbound_stream.id,
            AttachWorkerCommit {
                start: worker_start,
                lifecycle,
                changed: client_changed,
                size_rollback,
            },
        )?;
        return Ok(attach_response(mux, surface_id, client, lease));
    }
    let MarkedClientAttach { lease, size_rollback, client_changed, .. } =
        mark_client_attached(mux, client, surface_id, outbound_stream.clone(), initial_size)?;
    lifecycle.set_resumes_pending_sequence(
        mux.control_clients.supports_capability(client, TERMINAL_PENDING_SEQUENCE_CAPABILITY),
    );
    let attach = match surface.attach_stream_with_lifecycle(lifecycle.clone()) {
        Ok(attach) => attach,
        Err(error) => {
            lifecycle.cancel();
            rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
            return Err(error.into());
        }
    };
    let shape = AttachWireShape {
        color_overrides: mux
            .control_clients
            .supports_capability(client, TERMINAL_COLOR_OVERRIDES_CAPABILITY),
        pending_sequence: mux
            .control_clients
            .supports_capability(client, TERMINAL_PENDING_SEQUENCE_CAPABILITY),
    };
    let (replay, pending_sequence) = if shape.pending_sequence || attach.pending_sequence.is_empty()
    {
        (attach.replay.clone(), attach.pending_sequence.clone())
    } else {
        (Arc::from([&*attach.replay, &*attach.pending_sequence].concat()), Arc::from([]))
    };
    let initial = VtStateMessage {
        surface: surface_id,
        cols: attach.cols,
        rows: attach.rows,
        replay,
        kitty_image_aliases: attach.kitty_image_aliases.clone(),
        kitty_state: attach.kitty_state,
        colors: terminal_colors_json(attach.colors, shape.color_overrides),
        pending_sequence,
    };
    if let Err(error) = writer.send_initial_vt_state(&initial, &outbound_stream) {
        handle_attach_send_error(&lifecycle, &error);
        rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
        return Err(error.into());
    }
    if let Err(error) = spawn_attach_notification_stream(
        mux.clone(),
        surface_id,
        writer.clone(),
        lifecycle.clone(),
        outbound_stream.clone(),
    ) {
        lifecycle.cancel();
        rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
        return Err(error.into());
    }
    let worker_writer = writer.clone();
    let worker_mux = mux.clone();
    let worker_stream = outbound_stream.clone();
    let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
    let spawned = std::thread::Builder::new().name("mux-attach-out".into()).spawn(move || {
        let writer = worker_writer;
        let mux = worker_mux;
        let outbound_stream = worker_stream;
        if worker_committed.recv().is_err() {
            return;
        }
        let interrupt = StreamInterrupt::new();
        writer.register_interrupt(&interrupt);
        outbound_stream.register_interrupt(&interrupt);
        attach.lifecycle.register_interrupt(&interrupt);
        attach.stream.wake_on(&interrupt);
        while writer.is_open() && outbound_stream.is_open() && !attach.lifecycle.is_canceled() {
            let frame = match attach.stream.recv_interruptible(&interrupt, None) {
                Ok(frame) => frame,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    attach.lifecycle.cancel();
                    if writer.is_open() {
                        let _ = writer.send_stream_backpressured(
                            &json!({"event": "detached", "surface": surface_id}),
                            &outbound_stream,
                        );
                    }
                    break;
                }
            };
            if let Err(error) =
                writer.send_attach_frame_backpressured(surface_id, &frame, shape, &outbound_stream)
            {
                handle_attach_send_error(&attach.lifecycle, &error);
                break;
            }
        }
        report_attach_overflow(&writer, surface_id, &attach.lifecycle, &outbound_stream);
        detach_committed_attach(&mux, client, surface_id, outbound_stream.id);
    });
    if let Err(error) = spawned {
        lifecycle.cancel();
        rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
        return Err(error.into());
    }
    commit_client_attach_and_start_worker(
        mux,
        client,
        surface_id,
        outbound_stream.id,
        AttachWorkerCommit {
            start: worker_start,
            lifecycle,
            changed: client_changed,
            size_rollback,
        },
    )?;
    Ok(attach_response(mux, surface_id, client, lease))
}
