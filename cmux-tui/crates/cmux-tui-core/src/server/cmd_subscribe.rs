//! Event subscription command handlers: subscribe (tree events and surface
//! output streams) and subscribe-activity, plus the JSON for every
//! subscribed mux event and the overflow notice. Each handler is one
//! `Command` arm of `handle_command_with_cancellation`.

use super::MessageWriter;
use super::OPEN_DEVICE_KINDS_CAPABILITY;
use super::SHARED_SIZING_CAPABILITY;
use super::SizeStateReader;
use super::connection_scheduler::REQUEST_THREAD_QOS;
use super::machine_usage_json;
use super::size_state_event_json;
use super::tree_delta_json;
use crate::GraphicsStatus;
use crate::Mux;
use crate::MuxEvent;
use crate::SurfaceId;
use crate::event_bus::MuxEventKind;
use crate::event_bus::MuxEventKinds;
use crate::panic_free::JsonFields;
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
    // A page relay hears only its page's events (page-router.json `events`;
    // client_hello admits its `subscribe` only when there are some). Their
    // kinds filter its stream on the bus, so the others (a busy terminal's
    // output) are never queued for it nor rendered to JSON.
    let page_events = super::origin_gate::page_relay_events(mux, client);
    let interest = page_events.and_then(page_event_kinds);
    let events = match (surface, interest) {
        (Some(surface), _) => mux
            .subscribe_surface_session(surface)
            .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?,
        (None, Some(kinds)) => mux.subscribe_kinds(kinds),
        (None, None) => mux.subscribe(),
    };
    #[cfg(test)]
    let probe = mux.control_clients.subscribe_probe(client);
    let event_mux = mux.clone();
    let trusted_pairing_client = mux.control_clients.is_unix(client);
    // Conversation events go to the person's own clients: the Unix socket
    // and authenticated WebSocket connections (`ws-conversations-v1`).
    let conversation_client = mux.control_clients.is_owner_client(client);
    // Its events are never tree deltas: render none only to drop them.
    let tree_deltas = tree_deltas && page_events.is_none();
    let pending_pairings = if trusted_pairing_client && page_events.is_none() {
        mux.pending_pairings()
    } else {
        Vec::new()
    };
    // `event-cause-v1`, echoed in set-client-info before this subscribe:
    // each event says what set it off (spec/events.md "Event cause").
    let caused_events =
        mux.control_clients.supports_capability(client, crate::event_cause::CAPABILITY);
    let writer = writer.clone();
    // Its events share the reply FIFO (spec/transports.md "Reply and event order").
    let outbound_stream = writer.start_control_stream(&subscription_overflow_json())?;
    cmux_threads::spawn("mux-events-out", REQUEST_THREAD_QOS, move || {
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
            let (event, cause) = match events.recv_caused_until_interrupted(&interrupt) {
                Ok(caused) => caused,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            };
            #[cfg(test)]
            probe.received.note(&event);
            // A surface stream is not filtered on the bus: drop an unwanted
            // kind before any JSON is built.
            if interest.is_some_and(|kinds| !kinds.accepts(&event)) {
                continue;
            }
            #[cfg(test)]
            probe.rendered.note(&event);
            let mut value = match &event {
                MuxEvent::PairingRequested(_) | MuxEvent::PairingResolved { .. }
                    if !trusted_pairing_client =>
                {
                    continue;
                }
                // A draft goes only to a trusted local connection that asked
                // for drafts in set-client-info (the admission of
                // `conversation.events`; old clients never see the event).
                MuxEvent::Conversation(event) if event.is_draft() => {
                    let wanted = conversation_client
                        && event_mux.control_clients.supports_capability(
                            client,
                            super::conversations::CONVERSATION_DRAFT_EVENTS_CAPABILITY,
                        );
                    match event.as_ref() {
                        crate::conversation_store::ConversationEvent::Draft {
                            conversation,
                            participant,
                            item,
                        } if wanted => json!({
                            "event": "conversation-draft",
                            "conversation": conversation,
                            "participant": participant,
                            "item": item,
                        }),
                        _ => continue,
                    }
                }
                MuxEvent::Conversation(_) if !conversation_client => {
                    continue;
                }
                // A participant's own list state (a pin, a "marked unread")
                // goes only to connections that act as that participant.
                MuxEvent::Conversation(event)
                    if matches!(
                        event.as_ref(),
                        crate::conversation_store::ConversationEvent::Inbox { participant, .. }
                            if *participant != event_mux.conversation_principal(client)
                    ) =>
                {
                    continue;
                }
                // A run's steps go only to a connection that asked for runs in
                // set-client-info (`conversation-runs-v1`): old clients never
                // see the event, and its steps can be large.
                MuxEvent::Conversation(event)
                    if event.is_run()
                        && !event_mux.control_clients.supports_capability(
                            client,
                            super::conversation_runs::CONVERSATION_RUNS_CAPABILITY,
                        ) =>
                {
                    continue;
                }
                // A Chief's live frames only to a connection that asked for
                // them in set-client-info (`chief-live-v1`).
                MuxEvent::Conversation(event)
                    if event.is_live()
                        && !event_mux.control_clients.supports_capability(
                            client,
                            super::conversation_live::CHIEF_LIVE_CAPABILITY,
                        ) =>
                {
                    continue;
                }
                // An avatar change only to a connection that asked for it in
                // set-client-info (`participant-avatars-v1`).
                MuxEvent::Conversation(event)
                    if event.is_avatar()
                        && !event_mux.control_clients.supports_capability(
                            client,
                            super::participant_avatars::PARTICIPANT_AVATARS_CAPABILITY,
                        ) =>
                {
                    continue;
                }
                // A Chief change only to the person's own connection that
                // asked for it in set-client-info (`chief-events-v1`): never
                // to a bound agent, which chief.profile.list may refuse.
                MuxEvent::Conversation(event)
                    if event.is_chief()
                        && (event_mux.conversation_principal(client)
                            != crate::conversation_store::LOCAL_USER
                            || !event_mux.control_clients.supports_capability(
                                client,
                                super::chief_registry_resource::CHIEF_EVENTS_CAPABILITY,
                            )) =>
                {
                    continue;
                }
                // The person's own clients: Unix, or an authenticated page
                // (`ws-cloud-conversations-v1`); `delivers` narrows it to the lease's.
                // The host replica's renewal only to the verified app: it holds the install token.
                MuxEvent::CloudConversation(event)
                    if host_replica_needed(event)
                        && !matches!(
                            super::origin_gate::connection_actor(&event_mux, client),
                            crate::workspace_registry::Actor::Frontend { .. }
                        ) =>
                {
                    continue;
                }
                MuxEvent::CloudConversation(_) if !conversation_client => {
                    continue;
                }
                MuxEvent::CloudConversation(event)
                    if !host_replica_needed(event)
                        && !super::cloud_conversations::delivers(&event_mux, client) =>
                {
                    continue;
                }
                // A Cloud Chief's run change, like a local one, only to a
                // connection that asked for runs (`conversation-runs-v1`).
                MuxEvent::CloudConversation(event)
                    if matches!(
                        event.as_ref(),
                        crate::cloud_conversations::CloudEvent::RunChanged { .. }
                    ) && !event_mux.control_clients.supports_capability(
                        client,
                        super::conversation_runs::CONVERSATION_RUNS_CAPABILITY,
                    ) =>
                {
                    continue;
                }
                // A Cloud Chief's live frame only to a connection that asked
                // for live frames (`chief-live-v1`).
                MuxEvent::CloudConversation(event)
                    if matches!(
                        event.as_ref(),
                        crate::cloud_conversations::CloudEvent::Live { .. }
                    ) && !event_mux.control_clients.supports_capability(
                        client,
                        super::conversation_live::CHIEF_LIVE_CAPABILITY,
                    ) =>
                {
                    continue;
                }
                // Typing in a Cloud conversation only to a connection that
                // asked for it (`cloud-conversation-typing-v1`).
                MuxEvent::CloudConversation(event)
                    if matches!(
                        event.as_ref(),
                        crate::cloud_conversations::CloudEvent::Typing { .. }
                    ) && !event_mux.control_clients.supports_capability(
                        client,
                        super::cloud_conversations::CLOUD_TYPING_CAPABILITY,
                    ) =>
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
                    let reader =
                        SizeStateReader { client, open, scheme: event_mux.participant_scheme() };
                    size_state_event_json(*surface, *runtime, state, Some(reader))
                }
                _ => subscribed_event_json(&event),
            };
            if let Some(events) = page_events
                && !value
                    .field("event")
                    .as_str()
                    .is_some_and(|name| events.iter().any(|e| e == name))
            {
                continue;
            }
            if caused_events {
                stamp_cause(&mut value, cause);
            }
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

/// What one connection's subscription took from the bus and what it
/// started to render to JSON, per event kind: tests read it to see which
/// events a filter kept out of a connection's stream.
#[cfg(test)]
#[derive(Default)]
pub(super) struct SubscribeProbe {
    pub(super) received: KindCounts,
    pub(super) rendered: KindCounts,
}

#[cfg(test)]
pub(super) struct KindCounts([std::sync::atomic::AtomicU64; MuxEventKind::COUNT]);

#[cfg(test)]
impl Default for KindCounts {
    fn default() -> Self {
        Self(std::array::from_fn(|_| std::sync::atomic::AtomicU64::new(0)))
    }
}

#[cfg(test)]
impl KindCounts {
    fn note(&self, event: &MuxEvent) {
        self.0[MuxEventKind::of(event) as usize].fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }

    pub(super) fn of(&self, kind: MuxEventKind) -> u64 {
        self.0[kind as usize].load(std::sync::atomic::Ordering::Relaxed)
    }
}

/// The kinds a page relay hearing the subscribe events `names` needs, or
/// `None` when a name is one this map does not know (the stream is then
/// filtered by name alone, as before).
pub(super) fn page_event_kinds(names: &[String]) -> Option<MuxEventKinds> {
    names.iter().try_fold(MuxEventKinds::NONE, |kinds, name| {
        wire_event_kinds(name).map(|more| kinds.union(more))
    })
}

/// The event kinds that can render as the subscribe event `name`
/// ([`subscribed_event_json`] and the arms of [`subscribe_command`]). Tree
/// delta names are left out: a page relay never hears deltas.
pub(super) fn wire_event_kinds(name: &str) -> Option<MuxEventKinds> {
    use MuxEventKind as Kind;
    let kind = match name {
        "surface-output" => Kind::SurfaceOutput,
        "surface-resized" => Kind::SurfaceResized,
        "surface-resize-failed" => Kind::SurfaceResizeFailed,
        "surface-exited" => Kind::SurfaceExited,
        "size-state" => Kind::SizeStateChanged,
        "title-changed" => Kind::TitleChanged,
        "agent-changed" => Kind::AgentChanged,
        "agent-presence-changed" => Kind::AgentPresenceChanged,
        "bell" => Kind::Bell,
        "program-status-changed" => Kind::ProgramStatusChanged,
        "notification" => Kind::Notification,
        "graphics-status" => Kind::GraphicsStatus,
        "status" => Kind::Status,
        "machine-usage-changed" => Kind::MachineUsageChanged,
        "config-reload-requested" => Kind::ConfigReloadRequested,
        "window-title-requested" => Kind::WindowTitleRequested,
        "scroll-changed" => Kind::ScrollChanged,
        "tree-changed" => {
            return Some(
                MuxEventKinds::NONE
                    .with(Kind::TreeChanged)
                    .with(Kind::TreeSelectionChanged)
                    .with(Kind::TreeDelta),
            );
        }
        "frontend-projection-changed" => Kind::FrontendProjectionChanged,
        "personal-changed" => Kind::PersonalChanged,
        "bookmarks-changed" => Kind::BookmarksChanged,
        "history-changed" => Kind::HistoryChanged,
        "settings-changed" => Kind::SettingsChanged,
        "keybindings-changed" => Kind::KeybindingsChanged,
        "terminal-registry-changed" => Kind::TerminalRegistryChanged,
        "terminal-reaped" => Kind::TerminalReaped,
        "layout-changed" => Kind::LayoutChanged,
        "client-attached" => Kind::ClientAttached,
        "client-changed" => Kind::ClientChanged,
        "client-detached" => Kind::ClientDetached,
        "client-list-invalidated" => Kind::ClientListInvalidated,
        "pairing-requested" => Kind::PairingRequested,
        "pairing-resolved" => Kind::PairingResolved,
        "empty" => Kind::Empty,
        // ConversationEvent::wire_json and the draft arm above.
        "chief-changed" | "participant-avatar-changed" => Kind::Conversation,
        name if name.starts_with("conversation-") => Kind::Conversation,
        // CloudEvent::wire_json.
        name if name.starts_with("cloud-") => Kind::CloudConversation,
        _ => return None,
    };
    Some(MuxEventKinds::NONE.with(kind))
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
        MuxEvent::SurfaceExited(id, end) => {
            json!({"event": "surface-exited", "surface": id, "end": end.as_deref()})
        }
        MuxEvent::SizeStateChanged { surface, runtime, state } => {
            size_state_event_json(*surface, *runtime, state, None)
        }
        MuxEvent::TitleChanged { surface, title } => {
            json!({"event": "title-changed", "surface": surface, "title": title.as_ref()})
        }
        MuxEvent::AgentChanged {
            surface,
            state,
            source,
            session,
            agent,
            agent_session_id,
            updated_at_ms,
            since_ms,
            last_prompt,
        } => json!({
            "event": "agent-changed",
            "surface": surface,
            "state": state.as_ref(),
            "source": source.as_ref(),
            "session": session.as_deref(),
            "agent": agent.as_deref(),
            "agent_session_id": agent_session_id.as_deref(),
            "updated_at_ms": updated_at_ms,
            "since_ms": since_ms,
            "last_prompt": last_prompt.as_deref(),
        }),
        MuxEvent::AgentPresenceChanged { surface, presence } => {
            let presence = presence.as_deref();
            json!({
                "event": "agent-presence-changed",
                "surface": surface,
                "activity": presence.map(|presence| presence.activity.as_str()),
                "agent": presence.and_then(|presence| presence.agent.as_deref()),
                "session": presence.and_then(|presence| presence.session.as_deref()),
                "tool": presence.and_then(|presence| presence.tool.as_deref()),
                "path": presence.and_then(|presence| presence.path.as_deref()),
                "line": presence.and_then(|presence| presence.line),
                "updated_at_ms": presence.map(|presence| presence.updated_at_ms),
            })
        }
        MuxEvent::Bell(id) => json!({"event": "bell", "surface": id}),
        MuxEvent::ProgramStatusChanged { surface, status } => json!({
            "event": "program-status-changed",
            "surface": surface,
            "program_status": status.map(|status| status.wire()),
        }),
        MuxEvent::Notification(notification) => json!({
            "event": "notification",
            "notification": notification.notification,
            "title": notification.title,
            "subtitle": notification.subtitle,
            "body": notification.body,
            "preview": notification.preview,
            "id": notification.id,
            "message": notification.message,
            "prompt": notification.prompt,
            "session": notification.session,
            "question": notification.question.as_deref(),
            "level": notification.level.as_str(),
            "surface": notification.surface,
            "workspace_id": notification.workspace_id,
            "source": notification.source.as_str(),
            "desktop": notification.desktop,
            "reply": notification.reply,
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
            payload.insert("event", json!("machine-usage-changed"));
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
        MuxEvent::HistoryChanged { revision, kinds } => json!({
            "event": "history-changed",
            "revision": revision,
            "kinds": kinds,
        }),
        MuxEvent::SettingsChanged(change) => json!({
            "event": "settings-changed",
            "revision": change.revision,
            "keys": change.keys,
            "origin": change.origin.as_str(),
        }),
        MuxEvent::KeybindingsChanged(change) => json!({
            "event": "keybindings-changed",
            "revision": change.revision,
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
        MuxEvent::LayoutChanged(screen, delta) => {
            let mut value = json!({"event": "layout-changed", "screen": screen});
            // `layout-delta-v1`: the screen's layout fields, flat, as in `Screen`.
            if let Some(delta) = delta {
                value.insert("workspace", json!(delta.workspace));
                if let (Value::Object(value), Value::Object(layout)) = (&mut value, &delta.layout) {
                    value.extend(layout.iter().map(|(key, field)| (key.clone(), field.clone())));
                }
                if let Some(transaction) = &delta.transaction {
                    value.insert("transaction", json!(transaction.as_ref()));
                }
            }
            value
        }
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

/// Adds `cause` to an event line for an `event-cause-v1` subscriber. A
/// program cause is left out: a missing field means it.
pub(super) fn stamp_cause(value: &mut Value, cause: crate::event_cause::EventCause) {
    if cause == crate::event_cause::EventCause::Program {
        return;
    }
    if let Some(fields) = value.as_object_mut() {
        fields.insert("cause".to_string(), Value::from(cause.wire_name()));
    }
}

pub(super) fn subscription_overflow_json() -> Value {
    json!({
        "event": "overflow",
        "error": "subscriber fell behind; resubscribe to continue receiving events",
    })
}

fn host_replica_needed(event: &crate::cloud_conversations::CloudEvent) -> bool {
    matches!(event, crate::cloud_conversations::CloudEvent::HostReplicaNeeded { .. })
}

#[cfg(all(test, unix))]
#[path = "cmd_subscribe_tests.rs"]
mod tests;
