//! The state fields of a tab's `extra`: pin, group, zoom, icon, history,
//! marks, the browser's owner and profile, the conversation record and the
//! keep-layout record.
//!
//! Two readers feed one builder ([`fields`]), so a tab reads the same from
//! each. [`tab_extra`] reads the rows of ONE tab with point statements: a
//! journal upsert, a mutation result, a list inside one workspace.
//! [`SessionTabExtras`] reads each table ONE time for every live tab: a list
//! of the session's tabs. With the point reader a `tab.list` with no scope
//! ran eight statements for each tab (about 7,400 for the 930 tabs of an
//! 826-workspace session: 20.78 ms in process where `pane.list` took
//! 2.90 ms; DAEMON LISTS 4, 2026-11-10).

use std::collections::{HashMap, HashSet};

use rusqlite::{Connection, OptionalExtension, Row};
use serde_json::{Map, Value, json};

use crate::state::{conversation_tabs_store, kept_tab_store};

/// The `tab_state` columns that `extra` shows, in the order of
/// [`TAB_STATE_COLUMNS`].
struct TabStateRow {
    zoom: Option<f64>,
    back: Option<String>,
    forward: Option<String>,
    icon: Option<String>,
    emulation: Option<String>,
    marked_unread: Option<i64>,
    attention: Option<String>,
}

const TAB_STATE_COLUMNS: &str =
    "zoom, back_json, forward_json, icon, emulation_json, marked_unread, attention_json";

impl TabStateRow {
    /// The row whose [`TAB_STATE_COLUMNS`] start at column `first`.
    fn read(row: &Row<'_>, first: usize) -> rusqlite::Result<Self> {
        Ok(Self {
            zoom: row.get(first)?,
            back: row.get(first + 1)?,
            forward: row.get(first + 2)?,
            icon: row.get(first + 3)?,
            emulation: row.get(first + 4)?,
            marked_unread: row.get(first + 5)?,
            attention: row.get(first + 6)?,
        })
    }
}

/// What the state tables hold for one tab.
struct TabRows {
    pinned: bool,
    group: Option<String>,
    state: Option<TabStateRow>,
    /// The owner and the profile of a frontend-rendered browser.
    frontend: Option<(Option<String>, Option<String>)>,
    conversation: Option<Value>,
    /// Null for a tab with no keep-layout record.
    relaunch: Value,
}

/// The `extra` fields of the tab that has `rows`.
fn fields(rows: TabRows) -> anyhow::Result<Map<String, Value>> {
    let mut fields = Map::new();
    if rows.pinned {
        fields.insert("pinned".into(), json!(true));
    }
    if let Some(group) = rows.group {
        fields.insert("tab_group_id".into(), json!(group));
    }
    if let Some(state) = rows.state {
        if let Some(emulation) =
            state.emulation.as_deref().and_then(crate::state::browser_devices::resolve)
        {
            fields.insert("emulation".into(), emulation);
        }
        if let Some(zoom) = state.zoom {
            fields.insert("zoom".into(), json!(zoom));
        }
        if let Some(icon) = state.icon {
            fields.insert("icon".into(), json!(icon));
        }
        // `tab-mark-unread-v1`: present only while the tab is marked.
        if state.marked_unread.is_some_and(|value| value != 0) {
            fields.insert("marked_unread".into(), json!(true));
        }
        // `tab-attention-v1`: `{reason, at_ms, request_id}`, present only while an agent
        // needs the person in this tab.
        if let Some(attention) = state.attention {
            fields.insert(
                "attention".into(),
                crate::state::tab_state_store::shown_attention(&attention)?,
            );
        }
        for (name, list) in [("back", state.back), ("forward", state.forward)] {
            if let Some(list) = list {
                fields.insert(name.into(), serde_json::from_str(&list)?);
            }
        }
    }
    // The install id of the app that hosts a frontend-rendered browser, and
    // the browser profile whose store the page uses (absent is `default`).
    if let Some((owner, profile)) = rows.frontend {
        if let Some(owner) = owner {
            fields.insert("owner".into(), json!(owner));
        }
        let profile =
            profile.unwrap_or_else(|| crate::workspace_registry::DEFAULT_PROFILE_ID.to_string());
        fields.insert("browser_profile_id".into(), json!(profile));
    }
    // `conversation-tabs-v1` / `agent-session-tabs-v1`: what a frontend tab shows.
    if let Some(conversation) = rows.conversation {
        fields.insert("conversation".into(), conversation);
    }
    // A keep-layout record (`end-terminals-keep-layout-v1`): restart a shell
    // in `cwd`. Absent (null) for every other tab, like the other extras.
    if !rows.relaunch.is_null() {
        fields.insert("relaunch".into(), rows.relaunch);
    }
    Ok(fields)
}

