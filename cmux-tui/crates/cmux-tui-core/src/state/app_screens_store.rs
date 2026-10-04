//! `app-screens-v1` storage (plans/cmux-next/app-screens.md section 2).
//!
//! Three side tables that older builds ignore:
//! - `app_workspaces`: a workspace of kind `app` and its app (one per app),
//!   written in the transaction that creates the workspace.
//! - `app_tabs`: the app (and route) a frontend-rendered tab shows, written
//!   in the commit of its frontend browser row, like `conversation_tabs`.
//! - The companion of an app workspace is an ordinary workspace of kind
//!   `app_tabs` in the one kind table (`workspace_kind`, home_store.rs,
//!   with its app, its default name and `renamed`): it takes the new tabs
//!   sent to the app workspace (one per app, placed directly after it).
//!   Clients localize its name while `extra.default_title` is true; any
//!   rename is final. Written in the commit that creates the workspace.
//! - `resource_screen_kinds`: a screen of kind `app` and its app. It is a
//!   resource side table (screen_rows.rs pattern): deleted when its screen is tombstoned, and overlaid at
//!   load only when the screen still has its shape ([`load_screen_apps`]); a
//!   screen that lost it loads as an ordinary screen and keeps every tab.
//!
//! An older build reads an app screen as an ordinary screen holding one
//! frontend browser tab.
//!
//! The store never reads app content.

use std::collections::HashMap;
use std::fmt;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Map, Value, json};

pub(crate) const APP_SCREENS_CAPABILITY: &str = "app-screens-v1";
/// The workspace kind and the canonical tab kind (`content_kind`, raw `kind`).
pub(crate) const APP_KIND: &str = "app";
/// The workspace kind of the companion of an app workspace.
pub(crate) const APP_TABS_KIND: &str = "app_tabs";
/// The frontend record of an app tab: the app renders its own page.
pub(crate) const APP_TAB_URL: &str = "about:blank";
pub(crate) const APP_TAB_ENGINE: &str = "webkit";
const APP_ID_MAX_BYTES: usize = 128;
/// The route is also a first-party page's small client state (R91).
const ROUTE_MAX_BYTES: usize = 4096;

pub(crate) fn create_app_state_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS app_workspaces (
           workspace_id TEXT PRIMARY KEY NOT NULL,
           app_id TEXT NOT NULL UNIQUE
         );
         CREATE TABLE IF NOT EXISTS app_tabs (
           browser_id TEXT PRIMARY KEY NOT NULL,
           app_id TEXT NOT NULL,
           route TEXT,
           origin TEXT,
           mutation_id TEXT
         );
         CREATE TABLE IF NOT EXISTS app_display_names (
           app_id TEXT PRIMARY KEY NOT NULL,
           display_name TEXT NOT NULL
         );
         CREATE UNIQUE INDEX IF NOT EXISTS app_tabs_by_mutation
           ON app_tabs(origin, mutation_id) WHERE mutation_id IS NOT NULL;",
    )?;
    Ok(())
}

/// The resource side table, created with the other screen side tables.
pub(crate) fn create_screen_kind_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS resource_screen_kinds (
           screen_id TEXT PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL CHECK(kind = 'app'),
           app_id TEXT NOT NULL
         );",
    )?;
    Ok(())
}

/// An app id as the manifest names it (`publisher/name`): ASCII letters,
/// digits and `.` `_` `-` `/`, starting with a letter or digit.
pub(crate) fn validate_app_id(app: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !app.is_empty()
            && app.len() <= APP_ID_MAX_BYTES
            && app.as_bytes()[0].is_ascii_alphanumeric()
            && app.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-/".contains(&byte)),
        "bad request: app must be an app id of at most {APP_ID_MAX_BYTES} letters, digits, \
         '.', '_', '-' or '/'"
    );
    Ok(())
}

/// The kind of a screen that is not an ordinary (`workspace`) screen. v1
/// has one: `app`, the only screen of its app workspace.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AppScreenKind {
    App,
}

impl AppScreenKind {
    pub(crate) fn parse(value: &str) -> anyhow::Result<Self> {
        match value {
            "app" => Ok(Self::App),
            _ => anyhow::bail!("bad request: kind must be \"app\""),
        }
    }

    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::App => "app",
        }
    }
}

/// The kind and app of an app screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ScreenApp {
    pub(crate) kind: AppScreenKind,
    pub(crate) app: String,
}

