//! Approved App Store apps on this machine (plans/cmux-next/
//! custom-panes-DESIGN.md section 6.4). The Cloud registry owns listings and
//! review; the Mac app downloads an approved bundle and hands it here with
//! `apps-store {op: "apps.registry.put"}` (a store mutation: the verified
//! cmux app connection only, `store_op_mutates`). The supervisor owns the
//! folder: it checks the bundle hash against the listing's, validates the
//! package, writes it atomically to `<state>/apps/registry/<namespace>/` and
//! reloads its catalog. Installing it is the ordinary `apps.install`, behind
//! the native scopes sheet; a registry app is unverified and starts sandboxed.

use std::collections::BTreeMap;
use std::path::{Component, Path};
use std::sync::PoisonError;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::catalog;
use super::mirror::Source;
use super::supervisor::{ApiError, Out, Supervisor};

/// Bundle limits, the same as the registry's (section 6.3).
const MAX_FILES: usize = 200;
const MAX_BYTES: usize = 2 * 1024 * 1024;
/// Publishers the registry never lists.
const RESERVED: [&str; 3] = ["cmux", "manaflow-ai", "local"];

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct PutParams {
    app: String,
    version: String,
    /// The listing's bundle hash (section 6.2), lowercase hex.
    sha256: String,
    /// Path in the package to its bytes, base64.
    files: BTreeMap<String, String>,
}

fn bad(code: &str, message: impl Into<String>) -> ApiError {
    ApiError::new(code, message)
}

/// The bundle hash of section 6.2: every file in ascending byte order of its
/// path, each as `path 0x00 <decimal length> 0x00 bytes`; lowercase hex.
pub(super) fn bundle_sha256(files: &BTreeMap<String, Vec<u8>>) -> String {
    let mut hasher = Sha256::new();
    for (path, bytes) in files {
        hasher.update(path.as_bytes());
        hasher.update([0]);
        hasher.update(bytes.len().to_string().as_bytes());
        hasher.update([0]);
        hasher.update(bytes);
    }
    hasher.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// A relative path with only normal components (no root, `.`, `..`, empty
/// part or backslash), at most 256 bytes.
fn safe_path(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= 256
        && !path.contains('\\')
        && !path.split('/').any(str::is_empty)
        && Path::new(path).components().all(|c| matches!(c, Component::Normal(_)))
}

/// `<publisher>/<name>` of a third-party app, with the manifest schema's id
/// pattern: a publisher of 1 to 39 and a name of 1 to 64 lowercase letters,
/// digits and `-`, each starting with a letter or digit.
pub(super) fn registry_app(app: &str) -> bool {
    let Some((publisher, name)) = app.split_once('/') else { return false };
    let part = |s: &str, max: usize| {
        !s.is_empty()
            && s.len() <= max
            && s.starts_with(|c: char| c.is_ascii_lowercase() || c.is_ascii_digit())
            && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    };
    part(publisher, 39) && part(name, 64) && !RESERVED.contains(&publisher)
}

/// The decoded files of `p`, checked against every limit and the hash.
fn decoded(p: &PutParams) -> Result<BTreeMap<String, Vec<u8>>, ApiError> {
    if !registry_app(&p.app) {
        return Err(bad("apps.registry.app", "not an App Store app id"));
    }
    if p.files.is_empty() || p.files.len() > MAX_FILES {
        return Err(bad("apps.registry.too_large", format!("a bundle has 1 to {MAX_FILES} files")));
    }
    let mut files = BTreeMap::new();
    let mut folded = std::collections::BTreeSet::new();
    let mut total = 0usize;
    for (path, body) in &p.files {
        if !safe_path(path) {
            return Err(bad("apps.registry.path", format!("{path}: not a safe relative path")));
        }
        // Paths that differ only in case land on one file of a case-insensitive disk.
        if !folded.insert(path.to_ascii_lowercase()) {
            return Err(bad(
                "apps.registry.path",
                format!("{path}: another path differs only in case"),
            ));
        }
        let bytes = STANDARD
            .decode(body)
            .map_err(|_| bad("apps.registry.encoding", format!("{path}: not base64")))?;
        total += bytes.len();
        if total > MAX_BYTES {
            return Err(bad("apps.registry.too_large", "the bundle is larger than 2 MiB"));
        }
        files.insert(path.clone(), bytes);
    }
    // The registry reads `cmux-app.v2.json` first and the catalog
    // `cmux-app.json`, and the disk may ignore case: with two manifest files
    // in any case, a reviewer could approve one and the Mac install the other.
    let manifests = [catalog::V2_MANIFEST, "cmux-app.json"];
    let manifest_like =
        files.keys().filter(|path| manifests.contains(&path.to_ascii_lowercase().as_str()));
    if manifest_like.clone().count() > 1
        || manifest_like.clone().any(|path| !manifests.contains(&path.as_str()))
    {
        return Err(bad(
            "apps.registry.manifest",
            "a bundle has one manifest file, named in lowercase",
        ));
    }
    if bundle_sha256(&files) != p.sha256.to_ascii_lowercase() {
        return Err(bad("apps.registry.hash", "the bundle does not match the listing's hash"));
    }
    Ok(files)
}

/// Writes `files` under `dir` (created fresh).
fn write_tree(dir: &Path, files: &BTreeMap<String, Vec<u8>>) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    for (path, bytes) in files {
        let file = dir.join(path);
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(file, bytes)?;
    }
    Ok(())
}

