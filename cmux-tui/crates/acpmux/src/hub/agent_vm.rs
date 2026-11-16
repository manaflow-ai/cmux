//! Whether this caller holds a peer at the VM boundary because its own fleet registry says the
//! peer is one of its dedicated agent VMs (`vm_boundary.rs`, "a saved peer's `vmBoundary`").
//!
//! A remote chain's Claude Code runs without the platform sandbox, and a Codex chat in full
//! access, only when the caller asks for it (`vm_boundary::FIELD`); the guest never decides.
//! Our lane VMs (`gcp-agent-lane-*`, the Codex lanes and swarm VMs) are marked `agent_vm: true`
//! in the fleet registry this caller reads (`admission.rs` `registry_path`: `FLEET_REGISTRY`,
//! else `~/.ssh/config.d/fleet-registry.json`, else leo-workspace's copy), and nothing wrote
//! `vmBoundary` into this caller's config.json for them, so a session started there from
//! huge-blue ran in the sandbox: Codex in `ask`, whose workspace-write sandbox left the host's
//! wt mirrors, `~/.local/state`, `~/.cache` and the daemon's socket out of reach. This reads the
//! registry instead, at each forwarded `session/new`, so a registry change applies with no
//! restart and no second copy of the list.
//!
//! The registry is the caller's own file, as its config.json is: whoever can write it already
//! decides that config.json. Only a peer whose name names a registry machine with
//! `agent_vm: true` qualifies, and an `ssh://` peer's host must name that same machine, so a
//! peer called after a lane VM that dials somewhere else does not. With no registry (acpmux
//! outside the fleet) nothing changes.

use serde_json::Value;

/// The host an `ssh://[user@]host[:port][/...]` peer url dials, lowercased; `None` for any
/// other scheme.
fn ssh_host(url: &str) -> Option<String> {
    let rest = url.strip_prefix("ssh://")?;
    let authority = rest.split('/').next().unwrap_or_default();
    let host = authority.rsplit('@').next().unwrap_or_default();
    let host = match host.strip_prefix('[') {
        Some(v6) => v6.split(']').next().unwrap_or_default(),
        None => host.split(':').next().unwrap_or_default(),
    };
    (!host.is_empty()).then(|| host.to_lowercase())
}

/// Whether `registry` says the peer `name` at `url` is one of the fleet's dedicated agent VMs
/// (module docs).
pub(crate) fn agent_vm_in(registry: &Value, name: &str, url: &str) -> bool {
    let Some(machine) = super::admission::machine_of(registry, None, name) else { return false };
    if let Some(host) = ssh_host(url)
        && super::admission::machine_of(registry, None, &host).as_deref() != Some(&machine)
    {
        return false;
    }
    let path = format!("/machines/{}/agent_vm", machine.replace('~', "~0").replace('/', "~1"));
    registry.pointer(&path) == Some(&Value::Bool(true))
}

/// [`agent_vm_in`] against this machine's fleet registry now (module docs).
pub(crate) fn registry_agent_vm(name: &str, url: &str) -> bool {
    let (source, set) = super::admission::registry_source();
    if source.as_os_str().is_empty() {
        return false;
    }
    let (registry, _) = super::admission::read_registry(&source, set);
    registry.is_some_and(|r| agent_vm_in(&r, name, url))
}

#[cfg(test)]
mod tests {
    use super::{agent_vm_in, ssh_host};
    use serde_json::json;

    fn registry() -> serde_json::Value {
        json!({"machines": {
            "gcp-agent-lane-1": {"agent_vm": true, "aliases": ["gcp-lane-1"]},
            "huge-blue": {"aliases": ["hb"]},
            "mini-3": {"agent_vm": false},
        }})
    }

    /// A start from huge-blue onto a lane VM its registry marks `agent_vm` asks for the VM
    /// boundary (so the lane runs unsandboxed, the VM being the boundary); any other peer does not.
    #[test]
    fn only_a_registry_agent_vm_peer_is_held_at_the_vm_boundary() {
        let r = registry();
        assert!(agent_vm_in(&r, "gcp-agent-lane-1", "ssh://gcp-agent-lane-1"));
        assert!(agent_vm_in(&r, "gcp-lane-1", "ssh://cmux@gcp-agent-lane-1:22"), "an alias");
        assert!(
            agent_vm_in(&r, "GCP-Agent-Lane-1", "ws://100.109.110.90:7777"),
            "not ssh: by name"
        );
        assert!(!agent_vm_in(&r, "gcp-agent-lane-1", "ssh://evil.example"), "dials elsewhere");
        assert!(!agent_vm_in(&r, "gcp-agent-lane-1", "ssh://huge-blue"), "another machine");
        assert!(!agent_vm_in(&r, "huge-blue", "ssh://huge-blue"), "no agent_vm");
        assert!(!agent_vm_in(&r, "mini-3", "ssh://mini-3"), "agent_vm false");
        assert!(!agent_vm_in(&r, "stranger", "ssh://stranger"), "not in the registry");
        assert!(!agent_vm_in(&json!({}), "gcp-agent-lane-1", "ssh://gcp-agent-lane-1"));
    }

    #[test]
    fn ssh_host_reads_the_dialed_host() {
        assert_eq!(ssh_host("ssh://a").as_deref(), Some("a"));
        assert_eq!(ssh_host("ssh://u@A:2222/x").as_deref(), Some("a"));
        assert_eq!(ssh_host("ssh://[::1]:22").as_deref(), Some("::1"));
        assert_eq!(ssh_host("wss://a"), None);
        assert_eq!(ssh_host("ssh://"), None);
    }
}
