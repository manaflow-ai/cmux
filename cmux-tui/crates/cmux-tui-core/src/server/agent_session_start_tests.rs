use super::*;

/// A Cloud chat on the caller's own VM starts as a new chat on the caller's app does: the
/// person's bypass (`fullAccess`) or `standard` gives no `ask` policy, so it neither starts in
/// Manual nor refuses a mode the person picks later. A phone, another host, an `ask` setting and
/// an app from before the param keep `ask`.
#[test]
fn an_owner_cloud_start_takes_the_persons_permission_mode() {
    assert_eq!(start_policy(true, false, Some("fullAccess")), None);
    assert_eq!(start_policy(true, false, Some("standard")), None);
    assert_eq!(start_policy(true, false, Some("ask")), Some("ask"));
    assert_eq!(start_policy(true, false, None), Some("ask"));
    assert_eq!(start_policy(true, true, Some("fullAccess")), Some("ask"));
    assert_eq!(start_policy(false, false, Some("fullAccess")), Some("ask"));
    let parsed = |mode: &str| {
        serde_json::from_value::<StartParams>(
            json!({"surface": 1, "cwd": "/w", "permission_mode": mode}),
        )
        .map(|params| params.valid())
    };
    assert_eq!(parsed("fullAccess").ok(), Some(true));
    assert_eq!(parsed("bypassPermissions").ok(), Some(false));
}

/// Lawrence 2026-11-20: "we need to support auto mode for cloud mode for claude harness". A Claude
/// chat on the caller's own Cloud VM with no pick, under the person's full-access level, moves to
/// Claude Code's Auto once it started (it keeps Bypass permissions where Claude Code refuses Auto).
/// A pick, another level and another family keep what the start gave them.
#[test]
fn an_owner_cloud_claude_start_defaults_to_auto() {
    assert_eq!(cloud_default_mode(None, Some("fullAccess"), "claude"), Some("auto"));
    assert_eq!(cloud_default_mode(None, Some("fullAccess"), "claude-sr2"), Some("auto"));
    assert_eq!(cloud_default_mode(Some("bypassPermissions"), Some("fullAccess"), "claude"), None);
    assert_eq!(cloud_default_mode(Some("default"), Some("fullAccess"), "claude"), None);
    assert_eq!(cloud_default_mode(None, Some("standard"), "claude"), None);
    assert_eq!(cloud_default_mode(None, Some("ask"), "claude"), None);
    assert_eq!(cloud_default_mode(None, None, "claude"), None);
    assert_eq!(cloud_default_mode(None, Some("fullAccess"), "codex"), None);
    assert_eq!(cloud_default_mode(None, Some("fullAccess"), "claudette"), None);
}

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
        step: Some("bind"),
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

/// An agent that answered `session/new` it is not signed in (acpmux typed it
/// `agent.sign_in_required`) refuses the start as `sign_in_required` naming the harness,
/// never the bare `refused`; only acpmux's typed facts pass, never its message or a harness
/// name that is not one (hq#11225). Any other acpmux error stays `refused`.
#[test]
fn a_start_whose_agent_is_signed_out_names_the_harness() {
    let typed = LinkError::Rpc(
        "Authentication required".into(),
        json!({
            "reason": "agent.sign_in_required",
            "errorKind": "auth.signed_out",
            "recovery": "cursor is not signed in on this machine.",
            "details": {"harness": "cursor"},
        }),
    );
    let StartRefused(refusal, data) = StartRefused::of_session_new(typed);
    assert_eq!(refusal, Refusal::SignInRequired);
    assert_eq!(refusal.code(), "agent_session.sign_in_required");
    assert_eq!(
        data,
        Some(json!({
            "reason": "agent.sign_in_required",
            "harness": "cursor",
            "errorKind": "auth.signed_out",
        }))
    );
    let odd = LinkError::Rpc(
        "x".into(),
        json!({
            "reason": "agent.sign_in_required",
            "errorKind": "anything",
            "details": {"harness": "not a harness!"},
        }),
    );
    let StartRefused(refusal, data) = StartRefused::of_session_new(odd);
    assert_eq!(refusal, Refusal::SignInRequired);
    assert_eq!(data, Some(json!({"reason": "agent.sign_in_required"})));
    assert_eq!(
        StartRefused::of_session_new(LinkError::Rpc("Authentication required".into(), Value::Null)),
        StartRefused(Refusal::Refused, None)
    );
    assert_eq!(
        StartRefused::of_session_new(LinkError::Timeout),
        StartRefused(Refusal::Timeout, None)
    );
}

/// The carrier drill (cmuxterm-hq run 43973035740): acpmux refused `session/new` because the
/// remote start's `ask` cannot hold on an ACP agent with no asking mode
/// (`policy_unenforceable`), and the machine answered a bare `agent_session.refused` that
/// named no cause. It is `not_asking` naming the harness; any other acpmux refusal keeps its
/// reason code (never its message text, nor a reason that is no short code).
#[test]
fn a_start_acpmux_refused_says_why() {
    let unenforceable = LinkError::Rpc(
        "permission policy ask cannot be enforced on harness carrier-drill: ...".into(),
        json!({
            "reason": "policy_unenforceable",
            "policy": "ask",
            "harness": "carrier-drill",
            "why": "this agent has no mode that asks before each change",
        }),
    );
    let StartRefused(refusal, data) = StartRefused::of_session_new(unenforceable);
    assert_eq!(refusal.code(), "agent_session.not_asking");
    assert_eq!(data, Some(json!({"reason": "policy_unenforceable", "harness": "carrier-drill"})));
    let other = LinkError::Rpc("x".into(), json!({"reason": "remote.local_claude_session"}));
    assert_eq!(
        StartRefused::of_session_new(other),
        StartRefused(Refusal::Refused, Some(json!({"reason": "remote.local_claude_session"})))
    );
    let prose = LinkError::Rpc("x".into(), json!({"reason": "not a code: secret text"}));
    assert_eq!(StartRefused::of_session_new(prose), StartRefused(Refusal::Refused, None));
    assert_eq!(
        super::super::refusal_text(Refusal::Refused, &json!({"reason": "permission.denied"})),
        "acpmux refused the request (permission.denied)"
    );
    assert_eq!(
        super::super::refusal_text(Refusal::NotAsking, &json!({"reason": "x"})),
        Refusal::NotAsking.message()
    );
}

