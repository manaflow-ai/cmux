//! sshd trust on a cmux machine: the bound CA keys, the revocation list
//! (KRL) and the live sessions of certificates it revokes (team-vm-plan.md
//! slices S5 and S14; cloud-automation.md section 5).
//!
//! The image's sshd drop-in (web/scripts/cmux-vm-image/sshd.ts) points
//! `TrustedUserCAKeys` and `RevokedKeys` at files that only [`store::apply`]
//! writes, and asks `cmux host team-ssh principals %u` for the principals.
//! sshd reads both files on each authentication, so a new KRL takes effect
//! without a restart.
//!
//! Rules (each has a test):
//! - `krl_version` and the CA generation never go backwards: an older
//!   snapshot is refused and changes no file ([`trust::decide`]).
//! - Fail closed: `principals` prints nothing when the last good sync is
//!   older than [`trust::STALE_AFTER_SECS`], so a machine that misses
//!   updates refuses new logins instead of trusting an old KRL.
//! - The KRL is written before the CA keys, so a new CA is never trusted
//!   before the KRL that goes with it (a compromised-CA rotation lists the
//!   old key in the KRL).
//! - `session-open` (pam_exec, as root) records each certificate session
//!   under its sshd process id and start time. After each KRL change the
//!   reaper ends only sessions it recorded whose process still has the
//!   recorded start time and whose certificate the KRL revokes; it never
//!   matches processes by name or pattern ([`sessions`]).
//!
//! Known limits:
//! - A revocation ends the sshd process and its logind session scope, turns
//!   the user's lingering off and, once no live session of that user holds
//!   an unrevoked certificate, stops that user's `user@<uid>.service` (so
//!   `systemd-run --user` work ends too). Team users never linger: each
//!   pass turns lingering off for every user with a principals file. While
//!   another valid session of the same Linux user is live, work the revoked
//!   session moved into the shared user manager keeps running until that
//!   session ends. Work handed to another system service (cron or at jobs,
//!   a docker daemon the user may reach) is outside these scopes.
//! - Only Ed25519 and ECDSA user certificates can be recorded; a session
//!   with another certificate type is refused at session open (the team CA
//!   is Ed25519 only).
//! - The fetcher ([`sync`]) runs only on a team VM that the bind
//!   ([`enroll`], vm-image.md 6b) gave an install; `apply` also reads a
//!   snapshot on stdin.

pub mod b64;
pub mod cert;
pub mod cli;
pub mod enroll;
#[cfg(target_os = "linux")]
pub mod linux_host;
pub mod sessions;
pub mod store;
pub mod sync;
pub mod trust;

#[cfg(test)]
mod cert_tests;
#[cfg(test)]
mod enroll_tests;
#[cfg(test)]
mod sessions_tests;
#[cfg(test)]
mod store_tests;
#[cfg(test)]
mod sync_tests;
#[cfg(test)]
mod test_support;
#[cfg(test)]
mod trust_tests;

/// sshd `TrustedUserCAKeys` (one CA public key line per trusted CA).
pub const CA_FILE: &str = "/etc/cmux/ssh/user-ca.pub";
/// sshd `RevokedKeys` (binary OpenSSH KRL).
pub const KRL_FILE: &str = "/etc/cmux/ssh/revoked.krl";
/// Principals per Linux user (`<dir>/<user>`), written by bind or the
/// team reconciler; `principals` passes them on only while trust is fresh.
pub const PRINCIPALS_DIR: &str = "/etc/cmux/ssh/principals";
/// The applied snapshot's versions and sync time ([`trust::TrustState`]).
pub const TRUST_FILE: &str = "/etc/cmux/ssh/trust.json";
/// Serializes `apply` (flock). Root-only directory, so no other user can
/// hold the lock and stall updates.
pub const APPLY_LOCK_FILE: &str = "/run/cmux-host/ssh-sessions/.apply.lock";
/// Root-only session records, one file per sshd process id.
pub const SESSIONS_DIR: &str = "/run/cmux-host/ssh-sessions";
