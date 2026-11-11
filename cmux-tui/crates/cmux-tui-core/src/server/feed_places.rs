//! Where a feed item happened, by the names the person sees
//! (plans/cmux-next/feed-page.md section 2, a row's `who` and `where`): the
//! workspace, the tab and the tab's agent harness, resolved from the item's
//! context ids against this daemon's workspaces and tabs.
//!
//! The tab is the first of `context.tab` (a `tab_…` public id or a surface
//! id), `context.terminal` (a `term_…` terminal shown in a tab) and
//! `context.acp_session` (the agent chat tab bound to that acpmux session)
//! that resolves. The workspace is the one holding that tab, else
//! `context.workspace` (a `ws_…` public id or a workspace id). Nothing
//! found (another machine's item) names nothing, and the row falls back to
//! what the poster declared.
//!
//! The feed client takes one [`PlaceIndex`] per read before it locks its
//! own state, so the cost is one pass over the tabs per read, never per
//! item, and no store lock is held under the feed's. Taking it reads the
//! presentation snapshot (an `Arc` clone), then the session `state` lock for
//! the ids; the names and titles are read after `state` is released.

use std::collections::HashMap;
use std::sync::Arc;

use cmux_feed_core::client::{FeedItem, Place};

use super::Mux;
use crate::Surface;
use crate::feed_client::Places;
use crate::resource::ContentPublicId;
use crate::state::conversation_tabs_store::ConversationTabRecord;

/// One tab as a row names it.
struct TabPlace {
    workspace: Option<usize>,
    title: String,
    harness: Option<String>,
}

/// One read's lookup of item places (module docs).
#[derive(Default)]
pub(crate) struct PlaceIndex {
    /// Workspace display names.
    workspaces: Vec<String>,
    /// `ws_…` public id and workspace id -> index into `workspaces`.
    workspace_ids: HashMap<String, usize>,
    tabs: Vec<TabPlace>,
    /// `tab_…` public id and surface id -> index into `tabs`.
    tab_ids: HashMap<String, usize>,
    /// `term_…` terminal public id -> the first tab showing it.
    terminals: HashMap<String, usize>,
    /// acpmux session -> the agent chat tab bound to it.
    sessions: HashMap<String, usize>,
}

impl PlaceIndex {
    pub(crate) fn place(&self, item: &FeedItem) -> Option<Place> {
        let lookup = |key: &str, ids: &HashMap<String, usize>| {
            item.context_str(key).and_then(|id| ids.get(id)).copied()
        };
        let tab = lookup("tab", &self.tab_ids)
            .or_else(|| lookup("terminal", &self.terminals))
            .or_else(|| lookup("acp_session", &self.sessions))
            .and_then(|index| self.tabs.get(index));
        let workspace = tab
            .and_then(|tab| tab.workspace)
            .or_else(|| lookup("workspace", &self.workspace_ids))
            .and_then(|index| self.workspaces.get(index).cloned());
        if tab.is_none() && workspace.is_none() {
            return None;
        }
        Some(Place::with_harness(
            tab.and_then(|tab| tab.harness.as_deref()),
            workspace,
            tab.map(|tab| tab.title.clone()),
        ))
    }
}

/// The title the tab bar shows: the person's name for it, else the
/// terminal's or page's own title.
fn tab_title(surface: &Surface) -> String {
    surface.name().filter(|name| !name.is_empty()).unwrap_or_else(|| surface.title())
}

impl Mux {
    /// The feed client's per-read place lookup (module docs).
    pub(super) fn feed_places(&self) -> Places {
        let index = self.place_index();
        Box::new(move |item| index.place(item))
    }

    pub(crate) fn place_index(&self) -> PlaceIndex {
        let presentation = self.presentation_snapshot();
        let mut index = PlaceIndex::default();
        // Ids only under `state`; surface names and titles take their own
        // locks, after it is released.
        let placed: Vec<(Arc<Surface>, String, u64, Option<usize>)> = self.with_state(|state| {
            for (position, workspace) in state.workspaces.iter().enumerate() {
                let display = presentation
                    .workspaces
                    .get(&workspace.key)
                    .and_then(|record| record.title.clone())
                    .filter(|title| !title.is_empty())
                    .unwrap_or_else(|| workspace.name.clone());
                index.workspaces.push(display);
                index.workspace_ids.insert(workspace.public_id.as_str().to_owned(), position);
                index.workspace_ids.insert(workspace.id.to_string(), position);
            }
            state
                .resource_indexes
                .tab_ids
                .iter()
                .filter_map(|(surface, tab)| {
                    let runtime = state.surfaces.get(surface)?;
                    let workspace = state
                        .pane_of(*surface)
                        .and_then(|pane| state.screen_of(pane))
                        .map(|(workspace, _)| workspace);
                    Some((Arc::clone(runtime), tab.as_str().to_owned(), *surface, workspace))
                })
                .collect()
        });
        // The same order every read: a terminal shown in two tabs names the
        // first by workspace, then by creation.
        let mut placed = placed;
        placed.sort_by_key(|(_, _, surface, workspace)| (*workspace, *surface));
        for (surface, tab_id, surface_id, workspace) in placed {
            let position = index.tabs.len();
            let mut harness = None;
            match surface.resource_identity().map(|identity| &identity.content_id) {
                Some(ContentPublicId::Browser(browser)) => {
                    if let Some(ConversationTabRecord::AgentSession {
                        session,
                        harness: kind,
                        ..
                    }) = presentation.conversation_tabs.get(browser.as_str())
                    {
                        harness.clone_from(kind);
                        if let Some(session) = session {
                            index.sessions.entry(session.clone()).or_insert(position);
                        }
                    }
                }
                Some(ContentPublicId::Terminal(terminal)) => {
                    index.terminals.entry(terminal.as_str().to_owned()).or_insert(position);
                }
                None => {}
            }
            if let Some(terminal) = surface.terminal_public_id() {
                index.terminals.entry(terminal.as_str().to_owned()).or_insert(position);
            }
            index.tab_ids.insert(tab_id, position);
            index.tab_ids.insert(surface_id.to_string(), position);
            index.tabs.push(TabPlace { workspace, title: tab_title(&surface), harness });
        }
        index
    }
}

#[cfg(test)]
#[path = "feed_places_tests.rs"]
mod tests;
