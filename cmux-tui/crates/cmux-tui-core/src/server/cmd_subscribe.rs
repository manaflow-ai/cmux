//! Event subscription command handlers: subscribe (tree events and surface
//! output streams) and subscribe-activity, plus the JSON for every
//! subscribed mux event and the overflow notice. Each handler is one
//! `Command` arm of `handle_command_with_cancellation`.

use super::MessageWriter;
use super::OPEN_DEVICE_KINDS_CAPABILITY;
use super::SHARED_SIZING_CAPABILITY;
use super::SizeStateReader;
use super::attach_lifecycle::attach_pump::{AttachDrain, AttachPump, PumpTimer, Turn};
use super::machine_usage_json;
use super::sequenced_pool::SequencePriority;
use super::size_state_event_json;
use super::tree_delta_json;
use crate::GraphicsStatus;
use crate::Mux;
use crate::MuxEvent;
use crate::SurfaceId;
use crate::event_bus::MuxEventKind;
use crate::event_bus::MuxEventKinds;
use crate::panic_free::JsonFields;
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
        (None, None)
            if matches!(
                super::origin_gate::connection_actor(mux, client),
                crate::workspace_registry::Actor::Frontend { .. }
            ) =>
        {
            mux.subscribe_frontend()
        }
        (None, None) => mux.subscribe(),
    };
    // The verified app's visible surfaces scope its own session streams (`frontend.visibility.set`);
    // a stream of one surface is that surface's view, never scoped.
    if surface.is_none() {
        super::frontend_visibility::follow(mux, client, &events);
    }
    #[cfg(test)]
    let probe = mux.control_clients.subscribe_probe(client);
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
    // `diagnostic-sites-v1`: the daemon's diagnostic sites, to the person's
    // own local app only. Read after `events` subscribed, so a site noted in
    // between comes twice rather than never (the app keeps one).
    let diagnostic_client = trusted_pairing_client
        && page_events.is_none()
        && mux.control_clients.supports_capability(client, super::DIAGNOSTIC_SITES_CAPABILITY);
    let seen_sites = if diagnostic_client { mux.diagnostic_sites.snapshot() } else { Vec::new() };
    let writer = writer.clone();
    // Its events share the reply FIFO (spec/transports.md "Reply and event order").
    let outbound_stream = writer.start_control_stream(&subscription_overflow_json())?;
    let pairings = pending_pairings.into_iter().map(|challenge| {
        json!({
            "event": "pairing-requested",
            "request": challenge.id,
            "code": challenge.code,
            "peer": challenge.peer,
            "expires_in": challenge.expires_in,
        })
    });
    let sites =
        seen_sites.into_iter().map(|site| subscribed_event_json(&MuxEvent::DiagnosticSite(site)));
    let filter = SubscribeFilter {
        mux: mux.clone(),
        client,
        interest,
        page_events,
        trusted_pairing_client,
        conversation_client,
        tree_deltas,
        caused_events,
        diagnostic_client,
        #[cfg(test)]
        probe,
    };
    // No thread: a drain on the pool, woken by the bus, the writer's room
    // and the close of the writer or the stream, as the
    // attach streams' pump (server/attach_pump.rs).
    let pump = AttachPump::new(&mux.sequenced_pool, SequencePriority::Control);
    writer.register_interrupt(pump.stop());
    outbound_stream.register_interrupt(pump.stop());
    outbound_stream.on_space(pump.hook());
    events.on_ready(pump.hook());
    pump.install(Box::new(SubscriptionDrain {
        filter,
        events,
        writer,
        stream: outbound_stream,
        initial: pairings.chain(sites).collect(),
        transport_overflow: false,
    }));
    pump.start().map_err(|error| anyhow::anyhow!("subscribe could not start: {error}"))?;
    Ok(json!({}))
}

/// Events a subscription takes from its bus in one turn before it yields
/// its worker to the other sequences.
const SUBSCRIPTION_TURN_EVENTS: usize = 64;

/// What one subscription sends: the connection's filters and capabilities,
/// read once at `subscribe`.
struct SubscribeFilter {
    mux: Arc<Mux>,
    client: u64,
    interest: Option<MuxEventKinds>,
    page_events: Option<&'static [String]>,
    trusted_pairing_client: bool,
    conversation_client: bool,
    tree_deltas: bool,
    caused_events: bool,
    diagnostic_client: bool,
    #[cfg(test)]
    probe: Arc<SubscribeProbe>,
}

