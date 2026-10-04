//! The authoritative `app-screens-v1` check (plans/cmux-next/app-screens.md
//! A1 to A4), run on the rows a commit writes, in its transaction
//! (`apply_resource_patch`). The checks in `app_rules.rs` refuse before a
//! command changes anything and give each command its typed error; this one
//! makes two racing requests, or any path that skipped them, unable to commit
//! a state that breaks the rules. A refusal here rolls the transaction back,
//! so the store is unchanged.
//!
//! For every live app screen the patch touches:
//! - A1: an `app` screen is one leaf pane (no viewport columns) holding one
//!   tab, an `app` tab of the screen's app.
//! - Its workspace is the app workspace of its app.
//!
//! And every app workspace the patch touches has at most one live screen.

use std::collections::BTreeSet;

use cmux_layout_reducer::AppRefusal;
use rusqlite::{OptionalExtension, Transaction};

use crate::state::app_screens_store::AppRule;
use crate::workspace_registry::{
    RegistryLayoutNode, RegistryViewport, ResourceChange, ResourcePatch,
};

fn one(transaction: &Transaction<'_>, sql: &str, id: &str) -> anyhow::Result<Option<String>> {
    Ok(transaction.query_row(sql, [id], |row| row.get::<_, String>(0)).optional()?)
}

const PANE_SCREEN: &str = "SELECT screen_id FROM resource_panes WHERE public_id = ?1";
const TAB_PANE: &str = "SELECT pane_id FROM resource_tabs WHERE public_id = ?1";
const SCREEN_WORKSPACE: &str = "SELECT workspace_id FROM resource_screens WHERE public_id = ?1";

/// The screens and workspaces whose rows `patch` wrote.
fn touched(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<(BTreeSet<String>, BTreeSet<String>)> {
    let (mut screens, mut panes, mut workspaces) =
        (BTreeSet::new(), BTreeSet::new(), BTreeSet::new());
    for change in &patch.changes {
        match change {
            ResourceChange::UpsertScreen(screen) => {
                screens.insert(screen.public_id.to_string());
                workspaces.insert(screen.workspace_id.to_string());
            }
            ResourceChange::TombstoneScreen { screen_id } => {
                workspaces.extend(one(transaction, SCREEN_WORKSPACE, screen_id.as_str())?);
            }
            ResourceChange::UpsertPane(pane) => {
                screens.insert(pane.screen_id.to_string());
            }
            ResourceChange::TombstonePane { pane_id } => {
                panes.insert(pane_id.to_string());
            }
            ResourceChange::SetTabOrder { pane_id, .. } => {
                panes.insert(pane_id.to_string());
            }
            ResourceChange::UpsertTab(tab) => {
                panes.insert(tab.pane_id.to_string());
            }
            ResourceChange::TombstoneTab { tab_id, .. } => {
                panes.extend(one(transaction, TAB_PANE, tab_id.as_str())?);
            }
            _ => {}
        }
    }
    for pane in panes {
        screens.extend(one(transaction, PANE_SCREEN, &pane)?);
    }
    for screen in &screens {
        workspaces.extend(one(transaction, SCREEN_WORKSPACE, screen)?);
    }
    Ok((screens, workspaces))
}

/// The one leaf pane of a layout, if it is a leaf.
fn leaf(node: &RegistryLayoutNode) -> Option<String> {
    match node {
        RegistryLayoutNode::Leaf { pane } => Some(pane.to_string()),
        _ => None,
    }
}

/// Whether `pane` holds exactly one live tab, an app tab of `app`.
fn holds_only_app(transaction: &Transaction<'_>, pane: &str, app: &str) -> anyhow::Result<bool> {
    let tabs = transaction
        .prepare(
            "SELECT a.app_id FROM resource_tabs AS t
             LEFT JOIN app_tabs AS a ON a.browser_id = t.content_id
             WHERE t.pane_id = ?1 AND t.deleted_revision IS NULL",
        )?
        .query_map([pane], |row| row.get::<_, Option<String>>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(matches!(tabs.as_slice(), [Some(tab_app)] if tab_app == app))
}

pub(crate) fn check_screen(transaction: &Transaction<'_>, screen: &str) -> anyhow::Result<()> {
    let row = transaction
        .query_row(
            "SELECT k.app_id, s.workspace_id, s.layout_json, s.viewport_json
             FROM resource_screen_kinds AS k
             JOIN resource_screens AS s ON s.public_id = k.screen_id
             WHERE k.screen_id = ?1 AND s.deleted_revision IS NULL",
            [screen],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            },
        )
        .optional()?;
    let Some((app, workspace, layout, viewport)) = row else { return Ok(()) };
    let layout: RegistryLayoutNode = serde_json::from_str(&layout)?;
    let viewport: RegistryViewport = serde_json::from_str(&viewport)?;
    let shaped = match leaf(&layout) {
        Some(pane) if viewport.columns.is_empty() => holds_only_app(transaction, &pane, &app)?,
        _ => false,
    };
    let workspace_app =
        one(transaction, "SELECT app_id FROM app_workspaces WHERE workspace_id = ?1", &workspace)?;
    let placed = workspace_app.is_some_and(|owner| owner == app);
    if shaped && placed {
        Ok(())
    } else {
        Err(AppRule::new(AppRefusal::ScreenFixed, screen.to_string()).into())
    }
}

/// An app workspace keeps at most one live screen.
fn check_workspace(transaction: &Transaction<'_>, workspace: &str) -> anyhow::Result<()> {
    let Some(_) =
        one(transaction, "SELECT app_id FROM app_workspaces WHERE workspace_id = ?1", workspace)?
    else {
        return Ok(());
    };
    let screens = transaction
        .prepare(
            "SELECT s.public_id, k.screen_id IS NOT NULL FROM resource_screens AS s
             LEFT JOIN resource_screen_kinds AS k ON k.screen_id = s.public_id
             WHERE s.workspace_id = ?1 AND s.deleted_revision IS NULL",
        )?
        .query_map([workspace], |row| Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?)))?
        .collect::<Result<Vec<_>, _>>()?;
    if screens.len() <= 1 {
        return Ok(());
    }
    let named = screens.iter().find(|(_, app)| *app).unwrap_or(&screens[0]);
    Err(AppRule::new(AppRefusal::ScreenFixed, named.0.clone()).into())
}

