//! Client sizing state: per-client surface sizes, resize requests and rollback tokens, the shared terminal sizing entries and members, participant ids, and the ClientSizingState bookkeeping.

use super::*;

pub(super) type ClientSurfaceSizes = HashMap<SurfaceId, HashMap<u64, (u16, u16)>>;

pub(super) type SurfaceResizeAcceptance = (bool, Option<u64>);

pub(super) type AppliedClientSize =
    (SurfaceResizeAcceptance, Option<(u16, u16)>, ClientSizeRollback);

pub(super) type SurfaceResizeOutcome = Result<(), Arc<str>>;

pub(super) type SurfaceResizeCompletion = SyncSender<SurfaceResizeOutcome>;

pub(super) struct ClientResizeRequest {
    pub(super) surface: SurfaceId,
    pub(super) client: u64,
    pub(super) requested: (u16, u16),
    pub(super) completion: Option<SurfaceResizeCompletion>,
    pub(super) terminal_runtime: Option<SurfaceId>,
}

pub(super) struct PreparedControlClientResize {
    pub(super) request: ClientResizeRequest,
    pub(super) attached: Option<crate::server::ClientSizeUpdate>,
}

pub(super) enum SurfaceResizeRestore {
    Complete(bool),
    Pending(Receiver<SurfaceResizeOutcome>),
}

#[derive(PartialEq, Eq)]
pub(super) struct ClientSizingRollbackToken {
    pub(super) surface_sizes: Option<HashMap<u64, (u16, u16)>>,
    pub(super) surface_orders: HashMap<u64, u64>,
    pub(super) participating_surface_clients: HashSet<u64>,
    pub(super) uses_excluded_fallback: bool,
}

#[derive(Clone, Copy)]
pub(crate) struct ClientSizeRollback {
    pub(crate) previous_size: Option<(u16, u16)>,
    pub(crate) previous_report_order: Option<u64>,
    pub(crate) previous_geometry: Option<(u16, u16)>,
    pub(crate) applied_report_order: u64,
}

pub(crate) struct ControlClientResize {
    pub accepted: bool,
    pub reservation_id: Option<u64>,
    pub effective_size: Option<(u16, u16)>,
    pub attached: Option<crate::server::ClientSizeUpdate>,
    pub rollback: ClientSizeRollback,
}

#[derive(Default)]
pub(super) struct SurfaceClientSizing {
    pub(super) excluded_clients: HashSet<u64>,
    pub(super) exclusive_client: Option<u64>,
}

/// Shared sizing state of one terminal runtime (one PTY grid). Every client
/// view of every placement of the runtime and every relay sub-view is one
/// participant of `engine`; see `docs/shared-terminal-sizing.md`.
pub(super) struct TerminalSizingEntry {
    pub(super) engine: TerminalSizingEngine,
    /// Placements whose views joined this runtime. Size-state events fan out
    /// to each of them.
    pub(super) placements: BTreeSet<SurfaceId>,
    /// Every participant of `engine`, keyed by participant id.
    pub(super) members: HashMap<String, SizingMember>,
    /// The grid this engine last applied. The engine resizes the PTY only
    /// when its decision changes, so it never fights a resize it did not
    /// make (for example a direct terminal-host renderer).
    pub(super) applied: std::cell::Cell<Option<(u16, u16)>>,
    /// The participants present when `applied` was last decided, to notice
    /// a departure (`Mux::terminal_grid_target`).
    /// Each with whether it is a phone or tablet (only a handheld's
    /// departure holds the grid) and whether it reported a size.
    pub(super) applied_participants:
        std::cell::RefCell<std::collections::BTreeMap<String, terminal_sizing::AppliedSeat>>,
    /// After a phone or tablet departs, the grid does not grow past this size until the
    /// instant passes (`DEPARTED_GRID_HOLD`); it may shrink.
    pub(super) hold: std::cell::Cell<Option<((u16, u16), Instant)>>,
}

/// Which connection and placement one engine participant belongs to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct SizingMember {
    pub(super) client: u64,
    /// The view whose viewport is the participant's: the connection's most
    /// recently active view of the terminal (its geometry view).
    pub(super) placement: SurfaceId,
    /// Every placement of the terminal this participant views: only
    /// `placement`, except under [`ParticipantScheme::PerApp`], where all of a
    /// connection's views of one terminal are leases of one participant.
    pub(super) views: BTreeSet<SurfaceId>,
    /// A view that joined before its first report while the geometry view
    /// had one: it becomes the geometry view with that report, so the
    /// participant never drops to no viewport between attach and report.
    pub(super) joining: Option<SurfaceId>,
    /// Relay sub-view name; `None` for the connection's own view.
    pub(super) view: Option<String>,
}

