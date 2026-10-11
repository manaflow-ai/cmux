//! The ordered session: synchronous reads of the [`Session`] plus one ordered
//! worker queue for every UI-originated mutation. This file owns the type, its
//! construction, and the read-side queries; the mutation queue, surface attach,
//! sizing and command wrappers live in the child modules.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use cmux_tui_core::sizing_policy::TerminalSizingPolicy;
use cmux_tui_core::{MuxEvent, SurfaceId};
#[cfg(test)]
use crossbeam_channel::Sender as SyncSender;

#[cfg(test)]
use crate::app::SurfaceAttachAfterObsoleteCheckHook;
use crate::app::{
    AppEvent, MutationImpact, PendingSessionMutation, PendingSessionMutationState,
    RemoteSurfaceAttachExecutor, SessionCompletionAction, SessionEventSender,
    SidebarPluginSyncState, SurfaceAttachClaimState, SurfaceResizeClaimState, SurfaceResizeFailure,
    SurfaceResizeOwnership, SurfaceSyncFailureState, participant_key,
};
use crate::pty_input::PtyInputSender;
use crate::session::{
    AgentInfo, AmbiguousCreation, Session, SurfaceHandle, SurfaceSizeState, TreeView,
};

mod attach;
mod commands;
mod mutations;
mod sizing;

#[derive(Clone, Copy)]
pub(super) enum CreationCompletionKind {
    Surface,
    Browser,
}

impl CreationCompletionKind {
    pub(super) fn completion(self, surface: SurfaceId) -> SessionCompletionAction {
        match self {
            Self::Surface => SessionCompletionAction::SurfaceCreated { surface },
            Self::Browser => SessionCompletionAction::BrowserTabCreated { surface },
        }
    }
}

pub(super) struct PendingAmbiguousCreation {
    pub(super) creation: AmbiguousCreation,
    pub(super) semantic_intent: Option<u64>,
    pub(super) kind: CreationCompletionKind,
    pub(super) label: &'static str,
}

/// Read access stays synchronous, while every UI-originated session mutation
/// enters the same ordered worker as PTY input. Accepted keys, mouse releases,
/// resizes, and closes therefore have one execution order without blocking the
/// event loop.
pub struct OrderedSession {
    pub(super) inner: Session,
    pub(super) operations: PtyInputSender,
    pub(super) events: SessionEventSender,
    pub(super) remote: bool,
    pub(super) pending_mutations: Arc<AtomicUsize>,
    pub(super) pending_pointer_mutations: Arc<AtomicUsize>,
    pub(super) cancellation_pending: Arc<AtomicBool>,
    pub(super) committed_mutation_generation: Arc<AtomicU64>,
    pub(super) pointer_map_generation: Arc<AtomicU64>,
    pub(super) destination_mutation_started: Arc<AtomicU64>,
    pub(super) destination_mutation_committed: Arc<AtomicU64>,
    pub(super) remote_refresh_queued: Arc<AtomicBool>,
    pub(super) remote_background_dirty: Arc<AtomicBool>,
    pub(super) remote_refresh_sequence: Arc<AtomicU64>,
    pub(super) client_refresh_queued: Arc<AtomicBool>,
    client_refresh_dirty: Arc<AtomicBool>,
    pub(super) client_refresh_generation: Arc<AtomicU64>,
    pub(super) surface_resize_claims: Arc<Mutex<HashMap<SurfaceId, SurfaceResizeClaimState>>>,
    pub(super) surface_resize_claim_sequence: Arc<AtomicU64>,
    pub(super) surface_resize_ownership: Arc<Mutex<HashMap<SurfaceId, SurfaceResizeOwnership>>>,
    pub(super) surface_attach_claims: Arc<Mutex<HashMap<SurfaceId, SurfaceAttachClaimState>>>,
    pub(super) surface_attach_failures: Arc<Mutex<HashMap<SurfaceId, SurfaceSyncFailureState>>>,
    pub(super) remote_surface_attaches: Mutex<Option<RemoteSurfaceAttachExecutor>>,
    pub(super) surface_resize_failures: Arc<Mutex<HashMap<SurfaceId, SurfaceResizeFailure>>>,
    pub(super) config_generation: Arc<AtomicU64>,
    pub(super) sidebar_plugin_sync: Arc<Mutex<SidebarPluginSyncState>>,
    pub(super) retired_surfaces: Arc<Mutex<HashSet<SurfaceId>>>,
    pub(super) layout_resize_owner: u64,
    pub(super) layout_resize_transaction: Arc<AtomicU64>,
    pub(super) ambiguous_creations: Arc<Mutex<VecDeque<PendingAmbiguousCreation>>>,
    #[cfg(test)]
    pub(super) surface_attach_after_obsolete_check: SurfaceAttachAfterObsoleteCheckHook,
}

