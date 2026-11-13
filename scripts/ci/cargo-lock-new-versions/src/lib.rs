//! A changed Cargo.lock may only use (crate, version) pairs some base Cargo.lock already has,
//! unless the pull request says it adds new ones. cmux#42155 called itself a version
//! "alignment" and said it added no versions; it added seven. This makes that claim checked.

use std::collections::BTreeSet;

/// The pull request body line that allows new versions. Its text after the colon is the reason.
pub const ALLOW_KEY: &str = "Cargo-Lock-New-Versions:";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Package {
    pub name: String,
    pub version: String,
    /// None for a path package (a workspace member): its version is the repository's own, not a download.
    pub source: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Finding {
    pub lock: String,
    pub name: String,
    pub version: String,
}

/// Reads the `[[package]]` entries of a Cargo.lock (any lock format version).
pub fn parse_lock(text: &str) -> Vec<Package> {
    let mut out = Vec::new();
    let mut current: Option<(Option<String>, Option<String>, Option<String>)> = None;
    let mut flush = |cur: &mut Option<(Option<String>, Option<String>, Option<String>)>| {
        if let Some((Some(name), Some(version), source)) = cur.take() {
            out.push(Package {
                name,
                version,
                source,
            });
        }
    };
    for raw in text.lines() {
        let line = raw.trim();
        if line.starts_with('[') {
            flush(&mut current);
            if line == "[[package]]" {
                current = Some((None, None, None));
            }
            continue;
        }
        let Some(cur) = current.as_mut() else {
            continue;
        };
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim();
        let Some(value) = value.strip_prefix('"').and_then(|v| v.strip_suffix('"')) else {
            continue;
        };
        match key.trim() {
            "name" => cur.0 = Some(value.to_string()),
            "version" => cur.1 = Some(value.to_string()),
            "source" => cur.2 = Some(value.to_string()),
            _ => {}
        }
    }
    flush(&mut current);
    out
}

/// Every (crate, version) any of the base locks has.
pub fn base_set<'a>(base_locks: impl IntoIterator<Item = &'a str>) -> BTreeSet<(String, String)> {
    base_locks
        .into_iter()
        .flat_map(parse_lock)
        .map(|p| (p.name, p.version))
        .collect()
}

/// The downloaded (crate, version) pairs in the changed locks that no base lock has.
/// Path packages are skipped: bumping a workspace member's own version downloads nothing.
pub fn new_versions(
    base: &BTreeSet<(String, String)>,
    changed: &[(String, String)],
) -> Vec<Finding> {
    let mut found = BTreeSet::new();
    for (lock, text) in changed {
        for p in parse_lock(text) {
            if p.source.is_none() || base.contains(&(p.name.clone(), p.version.clone())) {
                continue;
            }
            found.insert(Finding {
                lock: lock.clone(),
                name: p.name,
                version: p.version,
            });
        }
    }
    found.into_iter().collect()
}

/// The reason given on a `Cargo-Lock-New-Versions: <reason>` body line, if any (key case-insensitive).
pub fn allowed(body: &str) -> Option<String> {
    body.lines().find_map(|line| {
        let line = line.trim();
        let head = line.get(..ALLOW_KEY.len())?;
        if !head.eq_ignore_ascii_case(ALLOW_KEY) {
            return None;
        }
        let reason = line[ALLOW_KEY.len()..].trim();
        (!reason.is_empty()).then(|| reason.to_string())
    })
}

/// The failure text: what is new, and how to say so when it is meant.
pub fn failure_text(findings: &[Finding]) -> String {
    let mut s = format!(
        "{} (crate, version) pair(s) in a changed Cargo.lock exist in no base Cargo.lock:\n",
        findings.len()
    );
    for f in findings {
        s.push_str(&format!("  {} {} ({})\n", f.name, f.version, f.lock));
    }
    s.push_str(&format!(
        "If the change means to add them, say so: add a line `{ALLOW_KEY} <why>` to the pull request body \
         (editing the body re-runs this check). Otherwise pin them to a version a base lock already has \
         (cargo update -p NAME --precise VERSION).\n"
    ));
    s
}