impl SubscribeFilter {
    /// The JSON of `event` for this subscription, or `None` when it does
    /// not go to it.
    fn render(&self, event: &MuxEvent, cause: crate::event_cause::EventCause) -> Option<Value> {
        #[cfg(test)]
        self.probe.received.note(event);
        // A surface stream is not filtered on the bus: drop an unwanted
        // kind before any JSON is built.
        if self.interest.is_some_and(|kinds| !kinds.accepts(event)) {
            return None;
        }
        #[cfg(test)]
        self.probe.rendered.note(event);
        let mut value = match event {
            MuxEvent::PairingRequested(_) | MuxEvent::PairingResolved { .. }
                if !self.trusted_pairing_client =>
            {
                return None;
            }
            // A draft goes only to a trusted local connection that asked
            // for drafts in set-client-info (the admission of
            // `conversation.events`; old clients never see the event).
            MuxEvent::Conversation(event) if event.is_draft() => {
                let wanted = self.conversation_client
                    && self.mux.control_clients.supports_capability(
                        self.client,
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
                    _ => return None,
                }
            }
            MuxEvent::Conversation(_) if !self.conversation_client => {
                return None;
            }
            // A participant's own list state (a pin, a "marked unread")
            // goes only to connections that act as that participant.
            MuxEvent::Conversation(event)
                if matches!(
                    event.as_ref(),
                    crate::conversation_store::ConversationEvent::Inbox { participant, .. }
                        if *participant != self.mux.conversation_principal(self.client)
                ) =>
            {
                return None;
            }
            // A run's steps go only to a connection that asked for runs in
            // set-client-info (`conversation-runs-v1`): old clients never
            // see the event, and its steps can be large.
            MuxEvent::Conversation(event)
                if event.is_run()
                    && !self.mux.control_clients.supports_capability(
                        self.client,
                        super::conversation_runs::CONVERSATION_RUNS_CAPABILITY,
                    ) =>
            {
                return None;
            }
            // A Chief's live frames only to a connection that asked for
            // them in set-client-info (`chief-live-v1`).
            MuxEvent::Conversation(event)
                if event.is_live()
                    && !self.mux.control_clients.supports_capability(
                        self.client,
                        super::conversation_live::CHIEF_LIVE_CAPABILITY,
                    ) =>
            {
                return None;
            }
            // An avatar change only to a connection that asked for it in
            // set-client-info (`participant-avatars-v1`).
            MuxEvent::Conversation(event)
                if event.is_avatar()
                    && !self.mux.control_clients.supports_capability(
                        self.client,
                        super::participant_avatars::PARTICIPANT_AVATARS_CAPABILITY,
                    ) =>
            {
                return None;
            }
            // A Chief change only to the person's own connection that
            // asked for it in set-client-info (`chief-events-v1`): never
            // to a bound agent, which chief.profile.list may refuse.
            MuxEvent::Conversation(event)
                if event.is_chief()
                    && (self.mux.conversation_principal(self.client)
                        != crate::conversation_store::LOCAL_USER
                        || !self.mux.control_clients.supports_capability(
                            self.client,
                            super::chief_registry_resource::CHIEF_EVENTS_CAPABILITY,
                        )) =>
            {
                return None;
            }
            // The person's own clients: Unix, or an authenticated page
            // (`ws-cloud-conversations-v1`); `delivers` narrows it to the lease's.
            // The host replica's renewal only to the verified app: it holds the install token.
            MuxEvent::CloudConversation(event)
                if host_replica_needed(event)
                    && !matches!(
                        super::origin_gate::connection_actor(&self.mux, self.client),
                        crate::workspace_registry::Actor::Frontend { .. }
                    ) =>
            {
                return None;
            }
            MuxEvent::CloudConversation(_) if !self.conversation_client => {
                return None;
            }
            MuxEvent::CloudConversation(event)
                if !host_replica_needed(event)
                    && !super::cloud_conversations::delivers(&self.mux, self.client) =>
            {
                return None;
            }
            // A Cloud Chief's run change, like a local one, only to a
            // connection that asked for runs (`conversation-runs-v1`).
            MuxEvent::CloudConversation(event)
                if matches!(
                    event.as_ref(),
                    crate::cloud_conversations::CloudEvent::RunChanged { .. }
                ) && !self.mux.control_clients.supports_capability(
                    self.client,
                    super::conversation_runs::CONVERSATION_RUNS_CAPABILITY,
                ) =>
            {
                return None;
            }
            // A Cloud Chief's live frame only to a connection that asked
            // for live frames (`chief-live-v1`).
            MuxEvent::CloudConversation(event)
                if matches!(
                    event.as_ref(),
                    crate::cloud_conversations::CloudEvent::Live { .. }
                ) && !self.mux.control_clients.supports_capability(
                    self.client,
                    super::conversation_live::CHIEF_LIVE_CAPABILITY,
                ) =>
            {
                return None;
            }
            // Typing in a Cloud conversation only to a connection that
            // asked for it (`cloud-conversation-typing-v1`).
            MuxEvent::CloudConversation(event)
                if matches!(
                    event.as_ref(),
                    crate::cloud_conversations::CloudEvent::Typing { .. }
                ) && !self.mux.control_clients.supports_capability(
                    self.client,
                    super::cloud_conversations::CLOUD_TYPING_CAPABILITY,
                ) =>
            {
                return None;
            }
            MuxEvent::DiagnosticSite(_) if !self.diagnostic_client => return None,
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
            MuxEvent::TreeDelta(delta) if self.tree_deltas => tree_delta_json(delta, &self.mux),
            MuxEvent::TreeDelta(_) => json!({"event": "tree-changed"}),
            MuxEvent::TreeSelectionChanged if self.tree_deltas => {
                json!({"event": "tree-changed"})
            }
            MuxEvent::TreeSelectionChanged => return None,
            MuxEvent::SizeStateChanged { surface, runtime, state } => {
                if !self
                    .mux
                    .control_clients
                    .supports_capability(self.client, SHARED_SIZING_CAPABILITY)
                {
                    return None;
                }
                let open = self
                    .mux
                    .control_clients
                    .supports_capability(self.client, OPEN_DEVICE_KINDS_CAPABILITY);
                let reader = SizeStateReader {
                    client: self.client,
                    open,
                    scheme: self.mux.participant_scheme(),
                };
                size_state_event_json(*surface, *runtime, state, Some(reader))
            }
            _ => subscribed_event_json(event),
        };
        if let Some(events) = self.page_events
            && !value.field("event").as_str().is_some_and(|name| events.iter().any(|e| e == name))
        {
            return None;
        }
        if self.caused_events {
            stamp_cause(&mut value, cause);
        }
        Some(value)
    }
}

