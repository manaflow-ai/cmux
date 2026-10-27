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
//! Every change is origin user only, as `set` (mirror reduce enforces it).

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use cmux_threads::checked::fs as files;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::mirror::{Origin, SetOp};
use super::store::{params, risk, text, to_value};
use super::supervisor::{ApiError, Supervisor};
use crate::panic_free::JsonFields;

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
    /// One panel op, or `None` when `op` is not one.
    pub(super) fn panel_call(
        &self,
        client: u64,
        op: &str,
        args: Value,
        origin: Origin,
    ) -> Option<Result<Value, ApiError>> {
        Some(match op {
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
                for (scope, reason) in
                    package.manifest.field(field).as_object().into_iter().flatten()
                {
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
        let lines = all.field("lines").as_array().cloned().unwrap_or_default();
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
        let size = files::metadata(package.dir.join(&p.path)).map_err(|_| missing())?.len();
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
