//! Package-level checks: the manifest file, the files it names, size limits.

use crate::issue::Issue;
use serde_json::Value;
use std::path::{Component, Path};

const MANIFEST_LIMIT: u64 = 64 * 1024;
const MAIN_LIMIT: u64 = 2 * 1024 * 1024;

/// The result of validating a package directory.
#[derive(Debug)]
pub struct PackageReport {
    pub manifest: Option<Value>,
    /// The catalog fragment (`catalog: "<file>"`) as validated, so a
    /// consumer keeps it in memory instead of reading the file again.
    pub catalog: Option<Value>,
    pub issues: Vec<Issue>,
}

impl PackageReport {
    pub fn is_valid(&self) -> bool {
        crate::is_valid(&self.issues)
    }

    fn refused(code: &'static str, message: String) -> Self {
        Self { manifest: None, catalog: None, issues: vec![Issue::error("", code, message)] }
    }
}

/// Validates `dir/cmux-app.json` and the files it references.
pub fn validate_package(dir: &Path) -> PackageReport {
    validate_package_file(dir, "cmux-app.json")
}

/// Validates the manifest `dir/<file_name>` (for example `cmux-app.v2.json`
/// while a package still ships a v1 `cmux-app.json`) and the files it
/// references, the catalog fragment included. At most one byte past the
/// manifest limit is read: a manifest over it is refused on its size, with
/// nothing parsed (base: a manifest of any size was read, parsed and
/// schema-checked in full, on every local reload pass).
pub fn validate_package_file(dir: &Path, file_name: &str) -> PackageReport {
    let Some(raw) = read_limited(&dir.join(file_name), MANIFEST_LIMIT) else {
        return PackageReport::refused("manifest.missing", format!("{file_name} not found"));
    };
    if raw.len() as u64 > MANIFEST_LIMIT {
        return PackageReport::refused(
            "limit.manifest",
            format!("{file_name} is larger than 64 KiB"),
        );
    }
    let mut issues = Vec::new();
    let manifest: Value = match serde_json::from_slice(&raw) {
        Ok(v) => v,
        Err(e) => {
            issues.push(Issue::error("", "json.invalid", e.to_string()));
            return PackageReport { manifest: None, catalog: None, issues };
        }
    };
    issues.extend(crate::validate_manifest(&manifest));
    if crate::is_valid(&issues) {
        issues.extend(referenced_files(dir, &manifest));
    }
    let mut catalog = None;
    if crate::is_valid(&issues) {
        let (fragment, found) = catalog_file(dir, &manifest);
        catalog = fragment;
        issues.extend(found);
    }
    PackageReport { manifest: Some(manifest), catalog, issues }
}

/// Bytes a catalog fragment may hold: four manifests' worth (it lists every
/// op with its input schema). Past it the fragment is refused unread.
const CATALOG_LIMIT: u64 = 4 * MANIFEST_LIMIT;

/// `path`'s first `limit + 1` bytes (one past the limit says it is over);
/// `None` when it cannot be opened or read.
fn read_limited(path: &Path, limit: u64) -> Option<Vec<u8>> {
    use std::io::Read as _;
    let file = std::fs::File::open(path).ok()?;
    let mut raw = Vec::new();
    file.take(limit + 1).read_to_end(&mut raw).ok()?;
    Some(raw)
}