/// A subscription's drain on its pump's sequence: the pending pairings and
/// sites first, then the bus, at most one event past the stream's
/// backpressure cap.
struct SubscriptionDrain {
    filter: SubscribeFilter,
    events: crate::event_bus::MuxEventReceiver,
    writer: MessageWriter,
    stream: super::OutboundStream,
    initial: std::collections::VecDeque<Value>,
    transport_overflow: bool,
}

impl SubscriptionDrain {
    /// The subscription ends: an overflow says so before the stream ends.
    fn end(&mut self) -> Turn {
        if self.events.overflowed() || self.transport_overflow {
            let _ = self.writer.send_terminal(&subscription_overflow_json(), &self.stream);
        }
        Turn::Done
    }
}

impl AttachDrain for SubscriptionDrain {
    fn turn(&mut self, _timer: &PumpTimer<'_>) -> Turn {
        for _ in 0..SUBSCRIPTION_TURN_EVENTS {
            if !self.writer.is_open() || !self.stream.is_open() {
                return self.end();
            }
            if !self.writer.sink.stream_has_room(&self.stream) {
                return Turn::Idle;
            }
            let value = match self.initial.pop_front() {
                Some(value) => value,
                // Rendered from the event every subscriber shares, never copied.
                None => match self.events.try_recv_shared() {
                    Ok((event, cause)) => match self.filter.render(&event, cause) {
                        Some(value) => value,
                        None => continue,
                    },
                    Err(std::sync::mpsc::TryRecvError::Empty) => return Turn::Idle,
                    Err(std::sync::mpsc::TryRecvError::Disconnected) => return self.end(),
                },
            };
            if let Err(error) = self.writer.send_stream(&value, &self.stream) {
                self.transport_overflow = error.kind() == std::io::ErrorKind::WouldBlock;
                return self.end();
            }
        }
        Turn::Yield
    }
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
        "server-diagnostic-site" => Kind::DiagnosticSite,
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
        MuxEvent::DiagnosticSite(site) => {
            let mut payload = site.fields();
            payload.insert("event", json!("server-diagnostic-site"));
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
