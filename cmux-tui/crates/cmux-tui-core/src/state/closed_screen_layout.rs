//! Reopen a closed screen in the splits it had (Leo 2026-10-19: "reopening
//! tabs/workspaces doesn't restore their layouts"). A closed screen record
//! carries its split tree (`layout`, pane ids), each pane's tabs and
//! selected tab (`panes`), and its focused and zoomed pane. Reopen rebuilds
//! the tree with ordinary tab moves: a split is made by creating the first
//! tab of its second side in the pane and moving it to that edge of the
//! pane at the recorded share, then each side is built in its own pane. No
//! extra shell is spawned and closed (a close would record history), and
//! every tab is made from its full record. A pane with no tab left (a stash
//! kept them) drops out with its split. A stack comes back as one pane
//! with all its tabs. Records without a layout reopen as before.

use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;

use anyhow::Context;
use serde_json::Value;

use crate::mux::*;
use crate::{Actor, PaneId, SurfaceId};

/// The split tree of a closed screen, with its tabs (indexes into the
/// screen record's `tabs`).
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Shape {
    Leaf {
        /// The closed pane ids this pane stands for (a stack's every pane).
        panes: Vec<String>,
        tabs: Vec<usize>,
        /// The selected tab's index in `tabs` (kept tabs only).
        active: usize,
    },
    Split {
        edge: TabDropEdge,
        /// The second side's share.
        share: f32,
        first: Box<Shape>,
        second: Box<Shape>,
    },
}

impl Shape {
    /// The shape of closed screen record `screen`; None when it has no
    /// layout (an older record) or no tab in it.
    pub(super) fn of(screen: &Value) -> Option<Self> {
        let panes = screen["panes"].as_object()?;
        let count = screen["tabs"].as_array()?.len();
        let mut shape = Self::node(&screen["layout"], panes, count)?;
        // A tab of a pane the tree does not name joins the first pane.
        let mut placed = HashSet::new();
        shape.each_tab(&mut |tab| {
            placed.insert(tab);
        });
        let mut rest = (0..count).filter(|tab| !placed.contains(tab)).peekable();
        if rest.peek().is_some()
            && let Self::Leaf { tabs, .. } = shape.first_leaf_mut()
        {
            tabs.extend(rest);
        }
        Some(shape)
    }

    fn node(node: &Value, panes: &serde_json::Map<String, Value>, count: usize) -> Option<Self> {
        let tabs_of = |pane: &str| {
            panes
                .get(pane)
                .and_then(|entry| entry["tabs"].as_array())
                .into_iter()
                .flatten()
                .filter_map(Value::as_u64)
                .filter_map(|tab| usize::try_from(tab).ok())
                .filter(|tab| *tab < count)
                .collect::<Vec<_>>()
        };
        let active_of = |pane: &str| {
            panes
                .get(pane)
                .and_then(|entry| entry["active"].as_u64())
                .and_then(|active| usize::try_from(active).ok())
                .unwrap_or(0)
        };
        match node["kind"].as_str()? {
            "leaf" => {
                let pane = node["pane"].as_str()?;
                let tabs = tabs_of(pane);
                let active = active_of(pane).min(tabs.len().saturating_sub(1));
                (!tabs.is_empty()).then(|| Self::Leaf {
                    panes: vec![pane.to_string()],
                    tabs,
                    active,
                })
            }
            "stack" => {
                let expanded = node["expanded"].as_str();
                let mut ids = Vec::new();
                let mut tabs = Vec::new();
                let mut active = 0;
                for pane in node["panes"].as_array()?.iter().filter_map(Value::as_str) {
                    if Some(pane) == expanded {
                        active = tabs.len() + active_of(pane);
                    }
                    ids.push(pane.to_string());
                    tabs.extend(tabs_of(pane));
                }
                let active = active.min(tabs.len().saturating_sub(1));
                (!tabs.is_empty()).then_some(Self::Leaf { panes: ids, tabs, active })
            }
            "split" => {
                let first = Self::node(&node["first"], panes, count);
                let second = Self::node(&node["second"], panes, count);
                match (first, second) {
                    (Some(first), Some(second)) => {
                        let edge = if node["direction"] == "down" {
                            TabDropEdge::Bottom
                        } else {
                            TabDropEdge::Right
                        };
                        let ratio = node["ratio"].as_f64().unwrap_or(0.5) as f32;
                        Some(Self::Split {
                            edge,
                            share: (1.0 - ratio).clamp(0.05, 0.95),
                            first: Box::new(first),
                            second: Box::new(second),
                        })
                    }
                    (first, second) => first.or(second),
                }
            }
            _ => None,
        }
    }

