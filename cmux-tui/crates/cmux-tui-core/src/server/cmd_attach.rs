//! Attach and detach command handlers: attach-surface (terminal, render and
//! browser attach with view leases and initial replay), reattach-view,
//! detach-client and detach-attached-view. Each function is one `Command`
//! arm of `handle_command_with_cancellation`.

use super::size_state_for_client;
use crate::panic_free::{JsonFields, RecoverPoison};

use super::ATTACH_OUTPUT_COALESCE_CAPABILITY;
use super::ATTACH_REPLAY_HISTORY_WINDOW_CAPABILITY;
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
use super::TERMINAL_RESUME_CAPABILITY;
use super::VtStateMessage;
use super::agent_cli_hybrid;
use super::agent_cli_hybrid::{HybridOut, HybridViewer};
use super::attach_output_coalesce;
use super::attach_output_coalesce::OutputCoalescer;
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
use super::spawn_attach_notification_stream_coalesced;
use super::terminal_colors_json;
use super::terminal_snapshot;
use super::wait_for_initial_browser_resize;
use super::{
    AGENT_CLI_HYBRID_CAPABILITY, AGENT_CLI_HYBRID_LEAN_CAPABILITY,
    TERMINAL_FULL_SCREEN_FRAMES_CAPABILITY, TERMINAL_SHELL_LINES_CAPABILITY,
};
use crate::Mux;
use crate::RenderAttachFrame;
use crate::SurfaceId;
use crate::SurfaceKind;
use crate::browser::BrowserPointerOwner;
use crate::resource::TerminalPublicId;
use crate::sizing_policy::TerminalDetachActor;
use crate::sizing_policy::detach_reason;
use crate::stream_interrupt::StreamInterrupt;
use crate::surface::AttachFrame;
use crate::surface::AttachLifecycle;
use base64::Engine as _;
use cmux_agent_cli_render::adapter::Adapter;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

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
    replay_history_rows: Option<u32>,
    output_coalesce_ms: Option<u32>,
    replay_history_start: Option<u64>,
    (hybrid_stream, hybrid_frame): (Option<String>, Option<u64>),
    (resume_offset, resume_generation): (Option<u64>, Option<String>),
    snapshot: terminal_snapshot::SnapshotAttachParams,
) -> anyhow::Result<Value> {
    let hybrid_declared =
        mux.control_clients.supports_capability(client, AGENT_CLI_HYBRID_CAPABILITY);
    let hybrid_lean =
        mux.control_clients.supports_capability(client, AGENT_CLI_HYBRID_LEAN_CAPABILITY);
    let shell_lines = hybrid_declared
        && hybrid_lean
        && mux.control_clients.supports_capability(client, TERMINAL_SHELL_LINES_CAPABILITY);
    // `terminal-full-screen-frames-v1`: a full-screen program as frames too (agent_cli_hybrid.rs).
    let full_screen_frames = shell_lines
        && mux.control_clients.supports_capability(client, TERMINAL_FULL_SCREEN_FRAMES_CAPABILITY);
    let hybrid_resume =
        agent_cli_hybrid::resume_request(hybrid_declared, hybrid_stream, hybrid_frame)?;
    anyhow::ensure!(
        replay_history_start.is_none() || replay_history_rows.is_some(),
        "attach-surface replay_history_start needs replay_history_rows"
    );
    let history_window =
        replay_history_rows.map(|rows| crate::surface::history_window::HistoryWindow {
            start: replay_history_start,
            rows: u64::from(rows),
        });
    anyhow::ensure!(
        resume_offset.is_some() == resume_generation.is_some(),
        "attach-surface resume_offset and resume_generation must be supplied together"
    );
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
            mux.wake_lazy_terminal(&terminal);
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
    // `agent-cli-hybrid-v1`: a plain byte attach of an agent CLI's terminal gets cell
    // deltas instead of its bytes, and with `terminal-shell-lines-v1` so does every other
    // terminal, PTY bytes only while it is full-screen (server/agent_cli_hybrid.rs).
    let adapter = if hybrid_declared
        && surface.kind() == SurfaceKind::Pty
        && mode.as_deref().unwrap_or("bytes") == "bytes"
    {
        agent_cli_hybrid::adapter(mux, &surface)
    } else {
        Adapter::Pty
    };
    // A viewer that asked for full-screen frames gets any terminal as an agent CLI's: frames
    // throughout, the alternate screen and input modes as bytes, never the PTY bytes.
    let shell_viewer = shell_lines && adapter == Adapter::Lines && !full_screen_frames;
    let hybrid = adapter == Adapter::Agent
        || shell_viewer
        || (full_screen_frames && adapter == Adapter::Lines);
    // Only the plain byte attach coalesces; render mode keeps its own frames.
    let coalesce_interval = if !hybrid
        && surface.kind() == SurfaceKind::Pty
        && mode.as_deref().unwrap_or("bytes") == "bytes"
    {
        attach_output_coalesce::attach_interval(
            mux.control_clients.supports_capability(client, ATTACH_OUTPUT_COALESCE_CAPABILITY),
            output_coalesce_ms,
        )?
    } else {
        None
    };
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
                let update = std::mem::take(&mut *frames.slot.lock().recover_poison());
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
            // Release this viewer's frame claim before the detach can resize
            // the page, so a natively hosted page is not restarted for nobody.
            drop(frames);
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
    if initial_size.is_some() {
        // A hosted PTY applies the attach's resize when its host answers. Build
        // the replay after that, so this view gets one replay at the grid it
        // will show, not one at the old grid followed by a `resized` replay
        // (cnx-ios termqa D4). A host that keeps another size times out here
        // and the replay is built at the current grid.
        surface
            .settle_hosted_viewer_size(std::time::Instant::now() + INITIAL_HOSTED_RESIZE_TIMEOUT);
    }
    lifecycle.set_resumes_pending_sequence(
        mux.control_clients.supports_capability(client, TERMINAL_PENDING_SEQUENCE_CAPABILITY),
    );
    // `terminal-resume-v1`: the plain byte stream carries its position; a
    // viewer that holds one gets only the bytes it missed when the daemon
    // still has them.
    let resume_wire = !hybrid
        && surface.kind() == SurfaceKind::Pty
        && (resume_offset.is_some()
            || mux.control_clients.supports_capability(client, TERMINAL_RESUME_CAPABILITY));
    let resumed = match (resume_wire, &resume_generation, resume_offset) {
        (true, Some(generation), Some(offset)) => {
            surface.attach_resume_stream(lifecycle.clone(), generation, offset, initial_size)
        }
        _ => None,
    };
    let resume_asked = resume_wire && resume_offset.is_some();
    let (attach, resume_missing) = match resumed {
        Some(resumed) => (resumed.attach, Some(resumed.missing)),
        None => {
            let attach = match surface.attach_stream_with_window(
                lifecycle.clone(),
                history_window,
                mux.control_clients
                    .supports_capability(client, ATTACH_REPLAY_HISTORY_WINDOW_CAPABILITY),
            ) {
                Ok(attach) => attach,
                Err(error) => {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
            };
            (attach, None)
        }
    };
    let shape = AttachWireShape {
        color_overrides: mux
            .control_clients
            .supports_capability(client, TERMINAL_COLOR_OVERRIDES_CAPABILITY),
        pending_sequence: mux
            .control_clients
            .supports_capability(client, TERMINAL_PENDING_SEQUENCE_CAPABILITY),
        stamp: None,
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
        history_rows_omitted: attach.history_rows_omitted,
        history_rows_skipped: attach.history_rows_skipped,
        stamp: resume_wire.then_some(attach.stamp),
        resume: resume_asked.then_some("gap"),
    };
    let attach_stamp = attach.stamp;
    let mut hybrid_viewer = None;
    let sent = if hybrid {
        let started = HybridViewer::start(
            surface_id,
            attach.cols,
            attach.rows,
            &[&*attach.replay, &*attach.pending_sequence].concat(),
            hybrid_resume,
            agent_cli_hybrid::Wants {
                lean: hybrid_lean,
                shell: shell_viewer,
                lines: shell_lines,
                display_frames: full_screen_frames && adapter == Adapter::Lines,
            },
        );
        let (mut viewer, first) = match started {
            Ok(started) => started,
            Err(error) => {
                lifecycle.cancel();
                rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
                return Err(error);
            }
        };
        let sent = match first {
            Some(first) => {
                // What `vt-state` would carry beside the screen: the terminal's colors.
                let mut colors = initial.colors;
                if let Some(fields) = colors.as_object_mut() {
                    fields.insert("event".into(), json!("colors-changed"));
                    fields.insert("surface".into(), json!(surface_id));
                }
                let output = |bytes: Vec<u8>| {
                    json!({
                        "event": "output",
                        "surface": surface_id,
                        "data": base64::engine::general_purpose::STANDARD.encode(bytes),
                    })
                };
                // An agent CLI on the alternate screen (Codex, opencode): the viewer's terminal
                // switches to it before the keyframe draws there.
                let screen = viewer.screen_before_first_frame().map(output);
                // The input modes the screen has set (bracketed paste, cursor keys): a lines
                // viewer's and an agent CLI viewer's keys and pastes follow them, and frames
                // do not carry them.
                let modes = viewer.input_modes().map(output);
                writer
                    .send_initial(&colors, &outbound_stream)
                    .and_then(|()| match &screen {
                        Some(screen) => writer.send_initial(screen, &outbound_stream),
                        None => Ok(()),
                    })
                    .and_then(|()| writer.send_initial(&first, &outbound_stream))
                    .and_then(|()| match &modes {
                        Some(modes) => writer.send_initial(modes, &outbound_stream),
                        None => Ok(()),
                    })
            }
            // A shell running a full-screen program: its bytes, as a byte viewer gets them.
            None => writer.send_initial_vt_state(&initial, &outbound_stream),
        };
        hybrid_viewer = Some(viewer);
        sent
    } else if let Some(missing) = &resume_missing {
        // An exact resume: the bytes after the viewer's offset, no replay.
        writer.send_initial(
            &json!({
                "event": "output",
                "surface": surface_id,
                "data": base64::engine::general_purpose::STANDARD.encode(missing),
                "offset": attach.stamp.offset,
                "generation": attach.stamp.generation(),
                "resume": "exact",
            }),
            &outbound_stream,
        )
    } else {
        writer.send_initial_vt_state(&initial, &outbound_stream)
    };
    if let Err(error) = sent {
        handle_attach_send_error(&lifecycle, &error);
        rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
        return Err(error.into());
    }
    if let Err(error) = spawn_attach_notification_stream_coalesced(
        mux.clone(),
        surface_id,
        writer.clone(),
        lifecycle.clone(),
        outbound_stream.clone(),
        coalesce_interval,
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
        // `attach-output-coalesce-v1`: `output` at most once per interval;
        // `None` sends each frame as it comes, as before.
        let mut coalescer = coalesce_interval.map(OutputCoalescer::new);
        let mut hybrid = hybrid_viewer;
        let mut hybrid_out: Vec<HybridOut> = Vec::new();
        let mut ready: Vec<AttachFrame> = Vec::new();
        // `terminal-resume-v1`: the position each frame leaves the stream at.
        let mut position = resume_wire.then_some(attach.stamp);
        'stream: while writer.is_open()
            && outbound_stream.is_open()
            && !attach.lifecycle.is_canceled()
        {
            let deadline = match hybrid.as_ref() {
                Some(viewer) => viewer.due(),
                None => coalescer.as_ref().and_then(OutputCoalescer::due),
            };
            let received = attach.stream.recv_interruptible(&interrupt, deadline);
            let now = std::time::Instant::now();
            let ended = match received {
                Ok(frame) => {
                    match (hybrid.as_mut(), coalescer.as_mut()) {
                        (Some(viewer), _) => {
                            // A frame the shadow terminal cannot build waits for the next
                            // write: the next frame's delta covers it.
                            let _ = viewer.take(frame, now, &mut hybrid_out);
                        }
                        (None, Some(coalescer)) => coalescer.push(frame, now, &mut ready),
                        (None, None) => {
                            // The writer is free now: the reads that queued while it was
                            // busy go out as one event, at once (no timer).
                            attach_output_coalesce::push_merged(frame, &mut ready);
                            while let Ok(next) = attach.stream.try_recv() {
                                attach_output_coalesce::push_merged(next, &mut ready);
                            }
                        }
                    }
                    false
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    if let Some(coalescer) = coalescer.as_mut() {
                        coalescer.flush_due(now, &mut ready);
                    }
                    false
                }
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    // The terminal's last bytes reach the viewer before its end.
                    if let Some(coalescer) = coalescer.as_mut() {
                        coalescer.flush(now, &mut ready);
                    }
                    if let Some(viewer) = hybrid.as_mut()
                        && let Ok(Some(event)) = viewer.frame_now(now)
                    {
                        hybrid_out.push(HybridOut::Event(event));
                    }
                    true
                }
            };
            if let Some(viewer) = hybrid.as_mut()
                && let Ok(Some(event)) = viewer.frame_due(now)
            {
                hybrid_out.push(HybridOut::Event(event));
            }
            for out in hybrid_out.drain(..) {
                let sent = match out {
                    HybridOut::Event(event) => {
                        writer.send_stream_backpressured(&event, &outbound_stream)
                    }
                    HybridOut::Attach(frame) => writer.send_attach_frame_backpressured(
                        surface_id,
                        &frame,
                        shape,
                        &outbound_stream,
                    ),
                };
                if let Err(error) = sent {
                    handle_attach_send_error(&attach.lifecycle, &error);
                    break 'stream;
                }
            }
            for frame in ready.drain(..) {
                let mut shape = shape;
                if let Some(position) = position.as_mut() {
                    match &frame {
                        AttachFrame::Output(output) => position.offset += output.len() as u64,
                        AttachFrame::OutputWithColors { output, .. } => {
                            position.offset += output.len() as u64;
                            position.epoch += 1;
                        }
                        _ => position.epoch += 1,
                    }
                    shape.stamp = Some(*position);
                }
                if let Err(error) = writer.send_attach_frame_backpressured(
                    surface_id,
                    &frame,
                    shape,
                    &outbound_stream,
                ) {
                    handle_attach_send_error(&attach.lifecycle, &error);
                    break 'stream;
                }
            }
            if ended {
                attach.lifecycle.cancel();
                if writer.is_open() {
                    let _ = writer.send_stream_backpressured(
                        &json!({"event": "detached", "surface": surface_id}),
                        &outbound_stream,
                    );
                }
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
    let mut response = attach_response(mux, surface_id, client, lease);
    if resume_asked {
        response.insert("resume", json!(if resume_missing.is_some() { "exact" } else { "gap" }));
        response.insert("through", json!(attach_stamp.offset));
        response.insert("generation", json!(attach_stamp.generation()));
    }
    Ok(response)
}
