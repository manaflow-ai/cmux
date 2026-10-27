//! The daemon side of the stateful request fuzzer (plans/cmux-next/
//! chrome-parity/p10-stability.md, task 176): an in-memory mux whose
//! terminals are in-process surfaces (no PTY, no host process, no child),
//! the ids a request may name, and the layout invariants checked after every
//! request (the same checks as layout_invariants_tests.rs).
//!
//! MojoLPM (Chromium's mojo/public/tools/fuzzers/mojolpm.h) drives a real
//! interface implementation in process with a generated message sequence;
//! this is that implementation's store and its post-message checks.

use std::collections::{BTreeMap, BTreeSet};

use cmux_layout_reducer::check_state;

use super::*;

/// Every id the state names now, by kind. Numbers are the v1 wire ids;
/// `names` are the public ids (workspace, screen, pane, tab, split,
/// terminal) that v1 terminal fields and v2 lines carry.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LiveIds {
    pub workspaces: Vec<u64>,
    pub screens: Vec<u64>,
    pub panes: Vec<u64>,
    pub surfaces: Vec<u64>,
    pub splits: Vec<u64>,
    pub names: Vec<String>,
}

impl Mux {
    /// An in-memory mux whose terminals never start a process.
    pub(crate) fn in_memory_for_fuzz(session: &str) -> anyhow::Result<Arc<Self>> {
        let registry = WorkspaceRegistry::in_memory(session)?;
        Self::from_workspace_registry(
            session.to_owned(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
    }

    /// The ids of everything the state holds now.
    pub(crate) fn fuzz_live_ids(&self) -> LiveIds {
        self.with_state(|state| {
            let indexes = &state.resource_indexes;
            let mut names = BTreeSet::new();
            names.extend(indexes.workspace_ids.values().map(ToString::to_string));
            names.extend(indexes.screen_ids.values().map(ToString::to_string));
            names.extend(indexes.pane_ids.values().map(ToString::to_string));
            names.extend(indexes.tab_ids.values().map(ToString::to_string));
            names.extend(indexes.split_ids.values().map(ToString::to_string));
            names.extend(state.terminal_catalog.keys().map(ToString::to_string));
            LiveIds {
                workspaces: state.workspaces.iter().map(|workspace| workspace.id).collect(),
                screens: state
                    .workspaces
                    .iter()
                    .flat_map(|workspace| workspace.screens.iter().map(|screen| screen.id))
                    .collect(),
                panes: sorted(state.panes.keys().copied()),
                surfaces: sorted(state.surfaces.keys().copied()),
                splits: sorted(indexes.split_ids.keys().copied()),
                names: names.into_iter().collect(),
            }
        })
    }

    /// Every layout invariant (I1-I3 of cmux-layout-reducer) the state
    /// breaks. The fuzzer starts from an empty session, so every state it
    /// reaches must pass the absolute check.
    pub(crate) fn fuzz_layout_violations(&self) -> Vec<String> {
        self.with_state(|state| {
            check_state(&layout_invariants::project(state))
                .iter()
                .map(ToString::to_string)
                .collect()
        })
    }

    /// Where the durable resource topology and memory disagree on the live
    /// panes or on the pane of a live tab. Only meaningful between requests,
    /// when no answer is outstanding.
    pub(crate) fn fuzz_durable_mismatches(&self) -> anyhow::Result<Vec<String>> {
        let topology = self
            .workspace_registry
            .lock()
            .map_err(|_| anyhow::anyhow!("the workspace registry lock is poisoned"))?
            .resource_topology_snapshot()?;
        let durable_tabs = topology
            .tabs
            .iter()
            .map(|tab| (tab.public_id.to_string(), tab.pane_id.to_string()))
            .collect::<BTreeMap<_, _>>();
        let durable_panes =
            topology.panes.iter().map(|pane| pane.public_id.to_string()).collect::<BTreeSet<_>>();
        Ok(self.with_state(|state| {
            let indexes = &state.resource_indexes;
            let mut memory_tabs = BTreeMap::new();
            let mut memory_panes = BTreeSet::new();
            let mut mismatches = Vec::new();
            for (pane_id, pane) in &state.panes {
                let Some(pane_name) = indexes.pane_ids.get(pane_id) else {
                    mismatches.push(format!("pane {pane_id} has no public id"));
                    continue;
                };
                memory_panes.insert(pane_name.to_string());
                for surface in &pane.tabs {
                    match indexes.tab_ids.get(surface) {
                        Some(tab) => {
                            memory_tabs.insert(tab.to_string(), pane_name.to_string());
                        }
                        None => mismatches.push(format!("tab {surface} has no public id")),
                    }
                }
            }
            if memory_tabs != durable_tabs {
                mismatches.push(format!(
                    "durable tab placement {durable_tabs:?} differs from memory {memory_tabs:?}"
                ));
            }
            if memory_panes != durable_panes {
                mismatches.push(format!(
                    "durable panes {durable_panes:?} differ from memory {memory_panes:?}"
                ));
            }
            mismatches
        }))
    }
}

fn sorted(ids: impl Iterator<Item = u64>) -> Vec<u64> {
    let mut ids = ids.collect::<Vec<_>>();
    ids.sort_unstable();
    ids
}
