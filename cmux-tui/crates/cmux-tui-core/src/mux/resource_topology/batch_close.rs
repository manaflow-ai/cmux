//! Batch closes: many tabs, or one pane, screen, workspace, or tab group,
//! plus the terminals the close ends, in one durable commit.
//!
//! Closing views one command at a time costs one journal fsync per view.
//! `close-tabs` and the container closes with `end_terminals` plan every
//! removal on one clone of the live state, project it once, and commit the
//! resource tombstones, the legacy workspace ledger, and the terminal host
//! tombstones in one SQLite transaction. Hosts are signaled only after that
//! commit, through the same parallel exit pool as `close-terminal`.
//!
//! With `end_terminals`, a terminal ends when every one of its views is in
//! the closed set and it is not marked `keep`. A terminal still shown in
//! another tab, or kept, is left running with its remaining views (or none,
//! for a kept one), exactly as a plain close leaves it.

use super::*;
use crate::workspace_registry::TopologyCloseCommit;

/// What one batch close removes.
pub(crate) enum BatchCloseTarget {
    /// These tab placements, in any panes and workspaces.
    Tabs(Vec<SurfaceId>),
    Pane(PaneId),
    Screen(ScreenId),
    Workspace(WorkspaceId),
    /// Every member placement of this tab group; the group row is removed in
    /// the same commit.
    TabGroup(String),
}

pub(crate) struct BatchCloseRequest<'a> {
    pub target: BatchCloseTarget,
    pub end_terminals: bool,
    pub operation: &'a str,
    pub fingerprint: &'a Value,
    pub mutation: &'a WorkspaceMutation,
    pub expected_generation: Option<&'a str>,
    /// Legacy workspace revision guard, checked when a workspace closes.
    pub expected_workspace_revision: Option<u64>,
    /// Hold the provider workspace authority (workspace lifecycle closes).
    pub authorize_workspace: bool,
}

/// A terminal the batch close ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct EndedTerminal {
    pub terminal_id: String,
    pub terminal_incarnation: Option<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct BatchCloseOutcome {
    /// The committed (or replayed) result: `closed` surfaces and `terminals`.
    pub result: Value,
    pub resource_revision: u64,
    pub workspace_revision: Option<u64>,
    pub replayed: bool,
}

impl BatchCloseOutcome {
    pub(crate) fn closed(&self) -> Vec<SurfaceId> {
        self.result["closed"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_u64)
            .collect()
    }

    pub(crate) fn terminals(&self) -> Vec<EndedTerminal> {
        self.result["terminals"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|terminal| {
                Some(EndedTerminal {
                    terminal_id: terminal["terminal_id"].as_str()?.to_string(),
                    terminal_incarnation: terminal["terminal_incarnation"]
                        .as_str()
                        .map(str::to_string),
                })
            })
            .collect()
    }
}

impl Mux {
    /// Plan, commit, and apply one batch close. Nothing changes unless the
    /// whole set commits; an unknown target changes nothing.
    pub(crate) fn commit_batch_close(
        &self,
        request: BatchCloseRequest<'_>,
    ) -> anyhow::Result<BatchCloseOutcome> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let _creation_fence = self.resource_creation_execution.lock().unwrap();
        let _authority = request
            .authorize_workspace
            .then(|| {
                self.authorize_workspace_lifecycle_mutation(
                    WorkspaceMutationAuthority::Ordinary,
                    "close",
                )
            })
            .transpose()?;
        // A retry of a committed close replays before its targets resolve:
        // they are gone by then.
        if let Some(replay) = self.workspace_registry.lock().unwrap().replay_resource_patch(
            request.mutation,
            request.operation,
            request.fingerprint,
        )? {
            return Ok(BatchCloseOutcome {
                result: replay.result,
                resource_revision: replay.revision,
                workspace_revision: None,
                replayed: true,
            });
        }
        let workspace = self.with_state(|state| match &request.target {
            BatchCloseTarget::Tabs(_) | BatchCloseTarget::TabGroup(_) => None,
            BatchCloseTarget::Pane(pane) => state
                .screen_of(*pane)
                .map(|(workspace, _)| state.workspaces[workspace].id),
            BatchCloseTarget::Screen(screen) => state
                .workspaces
                .iter()
                .find(|workspace| workspace.screens.iter().any(|item| item.id == *screen))
                .map(|workspace| workspace.id),
            BatchCloseTarget::Workspace(workspace) => {
                state.workspace_index(*workspace).map(|_| *workspace)
            }
        });
        if matches!(
            request.target,
            BatchCloseTarget::Pane(_) | BatchCloseTarget::Screen(_) | BatchCloseTarget::Workspace(_)
        ) && workspace.is_none()
        {
            anyhow::bail!("close target disappeared");
        }
        let lifecycle = workspace.map(|workspace| self.workspace_lifecycle(workspace));
        let workspace_lifecycle = lifecycle.as_ref().map(|lifecycle| lifecycle.lock().unwrap());
        let notifications = self.tree_decorations();
        let mut registry = self.workspace_registry.lock().unwrap();
        let mut state = self.state.lock().unwrap();