/// Write the app workspace row of a new workspace (in its creation commit).
/// A row left by a closed workspace of the same app is replaced.
pub(crate) fn write_app_workspace(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    app: &str,
) -> anyhow::Result<()> {
    validate_app_id(app)?;
    transaction.execute("DELETE FROM app_workspaces WHERE app_id = ?1", [app])?;
    transaction.execute(
        "INSERT INTO app_workspaces(workspace_id, app_id) VALUES(?1, ?2)",
        params![workspace_id, app],
    )?;
    Ok(())
}

/// The live workspace of `app`: its public id and key.
pub(crate) fn live_app_workspace(
    connection: &Connection,
    app: &str,
) -> anyhow::Result<Option<(String, String)>> {
    Ok(connection
        .query_row(
            "SELECT a.workspace_id, rw.workspace_key
             FROM app_workspaces AS a
             JOIN resource_workspaces AS rw ON rw.public_id = a.workspace_id
             WHERE a.app_id = ?1 AND rw.deleted_revision IS NULL",
            [app],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?)
}

/// The app of a workspace of kind `app`.
pub(crate) fn workspace_app(
    connection: &Connection,
    workspace_id: &str,
) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT app_id FROM app_workspaces WHERE workspace_id = ?1",
            [workspace_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?)
}

/// The app of every live app workspace, keyed by workspace key (the raw
/// tree's presentation snapshot).
pub(crate) fn read_app_workspaces(
    connection: &Connection,
) -> anyhow::Result<HashMap<String, String>> {
    let mut statement = connection.prepare(
        "SELECT rw.workspace_key, a.app_id
         FROM app_workspaces AS a
         JOIN resource_workspaces AS rw ON rw.public_id = a.workspace_id
         WHERE rw.deleted_revision IS NULL",
    )?;
    let rows = statement
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
        .collect::<Result<HashMap<_, _>, _>>()?;
    Ok(rows)
}

/// The app records the raw tree reads from the presentation snapshot.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AppPresentation {
    /// The app of every live app workspace, by workspace key.
    pub workspaces: HashMap<String, String>,
    /// App tab records, by public browser id.
    pub tabs: HashMap<String, AppTabRecord>,
    /// The app of every live companion workspace (kind `app_tabs`), by
    /// workspace key.
    pub companions: HashMap<String, CompanionRecord>,
}

/// A live companion workspace (kind `app_tabs`) as the raw tree reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompanionRecord {
    pub app: String,
    /// The name the daemon gave it.
    pub default_name: String,
    /// A committed rename happened (`default_title` is false for good).
    pub renamed: bool,
}

impl CompanionRecord {
    /// `default_title`: the daemon's name still stands.
    pub fn default_title(&self, name: &str) -> bool {
        !self.renamed && name == self.default_name
    }
}

impl AppPresentation {
    pub(crate) fn read(connection: &Connection) -> anyhow::Result<Self> {
        Ok(Self {
            workspaces: read_app_workspaces(connection)?,
            tabs: read_app_tabs(connection)?,
            companions: read_companions(connection)?,
        })
    }
}

/// The screen kinds of the live state, by screen slot.
pub(crate) type ScreenApps = HashMap<crate::ScreenId, ScreenApp>;

/// The live companion workspace (kind `app_tabs`) of `app`.
pub(crate) fn live_companion(connection: &Connection, app: &str) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT c.workspace_id FROM workspace_kind AS c
             JOIN resource_workspaces AS rw ON rw.public_id = c.workspace_id
             WHERE c.kind = 'app_tabs' AND c.app_id = ?1 AND rw.deleted_revision IS NULL",
            [app],
            |row| row.get::<_, String>(0),
        )
        .optional()?)
}

/// The app whose companion `workspace_id` is.
pub(crate) fn companion_app(
    connection: &Connection,
    workspace_id: &str,
) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT app_id FROM workspace_kind WHERE workspace_id = ?1 AND kind = 'app_tabs'",
            [workspace_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?)
}

/// Every live companion workspace, keyed by workspace key.
fn read_companions(connection: &Connection) -> anyhow::Result<HashMap<String, CompanionRecord>> {
    let mut statement = connection.prepare(
        "SELECT rw.workspace_key, c.app_id, c.default_name, c.renamed
         FROM workspace_kind AS c
         JOIN resource_workspaces AS rw ON rw.public_id = c.workspace_id
         WHERE c.kind = 'app_tabs' AND rw.deleted_revision IS NULL",
    )?;
    let rows = statement
        .query_map([], |row| {
            let record = CompanionRecord {
                app: row.get(1)?,
                default_name: row.get(2)?,
                renamed: row.get::<_, i64>(3)? != 0,
            };
            Ok((row.get::<_, String>(0)?, record))
        })?
        .collect::<Result<HashMap<_, _>, _>>()?;
    Ok(rows)
}

