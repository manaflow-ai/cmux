//! Field rules for a parsed channel manifest.

use std::collections::BTreeSet;

use super::{ChannelManifest, ManifestError, Package, SCHEMA, parse_rfc3339_utc_ms};

/// `MAJOR.MINOR.PATCH`, numeric only.
pub type Version = (u64, u64, u64);

pub fn parse_version(s: &str) -> Option<Version> {
    let mut parts = s.split('.');
    let mut next = || -> Option<u64> {
        let p = parts.next()?;
        if p.is_empty() || p.len() > 9 || !p.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        p.parse().ok()
    };
    let v = (next()?, next()?, next()?);
    parts.next().is_none().then_some(v)
}

pub fn valid_sha256(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// `[a-z0-9][a-z0-9._-]{0,63}`, never `.` or `..`: a package name may name
/// a directory in a profile.
fn valid_name(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= 64
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter().all(|c| {
            c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, b'.' | b'_' | b'-')
        })
}

fn valid_role(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= 32
        && b[0].is_ascii_lowercase()
        && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

fn invalid(what: String) -> ManifestError {
    ManifestError::Invalid(what)
}

fn check_package(p: &Package) -> Result<(), ManifestError> {
    let n = &p.name;
    if !valid_name(n) {
        return Err(invalid(format!("package name {n:?}")));
    }
    if p.version.is_empty()
        || p.version.len() > 64
        || p.version.chars().any(|c| c.is_control() || c.is_whitespace())
    {
        return Err(invalid(format!("package {n} version")));
    }
    let host_ok = p.url.strip_prefix("https://").is_some_and(|rest| {
        let host = rest.split('/').next().unwrap_or("");
        !host.is_empty() && !host.contains('@')
    });
    if !host_ok || p.url.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err(invalid(format!("package {n} url must be https")));
    }
    if !valid_sha256(&p.sha256) {
        return Err(invalid(format!("package {n} sha256")));
    }
    if p.size == 0 {
        return Err(invalid(format!("package {n} size")));
    }
    if p.roles.is_empty() || !p.roles.iter().all(|r| valid_role(r)) {
        return Err(invalid(format!("package {n} roles")));
    }
    Ok(())
}

/// Checks every field and returns the expiry in Unix ms.
pub(super) fn check(m: &ChannelManifest) -> Result<u64, ManifestError> {
    if m.schema != SCHEMA {
        return Err(invalid(format!("schema {}", m.schema)));
    }
    if !valid_role(&m.channel) {
        return Err(invalid(format!("channel {:?}", m.channel)));
    }
    let expires = parse_rfc3339_utc_ms(&m.expires_at)
        .ok_or_else(|| invalid(format!("expires_at {:?}", m.expires_at)))?;
    if parse_version(&m.min_cmux_version).is_none() {
        return Err(invalid(format!("min_cmux_version {:?}", m.min_cmux_version)));
    }
    if m.packages.is_empty() {
        return Err(invalid("no packages".to_owned()));
    }
    let mut names = BTreeSet::new();
    for p in &m.packages {
        check_package(p)?;
        if !names.insert(p.name.as_str()) {
            return Err(invalid(format!("duplicate package {}", p.name)));
        }
    }
    Ok(expires)
}
