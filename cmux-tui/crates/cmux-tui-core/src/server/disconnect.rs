//! Client disconnect and detach: detached and size-state events, the
//! detach actor and own-view targets, disconnecting or kicking a client with
//! a notice, completing a daemon shutdown after its acknowledgement flushes,
//! and detaching a size participant or a whole control client.

use super::CLIENT_DETACH_WRITE_TIMEOUT;
use super::DAEMON_SHUTDOWN_EVENT;
use super::DetachClientTarget;
use super::DetachNotice;
use super::MessageWriter;
use super::OPEN_DEVICE_KINDS_CAPABILITY;
use super::SHUTDOWN_ACK_FLUSH_TIMEOUT;
use super::SIZING_VIEW_DETACH_CAPABILITY;
use crate::Mux;
use crate::MuxEvent;
use crate::SurfaceId;
use crate::SurfaceKind;
use crate::browser::BrowserPointerOwner;
use crate::sizing_policy::TerminalDetachActor;
use crate::sizing_policy::TerminalSizingState;
use crate::sizing_policy::detach_reason;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(super) fn detached_event_json(
    surface: SurfaceId,
    notice: &DetachNotice,
    view: Option<&str>,
) -> Value {
    let mut event = json!({"event": "detached", "surface": surface, "reason": notice.reason});
    if let Some(by) = notice.by.as_ref().filter(|by| !by.is_empty()) {
        event["by"] = json!(by);
    }
    if let Some(view) = view {
        event["view"] = json!(view);
    }
    event
}

/// The connection's own view that a `detach-client` target names, when that
/// connection opted into [`SIZING_VIEW_DETACH_CAPABILITY`]: the view leaves
/// and the connection stays. `None` keeps the whole-client kick.
pub(super) fn own_view_detach_target(
    mux: &Mux,
    target: &DetachClientTarget,
    surface: Option<SurfaceId>,
) -> Option<(u64, SurfaceId)> {
    let DetachClientTarget::Participant(participant) = target else { return None };
    let (client, placement, view) = match surface {
        Some(surface) => mux.terminal_participant_member_on(surface, participant)?,
        None => mux.terminal_participant_member(participant)?,
    };
    (view.is_none()
        && mux.control_clients.supports_capability(client, SIZING_VIEW_DETACH_CAPABILITY))
    .then_some((client, placement))
}

/// `state` as `client` may read it (`open-device-kinds-v1`).
pub(super) fn size_state_for_client(mux: &Mux, client: u64, state: &TerminalSizingState) -> Value {
    let open = mux.control_clients.supports_capability(client, OPEN_DEVICE_KINDS_CAPABILITY);
    json!(state.for_client(open))
}

/// A `size-state` event. Without a client it has only the kinds every
/// `shared-sizing-v1` client decodes.
pub(super) fn size_state_event_json(
    surface: SurfaceId,
    runtime: SurfaceId,
    state: &TerminalSizingState,
    client: Option<(u64, bool)>,
) -> Value {
    let open = client.is_some_and(|(_, open)| open);
    let mut event =
        json!({"event": "size-state", "surface": surface, "state": state.for_client(open)});
    if let Some((client, _)) = client {
        let id = crate::mux::view_participant_id(runtime, surface, client);
        if state.participant(&id).is_some() {
            event["self_participant"] = json!(id);
        }
    }
    event
}

/// The actor recorded on a kick: the explicit `by`, else the requester's own identity.
pub(super) fn detach_actor(
    mux: &Mux,
    requester: u64,
    by: Option<TerminalDetachActor>,
) -> TerminalDetachActor {
    by.unwrap_or_else(|| {
        let identity = mux.control_clients.sizing_identity(requester).unwrap_or_default();
        TerminalDetachActor {
            user_id: identity.user_id,
            display_name: identity.display_name,
            device_name: identity.device_name,
        }
    })
}

pub(super) fn disconnect_client(mux: &Arc<Mux>, client: u64, send_detached: bool) -> bool {
    disconnect_client_with_notice(mux, client, send_detached, None, &DetachNotice::network())
}

/// Disconnect a client because another participant (or the client itself)
/// asked. Its `detached` events carry `reason:"disconnected-by"` and `by`, so
/// the viewer does not reconnect automatically.
pub(super) fn kick_client(mux: &Arc<Mux>, client: u64, by: TerminalDetachActor) -> bool {
    disconnect_client_with_notice(
        mux,
        client,
        true,
        None,
        &DetachNotice { reason: detach_reason::DISCONNECTED_BY, by: Some(by) },
    )
}

