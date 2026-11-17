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
    pub issues: Vec<Issue>,
}

impl PackageReport {
    pub fn is_valid(&self) -> bool {
        crate::is_valid(&self.issues)
    }
}

/// Validates `dir/cmux-app.json` and the files it references.
pub fn validate_package(dir: &Path) -> PackageReport {
    validate_package_file(dir, "cmux-app.json")
}

/// Validates the manifest `dir/<file_name>` (for example `cmux-app.v2.json`
/// while a package still ships a v1 `cmux-app.json`) and the files it
/// references, the catalog fragment included.
pub fn validate_package_file(dir: &Path, file_name: &str) -> PackageReport {
    let path = dir.join(file_name);
    let raw = match std::fs::read(&path) {
        Ok(raw) => raw,
        Err(_) => {
            return PackageReport {
                manifest: None,
                issues: vec![Issue::error(
                    "",
                    "manifest.missing",
                    format!("{file_name} not found"),
                )],
            };
        }
    };
    let mut issues = Vec::new();
    if raw.len() as u64 > MANIFEST_LIMIT {
        issues.push(Issue::error(
            "",
            "limit.manifest",
            format!("{file_name} is larger than 64 KiB"),
        ));
    }
    let manifest: Value = match serde_json::from_slice(&raw) {
        Ok(v) => v,
        Err(e) => {
            issues.push(Issue::error("", "json.invalid", e.to_string()));
            return PackageReport { manifest: None, issues };
        }
    };
    issues.extend(crate::validate_manifest(&manifest));
    if crate::is_valid(&issues) {
        issues.extend(referenced_files(dir, &manifest));
    }
    if crate::is_valid(&issues) {
        issues.extend(catalog_file(dir, &manifest));
    }
    PackageReport { manifest: Some(manifest), issues }
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

fn catalog_file(dir: &Path, m: &Value) -> Vec<Issue> {
    let Some(rel) = m["catalog"].as_str() else { return Vec::new() };
    let parsed = std::fs::read(dir.join(rel))
        .map_err(|e| e.to_string())
        .and_then(|raw| serde_json::from_slice::<Value>(&raw).map_err(|e| e.to_string()));
    match parsed {
        Ok(catalog) => crate::validate_catalog(m, &catalog),
        Err(e) => vec![Issue::error("/catalog", "catalog.json", e)],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir() -> std::path::PathBuf {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        let dir = std::env::temp_dir()
            .join(format!("cmux-manifest-limit-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A manifest past 64 KiB is refused on its size alone: nothing past
    /// the limit is parsed, so a broken far end reports no JSON error, and
    /// no manifest comes back (base red: the whole file was read and parsed,
    /// and a valid oversize manifest came back parsed).
    #[test]
    fn an_oversize_manifest_is_refused_without_parsing_it() {
        let dir = dir();
        let pad = "x".repeat(MANIFEST_LIMIT as usize);
        std::fs::write(dir.join("cmux-app.json"), format!(r#"{{"name":"{pad}"}}"#)).unwrap();
        let valid_json = validate_package(&dir);
        std::fs::write(dir.join("cmux-app.json"), format!(r#"{{"name":"{pad}" BROKEN"#)).unwrap();
        let broken_tail = validate_package(&dir);
        let _ = std::fs::remove_dir_all(&dir);
        for report in [valid_json, broken_tail] {
            assert!(report.manifest.is_none(), "an oversize manifest is not parsed");
            let codes: Vec<&str> = report.issues.iter().map(|i| i.code).collect();
            assert_eq!(codes, ["limit.manifest"], "{:?}", report.issues);
        }
    }
}
