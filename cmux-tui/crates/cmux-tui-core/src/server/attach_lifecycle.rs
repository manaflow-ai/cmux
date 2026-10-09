//! Attach lifecycle shared by the control and resource attach paths:
//! marking a client attached (view lease policy, sizing participation,
//! announcements), waiting for the initial browser resize, committing an
//! attach and starting its stream worker, rollback and cleanup of failed
//! attaches, detaching committed attaches, and view geometry replacement.

use super::MessageWriter;
use super::OutboundStream;

use super::INITIAL_BROWSER_RESIZE_TIMEOUT;
use super::SHARED_SIZING_CAPABILITY;
use super::ViewResizePreparation;
use super::handle_attach_send_error;
use super::report_attach_overflow;
use super::size_state_for_client;
use crate::Mux;
use crate::MuxEvent;
use crate::SurfaceId;
use crate::stream_interrupt::StreamInterrupt;
use crate::surface::AttachLifecycle;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(super) fn spawn_attach_notification_stream(
    mux: Arc<Mux>,
    surface_id: SurfaceId,
    writer: MessageWriter,
    lifecycle: AttachLifecycle,
    outbound_stream: OutboundStream,
) -> std::io::Result<()> {
    let events = mux.subscribe_attached_surface(surface_id);
    std::thread::Builder::new()
        .name("mux-attach-notifications".into())
        .spawn(move || {
            let interrupt = StreamInterrupt::new();
            writer.register_interrupt(&interrupt);
            outbound_stream.register_interrupt(&interrupt);
            lifecycle.register_interrupt(&interrupt);
            events.wake_on(&interrupt);
            while writer.is_open() && outbound_stream.is_open() && !lifecycle.is_canceled() {
                let event = match events.recv_until_interrupted(&interrupt) {
                    Ok(event) => event,
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                };
                let value = match event {
                    MuxEvent::Notification(notification)
                        if notification.surface == Some(surface_id) =>
                    {
                        json!({
                            "event": "notification",
                            "notification": notification.notification,
                            "title": notification.title,
                            "body": notification.body,
                            "level": notification.level.as_str(),
                            "surface": notification.surface,
                        })
                    }
                    MuxEvent::ScrollChanged { surface, offset, at_bottom }
                        if surface == surface_id =>
                    {
                        json!({
                            "event": "scroll-changed",
                            "surface": surface,
                            "offset": offset,
                            "at_bottom": at_bottom,
                        })
                    }
                    _ => continue,
                };
                if let Err(error) = writer.send_stream_backpressured(&value, &outbound_stream) {
                    handle_attach_send_error(&lifecycle, &error);
                    break;
                }
            }
            if events.overflowed() {
                lifecycle.mark_overflow();
            }
            report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
        })
        .map(|_| ())
}

pub(super) struct MarkedClientAttach {
    pub(super) lease: Option<String>,
    pub(super) size_rollback: Option<crate::mux::ClientSizeRollback>,
    pub(super) client_changed: Option<(Option<String>, Option<String>)>,
    pub(super) resize_reservation: Option<u64>,
    pub(super) resize_completion: Option<std::sync::mpsc::Receiver<Result<(), Arc<str>>>>,
}

pub(super) fn mark_client_attached(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: OutboundStream,
    initial_size: Option<(u16, u16)>,
) -> anyhow::Result<MarkedClientAttach> {
    mark_client_attached_with_lease_policy(mux, client, surface, stream, initial_size, false)
}

pub(super) fn mark_resource_client_attached(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: OutboundStream,
    initial_size: Option<(u16, u16)>,
) -> anyhow::Result<MarkedClientAttach> {
    mark_client_attached_with_lease_policy(mux, client, surface, stream, initial_size, true)
}