/// A bare `refused` names the phase acpmux refused in (`data.step`, and its text "at STEP"), so a
/// refusal with no reason code still says which call it was (the 2026-11-27T20:12Z
/// notify-banner-click row read only "acpmux refused the request"); other refusals stay as they are.
#[test]
fn a_bare_start_refusal_names_its_step() {
    let mut timings = super::StartTimings::default();
    assert_eq!(timings.refusal_data(Refusal::Refused, None), None);
    timings.at("session_new");
    let bare = timings.refusal_data(Refusal::Refused, None).expect("a step");
    assert_eq!(bare, json!({"step": "session_new"}));
    assert_eq!(
        super::super::refusal_text(Refusal::Refused, &bare),
        "acpmux refused the request at session_new"
    );
    let coded = timings
        .refusal_data(Refusal::Refused, Some(json!({"reason": "permission.denied"})))
        .expect("data");
    assert_eq!(
        super::super::refusal_text(Refusal::Refused, &coded),
        "acpmux refused the request (permission.denied) at session_new"
    );
    assert_eq!(timings.refusal_data(Refusal::UntrustedFolder, None), None);
    let keyed = json!({"reason": "needs_keyed_start"});
    assert_eq!(timings.refusal_data(Refusal::NeedsKeyedStart, Some(keyed.clone())), Some(keyed));
}

/// An agent the machine's acpmux catalog does not have (pi on a Cloud machine, whose image
/// ships `pi` but not the `pi-acp` adapter acpmux runs it through) is refused as
/// `harness_missing` naming it, never `not_asking`, which said the agent cannot ask first
/// (hq#11225). A harness the catalog has resolves to its family as before.
#[test]
fn a_start_of_an_agent_the_machine_lacks_names_it() {
    let catalog = json!({
        "harnesses": {"claude": {"family": "claude"}, "cmux": {"family": "claude"}},
        "families": {"claude": ["claude", "cmux"]},
        "defaultHarness": "claude",
    });
    assert_eq!(start_family(&catalog, Some("cmux")), Ok("claude".to_owned()));
    assert_eq!(start_family(&catalog, None), Ok("claude".to_owned()));
    let StartRefused(refusal, data) = start_family(&catalog, Some("pi")).unwrap_err();
    assert_eq!(refusal.code(), "agent_session.harness_missing");
    assert_eq!(data, Some(json!({"reason": "agent.not_installed", "harness": "pi"})));
    // A name that is no harness id is never echoed back.
    let StartRefused(refusal, data) = start_family(&catalog, Some("no such!")).unwrap_err();
    assert_eq!(refusal, Refusal::HarnessMissing);
    assert_eq!(data, Some(json!({"reason": "agent.not_installed"})));
    // No harness named and no default: still the missing agent, not a mode refusal.
    let bare = json!({"harnesses": {}, "families": {}});
    assert_eq!(start_family(&bare, None).unwrap_err().0, Refusal::HarnessMissing);
}

/// A start whose agent's model route cannot serve it on the machine (acpmux `route.*`: the
/// cmux router harness on a Cloud machine, which runs no signed-in local router) is refused
/// as `route_unavailable` naming the route's reason and the harness asked for, never the
/// bare `refused` (hq#11225). acpmux's message never passes.
#[test]
fn a_start_whose_route_cannot_serve_it_names_the_route() {
    for reason in ["route.unavailable", "route.not_found", "route.invalid"] {
        let down = LinkError::Rpc(
            "the local CodeRouter is not running (No such file or directory)".into(),
            json!({"reason": reason}),
        );
        let StartRefused(refusal, data) = StartRefused::of_session_new(down).naming(Some("cmux"));
        assert_eq!(refusal.code(), "agent_session.route_unavailable", "{reason}");
        assert_eq!(data, Some(json!({"reason": reason, "harness": "cmux"})), "{reason}");
    }
    let down = LinkError::Rpc("x".into(), json!({"reason": "route.unavailable"}));
    let StartRefused(refusal, data) = StartRefused::of_session_new(down).naming(None);
    assert_eq!(refusal, Refusal::RouteUnavailable);
    assert_eq!(data, Some(json!({"reason": "route.unavailable"})));
    // Naming leaves every other refusal as it was, and a sign-in's own harness stays.
    assert_eq!(
        StartRefused::from(Refusal::Refused).naming(Some("cmux")),
        StartRefused(Refusal::Refused, None)
    );
    let signed_out = LinkError::Rpc(
        "Authentication required".into(),
        json!({"reason": "agent.sign_in_required", "details": {"harness": "cursor"}}),
    );
    let StartRefused(_, data) = StartRefused::of_session_new(signed_out).naming(Some("grok"));
    assert_eq!(data.unwrap()["harness"], "cursor");
}
