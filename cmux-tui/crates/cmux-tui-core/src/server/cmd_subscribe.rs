//! Event subscription command handlers: subscribe (tree events and surface
//! output streams) and subscribe-activity, plus the JSON for every
//! subscribed mux event and the overflow notice. Each handler is one
//! `Command` arm of `handle_command_with_cancellation`.

use super::MessageWriter;
use super::OPEN_DEVICE_KINDS_CAPABILITY;
use super::ResourceWorkerAdmissionError;
use super::SHARED_SIZING_CAPABILITY;
use super::machine_usage_json;
use super::size_state_event_json;
use super::tree_delta_json;
use crate::GraphicsStatus;
use crate::Mux;
use crate::MuxEvent;
use crate::SurfaceId;
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

/// A connection that has no use for `scroll-changed` on its event stream (the Mac app: its terminals' scrollbars come
/// from its own surfaces; a terminal's attach stream still carries the event) says this in
/// `set-client-info`: its `subscribe` carries no `scroll-changed` (SWITCH FRAMES SF-5: every hidden busy terminal
/// woke the app's event pump about 15 times a second for an event its store ignores).
pub(crate) const SUBSCRIBE_SCROLL_ON_ATTACH_CAPABILITY: &str = "subscribe-scroll-on-attach-v1";
/// A delta subscriber that says this in `set-client-info` gets a selection change that rides with a
/// tree delta as `selection-changed` (the changed workspace's whole selection) instead of a
/// `tree-changed` that makes it read the whole tree again (#32408).
pub(crate) const TREE_SELECTION_DELTAS_CAPABILITY: &str = "tree-selection-deltas-v1";
/// An owner app that understands the authenticated worker's screen identity
/// opts into its initial replay and live `screen-device-changed` events.
pub(crate) const SCREEN_DEVICE_IDENTITY_CAPABILITY: &str = "screen-device-identity-v1";
/// A client that says it in `set-client-info` gets, first on each `subscribe`, an
/// `agent-presence-changed` for every terminal's presence, a cleared one with nulls. It can then
/// keep the presence it shows across a reconnect to the same daemon instead of dropping it until
/// each agent's next hook event (hq#19373, ask c-ea62b204f6). `identify` lists it.
pub(crate) const AGENT_PRESENCE_REPLAY_CAPABILITY: &str = "agent-presence-replay-v1";

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
    // Its thread holds the permit until the stream ends (the connection
    // closed or the stream overflowed), so a client that sends `subscribe`
    // in a loop gets refusals, not a thread and a mailbox per line.
    let admission = &mux.control_clients.event_subscription_admission;
    let permit = admission.try_reserve(client).map_err(|error| match error {
        ResourceWorkerAdmissionError::ClientCapacity => anyhow::anyhow!(
            "too many event subscriptions are open on this connection (limit {}); \
             subscribe was not executed",
            admission.per_client_capacity
        ),
        ResourceWorkerAdmissionError::ServerCapacity => anyhow::anyhow!(
            "too many event subscriptions are open on this daemon (limit {}); \
             subscribe was not executed",
            admission.server_capacity
        ),
    })?;
    // A page relay hears only its page's events (page-router.json `events`;
    // client_hello admits its `subscribe` only when there are some).
    let page_events = super::origin_gate::page_relay_events(mux, client);
    let events = match surface {
        Some(surface) => mux
            .subscribe_surface_session(surface)
            .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?,
        None => match page_events {
            // Its mailbox takes only them: the output of every terminal never
            // wakes its thread or becomes JSON it drops (audit 2026-11-18 §14).
            // A remote device's incognito filter learns from tree events, so
            // its relay keeps the whole stream.
            Some(names) if !super::incognito_remote::is_remote_device(mux, client) => {
                mux.subscribe_where(move |event| page_relay_takes(names, event))
            }
            _ => mux.subscribe(),
        },
    };
    let event_mux = mux.clone();
    let trusted_pairing_client = mux.control_clients.is_unix(client);
    // Read once: the handshake sends `set-client-info` before `subscribe`.
    let scroll_on_attach =
        mux.control_clients.supports_capability(client, SUBSCRIBE_SCROLL_ON_ATTACH_CAPABILITY);
    let selection_deltas =
        mux.control_clients.supports_capability(client, TREE_SELECTION_DELTAS_CAPABILITY);
    // Conversation events go to the person's own clients: the Unix socket
    // and authenticated WebSocket connections (`ws-conversations-v1`).
    let conversation_client = mux.control_clients.is_owner_client(client);
    // Screen identity is an app-owned projection. The local app may arrive
    // over its authenticated owner WebSocket as well as the Unix socket;
    // page relays and unowned carriers never receive it.
    let trusted_screen_client = mux.control_clients.is_owner_client(client)
        && page_events.is_none()
        && mux.control_clients.supports_capability(client, SCREEN_DEVICE_IDENTITY_CAPABILITY);
    // Its events are never tree deltas: render none only to drop them.
    let tree_deltas = tree_deltas && page_events.is_none();
    // A remote device hears nothing of an incognito workspace (#31210).
    let mut incognito = super::incognito_remote::EventFilter::start(mux, client);
    let pending_pairings = if trusted_pairing_client && page_events.is_none() {
        mux.pending_pairings()
    } else {
        Vec::new()
    };
    // Read after the subscription exists: a change after this read also comes live, after these.
    let presence_replay =
        if mux.control_clients.supports_capability(client, AGENT_PRESENCE_REPLAY_CAPABILITY) {
            mux.agent_presence_replay()
        } else {
            Vec::new()
        };
    let writer = writer.clone();
    let outbound_stream = writer.start_stream(&subscription_overflow_json())?;
    std::thread::Builder::new().name("mux-events-out".into()).spawn(move || {
        let _permit = permit;
        let mut transport_overflow = false;
        // Replay the current authenticated worker identity before consuming
        // live events. This closes the identify -> subscribe race and also
        // clears stale aliases when the worker has gone away.
        if trusted_screen_client {
            let initial = json!({
                "event": "screen-device-changed",
                "screen_device_id": event_mux.control_clients.remote_host.screen_device_id(),
            });
            if let Err(error) = writer.send_stream_backpressured(&initial, &outbound_stream) {
                transport_overflow = error.kind() == std::io::ErrorKind::WouldBlock;
            }
        }
        if transport_overflow {
            let _ = writer.send_terminal(&subscription_overflow_json(), &outbound_stream);
            return;
        }
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
        // The replay goes through the same filters as a live event (incognito, page relays).
        let mut presence_replay = presence_replay.into_iter();
        while writer.is_open() && outbound_stream.is_open() {
            let next = match presence_replay.next() {
                Some(event) => Ok(event),
                None => events.recv_until_interrupted(&interrupt),
            };
            let event = match next {
                Ok(event) => event,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            };
            let mut value = match &event {
                // The client applies none (SWITCH FRAMES SF-5); attach streams still carry it.
                MuxEvent::ScrollChanged { .. } if scroll_on_attach => continue,
                MuxEvent::PairingRequested(_) | MuxEvent::PairingResolved { .. }
                    if !trusted_pairing_client =>
                {
                    continue;
                }
                // A chat's shares changed: only to the owner's own connections that asked
                // (`agent-session-share-events-v1`).
                #[cfg(unix)]
                MuxEvent::AgentSessionShareChanged { .. }
                    if !super::agent_session_attach::hears_share_events(&event_mux, client) =>
                {
                    continue;
                }
                MuxEvent::ScreenDeviceChanged(_) if !trusted_screen_client => continue,
                // Read the cache at send time rather than trusting a queued
                // payload; a rapid rotation/removal cannot regress the app.
                MuxEvent::ScreenDeviceChanged(_) => json!({
                    "event": "screen-device-changed",
                    "screen_device_id": event_mux.control_clients.remote_host.screen_device_id(),
                }),
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
                            | crate::conversation_store::ConversationEvent::Scheduled {
                                participant, ..
                            }
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
                // The person's feed only to their own clients, as for the
                // cloud conversations.
                MuxEvent::FeedViewChanged { .. } | MuxEvent::FeedReportsChanged { .. }
                    if !conversation_client =>
                {
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
                // Who views a Cloud conversation only to a connection that
                // asked for it (`cloud-conversation-presence-v1`).
                MuxEvent::CloudConversation(event)
                    if matches!(
                        event.as_ref(),
                        crate::cloud_conversations::CloudEvent::Presence { .. }
                    ) && !event_mux.control_clients.supports_capability(
                        client,
                        super::cloud_conversations::CLOUD_PRESENCE_CAPABILITY,
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
                // Read when written: a screen or pane added since is unknown to the client until its
                // own delta, which carries its selection; the client skips it here.
                MuxEvent::TreeSelectionChanged(Some(workspace))
                    if tree_deltas && selection_deltas =>
                {
                    event_mux
                        .with_state(|state| {
                            crate::server::selection_changed_json(state, *workspace)
                        })
                        .unwrap_or_else(|| json!({"event": "tree-changed"}))
                }
                MuxEvent::TreeSelectionChanged(_) if tree_deltas => {
                    json!({"event": "tree-changed"})
                }
                MuxEvent::TreeSelectionChanged(_) => continue,
                MuxEvent::WorkspacePresentationChanged(workspace)
                    if tree_deltas && selection_deltas =>
                {
                    event_mux
                        .with_state(|state| {
                            crate::server::workspace_presentation_changed_json(
                                state,
                                &event_mux.tree_decorations_in_state(state),
                                *workspace,
                            )
                        })
                        .unwrap_or_else(|| json!({"event": "tree-changed"}))
                }
                MuxEvent::WorkspacePresentationChanged(_) => json!({"event": "tree-changed"}),
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
                // Apps clients already hear it on their own sink; only a page
                // relay (whose page names it) gets it from the event stream.
                MuxEvent::AppsChanged(_) if page_events.is_none() => continue,
                // Other clients hear a stash change as a `stash` resource on
                // `session.events`; only the Stashed Tabs page's relay gets it here.
                MuxEvent::StashChanged { .. } if page_events.is_none() => continue,
                // Only the Tasks page hears its owner's changes.
                MuxEvent::TasksChanged(_) if page_events.is_none() => continue,
                // What agents do with the person's apps: their own local connections only.
                MuxEvent::ComputerUseActivity(_) | MuxEvent::ComputerUsePreview(_)
                    if !trusted_pairing_client || page_events.is_some() =>
                {
                    continue;
                }
                // Apps hear it as `chat.changed`; no subscribe event carries it yet.
                MuxEvent::ChatsChanged { .. } => continue,
                // Apps hear it as `github.changed`; no subscribe event carries it.
                MuxEvent::GitHubChanged { .. } => continue,
                _ => subscribed_event_json(&event),
            };
            if incognito.hides(&event_mux, client, &event, &mut value) {
                continue;
            }
            // The mailbox filter named it by `subscribed_event_name`: the two agree.
            debug_assert!(
                page_events.is_none()
                    || value.field("event").as_str() == subscribed_event_name(&event),
                "subscribed_event_name disagrees with the wire event {value}",
            );
            if let Some(events) = page_events
                && !value
                    .field("event")
                    .as_str()
                    .is_some_and(|name| events.iter().any(|e| e == name))
            {
                continue;
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

/// Whether a page relay whose page hears `names` takes `event` into its
/// mailbox: an event it would send (by `subscribed_event_name`), or the
/// wake that ends the stream.
pub(super) fn page_relay_takes(names: &[String], event: &MuxEvent) -> bool {
    matches!(event, MuxEvent::Empty)
        || subscribed_event_name(event).is_some_and(|name| names.iter().any(|n| n == name))
}

/// The `event` name `subscribed_event_json` gives `event` on a coarse stream,
/// read without building it; `None` for the events no subscribe line carries.
/// Every arm names the variant, so a new event cannot skip it.
pub(super) fn subscribed_event_name(event: &MuxEvent) -> Option<&str> {
    Some(match event {
        MuxEvent::SurfaceOutput(_) => "surface-output",
        MuxEvent::SurfaceResized { .. } => "surface-resized",
        MuxEvent::SurfaceResizeFailed { .. } => "surface-resize-failed",
        MuxEvent::SurfaceExited(..) => "surface-exited",
        MuxEvent::SizeStateChanged { .. } => "size-state",
        MuxEvent::TitleChanged { .. } => "title-changed",
        MuxEvent::AgentChanged { .. } => "agent-changed",
        MuxEvent::AgentPresenceChanged { .. } => "agent-presence-changed",
        MuxEvent::Bell(_) => "bell",
        MuxEvent::ProgramStatusChanged { .. } => "program-status-changed",
        MuxEvent::Notification(_) => "notification",
        MuxEvent::GraphicsStatus(_) => "graphics-status",
        MuxEvent::Status(_) => "status",
        MuxEvent::ScreenDeviceChanged(_) => "screen-device-changed",
        MuxEvent::MachineUsageChanged(_) => "machine-usage-changed",
        MuxEvent::ConfigReloadRequested => "config-reload-requested",
        MuxEvent::WindowTitleRequested(_) => "window-title-requested",
        MuxEvent::ScrollChanged { .. } => "scroll-changed",
        MuxEvent::TreeChanged
        | MuxEvent::TreeSelectionChanged(_)
        | MuxEvent::WorkspacePresentationChanged(_)
        | MuxEvent::TreeDelta(_) => "tree-changed",
        MuxEvent::FrontendProjectionChanged { .. } => "frontend-projection-changed",
        MuxEvent::PersonalChanged { .. } => "personal-changed",
        MuxEvent::Conversation(event) => event.wire_name(),
        MuxEvent::CloudConversation(event) => event.wire_name(),
        MuxEvent::BookmarksChanged(_) => "bookmarks-changed",
        MuxEvent::StashChanged { .. } => "stash-changed",
        MuxEvent::HistoryChanged { .. } => "history-changed",
        MuxEvent::FeedViewChanged { .. } => "feed-view-changed",
        MuxEvent::FeedReportsChanged { .. } => "feed-reports-changed",
        MuxEvent::SettingsChanged(_) => "settings-changed",
        MuxEvent::KeybindingsChanged(_) => "keybindings-changed",
        MuxEvent::TerminalRegistryChanged { .. } => "terminal-registry-changed",
        MuxEvent::TerminalReaped { .. } => "terminal-reaped",
        MuxEvent::LayoutChanged(..) => "layout-changed",
        MuxEvent::ClientAttached { .. } => "client-attached",
        MuxEvent::ClientChanged { .. } => "client-changed",
        MuxEvent::ClientDetached(_) => "client-detached",
        MuxEvent::ClientListInvalidated => "client-list-invalidated",
        MuxEvent::PairingRequested(_) => "pairing-requested",
        MuxEvent::PairingResolved { .. } => "pairing-resolved",
        MuxEvent::AgentSessionShareChanged { .. } => "agent-session-share-changed",
        MuxEvent::AppsChanged(payload)
        | MuxEvent::TasksChanged(payload)
        | MuxEvent::ComputerUseActivity(payload)
        | MuxEvent::ComputerUsePreview(payload) => {
            return payload.get("event").and_then(Value::as_str);
        }
        MuxEvent::ChatsChanged { .. } | MuxEvent::GitHubChanged { .. } | MuxEvent::Empty => {
            return None;
        }
    })
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
        // `text` and `activity` are what the tab shows (D2); `title` stays raw
        // for clients from before them, which split the glyphs themselves.
        MuxEvent::TitleChanged { surface, title, shown } => json!({
            "event": "title-changed",
            "surface": surface,
            "title": title.as_ref(),
            "text": shown.text.as_ref(),
            "activity": shown.activity.map(crate::TitleActivity::as_str),
        }),
        MuxEvent::AgentChanged {
            surface,
            terminal_id,
            state,
            source,
            session,
            agent,
            agent_session_id,
            updated_at_ms,
            since_ms,
            last_prompt,
        } => {
            let mut event = json!({
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
            });
            // Optional, never null: an older remote daemon's forwarded event names no terminal.
            if let (Some(terminal_id), Some(fields)) =
                (terminal_id.as_deref(), event.as_object_mut())
            {
                fields.insert("terminal_id".to_owned(), json!(terminal_id));
            }
            event
        }
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
        MuxEvent::ScreenDeviceChanged(screen_device_id) => json!({
            "event": "screen-device-changed",
            "screen_device_id": screen_device_id,
        }),
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
        MuxEvent::TreeSelectionChanged(_) => json!({"event": "tree-changed"}),
        MuxEvent::WorkspacePresentationChanged(_) => json!({"event": "tree-changed"}),
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
        MuxEvent::StashChanged { revision } => json!({
            "event": "stash-changed",
            "revision": revision,
        }),
        MuxEvent::HistoryChanged { revision, kinds } => json!({
            "event": "history-changed",
            "revision": revision,
            "kinds": kinds,
        }),
        MuxEvent::FeedViewChanged { revision, changed } => json!({
            "event": "feed-view-changed",
            "revision": revision,
            "changed": changed.as_ref(),
        }),
        MuxEvent::FeedReportsChanged { revision } => json!({
            "event": "feed-reports-changed",
            "revision": revision,
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
        MuxEvent::AgentSessionShareChanged { session } => json!({
            "event": "agent-session-share-changed",
            "session": session,
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
        MuxEvent::AppsChanged(payload) => payload.as_ref().clone(),
        MuxEvent::TasksChanged(payload) => payload.as_ref().clone(),
        MuxEvent::ComputerUseActivity(payload) | MuxEvent::ComputerUsePreview(payload) => {
            payload.as_ref().clone()
        }
        // The subscribe loop never sends a chat change (apps hear it as `chat.changed`).
        MuxEvent::ChatsChanged { .. } | MuxEvent::GitHubChanged { .. } | MuxEvent::Empty => {
            json!({"event": "empty"})
        }
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

#[cfg(test)]
#[path = "cmd_subscribe_names_tests.rs"]
mod names_tests;
