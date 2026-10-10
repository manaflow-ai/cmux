//! The presentation snapshot reader (moved out of presentation_store.rs).

use super::*;

impl WorkspaceRegistry {
    /// Groups in order plus the presentation of every live workspace.
    pub fn presentation_snapshot(&self) -> anyhow::Result<PresentationSnapshot> {
        let groups = read_groups(&self.connection.get())?;
        let db = self.connection.get();
        let mut statement = db.prepare(
            "SELECT p.workspace_key, p.group_id, p.color, p.icon, p.title, p.pinned,
                    p.marked_unread
             FROM workspace_presentation AS p
             JOIN workspaces AS w ON w.workspace_key = p.workspace_key
             WHERE w.tombstoned = 0",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                WorkspacePresentationRecord {
                    group: row.get(1)?,
                    color: row.get(2)?,
                    icon: row.get(3)?,
                    title: row.get(4)?,
                    pinned: row.get::<_, i64>(5)? != 0,
                    marked_unread: row.get::<_, i64>(6)? != 0,
                },
            ))
        })?;
        let mut workspaces = HashMap::new();
        for row in rows {
            let (key, mut record) = row?;
            if record.group.as_deref().is_some_and(|id| !groups.iter().any(|g| g.id == id)) {
                record.group = None;
            }
            if !record.is_empty() {
                workspaces.insert(key, record);
            }
        }
        let db = self.connection.get();
        let pinned_tabs = db
            .prepare(
                "SELECT p.tab_id FROM tab_presentation AS p
                 JOIN resource_tabs AS t ON t.public_id = p.tab_id
                 WHERE p.pinned = 1 AND t.deleted_revision IS NULL",
            )?
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<HashSet<_>, _>>()?;
        let mut frontend_browsers = HashMap::new();
        {
            let db = self.connection.get();
            let mut statement = db.prepare(
                "SELECT f.browser_id, f.engine, f.url, f.title, f.favicon_url, f.profile_id, f.owner
                 FROM frontend_browser_tabs AS f
                 WHERE NOT EXISTS (
                   SELECT 1 FROM resource_browsers AS b
                   WHERE b.public_id = f.browser_id AND b.lifecycle = 'tombstoned'
                 )",
            )?;
            let rows = statement.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    FrontendBrowserRecord {
                        engine: row.get(1)?,
                        url: row.get(2)?,
                        title: row.get(3)?,
                        favicon_url: row.get(4)?,
                        profile_id: row.get(5)?,
                        owner: row.get(6)?,
                    },
                ))
            })?;
            for row in rows {
                let (browser_id, record) = row?;
                frontend_browsers.insert(browser_id, record);
            }
        }
        let tab_groups = read_tab_group_state(&self.connection.get())?;
        let saved_tab_groups = read_saved_tab_groups(&self.connection.get())?;
        let screens = super::super::screen_store::read_screen_state(&self.connection.get())?;
        let saved_screen_groups =
            super::super::screen_store::read_saved_screen_groups(&self.connection.get())?;
        let kept_tabs = crate::state::kept_tab_store::read_kept_tabs(&self.connection.get())?;
        let conversation_tabs = read_conversation_tabs(&self.connection.get())?;
        let home_workspace =
            crate::state::home_store::live_home(&self.connection.get())?.map(|h| h.1);
        Ok(PresentationSnapshot {
            groups,
            workspaces,
            pinned_tabs,
            frontend_browsers,
            conversation_tabs,
            home_workspace,
            tab_groups,
            saved_tab_groups,
            screens,
            saved_screen_groups,
            kept_tabs,
        })
    }
}