/// The app tabs of every live app screen before a commit, so the check can
/// tell a closed app screen (its tabs closed with it) from one whose screen
/// went away while its app tab moved on.
pub(crate) struct AppScreensBefore {
    screens: Vec<(String, AppRefusal, Vec<String>)>,
}

/// Read before `apply_resource_patch` writes; `None` when no app screen or
/// app workspace exists (the check then costs nothing more).
pub(crate) fn before_patch(
    transaction: &Transaction<'_>,
) -> anyhow::Result<Option<AppScreensBefore>> {
    // Registries opened by older builds or mid-migration may lack the tables.
    let ready = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table'
           AND name = 'app_workspaces')
         AND EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table'
           AND name = 'resource_screen_kinds')",
        [],
        |row| row.get::<_, bool>(0),
    )?;
    if !ready
        || !transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM resource_screen_kinds)
               OR EXISTS(SELECT 1 FROM app_workspaces)",
            [],
            |row| row.get::<_, bool>(0),
        )?
    {
        return Ok(None);
    }
    let kinds = transaction
        .prepare(
            "SELECT k.screen_id, k.app_id FROM resource_screen_kinds AS k
             JOIN resource_screens AS s ON s.public_id = k.screen_id
             WHERE s.deleted_revision IS NULL",
        )?
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
        .collect::<Result<Vec<_>, _>>()?;
    let mut screens = Vec::with_capacity(kinds.len());
    for (screen, app) in kinds {
        let tabs = transaction
            .prepare(
                "SELECT t.public_id FROM resource_tabs AS t
                 JOIN resource_panes AS p ON p.public_id = t.pane_id
                 JOIN app_tabs AS a ON a.browser_id = t.content_id
                 WHERE p.screen_id = ?1 AND a.app_id = ?2
                   AND t.deleted_revision IS NULL AND p.deleted_revision IS NULL",
            )?
            .query_map([&screen, &app], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        screens.push((screen, AppRefusal::ScreenFixed, tabs));
    }
    Ok(Some(AppScreensBefore { screens }))
}

/// An app screen that went away took its app tab with it (a close), never
/// left it live elsewhere (a move out).
fn check_gone_screens(
    transaction: &Transaction<'_>,
    before: &AppScreensBefore,
) -> anyhow::Result<()> {
    for (screen, refusal, tabs) in &before.screens {
        let live = one(
            transaction,
            "SELECT public_id FROM resource_screens
             WHERE public_id = ?1 AND deleted_revision IS NULL",
            screen,
        )?;
        if live.is_some() {
            continue;
        }
        for tab in tabs {
            let moved = one(
                transaction,
                "SELECT public_id FROM resource_tabs
                 WHERE public_id = ?1 AND deleted_revision IS NULL",
                tab,
            )?;
            if moved.is_some() {
                return Err(AppRule::new(*refusal, screen.clone()).into());
            }
        }
    }
    Ok(())
}

/// The check of one commit, after `patch` is applied in `transaction`;
/// `before` is [`before_patch`] of the same transaction.
pub(crate) fn check_committed_patch(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
    before: Option<AppScreensBefore>,
) -> anyhow::Result<()> {
    let Some(before) = before else { return Ok(()) };
    check_gone_screens(transaction, &before)?;
    let (screens, workspaces) = touched(transaction, patch)?;
    for screen in &screens {
        check_screen(transaction, screen)?;
    }
    for workspace in &workspaces {
        check_workspace(transaction, workspace)?;
    }
    Ok(())
}