impl OrderedSession {
    #[cfg(test)]
    pub(super) fn new(
        inner: Session,
        operations: PtyInputSender,
        events: SyncSender<AppEvent>,
        layout_resize_owner: u64,
    ) -> Self {
        Self::new_with_event_sender(
            inner,
            operations,
            SessionEventSender::unscoped(events),
            layout_resize_owner,
        )
    }

    pub(super) fn new_with_event_sender(
        inner: Session,
        operations: PtyInputSender,
        events: SessionEventSender,
        layout_resize_owner: u64,
    ) -> Self {
        let remote = matches!(inner, Session::Remote(_));
        Self {
            inner,
            operations,
            events,
            remote,
            pending_mutations: Arc::new(AtomicUsize::new(0)),
            pending_pointer_mutations: Arc::new(AtomicUsize::new(0)),
            cancellation_pending: Arc::new(AtomicBool::new(false)),
            committed_mutation_generation: Arc::new(AtomicU64::new(0)),
            pointer_map_generation: Arc::new(AtomicU64::new(0)),
            destination_mutation_started: Arc::new(AtomicU64::new(0)),
            destination_mutation_committed: Arc::new(AtomicU64::new(0)),
            remote_refresh_queued: Arc::new(AtomicBool::new(false)),
            remote_background_dirty: Arc::new(AtomicBool::new(false)),
            remote_refresh_sequence: Arc::new(AtomicU64::new(0)),
            client_refresh_queued: Arc::new(AtomicBool::new(false)),
            client_refresh_dirty: Arc::new(AtomicBool::new(false)),
            client_refresh_generation: Arc::new(AtomicU64::new(0)),
            surface_resize_claims: Arc::new(Mutex::new(HashMap::new())),
            surface_resize_claim_sequence: Arc::new(AtomicU64::new(0)),
            surface_resize_ownership: Arc::new(Mutex::new(HashMap::new())),
            surface_attach_claims: Arc::new(Mutex::new(HashMap::new())),
            surface_attach_failures: Arc::new(Mutex::new(HashMap::new())),
            remote_surface_attaches: Mutex::new(None),
            surface_resize_failures: Arc::new(Mutex::new(HashMap::new())),
            config_generation: Arc::new(AtomicU64::new(0)),
            sidebar_plugin_sync: Arc::new(Mutex::new(SidebarPluginSyncState::default())),
            retired_surfaces: Arc::new(Mutex::new(HashSet::new())),
            layout_resize_owner,
            layout_resize_transaction: Arc::new(AtomicU64::new(1)),
            ambiguous_creations: Arc::new(Mutex::new(VecDeque::new())),
            #[cfg(test)]
            surface_attach_after_obsolete_check: Arc::new(Mutex::new(None)),
        }
    }

    pub(super) fn supports_tab_workspace_moves(&self) -> bool {
        self.inner.supports_tab_workspace_moves()
    }

    pub(super) fn supports_clear_history_key_fallback(&self, surface: SurfaceId) -> bool {
        self.inner.supports_clear_history_key_fallback(surface)
    }

    pub(super) fn retire_surface_input(&self, surface: SurfaceId) {
        self.operations.retire_surface(surface);
    }

    pub(super) fn pending_mutation_with_impact(
        &self,
        impact: MutationImpact,
    ) -> PendingSessionMutation {
        self.pending_mutation_for_semantic_intent(impact, None)
    }

    pub(super) fn pending_mutation_for_semantic_intent(
        &self,
        impact: MutationImpact,
        semantic_intent: Option<u64>,
    ) -> PendingSessionMutation {
        self.pending_mutations.fetch_add(1, Ordering::AcqRel);
        if impact.blocks_pointer() {
            self.pending_pointer_mutations.fetch_add(1, Ordering::AcqRel);
            self.pointer_map_generation.fetch_add(1, Ordering::AcqRel);
        }
        PendingSessionMutation(Arc::new(PendingSessionMutationState {
            events: self.events.clone(),
            pending_mutations: self.pending_mutations.clone(),
            pending_pointer_mutations: self.pending_pointer_mutations.clone(),
            impact,
            semantic_intent,
            cancellation_pending: self.cancellation_pending.clone(),
            settled: AtomicBool::new(false),
            deferred_outcome: Mutex::new(None),
            canceled_outcome: Mutex::new(None),
        }))
    }

    pub(super) fn tree(&self) -> TreeView {
        self.inner.tree()
    }

    pub(super) fn report_focus(
        &self,
        previous: Option<crate::session::ClientFocus>,
        focus: crate::session::ClientFocus,
        client_id: Option<&str>,
    ) {
        self.inner.report_focus(previous, focus, client_id);
    }