fn disconnect_client_with_notice(
    mux: &Arc<Mux>,
    client: u64,
    send_detached: bool,
    notice: Option<&str>,
    detach: &DetachNotice,
) -> bool {
    let record = {
        let _lifecycle = mux.lock_client_sizing_lifecycle();
        let Some(record) = mux.control_clients.remove(client) else { return false };
        mux.remove_size_client_from_attached_surfaces(client, record.attached.keys().copied());
        record
    };
    mux.unbind_conversation_principal(client);
    mux.release_cloud_conversation_client(client);
    // Provider capabilities are valid only for the control connection that
    // published them. Release before announcing detachment so waiters can
    // never observe a stale target after the owning client is gone.
    mux.unregister_browser_provider(client);
    #[cfg(unix)]
    mux.image_pastes.disconnect(client);
    if let Some(owner @ BrowserPointerOwner::Client(_)) = record.browser_pointer_owner {
        // Pointer commands do not require a frame-stream attachment, so any
        // browser worker may own this negotiated client. Disconnects are rare;
        // wake all browser workers after registry removal instead of polling
        // every idle worker forever.
        let surfaces = mux.with_state(|state| {
            state
                .surfaces
                .values()
                .filter(|surface| surface.kind() == SurfaceKind::Browser)
                .cloned()
                .collect::<Vec<_>>()
        });
        for surface in surfaces {
            surface.forget_browser_pointer_owner(owner);
            surface.wake_browser_pointer_cleanup();
        }
    }
    if send_detached {
        let _ = record.writer.set_write_timeout(Some(CLIENT_DETACH_WRITE_TIMEOUT));
        if let Some(event) = notice {
            let _ = record.writer.send_control(&json!({"event": event}));
            let _ = record.writer.flush_control(CLIENT_DETACH_WRITE_TIMEOUT);
        }
        for (surface, attached) in &record.attached {
            for stream in attached.streams.values() {
                let _ = record
                    .writer
                    .send_terminal(&detached_event_json(*surface, detach, None), stream);
            }
        }
        record.writer.close_after_control();
    } else {
        record.writer.close();
    }
    mux.emit(MuxEvent::ClientDetached(client));
    true
}

pub(super) fn complete_daemon_shutdown_after_ack(
    mux: &Arc<Mux>,
    requesting_client: u64,
    writer: &MessageWriter,
) -> bool {
    if mux
        .commit_daemon_handoff_after_ack(requesting_client, || {
            writer.flush_control(SHUTDOWN_ACK_FLUSH_TIMEOUT)
        })
        .is_err()
    {
        mux.cancel_daemon_handoff(requesting_client);
        return false;
    }
    let requester_notice_sent = writer
        .send_control(&json!({"event": DAEMON_SHUTDOWN_EVENT}))
        .and_then(|()| writer.flush_control(SHUTDOWN_ACK_FLUSH_TIMEOUT))
        .is_ok();
    for peer in mux.control_clients.client_ids() {
        if peer != requesting_client {
            disconnect_client_with_notice(
                mux,
                peer,
                true,
                Some(DAEMON_SHUTDOWN_EVENT),
                &DetachNotice { reason: detach_reason::HOST_SHUTDOWN, by: None },
            );
        }
    }
    // Keep the owner alive until every detached client has received the
    // shutdown notice. The committed handoff reservation fences new work
    // while these notices are being flushed.
    mux.request_daemon_shutdown();
    requester_notice_sent
}

/// Detaches `owner`'s own view of `placement` and tells it with
/// `detached {scope:"view"}`; its connection and relay sub-views stay.
pub(super) fn detach_own_view(
    mux: &Mux,
    owner: u64,
    placement: SurfaceId,
    by: TerminalDetachActor,
) {
    mux.detach_terminal_own_view(placement, owner);
    let notice = DetachNotice { reason: detach_reason::DISCONNECTED_BY, by: Some(by) };
    let mut event = detached_event_json(placement, &notice, None);
    event["scope"] = json!("view");
    mux.control_clients.send_surface_event(owner, placement, None, &event);
}

/// Disconnects one shared-sizing participant on behalf of `requester` (the
/// in-process frontend's `detach-client {client: <participant>}`): a relay
/// sub-view leaves alone and its relay forwards the notice; the own view of
/// a client with [`SIZING_VIEW_DETACH_CAPABILITY`] leaves alone and that
/// client stays; any other participant's whole client is kicked with `disconnected-by`.
pub fn detach_size_participant(
    mux: &Arc<Mux>,
    requester: u64,
    participant: &str,
    surface: Option<SurfaceId>,
) -> anyhow::Result<()> {
    let by = detach_actor(mux, requester, None);
    let target = DetachClientTarget::Participant(participant.to_string());
    if let Some((owner, placement)) = own_view_detach_target(mux, &target, surface) {
        detach_own_view(mux, owner, placement, by);
        return Ok(());
    }
    let member = match surface {
        Some(surface) => mux.terminal_participant_member_on(surface, participant),
        None => mux.terminal_participant_member(participant),
    };
    let Some((client, placement, view)) = member else {
        anyhow::bail!("unknown participant {participant}");
    };
    if let Some(view) = view {
        mux.detach_terminal_sub_view(placement, client, &view);
        let notice = DetachNotice { reason: detach_reason::DISCONNECTED_BY, by: Some(by) };
        mux.control_clients.send_surface_event(
            client,
            placement,
            None,
            &detached_event_json(placement, &notice, Some(&view)),
        );
        return Ok(());
    }
    anyhow::ensure!(client != requester, "cannot disconnect this client");
    anyhow::ensure!(kick_client(mux, client, by), "unknown client {client}");
    Ok(())
}

pub fn detach_control_client(mux: &Arc<Mux>, client: u64) -> bool {
    disconnect_client(mux, client, true)
}
