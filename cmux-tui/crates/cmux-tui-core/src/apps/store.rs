//! App Store ops (`cmux.apps.*`): the catalog semantics behind the React App
//! Store page, the CLI and MCP (plans/cmux-next/app-platform.md section 15).
//! The supervisor owns them; params, results and events are Rust types with
//! `schemars`, so they enter the one IR through emit-ir (pane-protocol.md).
//! Install, uninstall, grant changes, updates and local apps need origin
//! user; agents are refused until the actor stamp lands. Install, uninstall,
//! update and grant.set always go through a native Swift confirmation sheet
//! (app name, scopes with risk class): only that sheet stamps origin user;
//! user activation in page JavaScript is not a gesture proof.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// How an op runs and which scope it needs (until the registration macro).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StoreOp {
    pub name: &'static str,
    pub scope: &'static str,
    pub mutation: bool,
    /// Origin user; never an agent or a script.
    pub user_only: bool,
    /// The supervisor asks the client for the native confirmation sheet
    /// before it runs the op.
    pub native_confirmation: bool,
    pub stream: bool,
}

/// Every `cmux.apps.*` op.
pub const STORE_OPS: &[StoreOp] = &[
    op("cmux.apps.catalog.list", "apps:read", false, false, false),
    op("cmux.apps.catalog.get", "apps:read", false, false, false),
    op("cmux.apps.asset.get", "apps:read", false, false, false),
    op("cmux.apps.installed.list", "apps:read", false, false, false),
    op("cmux.apps.install", "apps:write", true, true, false),
    op("cmux.apps.uninstall", "apps:write", true, true, false),
    op("cmux.apps.set", "apps:write", true, false, false),
    op("cmux.apps.grants.get", "apps:read", false, false, false),
    op("cmux.apps.grant.set", "apps:write", true, true, false),
    op("cmux.apps.updates.list", "apps:read", false, false, false),
    op("cmux.apps.update", "apps:write", true, true, false),
    op("cmux.apps.local.add", "apps:write", true, true, false),
    op("cmux.apps.local.remove", "apps:write", true, true, false),
    op("cmux.apps.validate", "apps:read", false, false, false),
    op("cmux.apps.logs", "apps:read", false, false, true),
    op("cmux.apps.watch", "apps:read", false, false, true),
    op("cmux.apps.open", "apps:write", true, false, false),
];