    pub(super) fn client_focus(&self, client_id: &str) -> Option<crate::session::ClientFocus> {
        self.inner.client_focus(client_id)
    }

    pub(super) fn agents(&self) -> Vec<AgentInfo> {
        self.inner.agents()
    }

    pub(super) fn respond_pairing(&self, request: u64, approve: bool) -> anyhow::Result<()> {
        self.inner.respond_pairing(request, approve)
    }

    /// Fetch the daemon's machine spend readout off the UI thread and feed
    /// it back as a `MachineUsageChanged` event. The event is scoped to this
    /// session generation, so a late answer from a replaced session is
    /// dropped. A failed read is silent: the readout is informational and
    /// the next `machine-usage-changed` event corrects it.
    pub(super) fn refresh_machine_usage_background(&self) {
        let session = self.inner.clone();
        let events = self.events.clone();
        let spawn =
            std::thread::Builder::new().name("machine-usage-refresh".into()).spawn(move || {
                match session.machine_usage() {
                    Ok(usage) => {
                        let _ = events.send(AppEvent::Mux(MuxEvent::MachineUsageChanged(usage)));
                    }
                    Err(error) => {
                        crate::client_log::log("DEBUG", "machine-usage", &error.to_string());
                    }
                }
            });
        if let Err(error) = spawn {
            crate::client_log::log("DEBUG", "machine-usage", &error.to_string());
        }
    }

    pub(super) fn refresh_clients_background(&self) {
        self.client_refresh_generation.fetch_add(1, Ordering::AcqRel);
        self.client_refresh_dirty.store(true, Ordering::Release);
        if self.client_refresh_queued.swap(true, Ordering::AcqRel) {
            return;
        }
        let session = self.inner.clone();
        let events = self.events.clone();
        let queued = self.client_refresh_queued.clone();
        let dirty = self.client_refresh_dirty.clone();
        let generation = self.client_refresh_generation.clone();
        let spawn =
            std::thread::Builder::new().name("client-list-refresh".into()).spawn(move || {
                loop {
                    dirty.store(false, Ordering::Release);
                    let request_generation = generation.load(Ordering::Acquire);
                    let result = session.clients().map_err(|error| error.to_string());
                    if request_generation != generation.load(Ordering::Acquire) {
                        continue;
                    }
                    if events
                        .send(AppEvent::ClientsUpdated { generation: request_generation, result })
                        .is_err()
                    {
                        queued.store(false, Ordering::Release);
                        break;
                    }
                    if dirty.swap(false, Ordering::AcqRel) {
                        continue;
                    }
                    queued.store(false, Ordering::Release);
                    // Close the race where an event marked the list dirty while
                    // this worker still owned the queued claim.
                    if dirty.swap(false, Ordering::AcqRel) && !queued.swap(true, Ordering::AcqRel) {
                        continue;
                    }
                    break;
                }
            });
        if let Err(error) = spawn {
            self.client_refresh_queued.store(false, Ordering::Release);
            let generation = self.client_refresh_generation.load(Ordering::Acquire);
            let _ = self
                .events
                .send(AppEvent::ClientsUpdated { generation, result: Err(error.to_string()) });
        }
    }

    pub(super) fn client_refresh_generation(&self) -> u64 {
        self.client_refresh_generation.load(Ordering::Acquire)
    }

    pub(super) fn set_client_sizing(&self, surface: SurfaceId, client: u64, enabled: bool) {
        self.enqueue_client_sizing_mutation(
            "set client sizing",
            ("set client sizing", surface, client),
            move |session| session.set_client_sizing(surface, client, enabled, false),
        );
    }

    pub(super) fn use_only_client_sizing(&self, surface: SurfaceId, client: u64) {
        self.enqueue_client_sizing_mutation(
            "use only client sizing",
            ("use only client sizing", surface, 0),
            move |session| session.use_only_client_sizing(surface, client),
        );
    }

    pub(super) fn claim_terminal_geometry(&self, surface: SurfaceId) {
        if matches!(&self.inner, Session::Local(_)) && !self.inner.has_surface(surface) {
            // A local authoritative tree can be replaced while an earlier
            // placement is being retired. Do not enqueue a geometry mutation
            // for a surface the local mux already knows is gone.
            return;
        }
        self.enqueue_client_sizing_mutation(
            "claim terminal geometry",
            ("claim terminal geometry", surface, 0),
            move |session| session.claim_terminal_geometry(surface),
        );
    }

    pub(super) fn use_all_client_sizing(&self, surface: SurfaceId) {
        self.enqueue_client_sizing_mutation(
            "use all client sizing",
            ("use all client sizing", surface, 0),
            move |session| session.use_all_client_sizing(surface),
        );
    }

