//! App Store ops (`cmux.apps.*`, plans/cmux-next/app-platform.md section
//! 15) on the supervisor: the catalog and install semantics behind the React
//! App Store page, the CLI and MCP. Pages reach them through the
//! `cmux.protocol/2` resource dispatcher as `apps.<verb>` (the short alias
//! of the canonical `cmux.apps.<verb>`).
//!
//! - `catalog.list` and `catalog.get`: the catalog packages, never
//!   `cmux/app-store` itself; first-party apps are `hide_only`.
//! - `installed.list`: the installed apps with their state and grants.
//! - `set`: `hidden` from any origin (D55); `enabled` and `sandboxed` only
//!   from the user, in both directions (APPS-ENABLE-ORIGIN).
//! - `install` and `uninstall`: origin user only (the A2 gate admits it only
//!   from the hosting app connection, after the native confirmation sheet),
//!   third-party apps only (`apps.first_party_hide_only`).
//! - `cmux.apps.open` opens UI, so the Mac app answers it; it is not a
//!   daemon op.
//!
//! The types are plain serde, ported from the draft on
//! feat-cmux-next-apps-store; they move to the IR crate (with schemars) when
//! it lands.
//!
//! No wire carries these ops yet: the page channel (the cmux.protocol/2
//! resource dispatcher) needs an origin on the v2 envelope first, so the
//! module is test-only reachable until that binding lands.
#![cfg_attr(not(test), allow(dead_code))]

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::catalog::Package;
use super::mirror::{Origin, Record, SetOp, Source, Tier};
use super::supervisor::{ApiError, Responder, Supervisor};

/// The App Store never lists itself.
const APP_STORE: &str = "cmux/app-store";
const DEFAULT_LIMIT: usize = 50;
const MAX_LIMIT: usize = 200;

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct CatalogListParams {
    query: Option<String>,
    category: Option<String>,
    tier: Option<Tier>,
    /// Opaque cursor from a previous page.
    cursor: Option<String>,
    /// 1 to 200; default 50.
    limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct CatalogGetParams {
    app: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct InstalledListParams {}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SetParams {
    app: String,
    enabled: Option<bool>,
    hidden: Option<bool>,
    sandboxed: Option<bool>,
    idempotency_key: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AppRef {
    app: String,
    idempotency_key: String,
}

#[derive(Debug, Serialize)]
pub(crate) struct CatalogListResult {
    listings: Vec<Listing>,
    next_cursor: Option<String>,
    /// The install mirror revision the install fields reflect.
    revision: u64,
}

/// One store row.
#[derive(Debug, Serialize)]
pub(crate) struct Listing {
    /// `publisher/name`.
    app: String,
    name: String,
    summary: String,
    publisher: String,
    tier: Tier,
    version: String,
    icon: Option<IconRef>,
    categories: Vec<String>,
    /// First-party apps offer Hide and Show only.
    hide_only: bool,
    install: Option<InstallState>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "snake_case")]
enum IconRef {
    /// A path in the package.
    Asset(String),
    /// An SF Symbol name.
    Symbol(String),
}

/// `catalog.get`: the listing plus the scopes the app asks for.
#[derive(Debug, Serialize)]
pub(crate) struct AppDetail {
    #[serde(flatten)]
    listing: Listing,
    scopes: Vec<ScopeRow>,
}

#[derive(Debug, Serialize)]
struct ScopeRow {
    scope: String,
    reason: String,
    /// standard, sensitive, restricted or elevated (scope-classes.json).
    risk: &'static str,
    optional: bool,
}

#[derive(Debug, Serialize)]
struct InstallState {
    installed: bool,
    enabled: bool,
    hidden: bool,
    sandboxed: bool,
    source: Source,
    version: Option<String>,
    update: Option<String>,
}

#[derive(Debug, Serialize)]
pub(crate) struct InstalledListResult {
    revision: u64,
    apps: Vec<InstalledApp>,
}

#[derive(Debug, Serialize)]
struct InstalledApp {
    app: String,
    name: String,
    tier: Tier,
    hide_only: bool,
    state: InstallState,
    grants: Vec<String>,
}

/// `set`, `install` and `uninstall` answer the app's new state.
#[derive(Debug, Serialize)]
struct SetResult {
    revision: u64,
    app: InstalledApp,
}

fn bad_request(e: impl std::fmt::Display) -> ApiError {
    ApiError::new("bad-request", e.to_string())
}

/// Parses op params; absent params are an empty object.
fn params<T: for<'de> Deserialize<'de>>(params: Value) -> Result<T, ApiError> {
    let params = if params.is_null() { Value::Object(Default::default()) } else { params };
    serde_json::from_value(params).map_err(bad_request)
}

fn to_value(value: impl Serialize) -> Result<Value, ApiError> {
    serde_json::to_value(value).map_err(|e| ApiError::new("operation.failed", e.to_string()))
}

/// The en text of a manifest string or `{en: ...}` object.
fn text(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Object(map) => map
            .get("en")
            .or_else(|| map.values().next())
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        _ => String::new(),
    }
}

fn state(record: &Record, package: Option<&Package>) -> InstallState {
    InstallState {
        installed: record.installed,
        enabled: record.enabled,
        hidden: record.hidden,
        sandboxed: record.sandboxed,
        source: record.source,
        version: package.filter(|_| record.installed).map(|p| p.version.clone()),
        update: None,
    }
}

fn listing(package: &Package, record: Option<&Record>) -> Listing {
    let m = &package.manifest;
    let icon = match &m["icon"] {
        Value::String(path) => Some(IconRef::Asset(path.clone())),
        Value::Object(map) => {
            map.get("symbol").and_then(Value::as_str).map(|s| IconRef::Symbol(s.into()))
        }
        _ => None,
    };
    Listing {
        app: package.id.clone(),
        name: text(&m["name"]),
        summary: text(&m["description"]),
        publisher: package.id.split('/').next().unwrap_or_default().to_string(),
        tier: package.tier,
        version: package.version.clone(),
        icon,
        categories: m["categories"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|c| c.as_str().map(str::to_string))
            .collect(),
        hide_only: package.tier == Tier::FirstParty,
        install: record.map(|r| state(r, Some(package))),
    }
}

fn installed_app(app: &str, record: &Record, package: Option<&Package>) -> InstalledApp {
    InstalledApp {
        app: app.to_string(),
        name: package.map_or_else(|| app.to_string(), |p| text(&p.manifest["name"])),
        tier: package.map_or(Tier::Unverified, |p| p.tier),
        hide_only: package.is_some_and(|p| p.tier == Tier::FirstParty),
        state: state(record, package),
        grants: record.grants.iter().cloned().collect(),
    }
}

fn risk(scope: &str) -> &'static str {
    use cmux_app_manifest::ScopeClass;
    match cmux_app_manifest::scope_info(scope).map(|i| i.class) {
        Some(ScopeClass::Standard) => "standard",
        Some(ScopeClass::Sensitive) => "sensitive",
        Some(ScopeClass::Restricted) => "restricted",
        Some(ScopeClass::Elevated) => "elevated",
        None => "unknown",
    }
}

