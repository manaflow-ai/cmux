use super::*;

fn preset(v: Value) -> Preset {
    serde_json::from_value(v).expect("a preset")
}

fn lane() -> Preset {
    preset(json!({"harness": "claude", "model": "claude-opus-5-5", "effort": "medium",
        "policy": "approve-all", "description": "fleet lanes"}))
}

fn approved(p: &Preset) -> Preset {
    let mut p = p.clone();
    p.unattended = approval_now(&p);
    p
}

#[test]
fn an_approval_holds_for_the_contents_it_was_given_and_no_others() {
    let p = approved(&lane());
    assert!(p.unattended_approved());
    // The description and the approvals are not contents.
    let mut described = p.clone();
    described.description = Some("other words".into());
    assert!(described.unattended_approved());
    assert_eq!(described.approval_digest(), lane().approval_digest());
    // Every field a session starts with is.
    for edit in [
        json!({"model": "claude-sonnet-5"}),
        json!({"effort": "high"}),
        json!({"policy": "approve-edits"}),
        json!({"harness": "codex"}),
    ] {
        let mut v = serde_json::to_value(&p).unwrap();
        v.as_object_mut().unwrap().extend(edit.as_object().unwrap().clone());
        assert!(!preset(v).unattended_approved(), "{edit}");
    }
}

#[test]
fn an_approval_field_leaves_the_digest_of_a_preset_without_one_as_it_was() {
    // A preset written before this field hashes as it did (its `modeApproval` still holds).
    let p = lane();
    let mut with = p.clone();
    with.unattended = approval_now(&p);
    assert_eq!(p.approval_digest(), with.approval_digest());
}

#[test]
fn only_a_preset_a_peer_starts_exactly_as_approved_can_be_approved() {
    assert_eq!(lane().unattended_blocker(), None);
    let cases = [
        (json!({"harness": "claude"}), "preset.policy_asks"),
        (json!({"harness": "claude", "policy": "ask"}), "preset.policy_asks"),
        (json!({"harness": "claude", "policy": "deny-all"}), "preset.policy_asks"),
        (json!({"harness": "claude", "policy": "approve-all", "env": {"A": "b"}}), "preset.env"),
        (json!({"harness": "claude", "policy": "approve-all", "args": ["--tools", ""]}), "preset.args"),
        (json!({"harness": "claude", "policy": "approve-all", "systemPromptSha256": "ab"}), "preset.system_prompt"),
        (json!({"harness": "claude", "policy": "approve-all", "mode": "bypassPermissions"}), "preset.mode"),
    ];
    for (v, why) in cases {
        let p = preset(v.clone());
        assert_eq!(p.unattended_blocker(), Some(why), "{v}");
        // Even with an approval record (a hand edit), such a preset is not approved.
        assert!(!approved(&p).unattended_approved(), "{v}");
    }
    assert_eq!(preset(json!({"harness": "claude", "policy": "approve-reads"})).unattended_blocker(), None);
}

#[test]
fn a_fleet_agent_machine_is_an_agent_vm_session_host_in_the_registry() {
    let registry = json!({"machines": {
        "gcp-agent-lane-1": {"agent_vm": true, "roles": ["session-host", "linux-build"], "aliases": ["gcp-lane-1"]},
        "air-blue": {"roles": ["attended", "leo-mac", "codex-lanes"]},
        "huge-blue": {"roles": ["session-host"]},
        "attended-vm": {"agent_vm": true, "roles": ["session-host", "attended"]},
        "builder": {"agent_vm": true, "roles": ["linux-build"]},
        "old-lane": {"agent_vm": true, "roles": ["session-host"], "retired": true},
    }});
    let r = Some(&registry);
    assert!(crate::placement::agent_vm(r, "gcp-agent-lane-1"));
    assert!(crate::placement::agent_vm(r, "GCP-LANE-1"), "an alias, any case");
    for name in ["air-blue", "huge-blue", "attended-vm", "builder", "old-lane", "unknown"] {
        assert!(!crate::placement::agent_vm(r, name), "{name}");
    }
    assert!(!crate::placement::agent_vm(None, "gcp-agent-lane-1"), "no registry, no fleet machine");
}

#[test]
fn a_dispatch_carries_the_approved_contents_and_never_the_preset_name() {
    let p = lane();
    let mut params = json!({"brief": "x", "preset": "agent-lane", "host": "gcp-agent-lane-1"});
    assert!(!overrides(Shape::Dispatch, &params, &p));
    put_contents(Shape::Dispatch, &mut params, &p);
    assert_eq!(params.get("preset"), None, "{params}");
    assert_eq!(params["harness"], "claude");
    assert_eq!(params["model"], "claude-opus-5-5");
    assert_eq!(params["effort"], "medium");
    assert_eq!(params["policy"], "approve-all");
    assert_eq!(params["brief"], "x");
}

