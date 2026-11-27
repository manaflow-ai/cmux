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

use serde_json::{Value, json};

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

/// The group [`one_parent_refusal`] enforces on: `"agent"` only for a VM the app leased for a
/// chat (a Cloud VM) or a machine the person set to `agent` themselves; `own` set by the person
/// wins. A fleet VM the registry or a saved `vmBoundary` marks stays `agent` in the pickers but
/// is not refused: the fleet runs many parent lanes on one VM (that is the "separately controlled
/// remote machines" case, not the regular one).
pub(crate) fn refused_group(leased: bool, set: Option<&str>) -> &'static str {
    match set {
        Some("own") => "own",
        Some("agent") => "agent",
        _ if leased => "agent",
        _ => "own",
    }
}

/// One parent session per provisioned VM (Leo: "we are opinoinated-ing to not allow more than 1
/// parent agent session per vm. you can have your sepatealy controlled remote machines, but
/// that's not our regular thing."). `rows` are the peer's sessions as it lists them; a root is a
/// live row no agent started (no `startedBy`). A start that names a parent is a sub-session and
/// never counts. Returns the refusal for a second parent-less start on an `agent` machine.
pub(crate) fn one_parent_refusal(
    peer: &str,
    group: &str,
    asks_parent: bool,
    rows: impl IntoIterator<Item = Value>,
) -> Option<crate::rpc::RpcError> {
    if group != "agent" || asks_parent {
        return None;
    }
    let held = rows.into_iter().find(|r| {
        r.get("status").and_then(Value::as_str) != Some("closed")
            && r.get("stale") != Some(&Value::Bool(true))
            && r.get("startedBy").is_none_or(Value::is_null)
    })?;
    let existing = held.get("name").and_then(Value::as_str).unwrap_or("a session");
    Some(
        crate::rpc::RpcError::new(
            -32000,
            format!(
                "{peer} is a provisioned VM and already holds a parent session ({existing}); \
                 a VM holds one. Start this chat on Cloud (or Auto), or attach to or move the \
                 existing session. To use {peer} as a machine of your own, set its `group` to \
                 \"own\" in config.json."
            ),
        )
        .with_data(json!({"reason": ONE_PARENT_PER_VM, "peer": peer, "existing": existing})),
    )
}

/// `data.reason` of [`one_parent_refusal`].
pub const ONE_PARENT_PER_VM: &str = "one_parent_per_vm";

#[cfg(test)]
mod group_tests {
    use super::{GroupFacts, group_of, one_parent_refusal};
    use serde_json::json;

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
    fn a_provisioned_vm_holds_one_parent_session() {
        let root = json!({"name": "lead", "status": "idle"});
        let child = json!({"name": "kid", "startedBy": {"id": "s1"}});
        let closed = json!({"name": "old", "status": "closed"});
        assert!(one_parent_refusal("vm-1", "agent", false, [root.clone()]).is_some());
        assert!(
            one_parent_refusal("vm-1", "agent", false, [child, closed]).is_none(),
            "children and closed rows"
        );
        assert!(
            one_parent_refusal("vm-1", "agent", true, [root.clone()]).is_none(),
            "a sub-session start"
        );
        assert!(one_parent_refusal("big-red", "own", false, [root]).is_none(), "own machines");
        assert!(one_parent_refusal("vm-1", "agent", false, []).is_none(), "the first parent");
    }

    #[test]
    fn only_a_leased_vm_or_the_persons_agent_placing_is_refused() {
        use super::refused_group;
        assert_eq!(refused_group(true, None), "agent", "a Cloud VM the app leased");
        assert_eq!(refused_group(false, None), "own", "a fleet VM keeps its many lanes");
        assert_eq!(refused_group(false, Some("agent")), "agent");
        assert_eq!(refused_group(true, Some("own")), "own");
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
#[path = "agent_vm_tests.rs"]
mod tests;
