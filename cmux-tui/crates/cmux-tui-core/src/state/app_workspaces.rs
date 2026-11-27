//! `app-screens-v1` (plans/cmux-next/app-screens.md, app-only model):
//! `workspace.ensure_app {app, route?, name?}` makes the one workspace of an
//! installed app, holding one app tab, and replays it after that.
//!
//! Storage:
//! - The workspace kind is a row of the one kind table `workspace_kind`
//!   (home_store.rs): kind `app` with its `app_id`, one live row per app.
//! - The app tab is a frontend-rendered browser tab (engine `webkit`, URL
//!   `about:blank`, the conversation tab plumbing) with an `app_tabs` row
//!   (its app and route), written in the commit of its frontend browser row.
//!
//! One commit publishes the workspace with its app tab and its kind row: the
//! session-target `tab.create_browser` effect stages the new workspace and
//! its kind row in one transaction ([`APP_WORKSPACE_FIELD`]), then the tab,
//! and the projection publishes both, so a v2 client never sees the
//! workspace empty or without its kind. The raw tree's first delta of the
//! workspace (`workspace-added`) already carries kind `app`; its screen
//! follows in the next delta, as for every session-target creation.
//!
//! An app that is not installed and enabled here is refused
//! (`validation.invalid`, field `app`). Closing the workspace closes the
//! app; the next `ensure_app` makes a new one. Older builds read an app
//! workspace as an ordinary workspace with one frontend browser tab.
//!
//! The store never reads app content.

use std::collections::HashMap;
use std::sync::Mutex;

use rusqlite::{Connection, Transaction, params};
use serde_json::{Map, json};

use crate::mux::*;
use crate::resource::BrowserPublicId;
use crate::state::home_store::live_app_workspace;
use crate::state::prelude::*;
use crate::workspace_registry::FrontendBrowserRecord;

pub(crate) const APP_SCREENS_CAPABILITY: &str = "app-screens-v1";
/// Internal `tab.create_browser` field (never accepted from a v2 client): the
/// new workspace of a session-target creation is this app's workspace.
pub(crate) const APP_WORKSPACE_FIELD: &str = "app_workspace";
/// Internal `tab.create_browser` field: the name of that new workspace.
pub(crate) const APP_WORKSPACE_NAME_FIELD: &str = "app_workspace_name";
/// The frontend record of an app tab: the app renders its own page.
const APP_TAB_URL: &str = "about:blank";
const APP_TAB_ENGINE: &str = "webkit";
const APP_ID_MAX_BYTES: usize = 128;
/// The route is also a first-party page's small client state.
const ROUTE_MAX_BYTES: usize = 4096;

/// One `ensure_app` at a time in this process, so two concurrent calls for
/// one app never make two workspaces.
static ENSURING: Mutex<()> = Mutex::new(());

pub(crate) fn create_app_tabs_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS app_tabs (
           browser_id TEXT PRIMARY KEY NOT NULL,
           app_id TEXT NOT NULL,
           route TEXT
         );",
    )?;
    Ok(())
}

/// The app (and route) a frontend-rendered tab shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppTabRecord {
    pub app: String,
    pub route: Option<String>,
}

impl AppTabRecord {
    /// The raw tree's `Tab.app`.
    pub(crate) fn wire(&self) -> Value {
        json!({"app": self.app, "route": self.route})
    }
}

/// Every app tab record, by public browser id.
pub(crate) fn read_app_tabs(
    connection: &Connection,
) -> anyhow::Result<HashMap<String, AppTabRecord>> {
    let mut statement = connection.prepare("SELECT browser_id, app_id, route FROM app_tabs")?;
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, AppTabRecord { app: row.get(1)?, route: row.get(2)? }))
        })?
        .collect::<Result<_, _>>()?;
    Ok(rows)
}

fn write_app_tab(
    transaction: &Transaction<'_>,
    browser_id: &str,
    record: &AppTabRecord,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO app_tabs(browser_id, app_id, route) VALUES(?1, ?2, ?3)",
        params![browser_id, record.app, record.route],
    )?;
    Ok(())
}

/// An app id as the manifest names it (`publisher/name`): ASCII letters,
/// digits and `.` `_` `-` `/`, starting with a letter or digit.
fn validate_app_id(app: &str) -> Result<(), ResourceError> {
    let valid = !app.is_empty()
        && app.len() <= APP_ID_MAX_BYTES
        && app.as_bytes()[0].is_ascii_alphanumeric()
        && app.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-/".contains(&byte));
    if valid {
        Ok(())
    } else {
        Err(ResourceError::validation_invalid(
            Some("app"),
            format!(
                "app must be an app id of at most {APP_ID_MAX_BYTES} letters, digits, '.', '_', \
                 '-' or '/'"
            ),
        ))
    }
}