    fn each_tab(&self, visit: &mut impl FnMut(usize)) {
        match self {
            Self::Leaf { tabs, .. } => tabs.iter().copied().for_each(visit),
            Self::Split { first, second, .. } => {
                first.each_tab(visit);
                second.each_tab(visit);
            }
        }
    }

    fn first_leaf_mut(&mut self) -> &mut Self {
        match self {
            Self::Leaf { .. } => self,
            Self::Split { first, .. } => first.first_leaf_mut(),
        }
    }

    /// The first tab of the first pane (`node` never makes a leaf without one).
    fn first_tab(&self) -> anyhow::Result<usize> {
        match self {
            Self::Leaf { tabs, .. } => tabs.first().copied().context("a closed pane has no tab"),
            Self::Split { first, .. } => first.first_tab(),
        }
    }
}

/// A rebuilt screen: each record's index with the tab made from it, in
/// record order, and the pane to focus.
type Rebuilt = (Vec<(usize, SurfaceId)>, Option<PaneId>);

/// A rebuild in progress: the closed screen's tab records and the tabs
/// made from them so far.
struct Build<'a> {
    actor: &'a Actor,
    tabs: &'a [Value],
    /// Each record index's tab, once made.
    made: BTreeMap<usize, SurfaceId>,
    /// Each rebuilt pane: (pane, its tabs in order, selected index, the
    /// closed pane ids it stands for).
    leaves: Vec<(PaneId, Vec<usize>, usize, Vec<String>)>,
}

impl Build<'_> {
    /// Merge rebuilt panes that ended up the same pane (a split that failed
    /// built both sides in it) into one strip: earlier tabs first, the
    /// earlier selection.
    fn join_shared_panes(&mut self) {
        let mut joined: Vec<(PaneId, Vec<usize>, usize, Vec<String>)> = Vec::new();
        for (pane, tabs, active, panes) in self.leaves.drain(..) {
            if let Some(entry) = joined.iter_mut().find(|entry| entry.0 == pane) {
                entry.1.extend(tabs);
                entry.3.extend(panes);
            } else {
                joined.push((pane, tabs, active, panes));
            }
        }
        self.leaves = joined;
    }
}

