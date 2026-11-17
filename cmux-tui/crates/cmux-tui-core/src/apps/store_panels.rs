//! The App Store's installed-app panels (`cmux.apps.*`, apps/store.rs):
//! what the Installed list shows beside each app and the changes it makes,
//! so every page host (the React page, a browser, the CLI) gets them from
//! the daemon (cx-hnmbt.13).
//!
//! - `grants.get`: the app's scopes (required and optional), each with
//!   whether it is granted, and whether the app is sandboxed.
//! - `logs`: the last lines of the app's log ring (no stream; the page
//!   reads again).
//! - `asset.get`: an image file of the package (its icon) as a `data:` URL.
//! - `hidden.set`: Hide or Show. It changes what the user sees, never what
//!   an app may do, so the Apps page needs only the person's gesture.
//! - `grant.set`: allow or revoke one scope (the Apps page asks on a native
//!   sheet: an allowed scope widens what the app may do).
//! - `grant.revoke`: revoke one scope (a gesture is enough: it only narrows).
//!
//! - `panels.list`: the page panels of installed, visible apps for one
//!   interface (`cmux.session.info.section/1` when none is named, or
//!   `cmux.newtab.widget/1` with the person's New Tab widget layout). It reads
//!   the catalog and the mirror only: no host starts until a page mounts one.
//! - `panels.layout.set`: the New Tab widget layout (which widgets are placed,
//!   in the person's order), kept in `<state>/apps-newtab-layout.json`.
//!
//! Every change is origin user only, as `set` (mirror reduce enforces it).

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::mirror::{Origin, SetOp};
use super::store::{params, risk, text, to_value};
use super::supervisor::{ApiError, Supervisor};

/// Session Info's app sections.
const SESSION_INFO_SECTION: &str = "cmux.session.info.section/1";
/// The New Tab page's widgets.
const NEW_TAB_WIDGET: &str = "cmux.newtab.widget/1";
/// The interfaces a page lists and mounts through `apps.panels.*`.
const PAGE_INTERFACES: &[&str] = &[SESSION_INFO_SECTION, NEW_TAB_WIDGET];
/// The New Tab layout file in the state directory.
const NEW_TAB_LAYOUT_FILE: &str = "apps-newtab-layout.json";
/// The most entries a New Tab layout holds, and the longest one (an
/// `app:<id>#<interface>` widget id or a built-in widget's name).
const MAX_LAYOUT_ENTRIES: usize = 64;
const MAX_LAYOUT_ENTRY_BYTES: usize = 256;