fn referenced_files(dir: &Path, m: &Value) -> Vec<Issue> {
    let mut refs: Vec<(String, String)> = Vec::new();
    let mut add = |at: &str, v: Option<&Value>| {
        if let Some(p) = v.and_then(Value::as_str) {
            refs.push((at.to_string(), p.to_string()));
        }
    };
    add("/runtime/main", m.pointer("/runtime/main"));
    add("/runtime/web/root", m.pointer("/runtime/web/root"));
    add("/catalog", m.get("catalog"));
    add("/strings", m.get("strings"));
    if m["icon"].is_string() {
        add("/icon", m.get("icon"));
    }
    if m.pointer("/presentation/sidebarItem/icon").is_some_and(Value::is_string) {
        add("/presentation/sidebarItem/icon", m.pointer("/presentation/sidebarItem/icon"));
    }
    if let Some(implements) = m["implements"].as_object() {
        for (name, imp) in implements {
            add(&format!("/implements/{}/web", crate::issue::escape(name)), imp.get("web"));
        }
    }
    for (i, notice) in m["notices"].as_array().into_iter().flatten().enumerate() {
        add(&format!("/notices/{i}/path"), notice.get("path"));
    }
    let files: Option<Vec<&str>> =
        m["files"].as_array().map(|a| a.iter().filter_map(Value::as_str).collect());
    let mut out = Vec::new();
    for (at, p) in refs {
        if Path::new(&p)
            .components()
            .any(|c| matches!(c, Component::ParentDir | Component::RootDir))
        {
            out.push(Issue::error(at, "path.escape", format!("{p} leaves the package")));
            continue;
        }
        let full = dir.join(&p);
        if !full.exists() {
            out.push(Issue::error(at, "path.missing", format!("{p} does not exist")));
            continue;
        }
        // A folder entry (`web/`) covers the folder itself (`runtime.web.root: "web"`) and
        // everything under it.
        if let Some(files) = &files
            && !files.iter().any(|f| {
                let f = f.trim_end_matches('/');
                let p = p.trim_end_matches('/');
                p == f || p.starts_with(&format!("{f}/"))
            })
        {
            out.push(Issue::error(
                at.clone(),
                "path.notInFiles",
                format!("{p} is not listed in files"),
            ));
        }
        if at == "/runtime/main" {
            if std::fs::metadata(&full).map(|md| md.len() > MAIN_LIMIT).unwrap_or(false) {
                out.push(Issue::error(at, "limit.main", "runtime.main is larger than 2 MiB"));
            } else if let Ok(script) = std::fs::read(&full) {
                // The script the host runs: no character that hides what it
                // does (hidden.rs). Not UTF-8 is the host's own refusal.
                if let Some(issue) = std::str::from_utf8(&script)
                    .ok()
                    .and_then(|text| crate::hidden::script_issue(&at, &p, text))
                {
                    out.push(issue);
                }
            }
        }
    }
    out
}

/// `dir/rel` resolved through symlinks, only when it stays under `dir`
/// resolved the same way: an extension cannot point its catalog at a file
/// outside its own folder (the check `Package::read` made before the
/// fragment was kept here).
fn inside(dir: &Path, rel: &str) -> Option<std::path::PathBuf> {
    let root = dir.canonicalize().ok()?;
    let path = dir.join(rel).canonicalize().ok()?;
    path.starts_with(&root).then_some(path)
}

/// The catalog fragment, parsed, and its issues.
fn catalog_file(dir: &Path, m: &Value) -> (Option<Value>, Vec<Issue>) {
    let Some(rel) = m["catalog"].as_str() else { return (None, Vec::new()) };
    let parsed = inside(dir, rel)
        .ok_or_else(|| format!("{rel} is not a file inside the package"))
        .and_then(|path| {
            read_limited(&path, CATALOG_LIMIT).ok_or_else(|| format!("{rel} cannot be read"))
        })
        .and_then(|raw| {
            if raw.len() as u64 > CATALOG_LIMIT {
                return Err(format!("{rel} is larger than {} KiB", CATALOG_LIMIT >> 10));
            }
            serde_json::from_slice::<Value>(&raw).map_err(|e| e.to_string())
        });
    match parsed {
        Ok(catalog) => {
            let issues = crate::validate_catalog(m, &catalog);
            (Some(catalog), issues)
        }
        Err(e) => (None, vec![Issue::error("/catalog", "catalog.json", e)]),
    }
}

#[cfg(test)]
#[path = "package_tests.rs"]
mod tests;