        let mut tab_groups = None;
        let mut plan = match &request.target {
            BatchCloseTarget::Tabs(surfaces) => self.tabs_close_plan_locked(surfaces, &state)?,
            BatchCloseTarget::TabGroup(group) => {
                let mut groups = self.presentation_snapshot().tab_groups.clone();
                let members = tab_groups::take_tab_group(&state, &mut groups, group)?;
                tab_groups = Some(groups);
                self.tabs_close_plan_locked(&members, &state)?
            }
            BatchCloseTarget::Pane(pane) => self.resource_close_plan_locked(
                ResourceOperation::PaneClose,
                batch_slots(workspace, None, Some(*pane)),
                &registry,
                &state,
                &notifications,
            )?,
            BatchCloseTarget::Screen(screen) => self.resource_close_plan_locked(
                ResourceOperation::ScreenClose,
                batch_slots(workspace, Some(*screen), None),
                &registry,
                &state,
                &notifications,
            )?,
            BatchCloseTarget::Workspace(_) => self.resource_close_plan_locked(
                ResourceOperation::WorkspaceClose,
                batch_slots(workspace, None, None),
                &registry,
                &state,
                &notifications,
            )?,
        };
        let closed = plan.removed.iter().map(|surface| surface.id).collect::<Vec<_>>();
        let (ended_runtimes, ended_ids, ended) = if request.end_terminals {
            self.end_unplaced_terminals_locked(&mut plan, &registry)?
        } else {
            (Vec::new(), Vec::new(), Vec::new())
        };
        let mut result = json!({
            "closed": closed,
            "terminals": ended.iter().map(|terminal| json!({
                "terminal_id": terminal.terminal_id,
                "terminal_incarnation": terminal.terminal_incarnation,
            })).collect::<Vec<_>>(),
        });
        if let Some(close) = plan.workspace_close.as_ref()
            && let Some(fields) = close.legacy_result.as_object()
        {
            for (key, value) in fields {
                result[key] = value.clone();
            }
        }
        let projection =
            self.resource_effect_projection_locked(&registry, &mut plan.state, json!({}))?;
        let committed: TopologyCloseCommit = registry.commit_topology_close(
            request.mutation,
            request.operation,
            request.fingerprint,
            request.expected_generation,
            request.expected_workspace_revision,
            &projection.patch,
            &result,
            &projection.changes,
            &plan.terminal_batch,
            plan.workspace_close.as_ref(),
            tab_groups.as_ref(),
        )?;
        if committed.resource.replayed {
            state.resource_revision = state.resource_revision.max(committed.resource.revision);
            return Ok(BatchCloseOutcome {
                result: committed.resource.result,
                resource_revision: committed.resource.revision,
                workspace_revision: None,
                replayed: true,
            });
        }
        let mut effects =
            plan.install(&mut state, committed.resource.revision, committed.workspace_revision);
        drop(state);
        if committed.terminal_batch.closed != 0 {
            self.emit_terminal_registry_changed(&registry, committed.terminal_batch.revision);
        }
        if tab_groups.is_some() {
            self.reload_presentation(&registry)?;
        }
        if matches!(
            &effects.tree_publication,
            ResourceCloseTreePublication::PendingDelta(delta)
                if delta.workspace_revision.is_some()
        ) {
            let ResourceCloseTreePublication::PendingDelta(delta) = std::mem::replace(
                &mut effects.tree_publication,
                ResourceCloseTreePublication::Published,
            ) else {
                unreachable!("revisioned workspace close publication was checked above");
            };
            self.emit_committed_workspace_delta(&registry, delta, effects.selection_resync);
        }
        drop(registry);
        drop(workspace_lifecycle);
        drop(_creation_fence);
        drop(_creation_handoff);
        let outcome = BatchCloseOutcome {
            result: committed.resource.result.clone(),
            resource_revision: committed.resource.revision,
            workspace_revision: committed.workspace_revision,
            replayed: false,
        };
        self.finish_resource_close(CommittedResourceClose { commit: committed.resource, effects });
        self.notify_terminal_exit_waiters(ended_ids);
        for runtime in ended_runtimes {
            self.purge_terminal_runtime_side_tables(&runtime);
            self.terminate_terminal_runtime(&runtime);
        }
        Ok(outcome)
    }

    /// Remove `surfaces` from a clone of the live state. Every surface must
    /// be a placed tab; duplicates are ignored.
    fn tabs_close_plan_locked(
        &self,
        surfaces: &[SurfaceId],
        state: &State,
    ) -> anyhow::Result<ResourceClosePlan> {
        let mut unique = HashSet::with_capacity(surfaces.len());
        let surfaces = surfaces
            .iter()
            .copied()
            .filter(|surface| unique.insert(*surface))
            .collect::<Vec<_>>();
        anyhow::ensure!(!surfaces.is_empty(), "close-tabs needs at least one surface");
        for surface in &surfaces {
            anyhow::ensure!(
                state.surfaces.contains_key(surface) && state.pane_of(*surface).is_some(),
                "unknown surface {surface}"
            );
        }
        let selection_before = active_tree_selection(state);
        let changed_screens = unique_screen_ids(
            surfaces.iter().filter_map(|surface| surface_screen_id(state, *surface)),
        );
        let removed = surfaces
            .iter()
            .filter_map(|surface| state.surfaces.get(surface).cloned())
            .collect::<Vec<_>>();
        let mut projected = state.clone();
        let mut split_index_changed = false;
        for surface in &surfaces {
            let (_, changed) = remove_surface(self, &mut projected, *surface);
            anyhow::ensure!(
                projected.pane_of(*surface).is_none(),
                "close target surface {surface} remained attached"
            );
            split_index_changed |= changed;
        }
        if split_index_changed {
            Self::rebuild_split_screen_index(&mut projected);
        }
        let selection_resync = selection_before != active_tree_selection(&projected);
        Ok(ResourceClosePlan {
            state: projected,
            removed,
            terminal_runtime: None,
            closed_terminal_public_id: None,
            terminal_batch: Vec::new(),
            workspace_close: None,
            delta: None,
            changed_screens,
            selection_resync,
        })
    }

    /// End every terminal whose views all left in `plan` and that is not
    /// kept: drop its catalog runtime from the planned state and add its
    /// host to the plan's terminal batch.
    #[allow(clippy::type_complexity)]
    fn end_unplaced_terminals_locked(
        &self,
        plan: &mut ResourceClosePlan,
        registry: &WorkspaceRegistry,
    ) -> anyhow::Result<(Vec<Arc<Surface>>, Vec<TerminalPublicId>, Vec<EndedTerminal>)> {
        let mut seen = HashSet::new();
        let candidates = plan
            .removed
            .iter()
            .filter_map(|view| view.terminal_public_id().cloned())
            .filter(|terminal| seen.insert(terminal.clone()))
            .collect::<Vec<_>>();
        let mut runtimes = Vec::new();
        let mut public_ids = Vec::new();
        let mut ended = Vec::new();
        for public_id in candidates {
            let Some(runtime) = plan.state.terminal_catalog.get(&public_id).cloned() else {
                continue;
            };
            let content_id = ContentPublicId::Terminal(public_id.clone());
            let still_placed = !plan.state.placements_of_content(&content_id).is_empty()
                || plan.state.surfaces.values().any(|view| view.shares_terminal_runtime(&runtime));
            if still_placed {
                continue;
            }
            let Some(host) = self.resource_terminal_host_identity(&runtime) else { continue };
            if registry.terminal_keep(&host.terminal_id)? {
                continue;
            }
            let incarnation = registry
                .terminal_record(&host.terminal_id)?
                .with_context(|| format!("terminal {public_id} has no durable receipt"))?
                .incarnation;
            let (removed_runtime, views, _) =
                remove_terminal_content_from_state(self, &mut plan.state, &public_id);
            anyhow::ensure!(views.is_empty(), "ended terminal {public_id} kept a view");
            if let Some(removed_runtime) = removed_runtime {
                runtimes.push(removed_runtime);
            }
            plan.terminal_batch.push((host.terminal_id.clone(), incarnation.clone()));
            public_ids.push(public_id);
            ended.push(EndedTerminal {
                terminal_id: host.terminal_id,
                terminal_incarnation: incarnation,
            });
        }
        Ok((runtimes, public_ids, ended))
    }
}

