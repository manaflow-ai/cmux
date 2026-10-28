//! Attach lifecycle shared by the control and resource attach paths:
//! marking a client attached (view lease policy, sizing participation,
//! announcements), waiting for the initial browser resize, committing an
//! attach and starting its stream worker, rollback and cleanup of failed
//! attaches, detaching committed attaches, and view geometry replacement.
//!
//! A control attach's worker, legacy or on a client-minted stream, is an
//! [`attach_pump::AttachPump`] on the daemon-wide sequenced pool, which
//! also takes the surface's notifications.
//! Resource attaches still start a worker thread
//! ([`commit_client_attach_and_start_worker`]) until p01-process-204.

use super::MessageWriter;
use super::OutboundStream;
use crate::panic_free::JsonFields;
use crate::server::request_hang_watch::ipc_reply;
use cmux_threads::checked::sync as waits;

use super::INITIAL_BROWSER_RESIZE_TIMEOUT;
use super::SHARED_SIZING_CAPABILITY;
use super::ViewResizePreparation;
use super::size_state_for_client;
use crate::Mux;
use crate::MuxEvent;
use crate::SurfaceId;
use crate::surface::AttachLifecycle;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

#[path = "attach_pump.rs"]
pub(super) mod attach_pump;
use attach_pump::AttachPump;

/// The wire item of a surface notification or scroll change for the view of
/// `surface`; `None` for any other event.
pub(super) fn attach_notification_json(surface: SurfaceId, event: MuxEvent) -> Option<Value> {
    match event {
        MuxEvent::Notification(notification) if notification.surface == Some(surface) => {
            Some(json!({
                "event": "notification",
                "notification": notification.notification,
                "title": notification.title,
                "body": notification.body,
                "level": notification.level.as_str(),
                "surface": notification.surface,
            }))
        }
        MuxEvent::ScrollChanged { surface: changed, offset, at_bottom } if changed == surface => {
            Some(json!({
                "event": "scroll-changed",
                "surface": changed,
                "offset": offset,
                "at_bottom": at_bottom,
            }))
        }
        _ => None,
    }
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
    // The browser host sizes the surface: a cross-process round trip. Its
    // callers run on work items (connection_frame.rs, resource_connection.rs).
    match ipc_reply(|| waits::recv_timeout(completion, INITIAL_BROWSER_RESIZE_TIMEOUT)) {
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
        response.insert("lease", json!(lease));
    }
    if mux.control_clients.supports_capability(client, SHARED_SIZING_CAPABILITY)
        && let Some(participant) = mux.terminal_view_participant_id(surface, client)
        && let Some(state) = mux.terminal_size_state(surface)
    {
        response.insert("participant", json!(participant));
        response.insert("size_state", size_state_for_client(mux, client, &state));
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

/// What committing an attach needs besides its worker.
pub(super) struct AttachCommit {
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
    let AttachWorkerCommit { start, lifecycle, changed, size_rollback } = worker;
    let commit = AttachCommit { lifecycle, changed, size_rollback };
    commit_and_start(mux, client, surface, stream, commit, || start.send(()).is_ok())
}

/// Commits an attach stream's view and starts its drain on the sequenced
/// pool; a failed commit drops the pump unstarted.
pub(super) fn commit_client_attach_and_start_pump(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: u64,
    commit: AttachCommit,
    pump: AttachPump,
) -> anyhow::Result<()> {
    commit_and_start(mux, client, surface, stream, commit, || pump.start().is_ok())
}

fn commit_and_start(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: u64,
    commit: AttachCommit,
    start: impl FnOnce() -> bool,
) -> anyhow::Result<()> {
    let AttachCommit { lifecycle, changed, size_rollback } = commit;
    if let Err(error) = commit_client_attach(mux, client, surface, stream, changed, size_rollback) {
        lifecycle.cancel();
        rollback_failed_attach(mux, client, surface, stream, size_rollback);
        return Err(error);
    }
    if !start() {
        lifecycle.cancel();
        rollback_failed_attach(mux, client, surface, stream, size_rollback);
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

pub(super) fn report_attach_overflow(
    writer: &MessageWriter,
    surface_id: SurfaceId,
    lifecycle: &AttachLifecycle,
    outbound_stream: &OutboundStream,
) {
    if !lifecycle.claim_overflow_report() {
        return;
    }
    // A client-minted stream ends with its own `stream-end{overflow}`.
    let _ = match outbound_stream.client_stream {
        Some(_) => writer.send_overflow_terminal(outbound_stream),
        None => writer.send_terminal(&attach_overflow_json(surface_id), outbound_stream),
    };
}

pub(super) fn handle_attach_send_error(lifecycle: &AttachLifecycle, error: &std::io::Error) {
    if error.kind() == std::io::ErrorKind::WouldBlock {
        lifecycle.mark_overflow();
    } else {
        lifecycle.cancel();
    }
}

pub(super) fn attach_overflow_json(surface: SurfaceId) -> Value {
    json!({
        "event": "overflow",
        "scope": "surface",
        "surface": surface,
        "error": "surface stream fell behind; reattach the surface",
    })
}
