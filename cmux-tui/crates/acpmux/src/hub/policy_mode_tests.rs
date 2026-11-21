use super::*;

/// An `asksBeforeTools` claim is believed only from an agent started from a harness entry of
/// the config that still launches what it started from (`claim_distrust`).
#[test]
fn a_policy_claim_is_believed_only_from_an_unchanged_config_entry() {
    let mut cfg: Config =
        serde_json::from_value(json!({"harnesses": {"lane": {"argv": ["lane-acp"]}}})).unwrap();
    let mut meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "s", "name": "s", "harness": "lane",
        "cwd": "/w", "status": "ready", "createdAt": 0, "updatedAt": 0,
        "agentCapabilities": {"_meta": {"acpmux": {"asksBeforeTools": true}}},
    }))
    .unwrap();
    // A copy of the claim (a fork before its start, a moved chat): no launch recorded.
    assert_eq!(claim_distrust(&meta, &cfg), Some("not_started_here"));
    assert!(!asks_before_tools(&meta, &cfg));
    meta.launch_digest = Some(cfg.harnesses["lane"].launch_digest());
    assert_eq!(claim_distrust(&meta, &cfg), None);
    assert!(asks_before_tools(&meta, &cfg));
    // In a mode that skips approvals, a believed claim still does not hold.
    meta.modes = Some(json!({"currentModeId": "bypassPermissions"}));
    assert!(!asks_before_tools(&meta, &cfg));
    meta.modes = None;
    let lane = cfg.harnesses.get_mut("lane").unwrap();
    lane.env.insert("LANE_FLAG".to_owned(), "1".to_owned());
    assert_eq!(claim_distrust(&meta, &cfg), Some("entry_changed"));
    assert!(!asks_before_tools(&meta, &cfg));
    // A folder profile, or an entry removed since.
    meta.harness = "acme".to_owned();
    assert_eq!(claim_distrust(&meta, &cfg), Some("not_a_config_entry"));
    // No claim at all: nothing to believe.
    meta.harness = "lane".to_owned();
    meta.agent_capabilities = Some(json!({}));
    assert!(!claims_asks(&meta));
}

/// The claim is judged by the recorded launch alone, with no look at the filesystem: a start
/// records the digest of its config entry as the entry is written, a remote start too (lead,
/// 2026-11-09). A launch whose program is some other path than the entry's (here the
/// canonical path a remote start resolves the entry's bare program to) is another launch.
#[test]
fn a_launch_with_another_program_path_is_not_the_entrys_launch() {
    let cfg: Config =
        serde_json::from_value(json!({"harnesses": {"py": {"argv": ["python3", "agent.py"]}}}))
            .unwrap();
    let mut resolved = cfg.harnesses["py"].clone();
    super::super::resolve::fix_remote_executable(&mut resolved).unwrap();
    assert_ne!(resolved.argv, cfg.harnesses["py"].argv, "python3 resolves to a path");
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "s", "name": "s", "harness": "py",
        "cwd": "/w", "status": "ready", "createdAt": 0, "updatedAt": 0,
        "launchDigest": resolved.launch_digest(),
        "agentCapabilities": {"_meta": {"acpmux": {"asksBeforeTools": true}}},
    }))
    .unwrap();
    assert_eq!(claim_distrust(&meta, &cfg), Some("entry_changed"));
}

fn ids(modes: &[&str]) -> Vec<String> {
    modes.iter().map(|m| (*m).to_owned()).collect()
}

#[test]
fn each_policy_maps_onto_a_codex_mode_that_keeps_it() {
    let codex = ids(&["ask", "read-only", "agent", "agent-full-access"]);
    for (policy, mode) in [
        (PermissionPolicy::Ask, "ask"),
        (PermissionPolicy::ApproveReads, "ask"),
        (PermissionPolicy::ApproveEdits, "ask"),
        (PermissionPolicy::DenyAll, "read-only"),
    ] {
        assert_eq!(policy_mode(policy, "codex", &codex).as_deref(), Some(mode), "{policy}");
    }
}

