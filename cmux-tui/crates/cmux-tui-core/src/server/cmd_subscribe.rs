//! Event subscription command handlers: subscribe (tree events and surface
//! output streams) and subscribe-activity, plus the JSON for every
//! subscribed mux event and the overflow notice. Each handler is one
//! `Command` arm of `handle_command_with_cancellation`.

use super::MessageWriter;
use super::OPEN_DEVICE_KINDS_CAPABILITY;
use super::SHARED_SIZING_CAPABILITY;
use super::machine_usage_json;
use super::size_state_event_json;
use super::tree_delta_json;
use crate::GraphicsStatus;
use crate::Mux;
use crate::MuxEvent;
use crate::SurfaceId;
use crate::stream_interrupt::StreamInterrupt;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(super) fn subscribe_activity(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
) -> anyhow::Result<Value> {
    if !mux.control_clients.is_unix(client) {
        anyhow::bail!("subscribe-activity requires a trusted local connection");
    }
    mux.activity.subscribe(mux, client, writer)
}

pub(super) fn subscribe_command(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    tree_events: Option<String>,
    surface: Option<SurfaceId>,
) -> anyhow::Result<Value> {
    let tree_deltas = match tree_events.as_deref().unwrap_or("coarse") {
        "coarse" => false,
        "deltas" => true,
        other => anyhow::bail!("bad request: unsupported tree_events {other:?}"),
    };
    let events = match surface {
        Some(surface) => mux
            .subscribe_surface_session(surface)
            .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?,
        None => mux.subscribe(),
    };
    let event_mux = mux.clone();
    let trusted_pairing_client = mux.control_clients.is_unix(client);
    let pending_pairings = if trusted_pairing_client { mux.pending_pairings() } else { Vec::new() };
    let writer = writer.clone();
    let outbound_stream = writer.start_stream(&subscription_overflow_json())?;
    std::thread::Builder::new().name("mux-events-out".into()).spawn(move || {
        let mut transport_overflow = false;
        for challenge in pending_pairings {
            let value = json!({
                "event": "pairing-requested",
                "request": challenge.id,
                "code": challenge.code,
                "peer": challenge.peer,
                "expires_in": challenge.expires_in,
            });
            if let Err(error) = writer.send_stream_backpressured(&value, &outbound_stream) {
                transport_overflow = error.kind() == std::io::ErrorKind::WouldBlock;
                break;
            }
        }
        let interrupt = StreamInterrupt::new();
        writer.register_interrupt(&interrupt);
        outbound_stream.register_interrupt(&interrupt);
        events.wake_on(&interrupt);
        while writer.is_open() && outbound_stream.is_open() {
            let event = match events.recv_until_interrupted(&interrupt) {
                Ok(event) => event,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            };
            let value = match &event {
                MuxEvent::PairingRequested(_) | MuxEvent::PairingResolved { .. }
                    if !trusted_pairing_client =>
                {
                    continue;
                }
                MuxEvent::Conversation(event) if event.is_draft() => continue,
                MuxEvent::Conversation(_) | MuxEvent::CloudConversation(_)
                    if !trusted_pairing_client =>
                {
                    continue;
                }
                MuxEvent::PairingRequested(challenge) => json!({
                    "event": "pairing-requested",
                    "request": challenge.id,
                    "code": challenge.code,
                    "peer": challenge.peer,
                    "expires_in": challenge.expires_in,
                }),
                MuxEvent::PairingResolved { request } => json!({
                    "event": "pairing-resolved",
                    "request": request,
                }),
                MuxEvent::TreeDelta(delta) if tree_deltas => tree_delta_json(delta, &event_mux),
                MuxEvent::TreeDelta(_) => json!({"event": "tree-changed"}),
                MuxEvent::TreeSelectionChanged if tree_deltas => {
                    json!({"event": "tree-changed"})
                }
                MuxEvent::TreeSelectionChanged => continue,
                MuxEvent::SizeStateChanged { surface, runtime, state } => {
                    if !event_mux
                        .control_clients
                        .supports_capability(client, SHARED_SIZING_CAPABILITY)
                    {
                        continue;
                    }
                    let open = event_mux
                        .control_clients
                        .supports_capability(client, OPEN_DEVICE_KINDS_CAPABILITY);
                    size_state_event_json(*surface, *runtime, state, Some((client, open)))
                }
                _ => subscribed_event_json(&event),
            };
            if let Err(error) = writer.send_stream_backpressured(&value, &outbound_stream) {
                transport_overflow = error.kind() == std::io::ErrorKind::WouldBlock;
                break;
            }
        }
        if events.overflowed() || transport_overflow {
            let _ = writer.send_terminal(&subscription_overflow_json(), &outbound_stream);
        }
    })?;
    Ok(json!({}))
}