/// What `workspace.ensure_app` returns.
pub(crate) struct EnsuredApp {
    pub(crate) result: Value,
    pub(crate) revision: u64,
    pub(crate) replayed: bool,
}

impl Mux {
    /// `workspace.ensure_app`: the live workspace of `app`, else a new one
    /// holding one app tab, created with its tab and kind in one commit.
    pub(crate) fn state_ensure_app(
        self: &Arc<Self>,
        app: &str,
        route: Option<String>,
        name: Option<String>,
        mutation: &WorkspaceMutation,
    ) -> Result<EnsuredApp, ResourceError> {
        validate_app_id(app)?;
        if route.as_ref().is_some_and(|route| route.len() > ROUTE_MAX_BYTES) {
            return Err(ResourceError::validation_invalid(
                Some("route"),
                format!("route must be at most {ROUTE_MAX_BYTES} bytes"),
            ));
        }
        if let Some(name) = name.as_deref() {
            Self::validate_workspace_name(name).map_err(|error| {
                ResourceError::validation_invalid(Some("name"), error.to_string())
            })?;
        }
        if !self.control_clients.apps().app_active(self, app) {
            return Err(ResourceError::validation_invalid(
                Some("app"),
                format!("app {app} is not installed and enabled"),
            ));
        }
        let _ensuring = ENSURING.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let existing = self
            .read_registry_state(|connection| live_app_workspace(connection, app))
            .map_err(crate::resource_router::resource_operation_error)?;
        if let Some((workspace_id, _)) = existing {
            let revision = self.with_state(|state| state.resource_revision);
            return Ok(EnsuredApp {
                result: json!({"kind": "workspace", "workspace_id": workspace_id}),
                revision,
                replayed: true,
            });
        }
        self.create_app_workspace(app, route, name, mutation)
            .map_err(crate::resource_router::resource_operation_error)
    }

    fn create_app_workspace(
        self: &Arc<Self>,
        app: &str,
        route: Option<String>,
        name: Option<String>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<EnsuredApp> {
        let record = AppTabRecord { app: app.to_string(), route };
        let browser_id = BrowserPublicId::random()?;
        let frontend = FrontendBrowserRecord {
            engine: APP_TAB_ENGINE.to_string(),
            url: APP_TAB_URL.to_string(),
            title: None,
            favicon_url: None,
            profile_id: None,
            owner: None,
        };
        {
            let id = browser_id.as_str().to_string();
            let write = |tx: &Transaction<'_>| write_app_tab(tx, &id, &record);
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            registry.put_frontend_browser(browser_id.as_str(), &frontend, Some(&write))?;
            self.reload_presentation(&registry)?;
        }
        let mut fields = Map::from_iter([
            ("url".to_string(), Value::String(APP_TAB_URL.to_string())),
            ("frontend_browser_id".to_string(), Value::String(browser_id.as_str().to_string())),
            (APP_WORKSPACE_FIELD.to_string(), Value::String(app.to_string())),
        ]);
        if let Some(name) = name {
            fields.insert(APP_WORKSPACE_NAME_FIELD.to_string(), Value::String(name));
        }
        let created = self.resource_topology_operation(
            crate::resource::ResourceOperation::TabCreateBrowser,
            Self::ordinary_resource_selectors(),
            fields,
            None,
            mutation,
        );
        let commit = match created {
            Ok(commit) => commit,
            Err(error) => {
                let mut registry = self
                    .workspace_registry
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if registry.delete_frontend_browser(browser_id.as_str()).is_ok() {
                    let _ = self.reload_presentation(&registry);
                }
                return Err(error);
            }
        };
        // The raw tree reads the workspace's kind and the tab's app from
        // the presentation snapshot.
        self.reload_presentation(
            &self.workspace_registry.lock().unwrap_or_else(std::sync::PoisonError::into_inner),
        )?;
        self.emit(MuxEvent::TreeChanged);
        self.publish_journal_event();
        let workspace_id = commit.result["workspace_id"]
            .as_str()
            .context("the created app tab has no workspace")?;
        Ok(EnsuredApp {
            result: json!({"kind": "workspace", "workspace_id": workspace_id}),
            revision: commit.revision,
            replayed: commit.replayed,
        })
    }
}