/// A remote start on the bridge settles in `read-only` only for an enrolled peer under
/// deny-all, and in `ask` from anyone else, under any other policy, or when the harness offers
/// no `read-only`.
#[test]
fn a_remote_bridge_start_settles_in_read_only_only_for_a_peer_under_deny_all() {
    let codex = ids(&["ask", "read-only", "agent", "agent-full-access"]);
    let deny_all = Some(PermissionPolicy::DenyAll);
    for vm in [false, true] {
        assert_eq!(bridge_settle_modes(true, deny_all, &codex, vm), ids(&["read-only"]));
        assert_eq!(bridge_settle_modes(false, deny_all, &codex, vm), ids(&["ask"]));
        assert_eq!(bridge_settle_modes(true, deny_all, &ids(&["ask", "agent"]), vm), ids(&["ask"]));
        assert_eq!(bridge_settle_modes(true, deny_all, &[], vm), ids(&["ask"]));
    }
    for policy in [
        None,
        Some(PermissionPolicy::Ask),
        Some(PermissionPolicy::ApproveReads),
        Some(PermissionPolicy::ApproveEdits),
    ] {
        assert_eq!(bridge_settle_modes(true, policy, &codex, false), ids(&["ask"]), "{policy:?}");
    }
}

/// A Codex chat the owner's peer daemon starts at its VM boundary (a lane VM of its own
/// fleet) with approve-all runs in full access, the VM being the boundary, so the lane can
/// write its host's wt mirrors, `~/.local/state` and `~/.cache` and reach the daemon's socket
/// for `acpmux send`; `ask` (Codex's workspace-write sandbox) only if that is refused. Never
/// for a narrower policy, a Web client or paired device, a chat away from the boundary, or a
/// harness that offers no full access.
#[test]
fn a_peer_codex_start_at_the_vm_boundary_runs_in_full_access() {
    let codex = ids(&["ask", "read-only", "agent", "agent-full-access"]);
    assert_eq!(bridge_settle_modes(true, None, &codex, true), ids(&["agent-full-access", "ask"]));
    assert_eq!(bridge_settle_modes(true, None, &codex, false), ids(&["ask"]), "no boundary");
    assert_eq!(bridge_settle_modes(false, None, &codex, true), ids(&["ask"]), "not the peer");
    assert_eq!(
        bridge_settle_modes(true, None, &ids(&["ask", "agent"]), true),
        ids(&["ask"]),
        "no full access offered"
    );
    for policy in [
        PermissionPolicy::Ask,
        PermissionPolicy::ApproveReads,
        PermissionPolicy::ApproveEdits,
        PermissionPolicy::Review,
    ] {
        assert_eq!(
            bridge_settle_modes(true, Some(policy), &codex, true),
            ids(&["ask"]),
            "{policy:?}"
        );
    }
}

/// Muse Code through muse-acp offers `default`, `readOnly` and `plan`, and asks through its
/// approval option, not a mode: deny-all holds in `readOnly`; the asking policies have no
/// mode that keeps them.
#[test]
fn muse_deny_all_runs_read_only() {
    let muse = ids(&["default", "readOnly", "plan"]);
    assert_eq!(policy_mode(PermissionPolicy::DenyAll, "muse", &muse).as_deref(), Some("readOnly"));
    assert_eq!(policy_mode(PermissionPolicy::Ask, "muse", &muse), None);
}

#[test]
fn claude_asks_in_default_and_opencode_and_a_modeless_harness_cannot_keep_a_policy() {
    let claude = ids(&["default", "acceptEdits", "plan", "bypassPermissions"]);
    for policy in [
        PermissionPolicy::Ask,
        PermissionPolicy::ApproveReads,
        PermissionPolicy::ApproveEdits,
        PermissionPolicy::DenyAll,
    ] {
        assert_eq!(policy_mode(policy, "claude", &claude).as_deref(), Some("default"));
        assert_eq!(policy_mode(policy, "opencode", &ids(&["build", "plan", "ask"])), None);
        assert_eq!(policy_mode(policy, "pi", &[]), None);
    }
}

