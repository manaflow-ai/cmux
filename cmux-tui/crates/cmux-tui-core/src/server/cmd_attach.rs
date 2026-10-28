//! Attach and detach command handlers: attach-surface (terminal, render and
//! browser attach with view leases and initial replay), reattach-view,
//! detach-client and detach-attached-view. Each function is one `Command`
//! arm of `handle_command_with_cancellation`.
//!
//! Every view, legacy or on a client-minted attach stream, is a stream of
//! its connection's bounded outbound queue, fed by a drain on the
//! daemon-wide sequenced pool: no view holds a thread (stream_attach_out.rs).
//! Chrome binds each Mojo receiver to a
//! sequence, not a thread (docs/threading_and_tasks.md "Prefer sequences to
//! threads").

use super::AttachWireShape;
use super::DetachClientTarget;
use super::DetachNotice;
use super::GUARDED_BROWSER_POINTER_CAPABILITY;
use super::MarkedClientAttach;
use super::MessageWriter;
use super::OutboundStream;
use super::TERMINAL_COLOR_OVERRIDES_CAPABILITY;
use super::TERMINAL_PENDING_SEQUENCE_CAPABILITY;
use super::VtStateMessage;
use super::attach_lifecycle::AttachCommit;
use super::attach_overflow_json;
use super::attach_response;
use super::attach_streams::ClientStreamId;
use super::attach_streams::StreamEndReason;
use super::browser_state_message;
use super::detach_actor;
use super::detach_committed_attach;
use super::detach_own_view;
use super::detached_event_json;
use super::get_surface;
use super::handle_attach_send_error;
use super::kick_client;
use super::kick_terminal_views;
use super::mark_client_attached;
use super::own_view_detach_target;
use super::render_state_message;
use super::require_pty;
use super::rollback_failed_attach;
use super::size_state_for_client;
use super::terminal_colors_json;
use super::terminal_snapshot;
use super::terminal_views_kick_target;
use super::wait_for_initial_browser_resize;
use crate::Mux;
use crate::SurfaceId;
use crate::SurfaceKind;
use crate::browser::BrowserPointerOwner;
use crate::resource::TerminalPublicId;
use crate::sizing_policy::TerminalDetachActor;
use crate::sizing_policy::detach_reason;
use crate::surface::AttachLifecycle;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

#[path = "stream_attach_out.rs"]
mod stream_attach_out;
use stream_attach_out::StreamView;

/// How long a sized terminal attach waits for its hosted PTY's resize before
/// it builds the replay anyway (then a `resized` replay follows, as before).
const INITIAL_HOSTED_RESIZE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(1);

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
        mux.release_terminal_grid_holds(&[placement]);
        let notice = DetachNotice { reason: detach_reason::DISCONNECTED_BY, by: Some(by) };
        mux.control_clients.send_surface_event(
            relay,
            placement,
            None,
            &detached_event_json(placement, &notice, Some(&view)),
        );
        return Ok(json!({}));
    }
    if let Some((owner, views)) = terminal_views_kick_target(mux, &target, surface)
        && owner != client
    {
        // One terminal's views of an app leave; the app's connection and its
        // other terminals stay.
        kick_terminal_views(mux, owner, &views, by);
        return Ok(json!({"scope": "terminal"}));
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
    writer: &MessageWriter,
    surface: SurfaceId,
    lease: Option<String>,
    view: Option<String>,
) -> anyhow::Result<Value> {
    let lease = match (lease, view) {
        (Some(lease), None) => lease,
        (None, Some(view)) => {
            let detached = mux.detach_terminal_sub_view(surface, client, &view);
            // A relay detaches its leaf: no departed-view hold for this
            // terminal (a relay does not say whether its leaf's link dropped).
            mux.release_terminal_grid_holds(&[surface]);
            return Ok(match detached {
                Some(_) => json!({"outcome": "applied"}),
                None => json!({"outcome": "superseded"}),
            });
        }
        _ => anyhow::bail!("bad request: detach-attached-view needs exactly one of lease or view"),
    };
    let Some((stream, outbound)) = mux.control_clients.view_stream(client, surface, &lease)? else {
        return Ok(json!({"outcome": "superseded"}));
    };
    // Closing the stream stops every producer immediately (a client-minted
    // stream also queues its `stream-end` and frees its id). Removing
    // its attachment state synchronously makes the command response a
    // cleanup fence; the attach worker's eventual duplicate detach is
    // intentionally idempotent.
    match outbound.client_stream {
        Some(_) => writer.end_client_stream(&outbound, StreamEndReason::Canceled),
        None => outbound.close(),
    }
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
    stream: Option<u16>,
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
    // A framed attach on stream S opens S: its queued INPUT and requests go
    // to this surface once the attach succeeds (server/pending_streams.rs).
    if let Some(stream) = writer.frame_call().and_then(|call| call.opens()) {
        anyhow::ensure!(
            stream.target(surface_id),
            "stream_ended: the stream ended before it opened"
        );
    }
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
    let render_mode = match mode.as_deref().unwrap_or("bytes") {
        "bytes" => false,
        "render" => true,
        other => anyhow::bail!("bad attach mode {other}"),
    };
    let snapshot_attach = surface.kind() == SurfaceKind::Pty && !render_mode;
    let snapshot_attach = snapshot_attach && snapshot.wants_snapshot()?;
    let Some(stream) = stream.map(ClientStreamId) else {
        let outbound_stream = writer.start_stream(&attach_overflow_json(surface_id))?;
        if snapshot_attach {
            return snapshot.attach(mux, client, surface, writer, initial_size, outbound_stream);
        }
        return attach_view(
            mux,
            client,
            writer,
            surface,
            render_mode,
            initial_size,
            outbound_stream,
        );
    };
    // attach-streams-v1: the id is this connection's from here until its
    // `stream-end`; a failed attach ends it before its error reply. An id
    // past the connection or daemon cap fails only this open.
    super::attach_streams::require_grant(mux, client)?;
    let outbound_stream =
        writer.start_client_stream(stream, &mux.control_clients.attach_stream_admission)?;
    let attached = if snapshot_attach {
        snapshot.attach(mux, client, surface, writer, initial_size, outbound_stream.clone())
    } else {
        attach_view(
            mux,
            client,
            writer,
            surface,
            render_mode,
            initial_size,
            outbound_stream.clone(),
        )
    };
    if attached.is_err() {
        writer.end_client_stream(&outbound_stream, StreamEndReason::AttachFailed);
    }
    attached
}

