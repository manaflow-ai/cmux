//! Reading the Claude login a Cloud machine already holds (the app's `CloudMachineLogin`): the
//! probe's one word, and the fingerprint of the account's cached token the probe compares on the
//! machine, so no token is sent there to compare. The app runs the probe (its shell text and the
//! exec stay the app's) and hands its output to [`crate::harness_login::decide`].

use crate::harness_login::MachineLogin;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// What the machine's login probe answered: its exit code and stdout.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Probe {
    pub exit_code: i64,
    pub stdout: String,
}

/// The probe's one word. An unknown answer keeps the older probe's reading of the exit code: 0 is
/// a login that stays (`working`), anything else none.
pub fn parse(exit_code: i64, stdout: &str) -> MachineLogin {
    match stdout.trim() {
        "none" => MachineLogin::None,
        "session" => MachineLogin::Session,
        "cached" => MachineLogin::Cached,
        "working" => MachineLogin::Working,
        "rejected" => MachineLogin::Rejected,
        _ if exit_code == 0 => MachineLogin::Working,
        _ => MachineLogin::None,
    }
}

/// The SHA-256 of a token, lowercase hex: what the probe compares on the machine.
pub fn fingerprint(token: &[u8]) -> String {
    Sha256::digest(token).iter().fold(String::with_capacity(64), |mut hex, byte| {
        use std::fmt::Write;
        let _ = write!(hex, "{byte:02x}");
        hex
    })
}

#[cfg(test)]
mod tests;