#[test]
fn a_new_session_carries_the_approved_contents_in_its_meta() {
    let p = preset(json!({"harness": "claude", "policy": "approve-all"}));
    let mut params = json!({"cwd": "/w", "_meta": {"acpmux": {"preset": "agent-lane", "name": "lane"}}});
    put_contents(Shape::SessionNew, &mut params, &p);
    let meta = &params["_meta"]["acpmux"];
    assert_eq!(meta.get("preset"), None, "{params}");
    assert_eq!(meta["harness"], "claude");
    assert_eq!(meta["policy"], "approve-all");
    assert_eq!(meta.get("model"), None, "no model of its own: the harness's default");
    assert_eq!(meta["name"], "lane");
    assert_eq!(params["cwd"], "/w");
}

#[test]
fn a_start_that_names_its_own_contents_is_not_the_approved_one() {
    let p = lane();
    let same = [
        json!({"preset": "agent-lane", "policy": "approve-all"}),
        json!({"preset": "agent-lane", "model": "claude/claude-opus-5-5"}),
        json!({"preset": "agent-lane", "harness": "claude", "effort": "medium"}),
    ];
    for v in same {
        assert!(!overrides(Shape::Dispatch, &v, &p), "{v}");
    }
    let other = [
        json!({"preset": "agent-lane", "policy": "approve-edits"}),
        json!({"preset": "agent-lane", "model": "codex/gpt-6"}),
        json!({"preset": "agent-lane", "model": "claude-sonnet-5"}),
        json!({"preset": "agent-lane", "effort": "high"}),
    ];
    for v in other {
        assert!(overrides(Shape::Dispatch, &v, &p), "{v}");
    }
    let meta = json!({"_meta": {"acpmux": {"preset": "agent-lane", "model": "claude-sonnet-5"}}});
    assert!(overrides(Shape::SessionNew, &meta, &p));
}

#[test]
fn a_stamp_counts_only_with_its_fields_and_a_client_one_is_dropped() {
    let mut params = json!({"_meta": {"acpmux": {STAMP_FIELD: {"preset": "agent-lane", "digest": "ab"}}}});
    assert!(stamp_of(&params).is_some());
    strip_stamp(&mut params);
    assert!(stamp_of(&params).is_none());
    for bad in [json!({"preset": "agent-lane"}), json!({"digest": "ab"}), json!(true), json!({"preset": "", "digest": "ab"})] {
        let params = json!({"_meta": {"acpmux": {STAMP_FIELD: bad}}});
        assert!(stamp_of(&params).is_none(), "{params}");
    }
}

#[test]
fn a_row_counts_runs_under_the_approval_and_tries_since_the_last_change() {
    let p = approved(&lane());
    let line = |kind: &str, at: u64| json!({"preset": "agent-lane", "kind": kind, "at": at, "host": "gcp-agent-lane-1", "from": "coord", "sessionId": format!("s{at}")});
    let log = vec![
        line("asked", 1),
        line("started", 2),
        line("approved", 3),
        line("started", 4),
        line("started", 5),
        json!({"preset": "other", "kind": "started", "at": 6}),
    ];
    let r = row("agent-lane", &p, &log);
    assert_eq!(r["runs"], 2, "{r}");
    assert_eq!(r["lastRun"]["sessionId"], "s5", "{r}");
    assert_eq!(r["asks"], json!([]), "{r}");
    assert_eq!(r["approval"]["host"], crate::hub::host_label(), "{r}");
    assert_eq!(r["digest"], p.approval_digest().unwrap());
    // Not approved: no runs, and the tries since the last change, newest first.
    let log = vec![line("asked", 1), line("revoked", 2), line("asked", 3), line("asked", 4)];
    let r = row("agent-lane", &lane(), &log);
    assert_eq!(r["approval"], Value::Null, "{r}");
    assert_eq!(r["runs"], 0);
    assert_eq!(r["lastRun"], Value::Null);
    let asks: Vec<u64> = r["asks"].as_array().unwrap().iter().map(|a| a["at"].as_u64().unwrap()).collect();
    assert_eq!(asks, vec![4, 3], "{r}");
    // An approval for other contents is none.
    let mut changed = approved(&lane());
    changed.model = Some("claude-sonnet-5".into());
    assert_eq!(row("agent-lane", &changed, &[])["approval"], Value::Null);
}