/// The render, browser or replay byte attach of `surface` on `outbound_stream`,
/// its output a drain on the sequenced pool.
fn attach_view(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    surface: Arc<crate::Surface>,
    render_mode: bool,
    initial_size: Option<(u16, u16)>,
    outbound_stream: OutboundStream,
) -> anyhow::Result<Value> {
    let surface_id = surface.id;
    let lifecycle = AttachLifecycle::default();
    if render_mode {
        require_pty(&surface)?;
        let MarkedClientAttach { lease, size_rollback, client_changed, .. } =
            mark_client_attached(mux, client, surface_id, outbound_stream.clone(), initial_size)?;
        // A sized attach shows the terminal: its first frame carries the
        // Kitty share's limits (memoryKittyShare; a no-op with it off).
        if initial_size.is_some()
            && let Some(runtime) = surface.terminal_runtime_id()
        {
            mux.settle_kitty_share(
                runtime,
                std::time::Instant::now() + INITIAL_HOSTED_RESIZE_TIMEOUT,
            );
        }
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
        let commit = AttachCommit { lifecycle, changed: client_changed, size_rollback };
        StreamView { mux, client, surface: surface_id, writer, stream: &outbound_stream, commit }
            .start_render(attach)?;
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
            && let Err(error) = match resize_completion.as_ref() {
                Some(completion) => {
                    wait_for_initial_browser_resize(completion, surface_id, reservation)
                }
                None => Err(anyhow::anyhow!("sized browser attach has no completion receiver")),
            }
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
        let commit = AttachCommit { lifecycle, changed: client_changed, size_rollback };
        StreamView { mux, client, surface: surface_id, writer, stream: &outbound_stream, commit }
            .start_browser(frames)?;
        return Ok(attach_response(mux, surface_id, client, lease));
    }
    let MarkedClientAttach { lease, size_rollback, client_changed, .. } =
        mark_client_attached(mux, client, surface_id, outbound_stream.clone(), initial_size)?;
    if initial_size.is_some() {
        // A hosted PTY applies the attach's resize when its host answers. Build
        // the replay after that, so this view gets one replay at the grid it
        // will show, not one at the old grid followed by a `resized` replay
        // (cnx-ios termqa D4). A host that keeps another size times out here
        // and the replay is built at the current grid. The size also shows the
        // terminal, so the Kitty share applies its limits first, for the
        // same reason (memoryKittyShare; a no-op with it off).
        let deadline = std::time::Instant::now() + INITIAL_HOSTED_RESIZE_TIMEOUT;
        surface.settle_hosted_viewer_size(deadline);
        if let Some(runtime) = surface.terminal_runtime_id() {
            mux.settle_kitty_share(runtime, deadline);
        }
    }
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
    // The terminal's key presses: each echo goes out with its stages.
    let key_stages = surface.input_stages();
    let commit = AttachCommit { lifecycle, changed: client_changed, size_rollback };
    StreamView { mux, client, surface: surface_id, writer, stream: &outbound_stream, commit }
        .start_bytes(attach, shape, key_stages)?;
    Ok(attach_response(mux, surface_id, client, lease))
}