pub(super) fn subscribed_event_json(event: &MuxEvent) -> Value {
    match event {
        MuxEvent::SurfaceOutput(id) => json!({"event": "surface-output", "surface": id}),
        MuxEvent::SurfaceResized { surface, cols, rows, reservation_id } => json!({
            "event": "surface-resized",
            "surface": surface,
            "cols": cols,
            "rows": rows,
            "reservation_id": reservation_id,
        }),
        MuxEvent::SurfaceResizeFailed {
            surface,
            cols,
            rows,
            error,
            retry_after_ms,
            reservation_id,
        } => json!({
            "event": "surface-resize-failed",
            "surface": surface,
            "cols": cols,
            "rows": rows,
            "error": error.as_ref(),
            "retry_after_ms": retry_after_ms,
            "reservation_id": reservation_id,
        }),
        MuxEvent::SurfaceExited(id) => json!({"event": "surface-exited", "surface": id}),
        MuxEvent::SizeStateChanged { surface, runtime, state } => {
            size_state_event_json(*surface, *runtime, state, None)
        }
        MuxEvent::TitleChanged { surface, title } => {
            json!({"event": "title-changed", "surface": surface, "title": title.as_ref()})
        }
        MuxEvent::AgentChanged { surface, state, source, session, agent, updated_at_ms } => json!({
            "event": "agent-changed",
            "surface": surface,
            "state": state.as_ref(),
            "source": source.as_ref(),
            "session": session.as_deref(),
            "agent": agent.as_deref(),
            "updated_at_ms": updated_at_ms,
        }),
        MuxEvent::Bell(id) => json!({"event": "bell", "surface": id}),
        MuxEvent::Notification(notification) => json!({
            "event": "notification",
            "notification": notification.notification,
            "title": notification.title,
            "body": notification.body,
            "level": notification.level.as_str(),
            "surface": notification.surface,
            "source": notification.source.as_str(),
        }),
        MuxEvent::GraphicsStatus(status) => match status {
            GraphicsStatus::KittyImageBudgetWorkerStartFailed { error } => json!({
                "event": "graphics-status",
                "kind": "kitty-image-budget-worker-start-failed",
                "error": error.as_ref(),
            }),
            GraphicsStatus::KittyImageBudgetUpdateFailed { retry_exhausted, summary } => json!({
                "event": "graphics-status",
                "kind": "kitty-image-budget-update-failed",
                "retry_exhausted": retry_exhausted,
                "summary": summary.as_ref(),
            }),
            GraphicsStatus::CellPixelUpdateRetriesExhausted {
                attempts,
                remaining,
                cell_pixels,
            } => json!({
                "event": "graphics-status",
                "kind": "cell-pixel-update-retries-exhausted",
                "attempts": attempts,
                "remaining": remaining,
                "cell_width": cell_pixels.0,
                "cell_height": cell_pixels.1,
            }),
        },
        MuxEvent::Status(message) => json!({"event": "status", "message": message}),
        MuxEvent::MachineUsageChanged(usage) => {
            let mut payload = machine_usage_json(usage.as_ref());
            payload["event"] = json!("machine-usage-changed");
            payload
        }
        MuxEvent::ConfigReloadRequested => json!({"event": "config-reload-requested"}),
        MuxEvent::WindowTitleRequested(title) => {
            json!({"event": "window-title-requested", "title": title})
        }
        MuxEvent::ScrollChanged { surface, offset, at_bottom } => json!({
            "event": "scroll-changed",
            "surface": surface,
            "offset": offset,
            "at_bottom": at_bottom,
        }),
        MuxEvent::TreeChanged => json!({"event": "tree-changed"}),
        MuxEvent::TreeSelectionChanged => json!({"event": "tree-changed"}),
        MuxEvent::TreeDelta(_) => json!({"event": "tree-changed"}),
        MuxEvent::FrontendProjectionChanged {
            frontend,
            scope,
            subject_key,
            projection_revision,
            origin,
            mutation_id,
        } => json!({
            "event": "frontend-projection-changed",
            "frontend": frontend,
            "scope": scope,
            "subject_key": subject_key,
            "projection_revision": projection_revision,
            "origin": origin,
            "mutation_id": mutation_id,
        }),
        MuxEvent::PersonalChanged { personal_revision } => json!({
            "event": "personal-changed",
            "personal_revision": personal_revision,
        }),
        MuxEvent::Conversation(event) => event.wire_json(),
        MuxEvent::CloudConversation(event) => event.wire_json(),
        MuxEvent::BookmarksChanged(change) => json!({
            "event": "bookmarks-changed",
            "browser_profile_id": change.browser_profile_id,
            "bookmarks_revision": change.bookmarks_revision,
        }),
        MuxEvent::SettingsChanged(change) => json!({
            "event": "settings-changed",
            "revision": change.revision,
            "keys": change.keys,
            "origin": change.origin.as_str(),
        }),
        MuxEvent::TerminalRegistryChanged { registry_id, generation, terminal_revision } => json!({
            "event":"terminal-registry-changed",
            "registry_id":registry_id,
            "generation":generation,
            "terminal_revision":terminal_revision,
            "refetch":"terminal-events-or-list-terminals",
        }),
        MuxEvent::TerminalReaped { terminal_id, terminal, grace_ms } => json!({
            "event": "terminal-reaped",
            "terminal_id": terminal_id,
            "terminal": terminal,
            "grace_ms": grace_ms,
        }),
        MuxEvent::LayoutChanged(screen) => json!({"event": "layout-changed", "screen": screen}),
        MuxEvent::ClientAttached { client, transport, name, kind } => json!({
            "event": "client-attached",
            "client": client,
            "transport": transport,
            "name": name,
            "kind": kind,
        }),
        MuxEvent::ClientChanged { client, name, kind } => json!({
            "event": "client-changed",
            "client": client,
            "name": name,
            "kind": kind,
        }),
        MuxEvent::ClientDetached(client) => {
            json!({"event": "client-detached", "client": client})
        }
        MuxEvent::ClientListInvalidated => json!({"event": "client-list-invalidated"}),
        MuxEvent::PairingRequested(challenge) => json!({
            "event": "pairing-requested",
            "request": challenge.id,
            "code": challenge.code,
            "peer": challenge.peer,
            "expires_in": challenge.expires_in,
        }),
        MuxEvent::PairingResolved { request } => {
            json!({"event": "pairing-resolved", "request": request})
        }
        MuxEvent::Empty => json!({"event": "empty"}),
    }
}

pub(super) fn subscription_overflow_json() -> Value {
    json!({
        "event": "overflow",
        "error": "subscriber fell behind; resubscribe to continue receiving events",
    })
}
