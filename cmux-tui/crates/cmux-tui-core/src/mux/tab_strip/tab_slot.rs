//! The strip index a tab created in an existing pane takes, so a creation
//! that restores a tab's old place (Reopen Closed, cx-d1xb8) adds the tab
//! there in one change: one `tab-added` at that index, and no
//! create-at-the-end-then-move that a client animates across the strip.
//!
//! The creator runs inside [`scoped`]; the tab creation into that pane takes
//! the index once ([`take_for`]) and carries it to its effect as the
//! internal [`INDEX_FIELD`], which is stored with the effect's intent, so a
//! creation resumed after a restart lands at the same index.
//!
//! A creation can also name the tab it goes right after ([`after_index`],
//! `tab-insert-after-v1` and `frontend-browser-insert-after-v1`): the effect
//! carries that tab, and the index is read from the strip in the same state
//! critical section that inserts the tab, so a tab added or closed meanwhile
//! never shifts it.

use std::cell::Cell;
use std::sync::Arc;

use serde_json::{Map, Value};

use super::StripRequest;
use crate::mux::{Mux, pane_tab_groups};
use crate::workspace_registry::PresentationSnapshot;
use crate::{Actor, PaneId, State, SurfaceId};

/// Internal `tab.create_terminal` and `tab.create_browser` field (never
/// accepted from a v2 client; the catalog refuses unknown fields): the index
/// of its pane's strip the created tab takes, clamped to the strip's end.
pub(crate) const INDEX_FIELD: &str = "tab_insert_index";

/// Advertised by `identify` once `new-tab` and `new-conversation-tab` take
/// `after`: the new tab lands right after that tab of its pane, in the
/// creating commit.
pub(crate) const TAB_INSERT_AFTER_CAPABILITY: &str = "tab-insert-after-v1";

/// Internal `tab.create_terminal` field (never accepted from a v2 client):
/// the surface the created tab goes right after ([`after_index`]). Stored
/// with the effect's intent, so a resumed creation finds the same slot.
pub(crate) const AFTER_FIELD: &str = "tab_insert_after";

thread_local! {
    static SCOPED: Cell<Option<(PaneId, usize)>> = const { Cell::new(None) };
}

/// Restores the slot that was set before [`scoped`].
struct Restore(Option<(PaneId, usize)>);

impl Drop for Restore {
    fn drop(&mut self) {
        SCOPED.with(|slot| slot.set(self.0));
    }
}

/// Run `create` with the next tab created in `pane` taking strip `index`.
pub(crate) fn scoped<T>(pane: PaneId, index: usize, create: impl FnOnce() -> T) -> T {
    let _restore = Restore(SCOPED.with(|slot| slot.replace(Some((pane, index)))));
    create()
}

/// The index a tab created now in `pane` takes, once: a second creation in
/// the same scope (or one in another pane) appends as usual.
pub(crate) fn take_for(pane: PaneId) -> Option<usize> {
    SCOPED.with(|slot| match slot.get() {
        Some((scoped, index)) if scoped == pane => {
            slot.set(None);
            Some(index)
        }
        _ => None,
    })
}

/// The index a tab created now in `pane` would take, left in place.
pub(crate) fn peek_for(pane: PaneId) -> Option<usize> {
    SCOPED.with(|slot| slot.get().and_then(|(scoped, index)| (scoped == pane).then_some(index)))
}

/// Put the scoped index of a creation in `pane` into its effect `fields`.
pub(crate) fn insert_field(fields: &mut Map<String, Value>, pane: Option<PaneId>) {
    if let Some(index) = pane.and_then(take_for) {
        fields
            .insert(INDEX_FIELD.to_string(), Value::from(u64::try_from(index).unwrap_or(u64::MAX)));
    }
}

/// The [`INDEX_FIELD`] of an effect.
pub(crate) fn effect_index(fields: &Map<String, Value>) -> Option<usize> {
    fields.get(INDEX_FIELD).and_then(Value::as_u64).and_then(|index| usize::try_from(index).ok())
}

/// Where a tab with `index` lands in a strip of `len` tabs: that index,
/// clamped to the end; the end without one.
pub(crate) fn slot(index: Option<usize>, len: usize) -> usize {
    index.map_or(len, |index| index.min(len))
}

/// The [`AFTER_FIELD`] of an effect.
pub(crate) fn effect_after(fields: &Map<String, Value>) -> Option<SurfaceId> {
    fields.get(AFTER_FIELD).and_then(Value::as_u64)
}

/// The index of `pane`'s strip a new tab takes: right after `after` when it
/// is a tab of the pane, else `None` (the caller appends). A slot inside a
/// tab group's run moves to the end of that run, so the still ungrouped tab
/// never splits a group; one that joins the group ([`after_group`]) then
/// moves into its slot.
pub(crate) fn after_index(
    state: &State,
    presentation: &PresentationSnapshot,
    pane: PaneId,
    after: Option<SurfaceId>,
) -> Option<usize> {
    let after = after?;
    let tabs = &state.panes.get(&pane)?.tabs;
    let slot = tabs.iter().position(|tab| *tab == after)? + 1;
    let inside_group = pane_tab_groups(state, presentation, pane)
        .into_iter()
        .find(|run| run.start < slot && slot < run.start + run.members.len());
    Some(inside_group.map_or(slot, |run| run.start + run.members.len()))
}

/// The tab group `after` belongs to in `pane`, and the index inside the
/// group right after it: where a tab put after it joins, as Chrome groups a
/// tab with the grouped tab it opens next to (cx-d0d.55).
pub(crate) fn after_group(
    state: &State,
    presentation: &PresentationSnapshot,
    pane: PaneId,
    after: Option<SurfaceId>,
) -> Option<(String, usize)> {
    let after = after?;
    pane_tab_groups(state, presentation, pane).into_iter().find_map(|run| {
        let index = run.members.iter().position(|member| *member == after)?;
        Some((run.group.id, index + 1))
    })
}

impl Mux {
    /// Put `added`, a tab created right after a grouped tab, into that
    /// group at the index [`after_group`] found. A failed join leaves the
    /// tab ungrouped after the group's run.
    pub(crate) fn join_after_group(self: &Arc<Self>, added: SurfaceId, joins: (String, usize)) {
        let (group, index) = joins;
        let request = StripRequest::local(&Actor::Daemon, "tab.group.add");
        match self.tab_group_add(request, &group, move |_| Ok(vec![added]), Some(index)) {
            Ok(_) => self.emit_tab_group_members(&[added], None),
            Err(error) => {
                eprintln!("cmux-tui: tab {added} did not join {group}: {error:#}");
            }
        }
    }
}