/// The `extra` fields of one tab, from point reads of its rows.
pub(super) fn tab_extra(
    connection: &Connection,
    tab_id: &str,
) -> anyhow::Result<Map<String, Value>> {
    let pinned = crate::state::values::query_row_cached(
        connection,
        "SELECT pinned FROM tab_presentation WHERE tab_id = ?1",
        [tab_id],
        |row| row.get::<_, i64>(0),
    )
    .optional()?
    .is_some_and(|value| value != 0);
    let group = crate::state::values::query_row_cached(
        connection,
        "SELECT m.group_id
             FROM tab_group_members AS m
             JOIN tab_groups AS g ON g.group_id = m.group_id
             JOIN resource_tabs AS t ON t.public_id = m.tab_id AND t.pane_id = g.pane_id
             WHERE m.tab_id = ?1",
        [tab_id],
        |row| row.get::<_, String>(0),
    )
    .optional()?;
    let state = crate::state::values::query_row_cached(
        connection,
        &format!("SELECT {TAB_STATE_COLUMNS} FROM tab_state WHERE tab_id = ?1"),
        [tab_id],
        |row| TabStateRow::read(row, 0),
    )
    .optional()?;
    let frontend = crate::state::values::query_row_cached(
        connection,
        "SELECT f.owner, f.profile_id FROM resource_tabs AS t
             JOIN frontend_browser_tabs AS f ON f.browser_id = t.content_id
             WHERE t.public_id = ?1",
        [tab_id],
        |row| Ok((row.get::<_, Option<String>>(0)?, row.get::<_, Option<String>>(1)?)),
    )
    .optional()?;
    fields(TabRows {
        pinned,
        group,
        state,
        frontend,
        conversation: conversation_tabs_store::tab_conversation_wire(connection, tab_id)?,
        relaunch: kept_tab_store::relaunch_value(connection, tab_id)?,
    })
}

/// The state rows of the session's tabs, each table read one time: what a
/// list of the session's tabs decorates its values from. The number of
/// statements does not depend on the number of tabs. `tab_state` keeps the
/// rows of closed tabs, so its read joins the live tabs; `tab_presentation`
/// and `kept_tabs` are pruned by their writers and are read as they are.
pub(super) struct SessionTabExtras {
    pinned: HashSet<String>,
    groups: HashMap<String, String>,
    states: HashMap<String, TabStateRow>,
    frontends: HashMap<String, (Option<String>, Option<String>)>,
    conversations: HashMap<String, Value>,
    relaunches: HashMap<String, Value>,
}

impl SessionTabExtras {
    /// Read the tables. Run it in the read transaction of the list, so the
    /// rows and the tabs are one cut.
    pub(super) fn read(connection: &Connection) -> anyhow::Result<Self> {
        let pinned = connection
            .prepare("SELECT tab_id FROM tab_presentation WHERE pinned != 0")?
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<HashSet<_>, _>>()?;
        let groups = connection
            .prepare(
                "SELECT m.tab_id, m.group_id
                 FROM tab_group_members AS m
                 JOIN tab_groups AS g ON g.group_id = m.group_id
                 JOIN resource_tabs AS t ON t.public_id = m.tab_id AND t.pane_id = g.pane_id",
            )?
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
            .collect::<Result<HashMap<_, _>, _>>()?;
        // Only the rows of live tabs: a closed tab keeps its row (its history,
        // zoom and icon; only a row with no field is deleted), so the table
        // grows with each tab the person ever closed.
        let states = connection
            .prepare(&format!(
                "SELECT s.tab_id, {TAB_STATE_COLUMNS}
                 FROM tab_state AS s
                 JOIN resource_tabs AS t ON t.public_id = s.tab_id
                 WHERE t.deleted_revision IS NULL"
            ))?
            .query_map([], |row| Ok((row.get::<_, String>(0)?, TabStateRow::read(row, 1)?)))?
            .collect::<Result<HashMap<_, _>, _>>()?;
        let frontends = connection
            .prepare(
                "SELECT t.public_id, f.owner, f.profile_id FROM resource_tabs AS t
                 JOIN frontend_browser_tabs AS f ON f.browser_id = t.content_id
                 WHERE t.deleted_revision IS NULL",
            )?
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    (row.get::<_, Option<String>>(1)?, row.get::<_, Option<String>>(2)?),
                ))
            })?
            .collect::<Result<HashMap<_, _>, _>>()?;
        Ok(Self {
            pinned,
            groups,
            states,
            frontends,
            conversations: conversation_tabs_store::tab_conversation_wires(connection)?,
            relaunches: kept_tab_store::relaunch_values(connection)?,
        })
    }

    /// The `tab_state` rows that the reader holds.
    #[cfg(test)]
    pub(super) fn state_rows(&self) -> usize {
        self.states.len()
    }

    /// The `extra` fields of tab `tab_id`: what [`tab_extra`] gives for it.
    /// A list names each tab one time, so the rows are taken, not copied.
    pub(super) fn take(&mut self, tab_id: &str) -> anyhow::Result<Map<String, Value>> {
        fields(TabRows {
            pinned: self.pinned.contains(tab_id),
            group: self.groups.remove(tab_id),
            state: self.states.remove(tab_id),
            frontend: self.frontends.remove(tab_id),
            conversation: self.conversations.remove(tab_id),
            relaunch: self.relaunches.remove(tab_id).unwrap_or(Value::Null),
        })
    }
}
