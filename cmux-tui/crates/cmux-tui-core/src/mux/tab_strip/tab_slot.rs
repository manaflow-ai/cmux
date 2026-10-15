//! The strip index a tab created in an existing pane takes, so a creation
//! that restores a tab's old place (Reopen Closed, cx-d1xb8) adds the tab
//! there in one change: one `tab-added` at that index, and no
//! create-at-the-end-then-move that a client animates across the strip.
//!
//! The creator runs inside [`scoped`]; the tab creation into that pane takes
//! the index once ([`take_for`]) and carries it to its effect as the
//! internal [`INDEX_FIELD`], which is stored with the effect's intent, so a
//! creation resumed after a restart lands at the same index.

use std::cell::Cell;

use serde_json::{Map, Value};

use crate::PaneId;

/// Internal `tab.create_terminal` and `tab.create_browser` field (never
/// accepted from a v2 client; the catalog refuses unknown fields): the index
/// of its pane's strip the created tab takes, clamped to the strip's end.
pub(crate) const INDEX_FIELD: &str = "tab_insert_index";

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