fn mark_client_attached_with_lease_policy(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: OutboundStream,
    initial_size: Option<(u16, u16)>,
    require_lease: bool,
) -> anyhow::Result<MarkedClientAttach> {
    let lease = if require_lease {
        Some(mux.control_clients.attach_surface_with_required_lease(
            client,
            surface,
            stream.clone(),
        )?)
    } else {
        mux.control_clients.attach_surface(client, surface, stream.clone())?
    };
    if let Some((cols, rows)) = initial_size {
        let cols = cols.max(1);
        let rows = rows.max(1);
        let is_browser = mux.surface(surface).is_some_and(|surface| surface.as_browser().is_some());
        let (completion_tx, completion_rx) = std::sync::mpsc::sync_channel(1);
        let mut previous_view_size = None;
        let resize = if let Some(lease) = lease.as_deref() {
            let _lifecycle = mux.lock_client_sizing_lifecycle();
            match mux.control_clients.prepare_view_resize(client, surface, lease, (cols, rows))? {
                ViewResizePreparation::GeometryOwner { update, previous_view_size: previous } => {
                    previous_view_size = Some(previous);
                    mux.resize_surface_for_prepared_control_client_with_completion(
                        surface,
                        client,
                        (cols, rows),
                        is_browser.then_some(completion_tx),
                        Some(update),
                    )
                }
                ViewResizePreparation::Passive { changed, name, kind } => {
                    return Ok(MarkedClientAttach {
                        lease: Some(lease.to_string()),
                        size_rollback: None,
                        client_changed: changed.then_some((name, kind)),
                        resize_reservation: None,
                        resize_completion: None,
                    });
                }
                ViewResizePreparation::Superseded => {
                    anyhow::bail!("view attachment was superseded before initial sizing");
                }
            }
        } else {
            mux.resize_surface_for_control_client_with_completion(
                surface,
                client,
                cols,
                rows,
                is_browser.then_some(completion_tx),
            )
        }
        .inspect_err(|_| {
            if let (Some(lease), Some(previous)) = (lease.as_deref(), previous_view_size) {
                mux.control_clients.restore_view_size(client, surface, lease, previous);
            }
            cleanup_failed_attach(mux, client, surface, stream.id);
        })?;
        let Some((changed, name, kind, _)) = resize.attached else {
            cleanup_failed_attach(mux, client, surface, stream.id);
            anyhow::bail!("client {client} is not attached to surface {surface}");
        };
        let mut resize_reservation = resize.reservation_id;
        let mut resize_completion = is_browser.then_some(completion_rx);
        let effective_size = resize.effective_size;
        let rollback = resize.rollback;
        if resize_reservation.is_none()
            && let Some((effective_cols, effective_rows)) = effective_size
        {
            let Some(attached_surface) = mux.surface(surface) else {
                rollback_failed_attach(mux, client, surface, stream.id, Some(rollback));
                anyhow::bail!("surface {surface} disappeared while sizing before attach");
            };
            match attached_surface.pending_resize_completion(effective_cols, effective_rows) {
                Ok(Some(pending)) => {
                    resize_reservation = Some(pending.reservation);
                    resize_completion = Some(pending.completion);
                }
                Ok(None) => {}
                Err(error) => {
                    rollback_failed_attach(mux, client, surface, stream.id, Some(rollback));
                    return Err(error);
                }
            }
        }
        return Ok(MarkedClientAttach {
            lease,
            size_rollback: Some(rollback),
            client_changed: changed.then_some((name, kind)),
            resize_reservation,
            resize_completion,
        });
    }
    Ok(MarkedClientAttach {
        lease,
        size_rollback: None,
        client_changed: None,
        resize_reservation: None,
        resize_completion: None,
    })
}

pub(super) fn wait_for_initial_browser_resize(
    completion: &std::sync::mpsc::Receiver<Result<(), Arc<str>>>,
    surface: SurfaceId,
    reservation: u64,
) -> anyhow::Result<()> {
    match completion.recv_timeout(INITIAL_BROWSER_RESIZE_TIMEOUT) {
        Ok(Ok(())) => Ok(()),
        Ok(Err(error)) => {
            anyhow::bail!(
                "failed to size browser surface {surface} before attach (reservation {reservation}): {error}"
            )
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            anyhow::bail!("timed out sizing browser surface {surface} before attach");
        }
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            anyhow::bail!(
                "browser resize completion disconnected before attach (surface {surface}, reservation {reservation})"
            )
        }
    }
}

fn announce_client_attached(mux: &Mux, client: u64) -> anyhow::Result<bool> {
    if let Some((transport, name, kind)) = mux.control_clients.announce_attached(client)? {
        mux.emit(MuxEvent::ClientAttached { client, transport, name, kind });
        return Ok(true);
    }
    Ok(false)
}

/// `attach-surface` result: the view lease when negotiated and, for a
/// `shared-sizing-v1` client on a terminal, this view's host participant id
/// and the current size state.
pub(super) fn attach_response(
    mux: &Mux,
    surface: SurfaceId,
    client: u64,
    lease: Option<String>,
) -> Value {
    let mut response = json!({});
    if let Some(lease) = lease {
        response["lease"] = json!(lease);
    }
    if mux.control_clients.supports_capability(client, SHARED_SIZING_CAPABILITY)
        && let Some(participant) = mux.terminal_view_participant_id(surface, client)
        && let Some(state) = mux.terminal_size_state(surface)
    {
        response["participant"] = json!(participant);
        response["size_state"] = size_state_for_client(mux, client, &state);
    }
    response
}

