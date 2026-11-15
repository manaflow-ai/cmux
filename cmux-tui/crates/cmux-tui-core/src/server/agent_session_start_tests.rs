use super::*;

/// A call on a Cloud VM (a start, a chat move in, folder trust) runs only
/// on the caller's `vm_kind: "owner"`; the VM's own `owner` record never
/// allows it. On a team VM that word (the creator's, from the Cloud API)
/// lets the call in too; without it a team VM still says so.
#[test]
fn a_call_on_a_cloud_vm_needs_the_callers_owner_word() {
    use AgentStartHost::{Allowed, OwnerCloud, TeamVm, UnknownCloud};
    let starts = AgentSessionStarts::default();
    assert_eq!(starts.host_gate(true), Err(Refusal::HostUnverified));
    let unverified = Err(Refusal::HostUnverified);
    let team = Err(Refusal::TeamVmBlocked);
    let cases = [
        (Allowed, Ok(()), Ok(())),
        (OwnerCloud, Ok(()), unverified),
        (UnknownCloud, Ok(()), unverified),
        (TeamVm, Ok(()), team),
    ];
    for (host, owner_word, no_word) in cases {
        starts.set_host(Arc::new(move || host));
        assert_eq!(starts.host_gate(true), owner_word, "{host:?}");
        assert_eq!(starts.host_gate(false), no_word, "{host:?}");
    }
}

/// The answer's `timings_ms` names each phase the start reached, in ms,
/// and whether it started acpmux; a phase it never reached is left out.
#[test]
fn timings_name_each_phase_reached() {
    let none = StartTimings::default().wire();
    assert_eq!(none, json!({"acpmux_started": false}));
    let all = StartTimings {
        keyed_gate: Some(1),
        acpmux_connect: Some(2),
        acpmux_started: true,
        checks: Some(3),
        session_new: Some(1800),
        settle: Some(4),
        bind: Some(5),
        total: Some(1815),
    };
    assert_eq!(
        all.wire(),
        json!({"keyed_gate": 1, "acpmux_connect": 2, "acpmux_started": true, "checks": 3,
               "session_new": 1800, "settle": 4, "bind": 5, "total": 1815})
    );
    let gated = StartTimings { keyed_gate: Some(7), total: Some(7), ..Default::default() };
    assert_eq!(gated.wire(), json!({"keyed_gate": 7, "total": 7, "acpmux_started": false}));
}

/// A pick that asks keeps policy `ask` on the owner's VM; Bypass permissions and Codex full
/// access do not ask, so the start names no policy for them (module docs).
#[test]
fn a_pick_asks_only_when_the_table_or_the_bridge_says_so() {
    let table = json!({"families": {"claude": ["default", "plan"]}});
    assert!(mode_asks(&table, "claude", "default"));
    assert!(mode_asks(&table, "claude", "plan"));
    assert!(!mode_asks(&table, "claude", "bypassPermissions"));
    assert!(!mode_asks(&table, "claude", "acceptEdits"));
    assert!(mode_asks(&table, "codex", "ask"));
    assert!(mode_asks(&table, "codex", "read-only"));
    assert!(!mode_asks(&table, "codex", "agent-full-access"));
    assert!(!mode_asks(&table, "codex", "agent"));
    assert!(!mode_asks(&table, "opencode", "ask"));
}

/// `mode` is a plain mode id: anything else makes the whole start a bad request.
#[test]
fn a_start_mode_is_a_plain_mode_id() {
    let params = |mode: &str| -> StartParams {
        serde_json::from_value(json!({"surface": 1, "cwd": "/home/u/work", "mode": mode}))
            .expect("params parse")
    };
    assert!(params("bypassPermissions").valid());
    assert!(params("agent-full-access").valid());
    assert!(!params("").valid());
    assert!(!params("bypass permissions").valid());
    assert!(!params(&"x".repeat(65)).valid());
}

/// Only a Cloud VM with no team evidence, and only on the caller's owner
/// word, lifts the asking-mode rule; a Mac or SSH host and a team VM never.
#[test]
fn only_the_callers_own_cloud_vm_starts_any_agent() {
    use AgentStartHost::{Allowed, OwnerCloud, TeamVm, UnknownCloud};
    let starts = AgentSessionStarts::default();
    assert!(!starts.owner_cloud(true));
    for (host, any_agent) in
        [(Allowed, false), (OwnerCloud, true), (UnknownCloud, true), (TeamVm, false)]
    {
        starts.set_host(Arc::new(move || host));
        assert_eq!(starts.owner_cloud(true), any_agent, "{host:?}");
        assert!(!starts.owner_cloud(false), "{host:?}");
    }
}
