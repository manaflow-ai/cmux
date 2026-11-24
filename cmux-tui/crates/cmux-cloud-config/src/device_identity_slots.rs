//! Which login Keychain items hold this device's hub identity, and where a renewal puts the new
//! one: the decisions behind `CmuxNextDevices/DeviceIdentity.swift` (`load`, `renew`) and the
//! protected capture's cleanup (`CaptureKeychainNamespace.swift`), served as
//! `cloud_identity_device_slots`. The app lists, reads, adds and deletes the Keychain items; this
//! says which ones.
//!
//! An identity is three items of service `<bundle id>.device-hub`, one generation: `device-id`,
//! `device-signing-key` and `device-agreement-key` (generation 1, the names every install made so
//! far, so they keep their identity), or the same names with `.<n>` (n from 2, no leading zeros).
//! The newest generation present is the identity; the app reads its three items and never mixes
//! two generations.
//!
//! Why generations (the same class as the install key, `install_key_slots` in cmux#43592, probe
//! cloud-signed-in-after-update-production, 2026-11-15): these are login (file) Keychain items,
//! and there another build of the same bundle id (the app after an update) may read an item but
//! not delete or update it: SecItemDelete and SecItemUpdate answer errSecInvalidOwnerEdit
//! (-25244). A renewal (the hub refused the id: `device_removed`, `device_key_mismatch`) deleted
//! the three items first and threw on that refusal, so an updated app could never become a new
//! device. A renewal now deletes what it can and puts the new identity above every item it could
//! not delete.

use serde::{Deserialize, Serialize};

/// `errSecSuccess`.
pub const STATUS_SUCCESS: i32 = 0;
/// `errSecItemNotFound`: already gone, as good as deleted.
pub const STATUS_NOT_FOUND: i32 = -25300;

/// The identity's three accounts of generation 1, in the order [`Generation`] names them.
pub const ACCOUNTS: [&str; 3] = ["device-id", "device-signing-key", "device-agreement-key"];

/// The three items of one generation of the identity.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Generation {
    /// The device id (a lowercase UUID).
    pub id: String,
    /// The signing key's Secure Enclave blob.
    pub signing_key: String,
    /// The key agreement key's Secure Enclave blob.
    pub agreement_key: String,
}

/// What the app does with the identity's items, from the accounts the Keychain listed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Slots {
    /// Every item of the identity present, oldest generation first: what a renewal deletes, and
    /// the only identity items a protected capture may remove.
    pub accounts: Vec<String>,
    /// The newest generation present, the one to read; none when no item of it is present. A
    /// generation with an item missing is still the newest: the app reads nothing of an older one,
    /// it renews.
    pub current: Option<Generation>,
}

/// One delete a renewal made, with the Keychain's status.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Delete {
    pub account: String,
    pub status: i32,
}

/// The generation `candidate` is of the identity: 1 for an account of [`ACCOUNTS`], n for
/// `<account>.<n>` (n from 2, written without leading zeros); none for any other item of the
/// service (a capture marker, a look-alike).
pub fn generation(candidate: &str) -> Option<u64> {
    ACCOUNTS.iter().find_map(|account| {
        if candidate == *account {
            return Some(1);
        }
        let suffix = candidate.strip_prefix(account)?.strip_prefix('.')?;
        let number: u64 = suffix.parse().ok()?;
        (number >= 2 && number.to_string() == suffix).then_some(number)
    })
}

/// The three item names of `generation`.
pub fn names(generation: u64) -> Generation {
    let name = |account: &str| {
        if generation <= 1 { account.to_owned() } else { format!("{account}.{generation}") }
    };
    Generation {
        id: name(ACCOUNTS[0]),
        signing_key: name(ACCOUNTS[1]),
        agreement_key: name(ACCOUNTS[2]),
    }
}

/// The identity's items among `accounts` (every account of the service, in any order).
pub fn slots(accounts: &[String]) -> Slots {
    let mut present: Vec<(u64, &String)> =
        accounts.iter().filter_map(|account| Some((generation(account)?, account))).collect();
    present.sort_unstable();
    present.dedup();
    Slots {
        current: present.last().map(|(newest, _)| names(*newest)),
        accounts: present.into_iter().map(|(_, account)| account.clone()).collect(),
    }
}

/// Where a renewal (or a first identity) puts the new one, from the deletes it made: generation 1
/// when every item went (or there was none), else the generation above every one that stayed, so
/// the refused identity is never read again and no generation mixes two identities.
pub fn replacement(deletes: &[Delete]) -> Generation {
    let kept = deletes
        .iter()
        .filter(|delete| delete.status != STATUS_SUCCESS && delete.status != STATUS_NOT_FOUND)
        .filter_map(|delete| generation(&delete.account))
        .max();
    names(kept.map_or(1, |top| top + 1))
}

#[cfg(test)]
#[path = "device_identity_slots_tests.rs"]
mod tests;