const fn op(name: &'static str, scope: &'static str, mutation: bool, user_only: bool, stream: bool) -> StoreOp {
    let confirm = matches!(name.as_bytes(), b"cmux.apps.install" | b"cmux.apps.uninstall" | b"cmux.apps.update" | b"cmux.apps.grant.set");
    StoreOp { name, scope, mutation, user_only, stream, native_confirmation: confirm }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum Tier {
    FirstParty,
    Verified,
    Unverified,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum InstallSource {
    /// Shipped with cmux and installed by default (deployment list).
    Default,
    User,
    /// Shipped with cmux, opt-in (samples).
    Bundled,
    /// A local folder (dev app; starts sandboxed).
    Local,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum ScopeClass {
    Standard,
    Sensitive,
    Restricted,
}

/// Localized text: the user's language, resolved by the owner.
pub type Text = String;

// MARK: catalog

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CatalogListParams {
    pub query: Option<String>,
    pub category: Option<String>,
    pub tier: Option<Tier>,
    /// Opaque cursor from a previous page.
    pub cursor: Option<String>,
    /// At most 200; default 50.
    pub limit: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct CatalogListResult {
    pub listings: Vec<Listing>,
    pub next_cursor: Option<String>,
    /// Install mirror revision the install fields reflect.
    pub revision: u64,
}

/// One store row: bundled, sample, local and registry apps alike.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Listing {
    /// `publisher/name`.
    pub app: String,
    pub name: Text,
    pub summary: Text,
    pub publisher: String,
    pub tier: Tier,
    pub version: String,
    /// `cmux.apps.asset.get` path, or an SF symbol name.
    pub icon: Option<IconRef>,
    pub categories: Vec<String>,
    pub install: Option<InstallState>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum IconRef {
    Asset(String),
    Symbol(String),
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CatalogGetParams {
    pub app: String,
    pub version: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct AppDetail {
    pub listing: Listing,
    pub description: Text,
    pub screenshots: Vec<String>,
    pub repository: Option<String>,
    pub license: Option<String>,
    pub scopes: Vec<ScopeRequest>,
    pub handles: Vec<HandleRequest>,
    pub notices: Vec<Notice>,
    pub versions: Vec<VersionInfo>,
    /// Interfaces the app implements (`cmux.section/1`, ...).
    pub implements: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct ScopeRequest {
    pub scope: String,
    pub reason: Text,
    pub class: ScopeClass,
    pub optional: bool,
    /// False when this tier may never hold it (shown locked).
    pub allowed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct HandleRequest {
    pub kind: String,
    pub reason: Text,
    pub max: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Notice {
    pub path: String,
    pub title: Option<Text>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct VersionInfo {
    pub version: String,
    pub published_at: Option<String>,
    pub changelog: Option<Text>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AssetGetParams {
    pub app: String,
    /// A path the manifest names (icon, screenshots, notices); never another file.
    pub path: Option<String>,
    /// The manifest's symbol icon at this pixel size. A Mac host renders it to
    /// PNG; other hosts answer `apps.asset.unavailable` and the client draws a
    /// generic glyph (SF Symbols never ship as web SVGs).
    pub symbol_png: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct AssetGetResult {
    pub content_type: String,
    /// Byte stream id (pane protocol `open`); small assets inline as base64 are not allowed.
    pub stream: u32,
    pub bytes: u64,
}

// MARK: installs

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct InstallState {
    pub installed: bool,
    pub enabled: bool,
    pub hidden: bool,
    pub sandboxed: bool,
    pub source: InstallSource,
    pub version: Option<String>,
    pub update: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct InstalledListParams {}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct InstalledListResult {
    pub revision: u64,
    pub apps: Vec<InstalledApp>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct InstalledApp {
    pub app: String,
    pub name: Text,
    pub tier: Tier,
    pub state: InstallState,
    pub grants: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct InstallParams {
    pub app: String,
    pub version: Option<String>,
    /// Optional scopes the user turned on in the consent sheet.
    pub grant_optional: Vec<String>,
    pub idempotency_key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AppRef {
    pub app: String,
    pub idempotency_key: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SetParams {
    pub app: String,
    pub enabled: Option<bool>,
    /// Any origin may hide or unhide (D55).
    pub hidden: Option<bool>,
    pub sandboxed: Option<bool>,
    pub idempotency_key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct SetResult {
    pub revision: u64,
    pub app: InstalledApp,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct GrantsResult {
    pub app: String,
    pub scopes: Vec<GrantRow>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct GrantRow {
    pub scope: String,
    pub class: ScopeClass,
    pub granted: bool,
    pub optional: bool,
    pub reason: Text,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GrantSetParams {
    pub app: String,
    pub scope: String,
    pub granted: bool,
    pub idempotency_key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct UpdatesResult {
    pub updates: Vec<UpdateRow>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct UpdateRow {
    pub app: String,
    pub from: String,
    pub to: String,
    /// Scopes the new version adds; the update asks before it applies them.
    pub new_scopes: Vec<String>,
}

// MARK: local apps and validation

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct LocalAddParams {
    /// Absolute path of a package folder on this machine.
    pub path: String,
    pub idempotency_key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ValidateParams {
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct ValidateResult {
    pub valid: bool,
    pub issues: Vec<ValidationIssue>,
}

/// `cmux_app_manifest::Issue` on the wire.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct ValidationIssue {
    pub severity: String,
    pub path: String,
    pub code: String,
    pub message: String,
}

// MARK: streams and open

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct LogsParams {
    pub app: String,
    pub follow: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct LogLine {
    pub at: String,
    pub level: String,
    pub text: String,
}

/// `cmux.apps.watch` event: install mirror, grant, hidden or registry change.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct AppsChanged {
    pub revision: u64,
    /// The app that changed; none for a registry refresh.
    pub app: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum OpenAs {
    /// The app screen (`presentation.screen`: app or appColumn), through the
    /// layout owner's `workspace.ensure_app {app, kind}`.
    Screen,
    /// A page tab.
    Tab,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct OpenParams {
    pub app: String,
    /// Default: `screen` when the manifest has `presentation.screen`, else `tab`.
    #[serde(rename = "as")]
    pub open_as: Option<OpenAs>,
    /// For `as: tab`: the tab drop zone (pane and index) the tab opens in.
    pub target: Option<TabTarget>,
    /// A command export to run after the app opens.
    pub command: Option<String>,
    /// Change the caller's view (CLI and MCP default false).
    pub focus: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TabTarget {
    pub pane: String,
    pub index: Option<u32>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn op_names_are_unique_and_in_the_cmux_apps_family() {
        let mut names = std::collections::HashSet::new();
        for op in STORE_OPS {
            assert!(op.name.starts_with("cmux.apps."), "{}", op.name);
            assert!(names.insert(op.name), "{} twice", op.name);
            assert!(!op.user_only || op.mutation, "{}", op.name);
            assert!(!op.native_confirmation || op.user_only, "{}", op.name);
        }
    }

    #[test]
    fn every_param_type_has_a_schema() {
        let _ = schemars::schema_for!(CatalogListParams);
        let _ = schemars::schema_for!(InstallParams);
        let _ = schemars::schema_for!(AppDetail);
        let _ = schemars::schema_for!(AppsChanged);
    }
}
