//! Which cookie domains changed between two fingerprints.
//!
//! Domains are host keys without a leading dot (`.github.com` and
//! `github.com` are one domain for the app's importer). A domain is
//! `removed` when no host key of it is left; any other domain with a host
//! key added, changed or removed is `changed`, and the app re-imports it
//! whole. Both lists are deduplicated and sorted.

use crate::fingerprint::Fingerprint;
use std::collections::BTreeSet;

/// What changed between two fingerprints.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Diff {
    pub changed: Vec<String>,
    pub removed: Vec<String>,
}

impl Diff {
    pub fn is_empty(&self) -> bool {
        self.changed.is_empty() && self.removed.is_empty()
    }
}

/// `host_key` without one leading dot.
pub fn domain(host: &str) -> &str {
    host.strip_prefix('.').unwrap_or(host)
}

/// The domains that differ from `old` to `new`.
pub fn diff(old: &Fingerprint, new: &Fingerprint) -> Diff {
    let mut touched: BTreeSet<&str> = BTreeSet::new();
    for (host, hash) in new {
        if old.get(host) != Some(hash) {
            touched.insert(domain(host));
        }
    }
    for host in old.keys() {
        if !new.contains_key(host) {
            touched.insert(domain(host));
        }
    }
    let present: BTreeSet<&str> = new.keys().map(|host| domain(host)).collect();
    let mut out = Diff::default();
    for domain in touched {
        if present.contains(domain) {
            out.changed.push(domain.to_owned());
        } else {
            out.removed.push(domain.to_owned());
        }
    }
    out
}