impl Mux {
    /// Rebuild closed screen `screen` as `shape`, starting from its fresh
    /// screen whose only tab is `first` (`reused`: the record `first`
    /// stands for, when it reused one). Answers each record's index with
    /// the tab made from it, in record order, and the pane to focus.
    #[track_caller]
    pub(super) fn rebuild_screen(
        self: &Arc<Self>,
        actor: &Actor,
        first: SurfaceId,
        reused: Option<usize>,
        screen: &Value,
        shape: &Shape,
    ) -> anyhow::Result<Rebuilt> {
        let pane =
            self.with_state(|state| state.pane_of(first)).context("new screen has no pane")?;
        let tabs = screen["tabs"].as_array().map(Vec::as_slice).unwrap_or_default();
        let mut build = Build { actor, tabs, made: BTreeMap::new(), leaves: Vec::new() };
        if let Some(reused) = reused {
            build.made.insert(reused, first);
        }
        self.build_shape(&mut build, shape, pane)?;
        build.join_shared_panes();
        // Every tab in its strip place, then each pane's selected tab.
        for (pane, order, active, _) in &build.leaves {
            for (index, tab) in order.iter().enumerate() {
                let Some(&surface) = build.made.get(tab) else { continue };
                let placed = self.with_state(|state| {
                    state.panes.get(pane).and_then(|pane| pane.tabs.get(index).copied())
                });
                if placed != Some(surface) {
                    self.move_tab_as(actor, surface, *pane, index);
                }
            }
            if let Some(&surface) = order.get(*active).and_then(|tab| build.made.get(tab)) {
                let index = self.with_state(|state| {
                    state.panes.get(pane)?.tabs.iter().position(|tab| *tab == surface)
                });
                self.select_tab_as(actor, Some(*pane), index, None);
            }
        }
        let pane_of = |closed: &str| {
            build
                .leaves
                .iter()
                .find(|(_, _, _, panes)| panes.iter().any(|pane| pane == closed))
                .map(|(pane, ..)| *pane)
        };
        if let Some(zoomed) = screen["zoomed_pane"].as_str().and_then(pane_of)
            && let Err(error) = self.zoom_pane_as(actor, Some(zoomed), ZoomMode::On)
        {
            eprintln!("cmux-tui: a reopened screen could not zoom its pane again: {error:#}");
        }
        // The splits were rebuilt with undoable moves; undo must not fold them back.
        self.forget_layout_undo(pane);
        // A focused pane a stash emptied: focus stays where the last selection left it.
        let focus = screen["active_pane"].as_str().and_then(pane_of);
        if let Some(focus) = focus {
            self.focus_pane_as(actor, focus);
        }
        let made = build.made.into_iter().collect();
        Ok((made, focus))
    }

    /// Make the tab of record `tab` in `pane`: the reused first tab is moved
    /// there (it already exists), any other is created.
    #[track_caller]
    fn make_tab(
        self: &Arc<Self>,
        build: &mut Build<'_>,
        tab: usize,
        pane: PaneId,
    ) -> anyhow::Result<SurfaceId> {
        if let Some(&surface) = build.made.get(&tab) {
            if self.with_state(|state| state.pane_of(surface)) != Some(pane) {
                let end = self.with_state(|state| state.panes.get(&pane).map(|p| p.tabs.len()));
                self.move_tab_as(build.actor, surface, pane, end.unwrap_or(0));
            }
            return Ok(surface);
        }
        let record = build.tabs.get(tab).context("a layout tab is not in its screen record")?;
        let surface = self.reopen_tab_record(build.actor, pane, record, false)?;
        build.made.insert(tab, surface);
        Ok(surface)
    }

    /// Build `shape` in `pane`, which covers exactly the area of `shape`.
    #[track_caller]
    fn build_shape(
        self: &Arc<Self>,
        build: &mut Build<'_>,
        shape: &Shape,
        pane: PaneId,
    ) -> anyhow::Result<()> {
        match shape {
            Shape::Leaf { panes, tabs, active } => {
                for tab in tabs {
                    self.make_tab(build, *tab, pane)?;
                }
                build.leaves.push((pane, tabs.clone(), *active, panes.clone()));
                Ok(())
            }
            Shape::Split { edge, share, first, second } => {
                let moved = second.first_tab()?;
                // A split moves a tab out, so the pane must keep another:
                // when its only tab is the reused one that moves, the first
                // side's first tab is made before.
                let alone = self.with_state(|state| {
                    let tabs = &state.panes.get(&pane)?.tabs;
                    Some(matches!(tabs.as_slice(), [only] if build.made.get(&moved) == Some(only)))
                });
                if alone == Some(true) {
                    self.make_tab(build, first.first_tab()?, pane)?;
                }
                let surface = self.make_tab(build, moved, pane)?;
                match self.move_tab_to_split_as(
                    build.actor,
                    surface,
                    pane,
                    *edge,
                    Some(*share),
                    false,
                    None,
                ) {
                    Ok(outcome) => {
                        self.build_shape(build, first, pane)?;
                        self.build_shape(build, second, outcome.pane)
                    }
                    // The tabs stay in this pane rather than not reopening.
                    // Both sides join this pane as one strip, first side first.
                    Err(error) => {
                        eprintln!("cmux-tui: a reopened screen could not split again: {error:#}");
                        self.build_shape(build, first, pane)?;
                        self.build_shape(build, second, pane)
                    }
                }
            }
        }
    }
}
