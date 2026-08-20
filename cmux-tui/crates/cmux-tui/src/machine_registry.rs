//! The ordered registry of machine providers.
//!
//! One client shows machines from several providers in one column. The
//! registry fixes their order, and that order assigns the provider slot of
//! every key in [`crate::machine_key`]. Slot 0 belongs to the current session,
//! so the first registry entry takes slot 1.
//!
//! A legacy configuration keeps working without an edit. The built-in SSH
//! entry always exists and owns the `machines` array, and an enabled
//! `machine_provider.cloud` becomes an SSH entry. Explicit
//! `machine_providers` entries come first, and a desugared entry is appended
//! only when its id is still free, so an explicit entry can replace it.

use std::collections::HashSet;
use std::path::PathBuf;

use serde::Deserialize;

use crate::config::CloudProviderConfig;
use crate::machine_key::ProviderSlot;

/// Id of the entry that owns the static SSH and Unix catalog.
pub const BUILTIN_SSH_ID: &str = "ssh";
/// Id of the entry desugared from `machine_provider.cloud`.
pub const CLOUD_ID: &str = "cloud";

const MAX_ID_LEN: usize = 64;

/// Registry entry before validation.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawMachineProviderEntry {
    pub id: Option<String>,
    pub name: Option<String>,
    pub kind: Option<String>,
    pub socket: Option<String>,
    pub command: Option<Vec<String>>,
    pub env_passthrough: Option<Vec<String>>,
    pub host: Option<String>,
    pub user: Option<String>,
    pub port: Option<u16>,
    pub identity_file: Option<String>,
}

/// One provider in the resolved registry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachineProviderEntry {
    pub id: String,
    pub name: String,
    pub kind: MachineProviderKind,
}

/// How the client reaches one provider.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MachineProviderKind {
    /// The static catalog, in process.
    BuiltinSsh,
    Unix {
        socket: PathBuf,
    },
    Command {
        command: Vec<String>,
        /// Names of environment variables the provider process inherits.
        /// Values never appear in configuration.
        env_passthrough: Vec<String>,
    },
    Ssh {
        host: String,
        user: Option<String>,
        port: Option<u16>,
        identity_file: Option<PathBuf>,
    },
}

impl MachineProviderKind {
    pub fn name(&self) -> &'static str {
        match self {
            Self::BuiltinSsh => "builtin-ssh",
            Self::Unix { .. } => "unix",
            Self::Command { .. } => "command",
            Self::Ssh { .. } => "ssh",
        }
    }
}

/// Returns the slot of the registry entry at `index`. Slot 0 stays with the
/// current session, so the first entry takes slot 1. Returns `None` when the
/// registry holds more entries than the slot field can address.
pub fn provider_slot(index: usize) -> Option<ProviderSlot> {
    ProviderSlot::from_index(index.checked_add(1)?)
}

/// Largest registry the slot field can address.
pub fn max_providers() -> usize {
    usize::from(u16::MAX)
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ID_LEN
        && id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
}

