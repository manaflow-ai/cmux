//! Semantic versions with SemVer 2.0.0 precedence, for the running `cmux`
//! version, which may carry a prerelease (`0.71.0-nightly.20261002`) or
//! build metadata. `min_cmux_version` in a manifest stays `MAJOR.MINOR.PATCH`.

use std::cmp::Ordering;

#[derive(Clone, Debug, PartialEq, Eq)]
enum PreId {
    Numeric(u64),
    Alpha(String),
}

impl Ord for PreId {
    fn cmp(&self, other: &Self) -> Ordering {
        match (self, other) {
            (PreId::Numeric(a), PreId::Numeric(b)) => a.cmp(b),
            (PreId::Numeric(_), PreId::Alpha(_)) => Ordering::Less,
            (PreId::Alpha(_), PreId::Numeric(_)) => Ordering::Greater,
            (PreId::Alpha(a), PreId::Alpha(b)) => a.cmp(b),
        }
    }
}

impl PartialOrd for PreId {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// A parsed version. Build metadata is dropped (it has no precedence).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SemVer {
    pub core: (u64, u64, u64),
    pre: Vec<PreId>,
}

impl SemVer {
    pub fn release(core: (u64, u64, u64)) -> SemVer {
        SemVer { core, pre: Vec::new() }
    }

    pub fn is_prerelease(&self) -> bool {
        !self.pre.is_empty()
    }

    /// Parses `MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]`.
    pub fn parse(s: &str) -> Option<SemVer> {
        let s = match s.split_once('+') {
            Some((v, build)) if valid_ids(build, false) => v,
            Some(_) => return None,
            None => s,
        };
        let (core, pre) = match s.split_once('-') {
            Some((core, pre)) if valid_ids(pre, true) => (core, Some(pre)),
            Some(_) => return None,
            None => (s, None),
        };
        let core = super::parse_version(core)?;
        let pre = pre.map_or_else(Vec::new, |p| {
            p.split('.')
                .map(|id| match id.parse() {
                    Ok(n) if id.bytes().all(|b| b.is_ascii_digit()) => PreId::Numeric(n),
                    _ => PreId::Alpha(id.to_owned()),
                })
                .collect()
        });
        Some(SemVer { core, pre })
    }
}

/// Dot-separated non-empty identifiers of `[0-9A-Za-z-]`; in a prerelease a
/// numeric identifier has no leading zero.
fn valid_ids(s: &str, prerelease: bool) -> bool {
    s.split('.').all(|id| {
        let numeric = id.bytes().all(|b| b.is_ascii_digit());
        !id.is_empty()
            && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            && !(prerelease && numeric && id.len() > 1 && id.starts_with('0'))
            && !(prerelease && numeric && id.len() > 19)
    })
}

impl Ord for SemVer {
    fn cmp(&self, other: &Self) -> Ordering {
        self.core.cmp(&other.core).then_with(|| match (self.pre.is_empty(), other.pre.is_empty()) {
            (true, true) => Ordering::Equal,
            (true, false) => Ordering::Greater,
            (false, true) => Ordering::Less,
            (false, false) => self.pre.cmp(&other.pre),
        })
    }
}

impl PartialOrd for SemVer {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
