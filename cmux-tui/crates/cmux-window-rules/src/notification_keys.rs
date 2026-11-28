//! The keys notification settings are saved under for one machine's workspace: what the macOS
//! app's `NotificationWorkspaceKey` decided. A local workspace keeps its bare id; a remote one is
//! `machine:<base64 machine>:workspace:<base64 workspace>`. A bare id saved before keys were
//! qualified still applies to a remote workspace while no workspace on this Mac holds that id, so
//! upgrading unmutes nothing and a local mute never reaches a forked machine's same-id workspace.
//!
//! The app's `localHolds` and `hasRule` closures arrive as id lists (`local_ids`, `rule_keys`).

use std::collections::BTreeSet;

const QUALIFIED_PREFIX: &str = "machine:";
const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Foundation's `Data.base64EncodedString()`: standard alphabet, padded, no line breaks.
pub fn base64_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let byte = |i: usize| u32::from(chunk.get(i).copied().unwrap_or(0));
        let n = (byte(0) << 16) | (byte(1) << 8) | byte(2);
        for i in 0..4 {
            if i <= chunk.len() {
                // The index is masked to 6 bits, so it is always in the 64-letter alphabet.
                let letter =
                    ALPHABET.get(((n >> (18 - 6 * i)) & 0x3F) as usize).copied().unwrap_or(b'=');
                out.push(char::from(letter));
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Foundation's `Data(base64Encoded:)` with no options: padded standard base64 only (a length a
/// multiple of 4, `=` only at the end); nil for anything else.
pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let quads = bytes.len() / 4;
    for (index, quad) in bytes.chunks(4).enumerate() {
        let pad = quad.iter().rev().take_while(|&&b| b == b'=').count();
        if pad > 2 || (pad > 0 && index + 1 != quads) {
            return None;
        }
        let mut n = 0u32;
        for &b in quad.iter().take(4 - pad) {
            let digit = ALPHABET.iter().position(|&a| a == b)? as u32;
            n = (n << 6) | digit;
        }
        n <<= 6 * pad as u32;
        let decoded = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
        out.extend(decoded.iter().take(3 - pad));
    }
    Some(out)
}

/// `NotificationWorkspaceKey.qualified`: a remote workspace's key.
pub fn qualified(machine: &str, workspace: &str) -> String {
    format!(
        "machine:{}:workspace:{}",
        base64_encode(machine.as_bytes()),
        base64_encode(workspace.as_bytes())
    )
}

/// `settingsKey`: the local machine's workspaces keep their bare id; a remote one is qualified.
pub fn settings_key(machine: &str, workspace: &str, local_machine: &str) -> String {
    if machine == local_machine { workspace.to_owned() } else { qualified(machine, workspace) }
}

/// `workspaceIDs`: the settings keys as the ids of one machine's workspaces. The local machine
/// reads every key; a remote one reads its own qualified keys and the legacy bare ids no local
/// workspace holds, never another machine's.
pub fn workspace_ids(
    keys: &BTreeSet<String>,
    machine: &str,
    local_machine: &str,
    local_ids: &BTreeSet<String>,
) -> BTreeSet<String> {
    if machine == local_machine {
        return keys.clone();
    }
    let prefix = format!("machine:{}:workspace:", base64_encode(machine.as_bytes()));
    keys.iter()
        .filter_map(|key| match key.strip_prefix(&prefix) {
            Some(encoded) => String::from_utf8(base64_decode(encoded)?).ok(),
            None => (!key.starts_with(QUALIFIED_PREFIX) && !local_ids.contains(key))
                .then(|| key.clone()),
        })
        .collect()
}

/// `legacyRemoteKey`: the bare id that still mutes remote `workspace`, while no local workspace
/// holds it.
pub fn legacy_remote_key(
    keys: &BTreeSet<String>,
    machine: &str,
    workspace: &str,
    local_machine: &str,
    local_ids: &BTreeSet<String>,
) -> Option<String> {
    (machine != local_machine && keys.contains(workspace) && !local_ids.contains(workspace))
        .then(|| workspace.to_owned())
}

/// `mutes`: whether `keys` mute `workspace` on `machine` (its own key, or the legacy bare id).
pub fn mutes(
    keys: &BTreeSet<String>,
    machine: &str,
    workspace: &str,
    local_machine: &str,
    local_ids: &BTreeSet<String>,
) -> bool {
    keys.contains(&settings_key(machine, workspace, local_machine))
        || legacy_remote_key(keys, machine, workspace, local_machine, local_ids).is_some()
}

/// `ruleKey`: the key a workspace's sound rule is saved under: its own, or for a remote workspace
/// the legacy bare id while only that has a rule and no local workspace holds it.
pub fn rule_key(
    machine: &str,
    workspace: &str,
    local_machine: &str,
    rule_keys: &BTreeSet<String>,
    local_ids: &BTreeSet<String>,
) -> String {
    let key = settings_key(machine, workspace, local_machine);
    if !rule_keys.contains(&key)
        && machine != local_machine
        && rule_keys.contains(workspace)
        && !local_ids.contains(workspace)
    {
        return workspace.to_owned();
    }
    key
}

#[cfg(test)]
#[path = "notification_keys_tests.rs"]
mod tests;