fn valid_env_name(name: &str) -> bool {
    let mut chars = name.chars();
    match chars.next() {
        Some(first) if first.is_ascii_alphabetic() || first == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn trimmed(value: Option<String>) -> Option<String> {
    value.map(|value| value.trim().to_string()).filter(|value| !value.is_empty())
}

/// Reports fields that do not belong to the selected kind, so a misplaced key
/// is visible instead of silently inert.
fn warn_unused_fields(id: &str, kind: &str, raw: &RawMachineProviderEntry, used: &[&str]) {
    let present: [(&str, bool); 7] = [
        ("socket", raw.socket.is_some()),
        ("command", raw.command.is_some()),
        ("env_passthrough", raw.env_passthrough.is_some()),
        ("host", raw.host.is_some()),
        ("user", raw.user.is_some()),
        ("port", raw.port.is_some()),
        ("identity_file", raw.identity_file.is_some()),
    ];
    for (field, is_present) in present {
        if is_present && !used.contains(&field) {
            eprintln!(
                "cmux-tui: ignoring machine_providers[{id}].{field}, which does not apply to kind \"{kind}\""
            );
        }
    }
}

fn resolve_entry(raw: RawMachineProviderEntry) -> Option<MachineProviderEntry> {
    let id = trimmed(raw.id.clone()).unwrap_or_default();
    if !valid_id(&id) {
        eprintln!(
            "cmux-tui: ignoring a machine_providers entry whose id is missing or invalid; use lowercase letters, digits, \"-\", and \"_\""
        );
        return None;
    }
    let kind_name = trimmed(raw.kind.clone()).unwrap_or_default();
    let kind = match kind_name.as_str() {
        "builtin-ssh" => {
            warn_unused_fields(&id, &kind_name, &raw, &[]);
            MachineProviderKind::BuiltinSsh
        }
        "unix" => {
            warn_unused_fields(&id, &kind_name, &raw, &["socket"]);
            let socket = trimmed(raw.socket.clone()).map(PathBuf::from)?;
            if !socket.is_absolute() {
                eprintln!(
                    "cmux-tui: ignoring machine_providers[{id}] because its socket is not an absolute path"
                );
                return None;
            }
            MachineProviderKind::Unix { socket }
        }
        "command" => {
            warn_unused_fields(&id, &kind_name, &raw, &["command", "env_passthrough"]);
            let command: Vec<String> = raw
                .command
                .clone()
                .unwrap_or_default()
                .into_iter()
                .map(|part| part.trim().to_string())
                .collect();
            if command.first().map(String::is_empty).unwrap_or(true) {
                eprintln!(
                    "cmux-tui: ignoring machine_providers[{id}] because its command has no program"
                );
                return None;
            }
            let mut env_passthrough = Vec::new();
            for name in raw.env_passthrough.clone().unwrap_or_default() {
                let name = name.trim().to_string();
                if valid_env_name(&name) {
                    env_passthrough.push(name);
                } else {
                    eprintln!(
                        "cmux-tui: ignoring an invalid machine_providers[{id}].env_passthrough name"
                    );
                }
            }
            MachineProviderKind::Command { command, env_passthrough }
        }
        "ssh" => {
            warn_unused_fields(&id, &kind_name, &raw, &["host", "user", "port", "identity_file"]);
            let Some(host) = trimmed(raw.host.clone()) else {
                eprintln!("cmux-tui: ignoring machine_providers[{id}] because its host is empty");
                return None;
            };
            let port = match raw.port {
                Some(0) => {
                    eprintln!("cmux-tui: ignoring zero machine_providers[{id}].port");
                    None
                }
                port => port,
            };
            MachineProviderKind::Ssh {
                host,
                user: trimmed(raw.user.clone()),
                port,
                identity_file: trimmed(raw.identity_file.clone()).map(PathBuf::from),
            }
        }
        other => {
            if other.is_empty() {
                eprintln!("cmux-tui: ignoring machine_providers[{id}] because it has no kind");
            } else {
                eprintln!(
                    "cmux-tui: ignoring machine_providers[{id}] with unknown kind \"{other}\""
                );
            }
            return None;
        }
    };
    let name = trimmed(raw.name).unwrap_or_else(|| id.clone());
    Some(MachineProviderEntry { id, name, kind })
}

/// Builds the ordered registry from explicit entries and the legacy keys.
pub fn resolve(
    raw: Vec<RawMachineProviderEntry>,
    cloud: &CloudProviderConfig,
) -> Vec<MachineProviderEntry> {
    let mut entries: Vec<MachineProviderEntry> = Vec::new();
    let mut ids: HashSet<String> = HashSet::new();
    for entry in raw.into_iter().filter_map(resolve_entry) {
        if !ids.insert(entry.id.clone()) {
            eprintln!("cmux-tui: ignoring duplicate machine_providers id \"{}\"", entry.id);
            continue;
        }
        entries.push(entry);
    }

    // Truncate the explicit entries before the desugared ones are appended, so
    // an oversized registry cannot push the static catalog out. That catalog
    // also carries the current session and the SSH host discovery the footer
    // needs, so it must always survive.
    let explicit_capacity = max_providers() - 1;
    if entries.len() > explicit_capacity {
        eprintln!(
            "cmux-tui: ignoring machine_providers entries after the first {explicit_capacity}"
        );
        entries.truncate(explicit_capacity);
        ids = entries.iter().map(|entry| entry.id.clone()).collect();
    }

    if ids.insert(BUILTIN_SSH_ID.to_string()) {
        entries.push(MachineProviderEntry {
            id: BUILTIN_SSH_ID.to_string(),
            name: "SSH".to_string(),
            kind: MachineProviderKind::BuiltinSsh,
        });
    }

    if cloud.enabled && entries.len() < max_providers() && ids.insert(CLOUD_ID.to_string()) {
        entries.push(MachineProviderEntry {
            id: CLOUD_ID.to_string(),
            name: "cmux Cloud".to_string(),
            kind: MachineProviderKind::Ssh {
                host: cloud.host.clone(),
                user: cloud.user.clone(),
                port: cloud.port,
                identity_file: cloud.identity_file.clone(),
            },
        });
    }

    debug_assert!(entries.len() <= max_providers());
    entries
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cloud(enabled: bool) -> CloudProviderConfig {
        CloudProviderConfig { enabled, ..CloudProviderConfig::default() }
    }

    fn raw(id: &str, kind: &str) -> RawMachineProviderEntry {
        RawMachineProviderEntry {
            id: Some(id.to_string()),
            kind: Some(kind.to_string()),
            ..RawMachineProviderEntry::default()
        }
    }

    fn ids(entries: &[MachineProviderEntry]) -> Vec<&str> {
        entries.iter().map(|entry| entry.id.as_str()).collect()
    }

    #[test]
    fn an_empty_configuration_still_provides_the_static_catalog() {
        let entries = resolve(Vec::new(), &cloud(false));
        assert_eq!(ids(&entries), vec![BUILTIN_SSH_ID]);
        assert_eq!(entries[0].kind, MachineProviderKind::BuiltinSsh);
    }

    #[test]
    fn enabled_cloud_desugars_into_an_ssh_entry_after_the_static_catalog() {
        let entries = resolve(Vec::new(), &cloud(true));
        assert_eq!(ids(&entries), vec![BUILTIN_SSH_ID, CLOUD_ID]);
        let MachineProviderKind::Ssh { host, .. } = &entries[1].kind else {
            panic!("cloud must desugar to an ssh entry");
        };
        assert_eq!(host, &cloud(true).host);
    }

    #[test]
    fn explicit_entries_keep_their_order_and_precede_desugared_ones() {
        let mut command = raw("e2b", "command");
        command.command = Some(vec!["cmux-provider-e2b".into()]);
        let mut unix = raw("lab", "unix");
        unix.socket = Some("/run/cmux/provider.sock".into());
        let entries = resolve(vec![command, unix], &cloud(true));
        assert_eq!(ids(&entries), vec!["e2b", "lab", BUILTIN_SSH_ID, CLOUD_ID]);
    }

    #[test]
    fn an_explicit_entry_replaces_the_desugared_one_with_the_same_id() {
        let mut explicit = raw(CLOUD_ID, "ssh");
        explicit.host = Some("edge.example.com".into());
        let entries = resolve(vec![explicit], &cloud(true));
        assert_eq!(ids(&entries), vec![CLOUD_ID, BUILTIN_SSH_ID]);
        let MachineProviderKind::Ssh { host, .. } = &entries[0].kind else {
            panic!("expected the explicit ssh entry");
        };
        assert_eq!(host, "edge.example.com");
    }

    #[test]
    fn a_duplicate_id_keeps_only_the_first_entry() {
        let mut first = raw("dup", "ssh");
        first.host = Some("first.example.com".into());
        let mut second = raw("dup", "ssh");
        second.host = Some("second.example.com".into());
        let entries = resolve(vec![first, second], &cloud(false));
        assert_eq!(ids(&entries), vec!["dup", BUILTIN_SSH_ID]);
        let MachineProviderKind::Ssh { host, .. } = &entries[0].kind else {
            panic!("expected an ssh entry");
        };
        assert_eq!(host, "first.example.com");
    }

    #[test]
    fn an_entry_without_a_usable_id_is_dropped() {
        assert!(resolve_entry(raw("", "builtin-ssh")).is_none());
        assert!(resolve_entry(raw("Upper", "builtin-ssh")).is_none());
        assert!(resolve_entry(raw("has space", "builtin-ssh")).is_none());
        assert!(resolve_entry(raw(&"a".repeat(MAX_ID_LEN + 1), "builtin-ssh")).is_none());
        assert!(resolve_entry(raw(&"a".repeat(MAX_ID_LEN), "builtin-ssh")).is_some());
    }

    #[test]
    fn an_unknown_or_missing_kind_is_dropped() {
        assert!(resolve_entry(raw("x", "docker")).is_none());
        assert!(resolve_entry(raw("x", "")).is_none());
    }

    #[test]
    fn a_unix_entry_requires_an_absolute_socket() {
        let mut relative = raw("lab", "unix");
        relative.socket = Some("provider.sock".into());
        assert!(resolve_entry(relative).is_none());
        let mut absolute = raw("lab", "unix");
        absolute.socket = Some("/run/cmux/provider.sock".into());
        assert!(resolve_entry(absolute).is_some());
        assert!(resolve_entry(raw("lab", "unix")).is_none());
    }

    #[test]
    fn a_command_entry_requires_a_program() {
        assert!(resolve_entry(raw("e2b", "command")).is_none());
        let mut empty = raw("e2b", "command");
        empty.command = Some(vec!["   ".into()]);
        assert!(resolve_entry(empty).is_none());
        let mut valid = raw("e2b", "command");
        valid.command = Some(vec!["cmux-provider-e2b".into(), "--profile".into()]);
        let resolved = resolve_entry(valid).expect("entry");
        let MachineProviderKind::Command { command, .. } = resolved.kind else {
            panic!("expected a command entry");
        };
        assert_eq!(command, vec!["cmux-provider-e2b", "--profile"]);
    }

    #[test]
    fn env_passthrough_keeps_only_valid_variable_names() {
        let mut entry = raw("e2b", "command");
        entry.command = Some(vec!["cmux-provider-e2b".into()]);
        entry.env_passthrough =
            Some(vec!["E2B_API_KEY".into(), "_ok9".into(), "9bad".into(), "BAD=VALUE".into()]);
        let resolved = resolve_entry(entry).expect("entry");
        let MachineProviderKind::Command { env_passthrough, .. } = resolved.kind else {
            panic!("expected a command entry");
        };
        assert_eq!(env_passthrough, vec!["E2B_API_KEY", "_ok9"]);
    }

    #[test]
    fn an_ssh_entry_requires_a_host_and_drops_a_zero_port() {
        assert!(resolve_entry(raw("cloud", "ssh")).is_none());
        let mut entry = raw("cloud", "ssh");
        entry.host = Some("edge.example.com".into());
        entry.port = Some(0);
        entry.user = Some("  ".into());
        let resolved = resolve_entry(entry).expect("entry");
        let MachineProviderKind::Ssh { host, user, port, .. } = resolved.kind else {
            panic!("expected an ssh entry");
        };
        assert_eq!(host, "edge.example.com");
        assert_eq!(user, None);
        assert_eq!(port, None);
    }

    #[test]
    fn a_missing_name_falls_back_to_the_id() {
        let mut entry = raw("e2b", "command");
        entry.command = Some(vec!["cmux-provider-e2b".into()]);
        assert_eq!(resolve_entry(entry).expect("entry").name, "e2b");
    }

    #[test]
    fn the_first_registry_entry_takes_the_slot_after_the_current_session() {
        assert_eq!(provider_slot(0), ProviderSlot::from_index(1));
        assert!(!provider_slot(0).expect("slot").is_local());
        assert_eq!(provider_slot(max_providers() - 1), ProviderSlot::from_index(max_providers()));
        assert_eq!(provider_slot(max_providers()), None);
    }

    #[test]
    fn a_registry_larger_than_the_slot_field_keeps_the_static_catalog() {
        let raw_entries: Vec<RawMachineProviderEntry> = (0..max_providers() + 2)
            .map(|index| {
                let mut entry = raw(&format!("p{index}"), "unix");
                entry.socket = Some("/run/cmux/provider.sock".into());
                entry
            })
            .collect();
        let entries = resolve(raw_entries, &cloud(true));
        assert_eq!(entries.len(), max_providers());
        assert!(provider_slot(entries.len() - 1).is_some());
        // The static catalog survives, and the cloud entry is the one dropped.
        assert_eq!(entries.last().expect("entry").id, BUILTIN_SSH_ID);
        assert!(!entries.iter().any(|entry| entry.id == CLOUD_ID));
    }
}
