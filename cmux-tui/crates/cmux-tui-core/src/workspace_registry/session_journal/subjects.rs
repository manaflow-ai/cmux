//! Collect and expand the resource subjects indexed for journal records.

use super::*;

pub(super) fn collect_patch_subjects(
    patch: &ResourcePatch,
    subjects: &mut BTreeSet<JournalSubject>,
) {
    for change in &patch.changes {
        match change {
            ResourceChange::UpsertWorkspace { workspace, active_screen, .. } => {
                insert_subject(subjects, "workspace", workspace.public_id.as_str());
                if let Some(screen) = active_screen {
                    insert_subject(subjects, "screen", screen.as_str());
                }
            }
            ResourceChange::TombstoneWorkspace { workspace_id } => {
                insert_subject(subjects, "workspace", workspace_id.as_str());
            }
            // The order is the session's: the workspaces a commit adds,
            // moves or selects are subjects through their own changes and
            // the result, not every workspace the order lists (2000 index
            // rows per create at 2000 workspaces).
            ResourceChange::SetWorkspaceOrder { .. } => {}
            ResourceChange::SetActiveWorkspace { workspace_id } => {
                if let Some(workspace) = workspace_id {
                    insert_subject(subjects, "workspace", workspace.as_str());
                }
            }
            ResourceChange::UpsertScreen(screen) => {
                insert_subject(subjects, "screen", screen.public_id.as_str());
                insert_subject(subjects, "workspace", screen.workspace_id.as_str());
                insert_subject(subjects, "pane", screen.active_pane.as_str());
                if let Some(pane) = &screen.zoomed_pane {
                    insert_subject(subjects, "pane", pane.as_str());
                }
                if let Some(panes) = &screen.auto_layout {
                    for pane in panes {
                        insert_subject(subjects, "pane", pane.as_str());
                    }
                }
                collect_layout_subjects(&screen.layout, subjects);
                for column in &screen.viewport.columns {
                    insert_subject(subjects, "split", column.id.as_str());
                    collect_layout_subjects(&column.layout, subjects);
                    if let Some(panes) = &column.auto_layout {
                        for pane in panes {
                            insert_subject(subjects, "pane", pane.as_str());
                        }
                    }
                }
            }
            ResourceChange::TombstoneScreen { screen_id } => {
                insert_subject(subjects, "screen", screen_id.as_str());
            }
            ResourceChange::SetScreenOrder { workspace_id, screen_ids } => {
                insert_subject(subjects, "workspace", workspace_id.as_str());
                for screen in screen_ids {
                    insert_subject(subjects, "screen", screen.as_str());
                }
            }
            ResourceChange::UpsertPane(pane) => {
                insert_subject(subjects, "pane", pane.public_id.as_str());
                insert_subject(subjects, "screen", pane.screen_id.as_str());
                if let Some(tab) = &pane.active_tab {
                    insert_subject(subjects, "tab", tab.as_str());
                }
            }
            ResourceChange::TombstonePane { pane_id } => {
                insert_subject(subjects, "pane", pane_id.as_str());
            }
            ResourceChange::UpsertTab(tab) => {
                insert_subject(subjects, "tab", tab.public_id.as_str());
                insert_subject(subjects, "pane", tab.pane_id.as_str());
                match &tab.content_id {
                    ContentPublicId::Terminal(terminal) => {
                        insert_subject(subjects, "terminal", terminal.as_str());
                    }
                    ContentPublicId::Browser(browser) => {
                        insert_subject(subjects, "browser", browser.as_str());
                    }
                }
            }
            ResourceChange::TombstoneTab { tab_id, .. } => {
                insert_subject(subjects, "tab", tab_id.as_str());
            }
            ResourceChange::SetTabOrder { pane_id, tab_ids } => {
                insert_subject(subjects, "pane", pane_id.as_str());
                for tab in tab_ids {
                    insert_subject(subjects, "tab", tab.as_str());
                }
            }
            ResourceChange::UpsertTerminal { public_id, .. }
            | ResourceChange::TombstoneTerminal { public_id, .. } => {
                insert_subject(subjects, "terminal", public_id.as_str());
            }
            ResourceChange::UpsertBrowser(browser) => {
                insert_subject(subjects, "browser", browser.public_id.as_str());
            }
            ResourceChange::TombstoneBrowser { public_id } => {
                insert_subject(subjects, "browser", public_id.as_str());
            }
        }
    }
}

fn collect_layout_subjects(layout: &RegistryLayoutNode, subjects: &mut BTreeSet<JournalSubject>) {
    match layout {
        RegistryLayoutNode::Leaf { pane } => insert_subject(subjects, "pane", pane.as_str()),
        RegistryLayoutNode::Split { split, first, second, .. } => {
            insert_subject(subjects, "split", split.as_str());
            collect_layout_subjects(first, subjects);
            collect_layout_subjects(second, subjects);
        }
        RegistryLayoutNode::Stack { panes, expanded } => {
            for pane in panes {
                insert_subject(subjects, "pane", pane.as_str());
            }
            insert_subject(subjects, "pane", expanded.as_str());
        }
    }
}

fn insert_subject(subjects: &mut BTreeSet<JournalSubject>, kind: &str, id: &str) {
    subjects.insert(JournalSubject { kind: kind.into(), id: id.into() });
}