impl Supervisor {
    /// `apps.registry.put` (see the module docs). Answers `{app, version,
    /// sha256}` once the app is in the catalog.
    pub(super) fn registry_put(&self, p: PutParams) -> Result<Value, ApiError> {
        let root =
            self.config.sources.registry.clone().ok_or_else(|| {
                bad("apps.registry.unavailable", "this daemon has no state folder")
            })?;
        let files = decoded(&p)?;
        let _one_put = self.registry_puts.lock().unwrap_or_else(PoisonError::into_inner);
        // First source wins in the catalog: a bundled or extra folder with the
        // same id would shadow the copy, so nothing is written for it.
        let shadowed = self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .catalog
            .packages
            .get(&p.app)
            .is_some_and(|package| package.source != Source::Registry);
        if shadowed {
            return Err(bad("apps.registry.shadowed", "another copy of this app is installed"));
        }
        let namespace = cmux_app_manifest::app_namespace(&p.app);
        // Staged beside the registry folder (same volume, so the rename below
        // is atomic) and never inside it, where a catalog read would see it.
        let spare = root.with_file_name("registry-staging");
        let staging = spare.join(format!("incoming-{namespace}-{}", super::calls::mint_key()));
        let io = |e: std::io::Error| bad("apps.registry.write", e.to_string());
        let checked = write_tree(&staging, &files).map_err(io).and_then(|()| {
            let report = cmux_app_manifest::validate_package_file(
                &staging,
                catalog::manifest_file(&staging, false),
            );
            let manifest = report.manifest.as_ref().filter(|_| report.is_valid());
            match manifest {
                None => Err(bad("apps.registry.invalid", "the bundle is not a valid cmux app")),
                Some(m) if m["id"] != p.app.as_str() || m["version"] != p.version.as_str() => {
                    Err(bad(
                        "apps.registry.mismatch",
                        "the bundle's manifest names another app or version",
                    ))
                }
                Some(_) => Ok(()),
            }
        });
        if let Err(error) = checked {
            let _ = std::fs::remove_dir_all(&staging);
            return Err(error);
        }
        // Swap folders by rename, so the catalog never reads a half-written app.
        let target = root.join(&namespace);
        let old = spare.join(format!("old-{namespace}-{}", super::calls::mint_key()));
        let had_old = target.exists();
        std::fs::create_dir_all(&root).map_err(io)?;
        if had_old {
            std::fs::rename(&target, &old).map_err(io)?;
        }
        if let Err(e) = std::fs::rename(&staging, &target) {
            if had_old {
                let _ = std::fs::rename(&old, &target);
            }
            let _ = std::fs::remove_dir_all(&staging);
            return Err(io(e));
        }
        if had_old {
            let _ = std::fs::remove_dir_all(&old);
        }
        self.reload_catalog_for(&p.app, "registry-put");
        // First source wins in the catalog: a bundled or extra folder with the
        // same id would shadow the copy just written.
        let source = self
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .catalog
            .packages
            .get(&p.app)
            .map(|p| p.source);
        match source {
            Some(Source::Registry) => {}
            Some(_) => {
                return Err(bad("apps.registry.shadowed", "another copy of this app is installed"));
            }
            None => return Err(bad("apps.registry.invalid", "the app did not load")),
        }
        Ok(json!({ "app": p.app, "version": p.version, "sha256": p.sha256.to_ascii_lowercase() }))
    }

    /// Reads the catalog again (off the lock), swaps it in, regrants `app`
    /// if it runs, and tells clients it changed.
    fn reload_catalog_for(&self, app: &str, transaction: &str) {
        let catalog = catalog::load(&self.config.sources);
        let outs: Vec<Out> = {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            inner.catalog = catalog;
            let mut outs = self.regrant_locked(&mut inner, app);
            outs.push(Out::Broadcast(json!({
                "event": "apps-changed",
                "revision": inner.mirror.revision,
                "transaction": transaction,
                "app": app,
            })));
            outs
        };
        self.emit(outs);
    }
}