impl SizingMember {
    pub(super) fn own_view(client: u64, placement: SurfaceId) -> Self {
        Self { client, placement, views: BTreeSet::from([placement]), joining: None, view: None }
    }

    pub(super) fn sub_view(client: u64, placement: SurfaceId, view: &str) -> Self {
        Self {
            client,
            placement,
            views: BTreeSet::from([placement]),
            joining: None,
            view: Some(view.to_string()),
        }
    }

    /// Makes `placement` one of this participant's views and its geometry
    /// view (a view's attach, claim or input is activity).
    pub(super) fn focus_view(&mut self, placement: SurfaceId) {
        self.views.insert(placement);
        self.placement = placement;
        self.joining = None;
    }

    /// Adds a newly attached view. With a report (or when the geometry view
    /// has none) it is the geometry view now; else it is once it reports.
    pub(super) fn join_view(&mut self, placement: SurfaceId, reports: impl Fn(SurfaceId) -> bool) {
        if reports(placement) || !reports(self.placement) {
            self.focus_view(placement);
        } else {
            self.views.insert(placement);
            self.joining = Some(placement);
        }
    }

    /// Notes that `placement` reported: a joining view takes the geometry.
    pub(super) fn note_report(&mut self, placement: SurfaceId) {
        if self.joining == Some(placement) {
            self.focus_view(placement);
        }
    }

    /// The geometry view `placement` released its report: another view with
    /// a report, if any, takes the geometry.
    pub(super) fn yield_geometry(
        &mut self,
        placement: SurfaceId,
        reports: impl Fn(SurfaceId) -> bool,
    ) {
        if self.placement != placement {
            return;
        }
        if let Some(next) =
            self.views.iter().copied().find(|view| *view != placement && reports(*view))
        {
            self.focus_view(next);
        }
    }

    /// Leaves `placement` out of this participant. When it was the geometry
    /// view, the next view with a report (else any view) takes its place.
    /// Returns whether the participant still has a view.
    pub(super) fn leave_view(
        &mut self,
        placement: SurfaceId,
        reports: impl Fn(SurfaceId) -> bool,
    ) -> bool {
        self.views.remove(&placement);
        if self.joining == Some(placement) {
            self.joining = None;
        }
        if self.placement == placement
            && let Some(next) = self
                .views
                .iter()
                .copied()
                .find(|view| reports(*view))
                .or_else(|| self.views.first().copied())
        {
            self.placement = next;
        }
        !self.views.is_empty()
    }
}

/// The daemon feature that makes every view of one connection a lease of one
/// participant per terminal (schemas/features/features.d/terminalSizingPerApp.json).
pub(crate) const PARTICIPANT_PER_APP_FEATURE: &str = "terminalSizingPerApp";

/// How a connection's own views of one terminal map to sizing participants.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum ParticipantScheme {
    /// One participant per (connection, placement): `c<client>`, or
    /// `c<client>@<placement>` for a projected placement.
    #[default]
    PerPlacement,
    /// One participant per (connection, terminal), `c<client>`: an app's
    /// views are leases of one client, as tmux sizes per client and not per
    /// pane. The participant's viewport is its most recently active view's;
    /// its other views crop, pan or scale the grid as another device's do.
    PerApp,
}

impl ParticipantScheme {
    /// From `CMUX_ENABLE_FEATURES` and `CMUX_DISABLE_FEATURES` (disable wins).
    pub(crate) fn from_env() -> Self {
        Self::from_enabled(cmux_features::listed_in_env(PARTICIPANT_PER_APP_FEATURE))
    }

    pub(crate) fn from_enabled(per_app: bool) -> Self {
        if per_app { Self::PerApp } else { Self::PerPlacement }
    }

    /// Host participant id of one client's own view of one terminal placement.
    pub(crate) fn view_participant_id(
        self,
        runtime: SurfaceId,
        placement: SurfaceId,
        client: u64,
    ) -> String {
        match self {
            Self::PerApp => format!("c{client}"),
            Self::PerPlacement if placement == runtime => format!("c{client}"),
            Self::PerPlacement => format!("c{client}@{placement}"),
        }
    }
}