pub(super) fn collect_subjects(value: &Value, subjects: &mut BTreeSet<JournalSubject>) {
    match value {
        Value::Array(values) => {
            for value in values {
                collect_subjects(value, subjects);
            }
        }
        Value::Object(values) => {
            for value in values.values() {
                collect_subjects(value, subjects);
            }
        }
        Value::String(value) => {
            if let Some(kind) = public_id_kind(value) {
                subjects.insert(JournalSubject { kind: kind.into(), id: value.clone() });
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

pub(crate) fn expand_topology_subjects(
    transaction: &Transaction<'_>,
    subjects: &mut BTreeSet<JournalSubject>,
) -> anyhow::Result<()> {
    if !subjects.iter().any(|subject| {
        matches!(subject.kind.as_str(), "screen" | "pane" | "tab" | "terminal" | "browser")
    }) {
        return Ok(());
    }
    let ids = subjects.iter().map(|subject| &subject.id).collect::<Vec<_>>();
    let ids_json = canonical_json(&serde_json::to_value(ids)?)?;
    let mut statement = transaction.prepare_cached(
        "WITH seeds(id) AS (
           SELECT value FROM json_each(?1)
         ),
         tab_paths(tab_id, pane_id, screen_id, workspace_id) AS (
           SELECT tab.public_id, tab.pane_id, pane.screen_id, screen.workspace_id
           FROM resource_tabs AS tab
           JOIN resource_panes AS pane ON pane.public_id = tab.pane_id
           JOIN resource_screens AS screen ON screen.public_id = pane.screen_id
           WHERE tab.public_id IN (SELECT id FROM seeds)
              OR tab.content_id IN (SELECT id FROM seeds)
         ),
         pane_paths(pane_id, screen_id, workspace_id) AS (
           SELECT pane.public_id, pane.screen_id, screen.workspace_id
           FROM resource_panes AS pane
           JOIN resource_screens AS screen ON screen.public_id = pane.screen_id
           WHERE pane.public_id IN (SELECT id FROM seeds)
         ),
         screen_paths(screen_id, workspace_id) AS (
           SELECT screen.public_id, screen.workspace_id
           FROM resource_screens AS screen
           WHERE screen.public_id IN (SELECT id FROM seeds)
         )
         SELECT 'tab', tab_id FROM tab_paths
         UNION SELECT 'pane', pane_id FROM tab_paths
         UNION SELECT 'screen', screen_id FROM tab_paths
         UNION SELECT 'workspace', workspace_id FROM tab_paths
         UNION SELECT 'pane', pane_id FROM pane_paths
         UNION SELECT 'screen', screen_id FROM pane_paths
         UNION SELECT 'workspace', workspace_id FROM pane_paths
         UNION SELECT 'screen', screen_id FROM screen_paths
         UNION SELECT 'workspace', workspace_id FROM screen_paths",
    )?;
    let expanded = statement
        .query_map([ids_json], |row| Ok(JournalSubject { kind: row.get(0)?, id: row.get(1)? }))?
        .collect::<Result<Vec<_>, _>>()?;
    subjects.extend(expanded);
    Ok(())
}

pub(crate) fn terminal_topology_subjects_batch(
    transaction: &Transaction<'_>,
    terminal_ids: impl IntoIterator<Item = String>,
) -> anyhow::Result<HashMap<String, Vec<JournalSubject>>> {
    let terminal_ids = terminal_ids.into_iter().collect::<BTreeSet<_>>();
    if terminal_ids.is_empty() {
        return Ok(HashMap::new());
    }
    let ids_json = canonical_json(&serde_json::to_value(&terminal_ids)?)?;
    let mut statement = transaction.prepare_cached(
        "WITH seeds(terminal_id) AS (
           SELECT value FROM json_each(?1)
         ),
         paths(terminal_id, tab_id, pane_id, screen_id, workspace_id) AS (
           SELECT seed.terminal_id, tab.public_id, tab.pane_id,
                  pane.screen_id, screen.workspace_id
           FROM seeds AS seed
           JOIN resource_tabs AS tab ON tab.content_id = seed.terminal_id
           JOIN resource_panes AS pane ON pane.public_id = tab.pane_id
           JOIN resource_screens AS screen ON screen.public_id = pane.screen_id
         )
         SELECT terminal_id, 'tab', tab_id FROM paths
         UNION SELECT terminal_id, 'pane', pane_id FROM paths
         UNION SELECT terminal_id, 'screen', screen_id FROM paths
         UNION SELECT terminal_id, 'workspace', workspace_id FROM paths",
    )?;
    let expanded = statement
        .query_map([ids_json], |row| {
            Ok((row.get::<_, String>(0)?, JournalSubject { kind: row.get(1)?, id: row.get(2)? }))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut by_terminal = HashMap::<String, BTreeSet<JournalSubject>>::new();
    for (terminal_id, subject) in expanded {
        by_terminal.entry(terminal_id).or_default().insert(subject);
    }
    Ok(by_terminal
        .into_iter()
        .map(|(terminal_id, subjects)| (terminal_id, subjects.into_iter().collect()))
        .collect())
}

fn public_id_kind(value: &str) -> Option<&'static str> {
    const PREFIXES: [(&str, &str); 17] = [
        ("frontend_projection", "projection"),
        ("pairing_request", "pairing"),
        ("sidebar_plugin", "sidebar_plugin"),
        ("sidebar_view", "sidebar_view"),
        ("notification", "notification"),
        ("workspace", "ws"),
        ("terminal", "term"),
        ("session", "session"),
        ("machine", "machine"),
        ("screen", "screen"),
        ("browser", "browser"),
        ("client", "client"),
        ("pane", "pane"),
        ("split", "split"),
        ("agent", "agent"),
        ("stream", "stream"),
        ("tab", "tab"),
    ];
    for (kind, prefix) in PREFIXES {
        let Some(payload) = value.strip_prefix(prefix).and_then(|value| value.strip_prefix('_'))
        else {
            continue;
        };
        if payload.len() == 32
            && payload.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Some(kind);
        }
    }
    None
}
