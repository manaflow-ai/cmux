//! One remove (plans/cmux-next/add-device-DESIGN.md 2.5): a device leaves
//! every store that lets it in. The plan is pure; `run` executes each step
//! with the store's own verb, so each store keeps its own rules (acpmux
//! closes a revoked device's connections, `host revoke` restarts the
//! listener).

use super::model::{Device, Via};

/// One `cmux` command that removes one store's record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Step {
    /// The words after `cmux`.
    pub args: Vec<String>,
    /// What stops, in words for the confirmation.
    pub what: String,
}

/// The steps that remove `device` from every store, in an order where a
/// failed step leaves nothing that lets it in that a later step would have
/// removed first: credentials before peers.
pub(crate) fn plan(device: &Device) -> Vec<Step> {
    let step = |args: &[&str], what: String| Step {
        args: args.iter().map(|a| (*a).to_owned()).collect(),
        what,
    };
    let mut credentials = Vec::new();
    let mut peers = Vec::new();
    for via in &device.via {
        match via {
            Via::Paired { id } => credentials.push(step(
                &["acp", "host", "ticket", "revoke", id, "--json"],
                format!(
                    "{} can no longer sign in here; its open connections close now",
                    device.name
                ),
            )),
            Via::Grant { login } => credentials.push(step(
                &["host", "revoke", login, "--json"],
                format!("{login} loses the access you granted to this computer"),
            )),
            Via::Allow { login } => credentials.push(step(
                &["host", "deny", login],
                format!("{login} can no longer open this computer's terminals"),
            )),
            Via::Joined { machine_id } => credentials.push(step(
                &["machine", "revoke", machine_id, "--yes", "--json"],
                format!(
                    "{} leaves your team's machines; its access ends within 30 seconds",
                    device.name
                ),
            )),
            Via::Peer { name } => peers.push(step(
                &["acp", "host", "rm", name, "--json"],
                format!("this computer stops running agents on {name}"),
            )),
        }
    }
    credentials.extend(peers);
    credentials
}