/// Identity of one control connection for the sizing engine.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct ClientSizingIdentity {
    pub(crate) user_id: Option<String>,
    pub(crate) display_name: Option<String>,
    pub(crate) device_kind: TerminalDeviceKind,
    pub(crate) device_name: Option<String>,
    pub(crate) device_id: Option<String>,
    /// A phone's spliced lane (cmux-mobile-host sets it): never one of this
    /// host's own views for the host sizing policy. Never published.
    pub(crate) remote: bool,
}

/// Where a size-state publication goes after the sizing lock is released.
pub(super) struct SizeStatePublication {
    pub(super) scheme: ParticipantScheme,
    pub(super) runtime: SurfaceId,
    pub(super) placements: Vec<SurfaceId>,
    pub(super) state: Arc<TerminalSizingState>,
}

#[derive(Default)]
pub(super) struct ClientSizingState {
    pub(super) surfaces: ClientSurfaceSizes,
    pub(super) report_order: HashMap<(SurfaceId, u64), u64>,
    pub(super) latest_explicit_size: Option<(u64, (u16, u16))>,
    pub(super) next_size_order: u64,
    pub(super) policies: HashMap<SurfaceId, SurfaceClientSizing>,
    pub(super) terminal_runtime_by_placement: HashMap<SurfaceId, SurfaceId>,
    /// Shared sizing engines keyed by terminal runtime id.
    pub(super) terminal_sizing: HashMap<SurfaceId, TerminalSizingEntry>,
    /// Per-terminal policy overrides keyed by terminal runtime id.
    pub(super) terminal_size_policies: HashMap<SurfaceId, TerminalSizingPolicy>,
    /// Workspace default policies for terminals without an override.
    pub(super) workspace_size_policies: HashMap<WorkspaceId, TerminalSizingPolicy>,
    /// Runtimes whose published state changed since the last flush.
    pub(super) pending_size_states: BTreeSet<SurfaceId>,
    /// Own views (connection, placement) someone detached with a view
    /// detach. The connection stays attached; its view is not a participant
    /// until `reattach-view`.
    pub(super) detached_views: HashSet<(u64, SurfaceId)>,
    /// The host sizing policy (`host-size-policy-v1`) from the settings
    /// owner; `None` until the owner read the settings file.
    pub(super) host_policy: Option<host_policy::HostSizePolicy>,
    /// The settings revision `host_policy` was read at.
    pub(super) host_policy_revision: Option<u64>,
    /// How own views map to participants, fixed for the daemon's life.
    pub(super) participant_scheme: ParticipantScheme,
    /// Counts [`Self::visible_terminals`] publications, so an older one never
    /// replaces a newer one (the Kitty share, `mux/kitty_share.rs`).
    pub(super) visibility_publications: u64,
}

pub(super) fn entry_owns(
    sizing: &ClientSizingState,
    runtime: SurfaceId,
    participant: &str,
) -> bool {
    sizing
        .terminal_sizing
        .get(&runtime)
        .is_some_and(|entry| entry.engine.state().owners.iter().any(|owner| owner == participant))
}

/// Host participant id of one relay sub-view.
pub(crate) fn sub_view_participant_id(client: u64, view: &str) -> String {
    format!("c{client}/{view}")
}

impl ClientSizingState {
    pub(super) fn with_scheme(participant_scheme: ParticipantScheme) -> Self {
        Self { participant_scheme, ..Self::default() }
    }

    /// Host participant id of `client`'s own view of `placement`.
    pub(super) fn view_participant_id(
        &self,
        runtime: SurfaceId,
        placement: SurfaceId,
        client: u64,
    ) -> String {
        self.participant_scheme.view_participant_id(runtime, placement, client)
    }

    /// Whether `client` has a retained report for `placement`.
    pub(super) fn has_report(&self, placement: SurfaceId, client: u64) -> bool {
        self.surfaces.get(&placement).is_some_and(|viewers| viewers.contains_key(&client))
    }

    /// `client`'s retained report for `placement` as an engine viewport.
    pub(super) fn view_report(
        &self,
        placement: SurfaceId,
        client: u64,
    ) -> Option<TerminalGridSize> {
        self.surfaces
            .get(&placement)
            .and_then(|viewers| viewers.get(&client))
            .map(|&(cols, rows)| TerminalGridSize::new(cols, rows))
    }

