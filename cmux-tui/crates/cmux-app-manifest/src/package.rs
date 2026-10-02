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
    let path = dir.join("cmux-app.json");
    let raw = match std::fs::read(&path) {
        Ok(raw) => raw,
        Err(_) => return PackageReport { manifest: None, issues: vec![Issue::error("", "manifest.missing", "cmux-app.json not found")] },
    };
    let mut issues = Vec::new();
    if raw.len() as u64 > MANIFEST_LIMIT {
        issues.push(Issue::error("", "limit.manifest", "cmux-app.json is larger than 64 KiB"));
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
    if let Some(implements) = m["implements"].as_object() {
        for (name, imp) in implements {
            add(&format!("/implements/{}/web", crate::issue::escape(name)), imp.get("web"));
        }
    }
    let files: Option<Vec<&str>> = m["files"].as_array().map(|a| a.iter().filter_map(Value::as_str).collect());
    let mut out = Vec::new();
    for (at, p) in refs {
        if Path::new(&p).components().any(|c| matches!(c, Component::ParentDir | Component::RootDir)) {
            out.push(Issue::error(at, "path.escape", format!("{p} leaves the package")));
            continue;
        }
        let full = dir.join(&p);
        if !full.exists() {
            out.push(Issue::error(at, "path.missing", format!("{p} does not exist")));
            continue;
        }
        if let Some(files) = &files
            && !files.iter().any(|f| p == *f || p.starts_with(&format!("{}/", f.trim_end_matches('/'))))
        {
            out.push(Issue::error(at.clone(), "path.notInFiles", format!("{p} is not listed in files")));
        }
        if at == "/runtime/main" && std::fs::metadata(&full).map(|md| md.len() > MAIN_LIMIT).unwrap_or(false) {
            out.push(Issue::error(at, "limit.main", "runtime.main is larger than 2 MiB"));
        }
    }
    out
}