/// Leo, 2026-11-17: "changed things shouldn't be so weirdly errored. and it shouldnt have
/// errored in the first place". A chief chat whose own policy is `ask` is refused with what
/// is wrong and the one command that runs it, and a wake under the same key gets the held
/// refusal instead of starting its harness again (every 30 s on Leo's Mac); a change of its
/// mode, policy or harness entry, or the person's prompt, lets it try once more.
#[test]
fn a_refused_chat_says_its_fix_and_is_not_started_again_until_it_changes() {
    let cfg = Config::default();
    let mut meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "chief-1", "name": "chief", "harness": "chief",
        "cwd": "/w", "status": "ready", "createdAt": 0, "updatedAt": 0,
        "permissionPolicy": "ask", "policySource": "set",
    }))
    .unwrap();
    let e = require_enforced(&meta, &cfg).unwrap_err();
    assert!(is_unenforceable(&e), "{e:?}");
    assert_eq!(
        e.message,
        "Harness chief cannot ask before tools, so a chat on it runs only under permission policy approve-all, and this one's is ask: set its policy to approve-all with `acpmux set chief-1 policy=approve-all`."
    );
    let data = e.data.clone().unwrap();
    assert_eq!(data["fix"], "acpmux set chief-1 policy=approve-all");
    assert_eq!(data["policy"], "ask");
    assert_eq!(data["harness"], "chief");
    assert!(!e.message.contains("did not start"), "{}", e.message);
    // Being created, the chat is discarded: its fix is the start's flag.
    let e = require_enforced_as(&meta, &cfg, true).unwrap_err();
    assert!(e.message.ends_with("start it with `--policy approve-all`."), "{}", e.message);
    // A harness with a mode that keeps the policy, whose agent did not take it.
    meta.modes = Some(json!({"currentModeId": "bypassPermissions"}));
    let refused =
        Refused { policy: PermissionPolicy::Ask, meta: &meta, wanted: Some("default"), new: false };
    let e = unenforceable(&refused, "it does not run in its mode that asks (default)");
    assert_eq!(
        e.message,
        "Harness chief keeps permission policy ask only in its mode default, and its agent stayed in bypassPermissions: set its policy to approve-all with `acpmux set chief-1 policy=approve-all`."
    );
    meta.modes = None;

    // The latch: held under its key, dropped when the key changes or the person writes.
    let latch = RefusalLatch::default();
    let key = refusal_key(&meta, cfg.permission_policy, "digest");
    assert!(latch.held(&key).is_none());
    assert!(latch.hold(key.clone(), &e), "the first refusal is logged");
    assert!(!latch.hold(key.clone(), &e), "the same refusal again is not");
    assert_eq!(latch.held(&key).map(|h| h.message), Some(e.message.clone()));
    assert_eq!(refusal_key(&meta, cfg.permission_policy, "digest"), key, "a wake: same key");
    let mut moved = meta.clone();
    moved.permission_policy = Some("approve-all".to_owned());
    assert!(latch.held(&refusal_key(&moved, cfg.permission_policy, "digest")).is_none());
    assert!(latch.held(&key).is_none(), "a changed key drops the refusal");
    latch.hold(key.clone(), &e);
    moved = meta.clone();
    moved.modes = Some(json!({"currentModeId": "default"}));
    assert_ne!(refusal_key(&moved, cfg.permission_policy, "digest"), key, "its mode");
    assert_ne!(refusal_key(&meta, cfg.permission_policy, "other"), key, "its harness entry");
    moved = meta.clone();
    moved.harness = "claude".to_owned();
    assert_ne!(refusal_key(&moved, cfg.permission_policy, "digest"), key, "its harness");
    latch.clear();
    assert!(latch.held(&key).is_none(), "the person's prompt tries again");
}
