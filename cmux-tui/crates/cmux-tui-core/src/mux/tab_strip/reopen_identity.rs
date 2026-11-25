//! The tab id a Reopen Closed creation takes: the closed tab's own
//! (plans/cmux-next/durable-links-DESIGN.md, persistent-ids D1 for tabs), so
//! a `cmux://tab/<id>` link to it keeps working after the reopen.
//!
//! Like [`super::tab_slot`], the reopen runs the creation inside [`scoped`];
//! the first tab creation in it takes the id once ([`take`]) and carries it
//! to its effect as the internal [`FIELD`], stored with the effect's intent,
//! so a creation resumed after a restart makes the same tab. The planner
//! accepts the id only when it names a retired tab ([`is_retired_tab`]): a
//! retired id comes back only for the same tab, from its closed record.

use std::cell::RefCell;

use serde_json::{Map, Value};

/// Internal `tab.create_terminal` and `tab.create_browser` field (never
/// accepted from a v2 client; the catalog refuses unknown fields): the
/// retired tab id the created tab takes again.
pub(crate) const FIELD: &str = "reopen_tab_id";

thread_local! {
    static SCOPED: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// Restores the id that was set before [`scoped`].
struct Restore(Option<String>);

impl Drop for Restore {
    fn drop(&mut self) {
        SCOPED.with(|slot| *slot.borrow_mut() = self.0.take());
    }
}

/// Run `create` with the next tab it creates taking the retired id `tab`
/// (none: every tab gets a new id, as before).
pub(crate) fn scoped<T>(tab: Option<&str>, create: impl FnOnce() -> T) -> T {
    let _restore = Restore(SCOPED.with(|slot| slot.replace(tab.map(str::to_string))));
    create()
}

/// The retired id the tab created now takes, once: a second creation in the
/// same scope gets a new id.
pub(crate) fn take() -> Option<String> {
    SCOPED.with(|slot| slot.borrow_mut().take())
}

/// Put the scoped id of a creation into its effect `fields`.
pub(crate) fn insert_field(fields: &mut Map<String, Value>) {
    if let Some(tab) = take() {
        fields.insert(FIELD.to_string(), Value::String(tab));
    }
}

/// Whether `tab` names a tab the registry retired (closed): the only ids a
/// reopen may give back.
pub(crate) fn is_retired_tab(connection: &rusqlite::Connection, tab: &str) -> anyhow::Result<bool> {
    use rusqlite::OptionalExtension;
    Ok(connection
        .query_row(
            "SELECT 1 FROM resource_tabs WHERE public_id = ?1 AND deleted_revision IS NOT NULL",
            [tab],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_creation_in_a_scope_takes_the_id_once_and_the_scope_restores() {
        assert_eq!(take(), None);
        scoped(Some("tab_a"), || {
            let mut fields = Map::new();
            insert_field(&mut fields);
            assert_eq!(fields.get(FIELD).and_then(Value::as_str), Some("tab_a"));
            let mut second = Map::new();
            insert_field(&mut second);
            assert!(second.get(FIELD).is_none(), "a second creation reused the id");
        });
        scoped(Some("tab_outer"), || {
            scoped(Some("tab_inner"), || assert_eq!(take().as_deref(), Some("tab_inner")));
            assert_eq!(take().as_deref(), Some("tab_outer"));
        });
        assert_eq!(take(), None);
    }
}
