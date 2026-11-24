//! Whether this caller holds a peer at the VM boundary because its own fleet registry says the
//! peer is one of its dedicated agent VMs (`vm_boundary.rs`, "a saved peer's `vmBoundary`").
//!
//! A remote chain's Claude Code runs without the platform sandbox, and a Codex chat in full
//! access, only when the caller asks for it (`vm_boundary::FIELD`); the guest never decides.
//! Our lane VMs (the agent lanes, Codex lanes and swarm VMs) are marked `agent_vm: true`
//! in the fleet registry this caller reads (`admission.rs` `registry_path`: `FLEET_REGISTRY`,
//! else `~/.ssh/config.d/fleet-registry.json`, else the workspace checkout's copy), and nothing wrote
//! `vmBoundary` into this caller's config.json for them, so a session started there from
//! another machine ran in the sandbox: Codex in `ask`, whose workspace-write sandbox left the host's
//! wt mirrors, `~/.local/state`, `~/.cache` and the daemon's socket out of reach. This reads the
//! registry instead, at each forwarded `session/new`, so a registry change applies with no
//! restart and no second copy of the list.
//!
//! The registry is the caller's own file, as its config.json is: whoever can write it already
//! decides that config.json. Only an `ssh://` peer qualifies (our lane VMs are saved ssh peers;
//! a Cloud link's leased `ws://` peer keeps its own rule, the Cloud API's `vmKind`), and both
//! its name and the host it dials must each be exactly a name of the same registry machine with
//! `agent_vm: true` (the key, an `aliases` entry or an origin `hostnames` entry, case aside): a
//! peer called after a lane VM that dials somewhere else, or `lane.evil.example`, does not. With
//! no registry (acpmux outside the fleet) nothing changes.

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

/// The registry machine `word` is exactly a name of (module docs), lowercase compared; no
/// short-name match, unlike `admission::machine_of`.
fn machine_named<'r>(registry: &'r Value, word: &str) -> Option<&'r str> {
    let word = word.trim().to_lowercase();
    let machines = registry.get("machines").and_then(Value::as_object)?;
    let listed = |v: Option<&Value>| {
        v.and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .any(|n| n.to_lowercase() == word)
    };
    machines
        .iter()
        .find(|(key, m)| {
            key.to_lowercase() == word
                || listed(m.get("aliases"))
                || listed(registry.pointer(&format!(
                    "/origins/{}/hostnames",
                    key.replace('~', "~0").replace('/', "~1")
                )))
        })
        .map(|(key, _)| key.as_str())
}

/// Whether `registry` says the peer `name` at `url` is one of the fleet's dedicated agent VMs
/// (module docs).
pub(crate) fn agent_vm_in(registry: &Value, name: &str, url: &str) -> bool {
    let Some(host) = ssh_host(url) else { return false };
    let Some(machine) = machine_named(registry, name) else { return false };
    if machine_named(registry, &host) != Some(machine) {
        return false;
    }
    registry.get("machines").and_then(|m| m.get(machine)).and_then(|m| m.get("agent_vm"))
        == Some(&Value::Bool(true))
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

/// The fleet registry as read now, for a caller that asks about many peers at once.
pub(crate) fn registry_now() -> Option<Value> {
    let (source, set) = super::admission::registry_source();
    if source.as_os_str().is_empty() {
        return None;
    }
    super::admission::read_registry(&source, set).0
}

/// What decides a machine's group: the person's own placing first, then what acpmux knows of
/// how the machine is run. Never its name.
pub(crate) struct GroupFacts {
    /// `PeerConfig` `group`, if it is `own` or `agent`.
    pub set: Option<String>,
    /// The peer is held at the VM boundary (a saved `vmBoundary`, or a Cloud lease's).
    pub vm_boundary: bool,
    /// A Cloud lease made the peer: an ephemeral VM the app leased.
    pub leased: bool,
    /// This caller's fleet registry marks the peer `agent_vm` ([`agent_vm_in`]).
    pub registry_agent_vm: bool,
}

/// `"agent"` for a machine agents run on (a lane VM, swarm VM, control plane or leased Cloud
/// VM), `"own"` for the person's own computer. The picker lists `own` machines inline and
/// folds `agent` ones into one group.
pub(crate) fn group_of(f: &GroupFacts) -> &'static str {
    match f.set.as_deref() {
        Some("own") => return "own",
        Some("agent") => return "agent",
        _ => {}
    }
    if f.vm_boundary || f.leased || f.registry_agent_vm { "agent" } else { "own" }
}

