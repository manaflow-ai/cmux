//! The cloud host replica follower's decisions (Swift
//! `CmuxNextPhoneAccess.CloudHostReplicaFollower`): Settings > Accounts >
//! Phone Access > `phone.cloudReplica`. While on (signed in, Cloud allowed,
//! the daemon serving `cloud-host-replica-v1`) the app leases this Mac's
//! install token to the daemon; off deletes the cloud copy (a purge, which
//! needs a lease first); signed out drops the lease. The app runs the token
//! read, the daemon calls and the defaults writes, one piece of work at a
//! time in order; Rust says which.
use serde::{Deserialize, Serialize};

/// The defaults key of the account whose copy may exist: set when a lease is
/// given, removed once that daemon confirmed the purge.
pub const PUBLISHED_KEY: &str = "cmux.cloudReplica.publishedUser.v1";
/// The defaults key of the daemon (pid) asked to purge for `PUBLISHED_KEY`.
pub const PURGE_ASKED_KEY: &str = "cmux.cloudReplica.purgeAskedDaemon.v1";

/// What one piece of lease work wants.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Want {
    /// A local daemon connection that serves `cloud-host-replica-v1`.
    pub connected: bool,
    /// The signed-in user's id while Cloud may be called.
    #[serde(default)]
    pub user_id: Option<String>,
    /// The setting.
    pub on: bool,
}

/// The first step of one piece of work.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Apply {
    /// No daemon: its lease died with it, and the next one starts with none.
    None,
    /// `cloud-host-replica-clear` with `purge: false` (signed out, or off with
    /// no copy of this account to delete).
    Clear,
    /// Read a token (after invalidating the cached one when `invalidate`), then lease.
    Lease { invalidate: bool },
    /// Off with a copy that may exist: read `cloud-host-replica-status`, then
    /// ask [`purge`].
    Status,
}

/// `renew`: the daemon asked for a new token (`cloud-host-replica-needed`).
/// `published_user`: the `PUBLISHED_KEY` value.
pub fn apply(want: &Want, renew: bool, published_user: Option<&str>) -> Apply {
    if !want.connected {
        return Apply::None;
    }
    // Signed out: no token to purge with; the mark stays for that account's next sign-in.
    let Some(user) = want.user_id.as_deref() else { return Apply::Clear };
    if want.on {
        Apply::Lease { invalidate: renew }
    } else if published_user == Some(user) {
        Apply::Status
    } else {
        Apply::Clear
    }
}

/// `cloud-host-replica-status`'s reply, the fields the follower reads.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Status {
    pub state: String,
    #[serde(default)]
    pub purge_pending: Option<bool>,
}

/// The purge step, given the status.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Purge {
    /// This daemon purged (or the cloud refused the install and drops a
    /// removed host's copy itself): remove both defaults keys, done.
    Forget,
    /// Lease (a purge needs a token; invalidate the cached one first when
    /// `invalidate`), and when a lease went, `cloud-host-replica-clear` with
    /// `purge: true`, then store `mark_purge_asked` under `PURGE_ASKED_KEY`
    /// when it is set. Never a plain clear here: that would cancel the purge.
    LeaseThenPurge { invalidate: bool, mark_purge_asked: Option<i64> },
}

/// `daemon`: the daemon's pid; `purge_asked`: the `PURGE_ASKED_KEY` value.
pub fn purge(renew: bool, daemon: Option<i64>, purge_asked: Option<i64>, status: &Status) -> Purge {
    if !renew
        && let Some(daemon) = daemon
        && purge_asked == Some(daemon)
        && status.state == "off"
        && status.purge_pending != Some(true)
    {
        return Purge::Forget;
    }
    Purge::LeaseThenPurge { invalidate: renew, mark_purge_asked: daemon }
}

/// The longest host name the daemon takes, in Unicode scalars.
pub const HOST_NAME_LIMIT: usize = 64;

/// The name phones show for this Mac: the computer name trimmed, "Mac" when
/// empty, cut to 64 Unicode scalars (`cloud-host-replica-set` takes 1-64).
pub fn host_name(computer_name: &str) -> String {
    let name = computer_name.trim();
    if name.is_empty() { "Mac".into() } else { name.chars().take(HOST_NAME_LIMIT).collect() }
}

/// `cloud-host-replica-set`'s fields.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Lease {
    pub api_base_url: String,
    pub install_token: String,
    /// Unix milliseconds.
    pub expires_at: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_version: Option<String>,
    pub host_name: String,
}

/// The lease to send once the token is read; None when there is no Cloud
/// origin (no lease goes). With a lease the app stores `user` under
/// `PUBLISHED_KEY` and removes `PURGE_ASKED_KEY` before sending it.
pub fn lease(
    origin: Option<&str>,
    token: String,
    expires_at: u64,
    client_version: Option<String>,
    computer_name: &str,
) -> Option<Lease> {
    Some(Lease {
        api_base_url: origin?.to_owned(),
        install_token: token,
        expires_at,
        client_version,
        host_name: host_name(computer_name),
    })
}