/// One page panel: a Session Info section or a New Tab widget. A v2 app
/// implements an interface once, so `section` is the interface name.
#[derive(Debug, Serialize)]
struct PagePanel {
    app: String,
    section: String,
    title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    symbol: Option<String>,
    #[serde(rename = "maxRows", skip_serializing_if = "Option::is_none")]
    max_rows: Option<u64>,
    /// A New Tab widget's cell: `small` or `wide`.
    #[serde(skip_serializing_if = "Option::is_none")]
    size: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct PanelsListParams {
    /// Session Info's sections when absent (the op's first contract).
    interface: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct LayoutSetParams {
    interface: String,
    /// Widget ids in the person's order: built-in names and `app:<id>#<interface>`.
    layout: Vec<String>,
    idempotency_key: String,
}

/// The largest asset `asset.get` answers (an icon, never a bundle).
const MAX_ASSET_BYTES: usize = 512 * 1024;
/// The most log lines `logs` answers.
const MAX_LOG_LINES: usize = 500;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AppParams {
    app: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct LogsParams {
    app: String,
    /// 1 to 500; default all lines the ring holds.
    limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AssetParams {
    app: String,
    /// A path in the package, as the manifest names it.
    path: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct HiddenParams {
    app: String,
    hidden: bool,
    idempotency_key: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct GrantParams {
    app: String,
    scope: String,
    granted: bool,
    idempotency_key: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RevokeParams {
    app: String,
    scope: String,
    idempotency_key: String,
}

#[derive(Debug, Serialize)]
struct GrantRow {
    scope: String,
    reason: String,
    risk: &'static str,
    optional: bool,
    granted: bool,
}

#[derive(Debug, Serialize)]
struct Grants {
    app: String,
    sandboxed: bool,
    scopes: Vec<GrantRow>,
}

/// The image types `asset.get` answers, by file extension.
fn image_type(path: &str) -> Option<&'static str> {
    let ext = path.rsplit_once('.')?.1.to_ascii_lowercase();
    Some(match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        _ => return None,
    })
}

impl Supervisor {
    /// The page panels for `interface` of installed, enabled and visible apps.
    /// It reads the catalog and the mirror only (R1: listing starts no host);
    /// a New Tab listing also carries the person's widget layout.
    pub(super) fn page_panels(&self, interface: Option<&str>) -> Result<Value, ApiError> {
        let interface = interface.unwrap_or(SESSION_INFO_SECTION);
        if !PAGE_INTERFACES.contains(&interface) {
            return Err(ApiError::new(
                "apps.panels.interface",
                format!("{interface} is not drawn on a page; use one of {PAGE_INTERFACES:?}"),
            ));
        }
        let panels: Vec<PagePanel> = {
            let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            inner
                .mirror
                .apps
                .iter()
                .filter(|(_, record)| record.installed && record.enabled && !record.hidden)
                .filter_map(|(app, _)| {
                    let entry = inner
                        .catalog
                        .packages
                        .get(app)?
                        .manifest
                        .get("implements")?
                        .get(interface)?;
                    let widget = interface == NEW_TAB_WIDGET;
                    Some(PagePanel {
                        app: app.clone(),
                        section: interface.to_string(),
                        title: entry.get("title").map_or_else(|| app.clone(), text),
                        symbol: entry.get("symbol").and_then(Value::as_str).map(str::to_string),
                        max_rows: (!widget)
                            .then(|| entry.pointer("/options/maxRows").and_then(Value::as_u64))
                            .flatten(),
                        size: widget.then(|| {
                            entry
                                .pointer("/options/size")
                                .and_then(Value::as_str)
                                .unwrap_or("small")
                                .to_string()
                        }),
                    })
                })
                .collect()
        };
        if interface == NEW_TAB_WIDGET {
            return Ok(json!({ "panels": panels, "layout": self.new_tab_layout() }));
        }
        Ok(json!({ "panels": panels }))
    }

    /// The person's New Tab widget layout; empty when none was saved or the
    /// file does not read (a fresh page shows only the built-in widgets).
    fn new_tab_layout(&self) -> Vec<String> {
        let Some(dir) = &self.config.state_dir else { return Vec::new() };
        std::fs::read(dir.join(NEW_TAB_LAYOUT_FILE))
            .ok()
            .and_then(|raw| serde_json::from_slice::<Value>(&raw).ok())
            .and_then(|doc| doc.get("layout").cloned())
            .and_then(|layout| serde_json::from_value::<Vec<String>>(layout).ok())
            .unwrap_or_default()
    }

    /// `apps.panels.layout.set`: saves the New Tab layout the page's edit mode
    /// left (a person's gesture only). Replacing the whole list makes a replay
    /// with the same key the same write.
    fn new_tab_layout_set(&self, p: LayoutSetParams, origin: Origin) -> Result<Value, ApiError> {
        if origin != Origin::User {
            return Err(ApiError::new(
                "apps.origin",
                "only a person can change the New Tab layout",
            ));
        }
        if p.interface != NEW_TAB_WIDGET {
            return Err(ApiError::new(
                "apps.panels.interface",
                "only New Tab widgets have a layout",
            ));
        }
        if p.idempotency_key.is_empty() {
            return Err(ApiError::new("bad-request", "idempotency_key is required"));
        }
        if p.layout.len() > MAX_LAYOUT_ENTRIES {
            return Err(ApiError::new("bad-request", "a layout holds at most 64 widgets"));
        }
        let mut seen = std::collections::BTreeSet::new();
        for entry in &p.layout {
            if entry.is_empty() || entry.len() > MAX_LAYOUT_ENTRY_BYTES {
                return Err(ApiError::new("bad-request", "a widget id is 1 to 256 bytes"));
            }
            if !seen.insert(entry.as_str()) {
                return Err(ApiError::new(
                    "bad-request",
                    format!("{entry} is in the layout twice"),
                ));
            }
        }
        // Under the supervisor lock: two pages' writes land one after the other.
        let _inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(dir) = &self.config.state_dir {
            write_durably(dir, NEW_TAB_LAYOUT_FILE, &json!({ "version": 1, "layout": p.layout }))
                .map_err(|e| ApiError::new("operation.failed", e.to_string()))?;
        }
        Ok(json!({ "layout": p.layout }))
    }

    /// One panel op, or `None` when `op` is not one.
    pub(super) fn panel_call(
        &self,
        client: u64,
        op: &str,
        args: Value,
        origin: Origin,
    ) -> Option<Result<Value, ApiError>> {
        Some(match op {
            "apps.panels.list" => params::<PanelsListParams>(args)
                .and_then(|p| self.page_panels(p.interface.as_deref())),
            "apps.panels.layout.set" => {
                params(args).and_then(|p| self.new_tab_layout_set(p, origin))
            }
            "apps.grants.get" => params(args).and_then(|p| to_value(self.grants_get(p)?)),
            "apps.logs" => params(args).and_then(|p| self.logs_tail(client, p)),
            "apps.asset.get" => params(args).and_then(|p| self.asset_get(p)),
            "apps.hidden.set" => params(args).and_then(|p: HiddenParams| {
                let op = SetOp {
                    key: p.idempotency_key,
                    app: p.app.clone(),
                    origin,
                    hidden: Some(p.hidden),
                    ..SetOp::default()
                };
                self.set(client, op)?;
                self.set_result(&p.app)
            }),
            "apps.grant.set" => params(args).and_then(|p: GrantParams| {
                self.grant(client, p.app, p.scope, p.granted, p.idempotency_key, origin)
            }),
            "apps.grant.revoke" => params(args).and_then(|p: RevokeParams| {
                self.grant(client, p.app, p.scope, false, p.idempotency_key, origin)
            }),
            _ => return None,
        })
    }

    fn grant(
        &self,
        client: u64,
        app: String,
        scope: String,
        granted: bool,
        key: String,
        origin: Origin,
    ) -> Result<Value, ApiError> {
        let op = SetOp {
            key,
            app: app.clone(),
            origin,
            grant: Some((scope, granted)),
            ..SetOp::default()
        };
        self.set(client, op)?;
        self.set_result(&app)
    }

    fn grants_get(&self, p: AppParams) -> Result<Grants, ApiError> {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let record = inner
            .mirror
            .apps
            .get(&p.app)
            .filter(|record| record.installed)
            .ok_or_else(|| ApiError::new("apps.not_installed", "the app is not installed"))?;
        let mut scopes = Vec::new();
        if let Some(package) = inner.catalog.packages.get(&p.app) {
            for (field, optional) in [("scopes", false), ("optionalScopes", true)] {
                for (scope, reason) in package.manifest[field].as_object().into_iter().flatten() {
                    scopes.push(GrantRow {
                        scope: scope.clone(),
                        reason: text(reason),
                        risk: risk(scope),
                        optional,
                        granted: record.grants.contains(scope),
                    });
                }
            }
        }
        Ok(Grants { app: p.app, sandboxed: record.sandboxed, scopes })
    }

    fn logs_tail(&self, client: u64, p: LogsParams) -> Result<Value, ApiError> {
        let known = self
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .catalog
            .packages
            .contains_key(&p.app);
        if !known {
            return Err(ApiError::new("apps.unknown", "no such app"));
        }
        let limit = p.limit.map_or(MAX_LOG_LINES, |l| l as usize).clamp(1, MAX_LOG_LINES);
        let all = self.logs(client, &p.app, false);
        let lines = all["lines"].as_array().cloned().unwrap_or_default();
        let skip = lines.len().saturating_sub(limit);
        Ok(json!({ "app": p.app, "lines": lines.into_iter().skip(skip).collect::<Vec<_>>() }))
    }

    fn asset_get(&self, p: AssetParams) -> Result<Value, ApiError> {
        let mime = image_type(&p.path)
            .ok_or_else(|| ApiError::new("apps.asset.type", "only image assets are served"))?;
        // The package, out of the lock: the file reads below never hold the supervisor.
        let package = self
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .catalog
            .packages
            .get(&p.app)
            .cloned()
            .ok_or_else(|| ApiError::new("apps.unknown", "no such app"))?;
        let missing = || ApiError::new("apps.asset.missing", "the package has no such file");
        let size = std::fs::metadata(package.dir.join(&p.path)).map_err(|_| missing())?.len();
        if size > MAX_ASSET_BYTES as u64 {
            return Err(ApiError::new("apps.asset.too_large", "the asset is larger than 512 KiB"));
        }
        // `read` refuses a path (or a symlink on the way) that leaves the package.
        let bytes = package.read(&p.path).ok_or_else(missing)?;
        if bytes.len() > MAX_ASSET_BYTES {
            return Err(ApiError::new("apps.asset.too_large", "the asset is larger than 512 KiB"));
        }
        Ok(json!({
            "app": p.app,
            "path": p.path,
            "data_url": format!("data:{mime};base64,{}", STANDARD.encode(&bytes)),
        }))
    }
}

/// Writes `name` in `dir` durably: temp file, fsync, rename.
fn write_durably(dir: &std::path::Path, name: &str, value: &Value) -> std::io::Result<()> {
    use std::io::Write as _;
    std::fs::create_dir_all(dir)?;
    let temp = dir.join(format!("{name}.tmp"));
    let body = serde_json::to_vec_pretty(value).map_err(std::io::Error::other)?;
    let mut file = std::fs::File::create(&temp)?;
    file.write_all(&body)?;
    file.sync_all()?;
    std::fs::rename(&temp, dir.join(name))
}
