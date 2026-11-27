//! Stable keys for notification settings of one machine's workspace (Swift
//! `NotificationWorkspaceKey`). Bare workspace ids stay the local machine's
//! keys; a remote workspace also reads one saved before keys were qualified,
//! unless a workspace on this Mac holds that id ([`legacy_remote_key`]).

use std::collections::BTreeSet;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;

const QUALIFIED_PREFIX: &str = "machine:";

/// `machine:<b64 machine>:workspace:<b64 workspace>`.
pub fn qualified(machine: &str, workspace: &str) -> String {
    format!("machine:{}:workspace:{}", STANDARD.encode(machine), STANDARD.encode(workspace))
}

/// The local machine keeps the bare id; any other machine's workspace is qualified.
pub fn settings_key(machine: &str, workspace: &str, local_machine: &str) -> String {
    if machine == local_machine { workspace.to_owned() } else { qualified(machine, workspace) }
}

/// `keys` as the workspace ids of `machine`'s sidebar. `local_ids` are the
/// workspace ids on this Mac.
pub fn workspace_ids(
    keys: &BTreeSet<String>,
    machine: &str,
    local_machine: &str,
    local_ids: &BTreeSet<String>,
) -> BTreeSet<String> {
    if machine == local_machine {
        return keys.clone();
    }
    let prefix = format!("machine:{}:workspace:", STANDARD.encode(machine));
    keys.iter()
        .filter_map(|key| match key.strip_prefix(&prefix) {
            Some(encoded) => String::from_utf8(STANDARD.decode(encoded).ok()?).ok(),
            None if key.starts_with(QUALIFIED_PREFIX) || local_ids.contains(key) => None,
            None => Some(key.clone()),
        })
        .collect()
}

/// The bare id that still mutes remote `workspace`: a mute saved before keys
/// were qualified, while no workspace on this Mac has that id.
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

/// Whether `keys` mute `workspace` on `machine`: its own key, or the legacy bare id.
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

/// The key `workspace`'s rule (`notifications.sounds.workspaces`) is saved
/// under: its own, or for a remote workspace the legacy bare id while only
/// that has a rule and no workspace on this Mac has the id. `rule_keys` are
/// the keys that have a rule.
pub fn rule_key(
    machine: &str,
    workspace: &str,
    local_machine: &str,
    rule_keys: &BTreeSet<String>,
    local_ids: &BTreeSet<String>,
) -> String {
    let key = settings_key(machine, workspace, local_machine);
    if rule_keys.contains(&key)
        || machine == local_machine
        || !rule_keys.contains(workspace)
        || local_ids.contains(workspace)
    {
        return key;
    }
    workspace.to_owned()
}