/// Whether `package` matches a catalog query: a case-insensitive substring
/// of its id, name, summary or keywords.
fn matches(package: &Package, query: &str) -> bool {
    let query = query.to_lowercase();
    let m = &package.manifest;
    let keywords = m["keywords"].as_array().into_iter().flatten().filter_map(Value::as_str);
    [package.id.clone(), text(&m["name"]), text(&m["description"])]
        .into_iter()
        .chain(keywords.map(str::to_string))
        .any(|field| field.to_lowercase().contains(&query))
}

impl Supervisor {
    /// Runs one App Store op. `origin` is the request's, admitted by the A2
    /// gate on the wire.
    pub fn store_call(
        &self,
        client: u64,
        op: &str,
        args: Value,
        origin: Origin,
        respond: Responder,
    ) {
        let result = match op.strip_prefix("cmux.").unwrap_or(op) {
            "apps.catalog.list" => params(args).and_then(|p| to_value(self.catalog_list(p)?)),
            "apps.catalog.get" => params(args).and_then(|p| to_value(self.catalog_get(p)?)),
            "apps.installed.list" => {
                params::<InstalledListParams>(args).and_then(|_| to_value(self.installed_list()))
            }
            "apps.set" => params(args).and_then(|p| self.store_set(client, p, origin)),
            "apps.install" => {
                params(args).and_then(|p| self.store_install(client, p, origin, true))
            }
            "apps.uninstall" => {
                params(args).and_then(|p| self.store_install(client, p, origin, false))
            }
            _ => Err(ApiError::new("apps.op.unknown", format!("{op} is not an App Store op"))),
        };
        respond(result);
    }