/// Mark `workspace` as the companion of `app`, named `default_name` by the
/// daemon (in the commit that creates it). A row left by a closed companion
/// of the same app is replaced.
pub(crate) fn write_companion(
    transaction: &Transaction<'_>,
    app: &str,
    workspace: &str,
    default_name: &str,
) -> anyhow::Result<()> {
    validate_app_id(app)?;
    // A row left by a closed companion of the same app.
    transaction
        .execute("DELETE FROM workspace_kind WHERE kind = 'app_tabs' AND app_id = ?1", [app])?;
    transaction.execute(
        "INSERT INTO workspace_kind(workspace_id, kind, app_id, default_name)
         VALUES(?1, 'app_tabs', ?2, ?3)",
        params![workspace, app, default_name],
    )?;
    Ok(())
}

/// A committed name other than the daemon's default renames a companion
/// for good (`extra.default_title` turns false and stays false). Runs on
/// the workspace rows of every commit, in its transaction, so every rename
/// path counts.
pub(crate) fn note_companion_renames(
    transaction: &Transaction<'_>,
    patch: &crate::workspace_registry::ResourcePatch,
) -> anyhow::Result<()> {
    use crate::workspace_registry::ResourceChange;
    if !patch.changes.iter().any(|change| matches!(change, ResourceChange::UpsertWorkspace { .. }))
        || !table_has_column(transaction, "workspace_kind", "app_id")?
    {
        return Ok(());
    }
    // The few companions that still have their default name.
    let defaults = transaction
        .prepare(
            "SELECT workspace_id, default_name FROM workspace_kind
             WHERE kind = 'app_tabs' AND renamed = 0",
        )?
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
        .collect::<Result<HashMap<_, _>, _>>()?;
    if defaults.is_empty() {
        return Ok(());
    }
    for change in &patch.changes {
        let ResourceChange::UpsertWorkspace { workspace, .. } = change else { continue };
        let id = workspace.public_id.as_str();
        if defaults.get(id).is_some_and(|default| *default != workspace.name) {
            transaction
                .execute("UPDATE workspace_kind SET renamed = 1 WHERE workspace_id = ?1", [id])?;
        }
    }
    Ok(())
}

/// Mid-migration registries may have the kind table of an older build.
fn table_has_column(connection: &Connection, table: &str, column: &str) -> anyhow::Result<bool> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2)",
        [table, column],
        |row| row.get::<_, bool>(0),
    )?)
}

/// The English name a client gave `app` (`display_name` on
/// `workspace.ensure_app` and `workspace.ensure_home`).
pub(crate) fn app_display_name(
    connection: &Connection,
    app: &str,
) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row("SELECT display_name FROM app_display_names WHERE app_id = ?1", [app], |row| {
            row.get::<_, String>(0)
        })
        .optional()?)
}

/// Record the English name of `app`; the latest one a client sent wins.
pub(crate) fn write_app_display_name(
    transaction: &Transaction<'_>,
    app: &str,
    display_name: &str,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO app_display_names(app_id, display_name) VALUES(?1, ?2)
         ON CONFLICT(app_id) DO UPDATE SET display_name = excluded.display_name",
        params![app, display_name],
    )?;
    Ok(())
}

/// A `display_name` as clients send it: a short single-line name.
pub(crate) fn validate_display_name(name: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !name.trim().is_empty() && name.len() <= 128 && !name.chars().any(char::is_control),
        "bad request: display_name must be 1 to 128 bytes without control characters"
    );
    Ok(())
}

/// Whether the companion `workspace_id` still has the daemon's default name.
fn companion_default_title(connection: &Connection, workspace_id: &str) -> anyhow::Result<bool> {
    Ok(connection
        .query_row(
            "SELECT renamed FROM workspace_kind WHERE workspace_id = ?1 AND kind = 'app_tabs'",
            [workspace_id],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .is_some_and(|renamed| renamed == 0))
}

/// What an `app` tab shows: an app and an optional route inside it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppTabRecord {
    pub app: String,
    pub route: Option<String>,
}

impl AppTabRecord {
    pub(crate) fn validate(&self) -> anyhow::Result<()> {
        validate_app_id(&self.app)?;
        if let Some(route) = &self.route {
            anyhow::ensure!(
                route.len() <= ROUTE_MAX_BYTES && !route.chars().any(char::is_control),
                "bad request: route must be at most {ROUTE_MAX_BYTES} bytes without control \
                 characters"
            );
        }
        Ok(())
    }