    pub(super) fn size_state(&self, surface: SurfaceId) -> Option<SurfaceSizeState> {
        self.inner.size_state(surface)
    }

    pub(super) fn set_size_policy(&self, surface: SurfaceId, policy: TerminalSizingPolicy) {
        self.enqueue_client_sizing_mutation(
            "set size policy",
            ("set size policy", surface, 0),
            move |session| session.set_size_policy(surface, policy),
        );
    }

    pub(super) fn set_size_counts(
        &self,
        surface: SurfaceId,
        participant: String,
        counts: Option<bool>,
    ) {
        self.enqueue_client_sizing_mutation(
            "set size counts",
            ("set size counts", surface, participant_key(&participant)),
            move |session| session.set_size_counts(surface, &participant, counts),
        );
    }

    pub(super) fn disconnect_size_participant(&self, surface: SurfaceId, participant: String) {
        self.enqueue_coalescing_pointer_mutation(
            "disconnect participant",
            ("disconnect participant", participant_key(&participant)),
            move |session| match session.disconnect_size_participant(surface, &participant) {
                // The menu is a snapshot; a participant that already left is done.
                Err(error) if error.to_string().contains("unknown participant") => Ok(()),
                result => result,
            },
        );
    }

    pub(super) fn disconnect_client(&self, client: u64) {
        self.enqueue_coalescing_pointer_mutation(
            "disconnect client",
            ("disconnect client", client),
            move |session| match session.disconnect_client(client) {
                Err(error) if error.to_string().contains(&format!("unknown client {client}")) => {
                    // The menu is a snapshot. A peer can disappear before activation, which
                    // makes this an already-completed detach rather than a session failure.
                    Ok(())
                }
                result => result,
            },
        );
    }

    pub(crate) fn surface(&self, id: SurfaceId) -> Option<SurfaceHandle> {
        self.inner.cached_surface(id)
    }

    pub(super) fn has_surface(&self, id: SurfaceId) -> bool {
        self.inner.has_surface(id)
    }

    pub(super) fn surface_is_ready_for_input(&self, id: SurfaceId) -> bool {
        // Remote attach caches its mirror before the initial VT state arrives.
        // The claim outlives that initialization, so cache presence alone is not readiness.
        self.has_surface(id) && !self.surface_attach_claims.lock().unwrap().contains_key(&id)
    }

    pub(super) fn has_surface_size_report(&self, id: SurfaceId) -> bool {
        self.inner.has_surface_size_report(id)
    }

    pub(super) fn terminal_geometry_claim_ready(&self, id: SurfaceId) -> bool {
        if !self.remote {
            return self.has_surface(id);
        }
        // A remote mirror is inserted before attach-surface settles. The
        // server can make this client exclusive only after the attach claim
        // has completed and its initial size lease exists.
        self.surface_is_ready_for_input(id) && self.has_surface_size_report(id)
    }

    pub(super) fn invalidate_surface_size_report(&self, id: SurfaceId) {
        self.inner.invalidate_surface_size_report(id);
    }

    pub(super) fn surface_overflow_retry_due(&self) -> bool {
        self.inner.surface_overflow_retry_due()
    }

    pub(super) fn forget_surface(&self, id: SurfaceId) {
        if self.remote {
            let mut retired_surfaces = self.retired_surfaces.lock().unwrap();
            let mut attach_claims = self.surface_attach_claims.lock().unwrap();
            retired_surfaces.insert(id);
            if let Some(claim) = attach_claims.get_mut(&id) {
                claim.retired = true;
            }
        }
        self.surface_attach_failures.lock().unwrap().remove(&id);
        self.surface_resize_failures.lock().unwrap().remove(&id);
        self.surface_resize_ownership.lock().unwrap().remove(&id);
        self.inner.forget_surface(id);
    }

    pub(super) fn invalidate_remote_tree(&self) {
        self.inner.invalidate_remote_tree();
    }

    pub(super) fn clear_surface_sync_failures(&self) {
        self.surface_attach_failures
            .lock()
            .unwrap()
            .retain(|_, failure| failure.sticky_until_reconnect);
        self.surface_resize_failures.lock().unwrap().clear();
    }

    pub(super) fn begin_shutdown(&self) {
        self.ambiguous_creations.lock().unwrap().clear();
        if let Some(executor) = self.remote_surface_attaches.lock().unwrap().as_ref() {
            executor.shutdown();
        }
        self.inner.begin_shutdown();
    }

    pub(super) fn daemon_shutdown_requested(&self) -> bool {
        self.inner.daemon_shutdown_requested()
    }

    /// The first reason recorded when a remote transport reader stopped, or
    /// `None` for local sessions and deliberate local disconnects.
    pub(super) fn transport_disconnect_reason(&self) -> Option<String> {
        self.inner.transport_disconnect_reason()
    }
}
