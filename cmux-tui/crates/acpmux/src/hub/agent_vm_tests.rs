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