impl Mux {
    /// `close-tabs`: close these tab placements in one commit.
    pub(crate) fn close_tabs(
        &self,
        surfaces: Vec<SurfaceId>,
        end_terminals: bool,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<BatchCloseOutcome> {
        let fingerprint = json!({
            "op": "close-tabs",
            "surfaces": surfaces,
            "end_terminals": end_terminals,
        });
        self.commit_batch_close(BatchCloseRequest {
            target: BatchCloseTarget::Tabs(surfaces),
            end_terminals,
            operation: "tabs.close",
            fingerprint: &fingerprint,
            mutation,
            expected_generation: None,
            expected_workspace_revision: None,
            authorize_workspace: false,
        })
    }

    /// `close-pane`, `close-screen`, or `close-tab-group` with
    /// `end_terminals`: the container and the terminals it ends, one commit.
    pub(crate) fn close_container_ending_terminals(
        &self,
        target: BatchCloseTarget,
    ) -> anyhow::Result<BatchCloseOutcome> {
        let (operation, fingerprint) = match &target {
            BatchCloseTarget::Pane(pane) => ("pane.close", json!({"op":"close-pane","pane":pane})),
            BatchCloseTarget::Screen(screen) => {
                ("screen.close", json!({"op":"close-screen","screen":screen}))
            }
            BatchCloseTarget::TabGroup(group) => {
                ("tab.group.close", json!({"op":"close-tab-group","group":group}))
            }
            BatchCloseTarget::Tabs(_) | BatchCloseTarget::Workspace(_) => {
                anyhow::bail!("not a container close target")
            }
        };
        let fingerprint = json!({"target": fingerprint, "end_terminals": true});
        let mutation = WorkspaceMutation::local("cmux-tui");
        self.commit_batch_close(BatchCloseRequest {
            target,
            end_terminals: true,
            operation,
            fingerprint: &fingerprint,
            mutation: &mutation,
            expected_generation: None,
            expected_workspace_revision: None,
            authorize_workspace: false,
        })
    }

    /// `close-workspace` with `end_terminals`. Same selectors, guards, and
    /// replay as `close-workspace`, plus the ended terminals in the commit.
    pub(crate) fn close_workspace_ending_terminals(
        &self,
        target: Option<WorkspaceId>,
        requested_key: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<(WorkspaceMutationResult, BatchCloseOutcome)> {
        let fingerprint = json!({
            "op": "close-workspace",
            "workspace": target,
            "key": requested_key,
            "end_terminals": true,
        });
        let resolved = {
            let state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            let index = resolve_workspace_index(&state, target, requested_key)?;
            state.workspaces[index].id
        };
        let outcome = self.commit_batch_close(BatchCloseRequest {
            target: BatchCloseTarget::Workspace(resolved),
            end_terminals: true,
            operation: "workspace.close",
            fingerprint: &fingerprint,
            mutation,
            expected_generation,
            expected_workspace_revision: expected_revision,
            authorize_workspace: true,
        })?;
        let revision = match outcome.workspace_revision {
            Some(revision) => revision,
            None => self
                .workspace_registry
                .lock()
                .unwrap()
                .replay(mutation, &fingerprint)?
                .context("replayed workspace close has no workspace receipt")?
                .revision,
        };
        let result = WorkspaceMutationResult {
            workspace: outcome.result["workspace"].as_u64().or(Some(resolved)),
            key: outcome.result["key"]
                .as_str()
                .context("workspace close result is missing its key")?
                .to_string(),
            index: outcome.result["index"].as_u64().and_then(|index| usize::try_from(index).ok()),
            revision,
            replayed: outcome.replayed,
            changed: true,
        };
        Ok((result, outcome))
    }
}

fn batch_slots(
    workspace: Option<WorkspaceId>,
    screen: Option<ScreenId>,
    pane: Option<PaneId>,
) -> EffectSlots {
    EffectSlots { workspace, screen, pane, tab: None, terminal: None }
}