    /// The own-view member that `client`'s view of `placement` belongs to:
    /// its participant's current member, or a new one with only this view.
    pub(super) fn own_view_member(
        &self,
        runtime: SurfaceId,
        placement: SurfaceId,
        client: u64,
    ) -> SizingMember {
        let id = self.view_participant_id(runtime, placement, client);
        self.terminal_sizing
            .get(&runtime)
            .and_then(|entry| entry.members.get(&id))
            .filter(|member| member.view.is_none() && member.client == client)
            .cloned()
            .unwrap_or_else(|| SizingMember::own_view(client, placement))
    }

    pub(super) fn next_size_order(&mut self) -> u64 {
        self.next_size_order = self.next_size_order.wrapping_add(1).max(1);
        self.next_size_order
    }

    pub(super) fn record_explicit_size(&mut self, size: (u16, u16)) {
        let order = self.next_size_order();
        self.latest_explicit_size = Some((order, size));
    }

    pub(super) fn rollback_token(
        &self,
        surface: SurfaceId,
        attached_clients: Option<&HashSet<u64>>,
    ) -> ClientSizingRollbackToken {
        let participating_surface_clients = self
            .surfaces
            .get(&surface)
            .into_iter()
            .flat_map(HashMap::keys)
            .filter(|client| self.client_participates(surface, **client))
            .copied()
            .collect();
        ClientSizingRollbackToken {
            surface_sizes: self.surfaces.get(&surface).cloned(),
            surface_orders: self
                .report_order
                .iter()
                .filter_map(|((reported_surface, client), order)| {
                    (*reported_surface == surface).then_some((*client, *order))
                })
                .collect(),
            participating_surface_clients,
            uses_excluded_fallback: self.uses_excluded_fallback(surface, attached_clients),
        }
    }

    pub(super) fn client_participates(&self, surface: SurfaceId, client: u64) -> bool {
        let Some(policy) = self.policies.get(&surface) else {
            return true;
        };
        policy.exclusive_client.map_or_else(
            || !policy.excluded_clients.contains(&client),
            |exclusive| exclusive == client,
        )
    }

    /// Whether this client's view of `surface` currently sets a dimension of
    /// the runtime's shared grid: its participant is an owner and `surface`
    /// is that participant's geometry view.
    pub(super) fn owns_terminal_geometry(
        &self,
        runtime: SurfaceId,
        surface: SurfaceId,
        client: u64,
    ) -> bool {
        let id = self.view_participant_id(runtime, surface, client);
        self.terminal_sizing.get(&runtime).is_some_and(|entry| {
            entry.engine.state().owners.contains(&id)
                && entry.members.get(&id).is_none_or(|member| member.placement == surface)
        })
    }

    /// Connections whose views or relay sub-views set a dimension of the grid.
    pub(super) fn terminal_owner_clients(&self, runtime: SurfaceId) -> HashSet<u64> {
        let Some(entry) = self.terminal_sizing.get(&runtime) else { return HashSet::new() };
        entry
            .engine
            .state()
            .owners
            .iter()
            .filter_map(|owner| entry.members.get(owner).map(|member| member.client))
            .collect()
    }

    pub(super) fn note_size_state(&mut self, runtime: SurfaceId, changed: bool) {
        if changed {
            self.pending_size_states.insert(runtime);
        }
    }

    /// The terminal runtimes a client's size lease shows now (a live size
    /// report of one of their placements), with this publication's order.
    /// O(reported placements): the panes on screen, not the session.
    pub(super) fn visible_terminals(&mut self) -> (u64, HashSet<SurfaceId>) {
        self.visibility_publications += 1;
        let visible = self
            .surfaces
            .iter()
            .filter(|(_, reporters)| !reporters.is_empty())
            .filter_map(|(placement, _)| self.terminal_runtime_by_placement.get(placement))
            .copied()
            .collect();
        (self.visibility_publications, visible)
    }

    pub(super) fn take_size_state_publications(&mut self) -> Vec<SizeStatePublication> {
        std::mem::take(&mut self.pending_size_states)
            .into_iter()
            .filter_map(|runtime| {
                let entry = self.terminal_sizing.get(&runtime)?;
                Some(SizeStatePublication {
                    scheme: self.participant_scheme,
                    runtime,
                    placements: entry.placements.iter().copied().collect(),
                    state: Arc::new(entry.engine.state().clone()),
                })
            })
            .collect()
    }

