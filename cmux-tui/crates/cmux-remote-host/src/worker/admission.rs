//! Who may use the Computer Use worker's socket, the rule of the macOS helper
//! (`CmuxCuaHelperCore/Admission.swift`) on Linux and Windows. Every check
//! must pass, in this order:
//!
//! 1. the peer runs as this user (`SO_PEERCRED` uid; the pipe client's token SID);
//! 2. its running image is this build's acpmux (SHA-256 of `/proc/<pid>/exe`
//!    or the image file, against the hashes the host trusts);
//! 3. an acpmux daemon the host registered (pid and start time) is one of its
//!    ancestors;
//! 4. it presents the per-launch secret.
//!
//! Checks 1-3 run at accept, before the worker reads a byte, so a plain
//! same-user client is refused without sending anything. Same documented
//! limit as upstream and macOS: a process inside an acpmux agent tree that
//! runs the acpmux binary itself passes 2-3; the secret and the session's
//! approvals still bind it.

use std::collections::HashSet;

use crate::platform::{PeerFacts, ProcessStamp};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AdmissionConfig {
    /// SHA-256 of the acpmux images the host trusts (lowercase hex).
    pub acpmux_hashes: HashSet<String>,
    /// The acpmux daemons the host registered; a peer must descend from one.
    pub daemons: HashSet<ProcessStamp>,
    /// The per-launch secret a peer presents first.
    pub secret: Vec<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    NotConfigured,
    ForeignUser,
    UnknownCode,
    OutsideAcpmuxTree,
    MissingSecret,
    WrongSecret,
}

impl Refusal {
    /// The same reason strings as the macOS helper.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NotConfigured => "not_configured",
            Self::ForeignUser => "foreign_user",
            Self::UnknownCode => "unknown_code",
            Self::OutsideAcpmuxTree => "outside_acpmux_tree",
            Self::MissingSecret => "missing_secret",
            Self::WrongSecret => "wrong_secret",
        }
    }
}

pub fn check_identity(peer: &PeerFacts, config: Option<&AdmissionConfig>) -> Option<Refusal> {
    let Some(config) = config else { return Some(Refusal::NotConfigured) };
    if !peer.same_user {
        return Some(Refusal::ForeignUser);
    }
    let known = peer.executable_sha256.as_ref().is_some_and(|hash| config.acpmux_hashes.contains(hash));
    if !known {
        return Some(Refusal::UnknownCode);
    }
    if !peer.ancestors.iter().any(|ancestor| config.daemons.contains(ancestor)) {
        return Some(Refusal::OutsideAcpmuxTree);
    }
    None
}

pub fn check_secret(presented: Option<&[u8]>, config: &AdmissionConfig) -> Option<Refusal> {
    match presented {
        None | Some([]) => Some(Refusal::MissingSecret),
        Some(bytes) if crate::wire::same_secret(bytes, &config.secret) => None,
        Some(_) => Some(Refusal::WrongSecret),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn daemon() -> ProcessStamp {
        ProcessStamp { pid: 100, start: 5 }
    }

    fn config() -> AdmissionConfig {
        AdmissionConfig {
            acpmux_hashes: HashSet::from(["aa".repeat(32)]),
            daemons: HashSet::from([daemon()]),
            secret: vec![7; 32],
        }
    }

    fn peer() -> PeerFacts {
        PeerFacts {
            same_user: true,
            stamp: ProcessStamp { pid: 300, start: 9 },
            executable: Some("/usr/lib/cmux/acpmux".into()),
            executable_sha256: Some("aa".repeat(32)),
            ancestors: vec![ProcessStamp { pid: 200, start: 7 }, daemon()],
        }
    }

    #[test]
    fn the_bridge_of_a_registered_daemon_is_admitted() {
        assert_eq!(check_identity(&peer(), Some(&config())), None);
        assert_eq!(check_secret(Some(&[7; 32]), &config()), None);
    }

    #[test]
    fn each_check_refuses_in_order() {
        assert_eq!(check_identity(&peer(), None), Some(Refusal::NotConfigured));
        let mut other = peer();
        other.same_user = false;
        assert_eq!(check_identity(&other, Some(&config())), Some(Refusal::ForeignUser));
        let mut shell = peer();
        shell.executable_sha256 = Some("bb".repeat(32));
        assert_eq!(check_identity(&shell, Some(&config())), Some(Refusal::UnknownCode));
        let mut stray = peer();
        stray.ancestors = vec![ProcessStamp { pid: 100, start: 6 }];
        assert_eq!(check_identity(&stray, Some(&config())), Some(Refusal::OutsideAcpmuxTree));
        assert_eq!(check_secret(None, &config()), Some(Refusal::MissingSecret));
        assert_eq!(check_secret(Some(&[8; 32]), &config()), Some(Refusal::WrongSecret));
    }
}