    fn catalog_list(&self, p: CatalogListParams) -> Result<CatalogListResult, ApiError> {
        let offset = match p.cursor.as_deref() {
            None => 0,
            Some(cursor) => cursor.parse::<usize>().map_err(|_| bad_request("bad cursor"))?,
        };
        let limit = p.limit.map_or(DEFAULT_LIMIT, |l| l as usize).clamp(1, MAX_LIMIT);
        let inner = self.inner.lock().unwrap();
        let rows: Vec<&Package> = inner
            .catalog
            .packages
            .values()
            .filter(|package| package.id != APP_STORE)
            .filter(|package| p.tier.is_none_or(|tier| package.tier == tier))
            .filter(|package| {
                p.category.as_deref().is_none_or(|category| {
                    package.manifest["categories"]
                        .as_array()
                        .is_some_and(|list| list.iter().any(|c| c == category))
                })
            })
            .filter(|package| p.query.as_deref().is_none_or(|query| matches(package, query)))
            .collect();
        let listings = rows
            .iter()
            .skip(offset)
            .take(limit)
            .map(|package| listing(package, inner.mirror.apps.get(&package.id)))
            .collect();
        let next_cursor = (offset + limit < rows.len()).then(|| (offset + limit).to_string());
        Ok(CatalogListResult { listings, next_cursor, revision: inner.mirror.revision })
    }

    fn catalog_get(&self, p: CatalogGetParams) -> Result<AppDetail, ApiError> {
        let inner = self.inner.lock().unwrap();
        let package = inner
            .catalog
            .packages
            .get(&p.app)
            .filter(|package| package.id != APP_STORE)
            .ok_or_else(|| ApiError::new("apps.unknown", "no such app"))?;
        let mut scopes = Vec::new();
        for (field, optional) in [("scopes", false), ("optionalScopes", true)] {
            for (scope, reason) in package.manifest[field].as_object().into_iter().flatten() {
                scopes.push(ScopeRow {
                    scope: scope.clone(),
                    reason: text(reason),
                    risk: risk(scope),
                    optional,
                });
            }
        }
        Ok(AppDetail { listing: listing(package, inner.mirror.apps.get(&p.app)), scopes })
    }

    fn installed_list(&self) -> InstalledListResult {
        let inner = self.inner.lock().unwrap();
        let apps = inner
            .mirror
            .apps
            .iter()
            .filter(|(_, record)| record.installed)
            .map(|(app, record)| installed_app(app, record, inner.catalog.packages.get(app)))
            .collect();
        InstalledListResult { revision: inner.mirror.revision, apps }
    }

    /// The app's state after a commit, as `set`, `install` and `uninstall`
    /// answer it.
    fn set_result(&self, app: &str) -> Result<Value, ApiError> {
        let inner = self.inner.lock().unwrap();
        let fallback = super::mirror::absent(Source::User, None);
        let record = inner.mirror.apps.get(app).unwrap_or(&fallback);
        let result = SetResult {
            revision: inner.mirror.revision,
            app: installed_app(app, record, inner.catalog.packages.get(app)),
        };
        to_value(result)
    }

    fn store_set(&self, client: u64, p: SetParams, origin: Origin) -> Result<Value, ApiError> {
        let op = SetOp {
            key: p.idempotency_key,
            app: p.app.clone(),
            origin,
            enabled: p.enabled,
            hidden: p.hidden,
            sandboxed: p.sandboxed,
            ..SetOp::default()
        };
        self.set(client, op)?;
        self.set_result(&p.app)
    }

    fn store_install(
        &self,
        client: u64,
        p: AppRef,
        origin: Origin,
        install: bool,
    ) -> Result<Value, ApiError> {
        if origin != Origin::User {
            let verb = if install { "installing" } else { "removing" };
            return Err(ApiError::new("apps.origin", format!("{verb} an app needs a user action")));
        }
        let first_party = {
            let inner = self.inner.lock().unwrap();
            inner
                .catalog
                .packages
                .get(&p.app)
                .is_some_and(|package| package.tier == Tier::FirstParty)
        };
        if first_party {
            return Err(ApiError::new(
                "apps.first_party_hide_only",
                "a first-party app ships with cmux; hide or show it instead",
            ));
        }
        let op = SetOp {
            key: p.idempotency_key,
            app: p.app.clone(),
            origin,
            installed: Some(install),
            ..SetOp::default()
        };
        self.set(client, op)?;
        self.set_result(&p.app)
    }
}