    /// The flat fields of the tab on the wire: `app`, and `route` when set.
    pub(crate) fn insert_wire(&self, fields: &mut Map<String, Value>) {
        fields.insert("app".into(), json!(self.app));
        if let Some(route) = &self.route {
            fields.insert("route".into(), json!(route));
        }
    }
}

/// Write the record of browser `browser_id` (in the frontend row's commit).
pub(crate) fn write_app_tab(
    transaction: &Transaction<'_>,
    browser_id: &str,
    record: &AppTabRecord,
    mutation: Option<(&str, &str)>,
) -> anyhow::Result<()> {
    record.validate()?;
    transaction.execute(
        "INSERT INTO app_tabs(browser_id, app_id, route, origin, mutation_id)
         VALUES(?1, ?2, ?3, ?4, ?5)",
        params![
            browser_id,
            record.app,
            record.route,
            mutation.map(|(origin, _)| origin),
            mutation.map(|(_, id)| id),
        ],
    )?;
    Ok(())
}

/// The browser id and record a creation with this idempotency key wrote.
pub(crate) fn app_tab_for_mutation(
    connection: &Connection,
    origin: &str,
    mutation_id: &str,
) -> anyhow::Result<Option<(String, AppTabRecord)>> {
    Ok(connection
        .query_row(
            "SELECT browser_id, app_id, route FROM app_tabs
             WHERE origin = ?1 AND mutation_id = ?2",
            params![origin, mutation_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    AppTabRecord { app: row.get(1)?, route: row.get(2)? },
                ))
            },
        )
        .optional()?)
}

/// Every app tab record, keyed by browser id.
pub(crate) fn read_app_tabs(
    connection: &Connection,
) -> anyhow::Result<HashMap<String, AppTabRecord>> {
    let mut statement = connection.prepare("SELECT browser_id, app_id, route FROM app_tabs")?;
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, AppTabRecord { app: row.get(1)?, route: row.get(2)? }))
        })?
        .collect::<Result<HashMap<_, _>, _>>()?;
    Ok(rows)
}

/// The app record of the tab with public id `tab_id`.
pub(crate) fn tab_app(
    connection: &Connection,
    tab_id: &str,
) -> anyhow::Result<Option<AppTabRecord>> {
    Ok(connection
        .query_row(
            "SELECT a.app_id, a.route FROM resource_tabs AS t
             JOIN app_tabs AS a ON a.browser_id = t.content_id
             WHERE t.public_id = ?1",
            [tab_id],
            |row| Ok(AppTabRecord { app: row.get(0)?, route: row.get(1)? }),
        )
        .optional()?)
}

/// Write the kind row of an app screen.
pub(crate) fn write_screen_app(
    transaction: &Transaction<'_>,
    screen_id: &str,
    screen: &ScreenApp,
) -> anyhow::Result<()> {
    validate_app_id(&screen.app)?;
    transaction.execute(
        "INSERT INTO resource_screen_kinds(screen_id, kind, app_id) VALUES(?1, ?2, ?3)
         ON CONFLICT(screen_id) DO UPDATE SET kind = excluded.kind, app_id = excluded.app_id",
        params![screen_id, screen.kind.as_str(), screen.app],
    )?;
    Ok(())
}

/// Every stored screen kind row, keyed by public screen id. Rows of an
/// unknown kind (a later build) are skipped.
pub(crate) fn read_screen_apps(
    connection: &Connection,
) -> anyhow::Result<HashMap<String, ScreenApp>> {
    let mut statement =
        connection.prepare("SELECT screen_id, kind, app_id FROM resource_screen_kinds")?;
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows
        .into_iter()
        .filter_map(|(screen, kind, app)| {
            let kind = AppScreenKind::parse(&kind).ok()?;
            Some((screen, ScreenApp { kind, app }))
        })
        .collect())
}

