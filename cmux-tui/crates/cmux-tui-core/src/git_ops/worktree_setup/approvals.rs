//! The repository recipes a person said yes to, by fingerprint
//! ([`super::super::worktree_recipe::Resolved::consent`]), in
//! `cmux-setup-approved.json` in the repository's git folder: a file of this
//! machine that git never commits, pushes or copies to another account, so an
//! answer holds for this checkout alone.

use super::*;

/// The list of approved fingerprints, in the repository's git folder.
pub(super) const FILE: &str = "cmux-setup-approved.json";
/// The answers kept: the newest ones, so a file never grows without end.
const KEPT: usize = 64;

/// Whether the person said yes to the recipe whose fingerprint is
/// `fingerprint`, in the repository whose git folder is `folder`.
pub(super) fn approved(folder: &OwnFolder, fingerprint: &str) -> bool {
    list(folder).iter().any(|kept| kept == fingerprint)
}

/// Keeps the person's yes to `fingerprint`. A write that fails keeps nothing:
/// the next new worktree asks again.
pub(super) fn approve(folder: &OwnFolder, fingerprint: &str) -> std::io::Result<()> {
    let mut list = list(folder);
    list.retain(|kept| kept != fingerprint);
    list.push(fingerprint.to_string());
    let extra = list.len().saturating_sub(KEPT);
    list.drain(..extra);
    folder.write(FILE, &serde_json::to_vec(&list)?)
}

fn list(folder: &OwnFolder) -> Vec<String> {
    folder
        .read(FILE)
        .ok()
        .flatten()
        .and_then(|bytes| serde_json::from_slice::<Vec<String>>(&bytes).ok())
        .unwrap_or_default()
}

#[cfg(test)]
#[path = "approvals_tests.rs"]
mod tests;
