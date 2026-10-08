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
//! - A revocation ends the sshd process and its logind session scope.
//!   Processes the user moved out of that scope (`systemd-run --user`, a
//!   lingering user manager) keep running.
//! - Only Ed25519 and ECDSA user certificates can be recorded; a session
//!   with another certificate type is refused at session open (the team CA
//!   is Ed25519 only).
//! - Until the team VM bind route (vm-image.md 6b) exists, no deployed
//!   machine fetches `team_vm.ssh_ca` by itself; `apply` reads the snapshot
//!   on stdin, and the fetcher that calls it lands with the bind.

pub mod b64;
pub mod cert;
pub mod cli;
#[cfg(target_os = "linux")]
pub mod linux_host;
pub mod sessions;
pub mod store;
pub mod trust;

#[cfg(test)]
mod cert_tests;
#[cfg(test)]
mod sessions_tests;
#[cfg(test)]
mod store_tests;
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