/// The kind row of one screen.
pub(crate) fn screen_app(
    connection: &Connection,
    screen_id: &str,
) -> anyhow::Result<Option<ScreenApp>> {
    let row = connection
        .query_row(
            "SELECT kind, app_id FROM resource_screen_kinds WHERE screen_id = ?1",
            [screen_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?;
    Ok(row.and_then(|(kind, app)| Some(ScreenApp { kind: AppScreenKind::parse(&kind).ok()?, app })))
}

/// Delete the kind row of a closed screen (in the tombstone transaction).
pub(crate) fn delete_screen_app(
    transaction: &Transaction<'_>,
    screen_id: &str,
) -> anyhow::Result<()> {
    transaction.execute("DELETE FROM resource_screen_kinds WHERE screen_id = ?1", [screen_id])?;
    Ok(())
}

/// The v2 `extra` of a workspace, a screen and a tab.
pub(crate) fn workspace_extra(
    connection: &Connection,
    workspace_id: &str,
    fields: &mut Map<String, Value>,
) -> anyhow::Result<()> {
    // The home workspace keeps `kind: home` when it is the Home app's
    // workspace; `app` names its app.
    let marked = match workspace_app(connection, workspace_id)? {
        Some(app) => Some((APP_KIND, app)),
        None => companion_app(connection, workspace_id)?.map(|app| (APP_TABS_KIND, app)),
    };
    if let Some((kind, app)) = marked {
        fields.entry("kind").or_insert_with(|| json!(kind));
        fields.insert("app".into(), json!(app));
        if kind == APP_TABS_KIND {
            let default = companion_default_title(connection, workspace_id)?;
            fields.insert("default_title".into(), json!(default));
        }
    }
    Ok(())
}

pub(crate) fn screen_extra(
    connection: &Connection,
    screen_id: &str,
    fields: &mut Map<String, Value>,
) -> anyhow::Result<()> {
    if let Some(screen) = screen_app(connection, screen_id)? {
        fields.insert("kind".into(), json!(screen.kind.as_str()));
        fields.insert("app".into(), json!(screen.app));
    }
    Ok(())
}

pub(crate) fn tab_extra(
    connection: &Connection,
    tab_id: &str,
    fields: &mut Map<String, Value>,
) -> anyhow::Result<()> {
    if let Some(record) = tab_app(connection, tab_id)? {
        record.insert_wire(fields);
    }
    Ok(())
}

/// A refused change to an app screen or an app column.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AppRule {
    refusal: cmux_layout_reducer::AppRefusal,
    /// The public id of the screen.
    screen: String,
}

impl AppRule {
    pub(crate) fn new(refusal: cmux_layout_reducer::AppRefusal, screen: String) -> Self {
        Self { refusal, screen }
    }

    /// The `cmux.protocol/2` catalog error code.
    pub(crate) fn code(&self) -> &'static str {
        match self.refusal {
            cmux_layout_reducer::AppRefusal::ScreenFixed => "app.screen_fixed",
        }
    }

    /// The raw protocol `error_code`.
    pub(crate) fn raw_code(&self) -> &'static str {
        match self.refusal {
            cmux_layout_reducer::AppRefusal::ScreenFixed => "app-screen-fixed",
        }
    }
}

impl fmt::Display for AppRule {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let (code, screen) = (self.raw_code(), &self.screen);
        match self.refusal {
            cmux_layout_reducer::AppRefusal::ScreenFixed => {
                write!(formatter, "{code}: screen {screen} shows one app and nothing else")
            }
        }
    }
}

impl std::error::Error for AppRule {}

/// The standard resource failure of a refused app screen change.
pub(crate) fn resource_error(error: &anyhow::Error) -> Option<crate::resource::ResourceError> {
    let rule = error.downcast_ref::<AppRule>().filter(|rule| !rule.screen.is_empty())?;
    let details = json!({"screen_id": rule.screen});
    Some(crate::resource::ResourceError::new(rule.code(), rule.to_string(), details, false))
}

/// The raw `error_code` of a refused app screen change.
pub(crate) fn error_code(error: &anyhow::Error) -> Option<String> {
    raw_error_code(error).map(str::to_string)
}

pub(crate) fn raw_error_code(error: &anyhow::Error) -> Option<&'static str> {
    error.downcast_ref::<AppRule>().map(AppRule::raw_code)
}

/// Rewrite every `app` tab in `value` to its `browser` form, for a
/// connection that did not negotiate `app-screens-v1` (the
/// `conversation-tabs-v1` projection, server/conversation_tabs_wire.rs).
pub(crate) fn downgrade_app_tabs(value: &mut Value) -> bool {
    match value {
        Value::Object(object) => {
            let mut changed = false;
            if object.get("content_kind").and_then(Value::as_str) == Some(APP_KIND) {
                object.insert("content_kind".into(), Value::String("browser".into()));
                changed = true;
            }
            if object.contains_key("browser_renderer")
                && object.get("kind").and_then(Value::as_str) == Some(APP_KIND)
            {
                object.insert("kind".into(), Value::String("browser".into()));
                changed = true;
            }
            for child in object.values_mut() {
                changed |= downgrade_app_tabs(child);
            }
            changed
        }
        Value::Array(items) => {
            let mut changed = false;
            for item in items {
                changed |= downgrade_app_tabs(item);
            }
            changed
        }
        _ => false,
    }
}
