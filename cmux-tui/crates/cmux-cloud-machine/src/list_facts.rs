//! The sign-in and machine-list state that decides whether a saved Cloud workspace is gone
//! (P-AUSTIN B7b): the window registry's `isDead` asks whether a machine left the account and
//! whether every Cloud machine list has settled.
//!
//! Only the list of the user and team signed in now says anything: after a team switch the user
//! stays signed in, and the store keeps the previous team's list until the new team's lands.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Inputs {
    pub is_signed_in: bool,
    pub is_restoring: bool,
    /// The store holds a list the server answered, for any account.
    pub has_loaded_machines: bool,
    /// Whom that list is for (`[user id, team id]` when it landed); None before any list.
    pub loaded_for: Option<Vec<Option<String>>>,
    /// Whom the person is signed in as now.
    pub account: Vec<Option<String>>,
    /// Set instead of the four above when the caller already knows the list is current.
    pub has_loaded_current_machines: Option<bool>,
}

/// Whether every Cloud machine that could still report workspaces has.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Settled {
    Yes,
    No,
    /// Once each live listed machine's tree has loaded.
    IfMachinesLoaded,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Facts {
    /// The store holds the list of the user and team signed in now.
    pub has_loaded_current_machines: bool,
    /// The signed-in account's own list has loaded: a machine it does not list left the account.
    /// Signed out, Cloud off, the list not loaded (or the previous team's): an unlisted machine
    /// is only not connected, so its workspaces stay and come back when it connects.
    pub account_list_loaded: bool,
    /// Signed out and not restoring, the Cloud holds none; otherwise the current account's list
    /// must have loaded and each live listed machine's tree too.
    pub settled: Settled,
}

pub fn facts(inputs: &Inputs) -> Facts {
    let current = inputs.has_loaded_current_machines.unwrap_or_else(|| {
        inputs.has_loaded_machines && inputs.loaded_for.as_ref() == Some(&inputs.account)
    });
    let settled = if !(inputs.is_signed_in || inputs.is_restoring) {
        Settled::Yes
    } else if current {
        Settled::IfMachinesLoaded
    } else {
        Settled::No
    };
    Facts {
        has_loaded_current_machines: current,
        account_list_loaded: inputs.is_signed_in && !inputs.is_restoring && current,
        settled,
    }
}

#[cfg(test)]
mod tests;