pub(super) fn commit_client_attach(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: u64,
    changed: Option<(Option<String>, Option<String>)>,
    rollback: Option<crate::mux::ClientSizeRollback>,
) -> anyhow::Result<()> {
    mux.control_clients.commit_surface(client, surface, stream, rollback)?;
    // Attaching is activity: the view joins the terminal's sizing engine and,
    // once it has a viewport, takes the grid under the default policy. The
    // attaching client reads the resulting state from the attach response.
    mux.sync_terminal_client_view(surface, client);
    let newly_announced = announce_client_attached(mux, client)?;
    if !newly_announced && let Some((name, kind)) = changed {
        mux.emit(MuxEvent::ClientChanged { client, name, kind });
    }
    Ok(())
}

pub(super) struct AttachWorkerCommit {
    pub(super) start: std::sync::mpsc::SyncSender<()>,
    pub(super) lifecycle: AttachLifecycle,
    pub(super) changed: Option<(Option<String>, Option<String>)>,
    pub(super) size_rollback: Option<crate::mux::ClientSizeRollback>,
}

pub(super) fn commit_client_attach_and_start_worker(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: u64,
    worker: AttachWorkerCommit,
) -> anyhow::Result<()> {
    if let Err(error) =
        commit_client_attach(mux, client, surface, stream, worker.changed, worker.size_rollback)
    {
        worker.lifecycle.cancel();
        rollback_failed_attach(mux, client, surface, stream, worker.size_rollback);
        return Err(error);
    }
    if worker.start.send(()).is_err() {
        worker.lifecycle.cancel();
        rollback_failed_attach(mux, client, surface, stream, worker.size_rollback);
        anyhow::bail!("attach output worker exited before stream {stream} was committed");
    }
    Ok(())
}

pub(super) fn cleanup_failed_attach(mux: &Mux, client: u64, surface: SurfaceId, stream: u64) {
    let _lifecycle = mux.lock_client_sizing_lifecycle();
    let detached = mux.control_clients.detach_surface(client, surface, stream);
    if detached.final_stream {
        mux.remove_surface_size_client(surface, client);
    } else if let Some(replacement) = detached.geometry_replacement {
        apply_view_geometry_replacement(mux, client, surface, replacement);
    }
}

pub(super) fn rollback_failed_attach(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: u64,
    size_rollback: Option<crate::mux::ClientSizeRollback>,
) {
    let detached = {
        let _lifecycle = mux.lock_client_sizing_lifecycle();
        mux.control_clients.detach_surface(client, surface, stream)
    };
    if detached.final_stream {
        // A failed first attach is one transaction: restore the geometry that
        // preceded its provisional size report before removing the report.
        // Final-stream detach has no surviving view to promote, so the
        // generic geometry-replacement marker must not suppress this rollback.
        if let Some(size_rollback) = detached.rollback.or(size_rollback) {
            mux.rollback_surface_size_client(surface, client, size_rollback);
        }
        mux.remove_surface_size_client(surface, client);
    } else if let Some(replacement) = detached.geometry_replacement {
        apply_view_geometry_replacement(mux, client, surface, replacement);
    } else if let Some(size_rollback) = detached.rollback.or(size_rollback) {
        mux.rollback_surface_size_client(surface, client, size_rollback);
    }
}

pub(super) fn detach_committed_attach(mux: &Mux, client: u64, surface: SurfaceId, stream: u64) {
    let lifecycle = mux.lock_client_sizing_lifecycle();
    let detached = mux.control_clients.detach_surface(client, surface, stream);
    if detached.final_stream {
        mux.remove_surface_size_client(surface, client);
    } else if let Some(replacement) = detached.geometry_replacement {
        apply_view_geometry_replacement(mux, client, surface, replacement);
    } else if let Some(rollback) = detached.rollback {
        // Rollback performs its own report-order-checked lifecycle transaction.
        // Release this transaction first so legacy multi-stream clients cannot
        // recursively acquire the non-reentrant lifecycle mutex.
        drop(lifecycle);
        mux.rollback_surface_size_client(surface, client, rollback);
    }
}

fn apply_view_geometry_replacement(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    replacement: Option<(u16, u16)>,
) {
    if let Some((cols, rows)) = replacement {
        let _ = mux.resize_surface_for_client_with_reservation(surface, client, cols, rows);
    } else {
        mux.remove_surface_size_client(surface, client);
    }
}