    pub(super) fn report_participates(&self, surface: SurfaceId, client: u64) -> bool {
        if let Some(runtime) = self.terminal_runtime_by_placement.get(&surface) {
            return self.owns_terminal_geometry(*runtime, surface, client);
        }
        self.client_participates(surface, client)
    }

    pub(super) fn uses_excluded_fallback(
        &self,
        surface: SurfaceId,
        attached_clients: Option<&HashSet<u64>>,
    ) -> bool {
        let attached_participates = attached_clients.is_some_and(|clients| {
            clients.iter().any(|client| self.client_participates(surface, *client))
        });
        let reporter_participates = self.surfaces.get(&surface).is_some_and(|viewers| {
            viewers.keys().any(|client| self.client_participates(surface, *client))
        });
        !attached_participates && !reporter_participates
    }

    pub(super) fn effective_size(
        &self,
        surface: SurfaceId,
        use_excluded: bool,
    ) -> Option<(u16, u16)> {
        self.surfaces
            .get(&surface)?
            .iter()
            .filter(|(client, _)| use_excluded || self.client_participates(surface, **client))
            .map(|(_, size)| *size)
            .reduce(|smallest, size| (smallest.0.min(size.0), smallest.1.min(size.1)))
    }

    pub(super) fn latest_effective_size(
        &self,
        attached_clients: &HashMap<SurfaceId, HashSet<u64>>,
    ) -> Option<(u64, (u16, u16))> {
        // The default for a newly created surface follows the latest
        // authoritative terminal report or the latest effective browser
        // report. Passive terminal viewports never influence future PTYs.
        // Cache browser fallback once per surface to keep this scan linear.
        let mut fallback_by_surface = HashMap::<SurfaceId, bool>::new();
        let ((surface, reporter), order) = self
            .report_order
            .iter()
            .filter(|((surface, client), _)| {
                let surface = *surface;
                let client = *client;
                if let Some(runtime) = self.terminal_runtime_by_placement.get(&surface) {
                    return self.owns_terminal_geometry(*runtime, surface, client)
                        && self
                            .surfaces
                            .get(&surface)
                            .is_some_and(|viewers| viewers.contains_key(&client));
                }
                let use_excluded = *fallback_by_surface.entry(surface).or_insert_with(|| {
                    self.uses_excluded_fallback(surface, attached_clients.get(&surface))
                });
                self.surfaces.get(&surface).is_some_and(|viewers| viewers.contains_key(&client))
                    && (use_excluded || self.client_participates(surface, client))
            })
            .max_by_key(|(_, order)| *order)
            .map(|(key, order)| (*key, *order))?;
        let size = if self.terminal_runtime_by_placement.contains_key(&surface) {
            self.surfaces.get(&surface).and_then(|viewers| viewers.get(&reporter)).copied()
        } else {
            let use_excluded = fallback_by_surface.get(&surface).copied().unwrap_or_else(|| {
                self.uses_excluded_fallback(surface, attached_clients.get(&surface))
            });
            self.effective_size(surface, use_excluded)
        }?;
        Some((order, size))
    }

    pub(super) fn creation_size(
        &mut self,
        attached_clients: &HashMap<SurfaceId, HashSet<u64>>,
    ) -> Option<(u16, u16)> {
        let report = self.latest_effective_size(attached_clients);
        match (self.latest_explicit_size, report) {
            (Some((explicit_order, explicit)), Some((report_order, _)))
                if explicit_order >= report_order =>
            {
                Some(explicit)
            }
            (_, Some((_, report))) => {
                self.latest_explicit_size = None;
                Some(report)
            }
            (Some((_, explicit)), None) => Some(explicit),
            (None, None) => None,
        }
    }

    pub(super) fn note_applied_report(
        &mut self,
        surface: SurfaceId,
        client: u64,
        attached_clients: &HashSet<u64>,
        effective: Option<(u16, u16)>,
        report_order: u64,
    ) {
        let use_excluded = self.uses_excluded_fallback(surface, Some(attached_clients));
        let contributes = use_excluded || self.client_participates(surface, client);
        if effective.is_some()
            && contributes
            && self
                .latest_explicit_size
                .is_some_and(|(explicit_order, _)| report_order > explicit_order)
        {
            self.latest_explicit_size = None;
        }
    }
}
