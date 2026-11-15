//! Where one install key's blob lives in the login Keychain, and what a rotation leaves: the
//! decisions behind the app's install key (`CmuxNextCloud/Identity/InstallSigners.swift`
//! `SlotInstallSigner`), served as `cloud_identity_install_key_slots`. The app lists, reads,
//! adds and deletes the Keychain items; this says which ones.
//!
//! A key is the account (`install-key-<16 hex>`, generation 1) or a later generation of it
//! (`install-key-<16 hex>.<n>`, n from 2). The newest generation present is the key.
//!
//! Why generations (probe cloud-signed-in-after-update-production, cmux24, 2026-11-15T04:06Z
//! and 04:49Z): the blob is a login (file) Keychain item, and there another build of the same
//! bundle id may read an item but not delete it. Build 4366880343301 read the key build
//! 4367130096301 made, its owner answered the key was already registered, and the rotation's
//! SecItemDelete answered errSecInvalidOwnerEdit (-25244): every later mint signed with that
//! retired key and was refused, so the app read signed in and never got a token. A rotation now
//! puts the new key above any item it could not delete, so an update never strands the account
//! on a retired key.

use serde::{Deserialize, Serialize};

/// `errSecSuccess`.
pub const STATUS_SUCCESS: i32 = 0;
/// `errSecItemNotFound`: already gone, as good as deleted.
pub const STATUS_NOT_FOUND: i32 = -25300;

/// What the app does with the items of one key, from the accounts the Keychain listed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Slots {
    /// Every generation present, oldest first: what a rotation deletes.
    pub slots: Vec<String>,
    /// The newest generation, the one to read; none when there is no key yet.
    pub current: Option<String>,
    /// Where a first key goes: above every generation present (one that vanished since the read
    /// found nothing), the account itself when there is none.
    pub next: String,
}

/// One delete a rotation made, with the Keychain's status.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Delete {
    pub account: String,
    pub status: i32,
}

/// The generation `candidate` is of `account`: 1 for the account itself, n for `<account>.<n>`
/// (n from 2, written without leading zeros); none for another user's key or a look-alike.
pub fn generation(account: &str, candidate: &str) -> Option<u64> {
    if candidate == account {
        return Some(1);
    }
    let suffix = candidate.strip_prefix(account)?.strip_prefix('.')?;
    let number: u64 = suffix.parse().ok()?;
    (number >= 2 && number.to_string() == suffix).then_some(number)
}

/// The item name of `generation` of `account`.
pub fn name(account: &str, generation: u64) -> String {
    if generation <= 1 { account.to_owned() } else { format!("{account}.{generation}") }
}

/// The key's items among `accounts` (every account of the service, in any order).
pub fn slots(account: &str, accounts: &[String]) -> Slots {
    let mut generations: Vec<u64> =
        accounts.iter().filter_map(|candidate| generation(account, candidate)).collect();
    generations.sort_unstable();
    generations.dedup();
    let newest = generations.last().copied();
    Slots {
        slots: generations.iter().map(|g| name(account, *g)).collect(),
        current: newest.map(|g| name(account, g)),
        next: name(account, newest.unwrap_or(0) + 1),
    }
}

/// Where a rotation puts the fresh key, from the deletes it made: none when every generation went
/// (the next use makes a key at the account itself); else the generation above every one that
/// stayed, so the retired key is never read again.
pub fn replacement(account: &str, deletes: &[Delete]) -> Option<String> {
    deletes
        .iter()
        .filter(|delete| delete.status != STATUS_SUCCESS && delete.status != STATUS_NOT_FOUND)
        .filter_map(|delete| generation(account, &delete.account))
        .max()
        .map(|top| name(account, top + 1))
}

#[cfg(test)]
#[path = "install_key_slots_tests.rs"]
mod tests;