#[cfg(test)]
mod group_tests {
    use super::{GroupFacts, group_of};

    fn facts(set: Option<&str>, vm: bool, leased: bool, reg: bool) -> GroupFacts {
        GroupFacts { set: set.map(str::to_owned), vm_boundary: vm, leased, registry_agent_vm: reg }
    }

    #[test]
    fn derives_from_how_the_machine_is_run_never_its_name() {
        assert_eq!(group_of(&facts(None, false, false, false)), "own");
        assert_eq!(group_of(&facts(None, true, false, false)), "agent");
        assert_eq!(group_of(&facts(None, false, true, false)), "agent");
        assert_eq!(group_of(&facts(None, false, false, true)), "agent");
    }

    #[test]
    fn the_persons_own_placing_wins() {
        assert_eq!(group_of(&facts(Some("own"), true, true, true)), "own");
        assert_eq!(group_of(&facts(Some("agent"), false, false, false)), "agent");
        assert_eq!(group_of(&facts(Some("bogus"), false, false, true)), "agent");
    }

    #[test]
    fn config_round_trips_group() {
        let pc: crate::config::PeerConfig =
            serde_json::from_str(r#"{"url":"ssh://a","group":"agent"}"#).unwrap();
        assert_eq!(pc.group.as_deref(), Some("agent"));
        let v = serde_json::to_value(&pc).unwrap();
        assert_eq!(v["group"], "agent");
        let none: crate::config::PeerConfig = serde_json::from_str(r#"{"url":"ssh://a"}"#).unwrap();
        assert!(serde_json::to_value(&none).unwrap().get("group").is_none());
    }
}

#[cfg(test)]
mod tests {
    use super::{agent_vm_in, ssh_host};
    use serde_json::json;

    fn registry() -> serde_json::Value {
        json!({"machines": {
            "agent-lane-1": {"agent_vm": true, "aliases": ["lane-1"]},
            "caller-box": {"aliases": ["hb"]},
            "mini-3": {"agent_vm": false},
        }})
    }

    /// A start from another machine onto a lane VM its registry marks `agent_vm` asks for the VM
    /// boundary (so the lane runs unsandboxed, the VM being the boundary); any other peer does not.
    #[test]
    fn only_a_registry_agent_vm_peer_is_held_at_the_vm_boundary() {
        let r = registry();
        assert!(agent_vm_in(&r, "agent-lane-1", "ssh://agent-lane-1"));
        assert!(agent_vm_in(&r, "lane-1", "ssh://cmux@agent-lane-1:22"), "an alias");
        assert!(agent_vm_in(&r, "Agent-Lane-1", "ssh://AGENT-LANE-1"), "case aside");
        assert!(!agent_vm_in(&r, "agent-lane-1", "ws://127.0.0.1:7777"), "a leased ws peer");
        assert!(!agent_vm_in(&r, "agent-lane-1", "wss://lane.example"), "not ssh");
        assert!(!agent_vm_in(&r, "agent-lane-1", "ssh://evil.example"), "dials elsewhere");
        assert!(
            !agent_vm_in(&r, "agent-lane-1", "ssh://agent-lane-1.evil.example"),
            "no short-name match on the host"
        );
        assert!(
            !agent_vm_in(&r, "agent-lane-1.evil", "ssh://agent-lane-1"),
            "no short-name match on the name"
        );
        assert!(!agent_vm_in(&r, "agent-lane-1", "ssh://caller-box"), "another machine");
        assert!(!agent_vm_in(&r, "caller-box", "ssh://caller-box"), "no agent_vm");
        assert!(!agent_vm_in(&r, "mini-3", "ssh://mini-3"), "agent_vm false");
        assert!(!agent_vm_in(&r, "stranger", "ssh://stranger"), "not in the registry");
        assert!(!agent_vm_in(&json!({}), "agent-lane-1", "ssh://agent-lane-1"));
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
