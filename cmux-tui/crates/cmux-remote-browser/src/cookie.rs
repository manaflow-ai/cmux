//! Cookie sync conflict rule between two profile owners (RT9;
//! remote-tab-protocol.md section 5.4, vectors
//! `schemas/remote-tab/cookie-sync.json`).
//!
//! Both machines evaluate the same pure rule on the same two versions and
//! reach the same winner, so live sync converges without a coordinator.

use serde::{Deserialize, Serialize};

use crate::proto::CookieVersion;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SyncPhase {
    /// The first reconcile after the user granted the site.
    Initial,
    /// Live changes after the first reconcile.
    Live,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncContext {
    /// eTLD+1 of the cookie's domain.
    pub site: String,
    pub granted_sites: Vec<String>,
    pub phase: SyncPhase,
    pub now_us: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SyncOutcome {
    /// The site is not granted: drop the change.
    DropNotGranted,
    /// Both sides already agree.
    NoopEqual,
    /// The two machines may be signed in to different accounts: ask the user.
    Prompt,
    /// The local version wins: keep it (and send it back if the peer needs it).
    KeepLocal,
    /// The remote version wins: write it locally.
    TakeRemote,
}

/// A version normalized for comparison: `None` = absent.
struct Norm<'a> {
    version: &'a CookieVersion,
    deleted: bool,
}

fn normalize(version: Option<&CookieVersion>, now_us: u64) -> Option<Norm<'_>> {
    version.map(|version| Norm {
        version,
        deleted: version.deleted || version.expires_us.is_some_and(|e| e <= now_us),
    })
}

fn live(n: &Option<Norm<'_>>) -> bool {
    n.as_ref().is_some_and(|n| !n.deleted)
}

/// Decides what the machine that holds `local` does with the incoming `remote`.
pub fn resolve(
    local: Option<&CookieVersion>,
    remote: Option<&CookieVersion>,
    ctx: &SyncContext,
) -> SyncOutcome {
    if !ctx.granted_sites.iter().any(|s| s == &ctx.site) {
        return SyncOutcome::DropNotGranted;
    }
    let l = normalize(local, ctx.now_us);
    let r = normalize(remote, ctx.now_us);
    let equal = match (&l, &r) {
        (None, None) => true,
        (Some(a), None) | (None, Some(a)) => a.deleted,
        (Some(a), Some(b)) => {
            a.deleted == b.deleted && (a.deleted || a.version.value == b.version.value)
        }
    };
    if equal {
        return SyncOutcome::NoopEqual;
    }
    if ctx.phase == SyncPhase::Initial && live(&l) && live(&r) {
        return SyncOutcome::Prompt;
    }
    match (&l, &r) {
        (Some(_), None) => SyncOutcome::KeepLocal,
        (None, Some(_)) => SyncOutcome::TakeRemote,
        (Some(a), Some(b)) => {
            let key = |n: &Norm<'_>| {
                (
                    n.version.last_update_us,
                    n.version.origin.clone(),
                    n.deleted,
                    n.version.value.clone(),
                )
            };
            if key(b) > key(a) { SyncOutcome::TakeRemote } else { SyncOutcome::KeepLocal }
        }
        (None, None) => SyncOutcome::NoopEqual,
    }
}
