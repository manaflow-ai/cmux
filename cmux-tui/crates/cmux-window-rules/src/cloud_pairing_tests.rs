use serde_json::{Value, json};

use super::*;

fn owner(code: &str, message: &str) -> Failure {
    Failure::Owner { code: code.into(), message: message.into() }
}

#[test]
fn a_lookup_reads_the_preview_of_the_code() {
    let call = call(&Request::Lookup { code: "K7QX2M9P".into() });
    assert_eq!(call.path, READ);
    assert_eq!(call.body, json!({"op": "server.pair.preview", "params": {"code": "K7QX2M9P"}}));
}

#[test]
fn the_team_read_and_the_chief_list_take_no_params() {
    let team = call(&Request::TeamRead);
    assert_eq!(team.path, READ);
    assert_eq!(team.body, json!({"op": "team.policy.get", "params": {}}));
    let chiefs = call(&Request::ChiefList);
    assert_eq!(chiefs.path, READ);
    assert_eq!(chiefs.body, json!({"op": "chief.list", "params": {}}));
}

#[test]
fn ensure_is_a_user_op_with_its_own_idempotency_key() {
    let call = call(&Request::Ensure { nonce: "N-1".into() });
    assert_eq!(call.path, OPS);
    assert_eq!(
        call.body,
        json!({"op": "user.ensure", "params": {}, "idempotency_key": "server-pair-ensure-N-1", "origin": "user"})
    );
}

#[test]
fn approve_and_revoke_carry_the_intents_key() {
    let approve = call(&Request::Approve {
        code: "K7QX2M9P".into(),
        team: "team_personal".into(),
        name: "build-01".into(),
        key: "intent-1".into(),
    });
    assert_eq!(approve.path, OPS);
    assert_eq!(
        approve.body,
        json!({
            "op": "server.pair.approve",
            "params": {"code": "K7QX2M9P", "team": "team_personal", "name": "build-01"},
            "idempotency_key": "intent-1",
            "origin": "user",
        })
    );
    let revoke = call(&Request::Revoke { host: "host_1".into(), key: "intent-2".into() });
    assert_eq!(revoke.path, OPS);
    assert_eq!(
        revoke.body,
        json!({"op": "server.revoke", "params": {"host": "host_1"}, "idempotency_key": "intent-2", "origin": "user"})
    );
}

#[test]
fn a_hosts_page_names_its_cursor_only_after_the_first() {
    let first = call(&Request::HostsPage { cursor: None });
    assert_eq!(first.body, json!({"op": "team.hosts.list", "params": {"limit": 100}}));
    let next = call(&Request::HostsPage { cursor: Some("c2".into()) });
    assert_eq!(
        next.body,
        json!({"op": "team.hosts.list", "params": {"limit": 100, "cursor": "c2"}})
    );
}

#[test]
fn a_worker_error_reply_is_the_owners_error() {
    assert_eq!(
        reply(&json!({"_tag": "Error", "code": "selector.not_found", "message": "no such code"})),
        Reply::Owner { code: "selector.not_found".into(), message: "no such code".into() }
    );
    // No message: the code stands for it.
    assert_eq!(
        reply(&json!({"_tag": "Error", "code": "auth.forbidden"})),
        Reply::Owner { code: "auth.forbidden".into(), message: "auth.forbidden".into() }
    );
}

#[test]
fn a_reply_without_a_tag_or_code_is_its_value() {
    assert_eq!(reply(&json!({"value": {"team": "t"}})), Reply::Ok { value: json!({"team": "t"}) });
    assert_eq!(reply(&json!({})), Reply::Ok { value: Value::Null });
    // A tag with no string code is not an error reply.
    assert_eq!(
        reply(&json!({"_tag": "Error", "code": 7, "value": 1})),
        Reply::Ok { value: json!(1) }
    );
    assert_eq!(
        reply(&json!({"_tag": null, "code": "x", "value": 2})),
        Reply::Ok { value: json!(2) }
    );
}

#[test]
fn the_team_is_named_as_the_account_else_its_id() {
    assert_eq!(
        team(&json!({"team": "team_personal"}), "Leo"),
        Some(Team { id: "team_personal".into(), name: "Leo".into() })
    );
    assert_eq!(
        team(&json!({"team": "team_personal"}), ""),
        Some(Team { id: "team_personal".into(), name: "team_personal".into() })
    );
}

#[test]
fn a_team_read_without_a_team_is_a_bad_reply() {
    assert_eq!(team(&json!({"team": ""}), "Leo"), None);
    assert_eq!(team(&json!({"team": 4}), "Leo"), None);
    assert_eq!(team(&json!({}), "Leo"), None);
    assert_eq!(team(&Value::Null, "Leo"), None);
}

#[test]
fn only_forbidden_ensures_the_personal_team() {
    assert!(team_read_ensures("auth.forbidden"));
    assert!(!team_read_ensures("selector.not_found"));
}

#[test]
fn an_approve_succeeds_only_with_the_enrolled_host() {
    assert_eq!(
        approved(&json!({"host": "host_1", "install": "inst_1"})),
        Some(Approved { host: "host_1".into(), install: Some("inst_1".into()) })
    );
    assert_eq!(
        approved(&json!({"host": "host_1"})),
        Some(Approved { host: "host_1".into(), install: None })
    );
    assert_eq!(approved(&json!({"install": "inst_1"})), None);
    assert_eq!(approved(&Value::Null), None);
}

#[test]
fn hosts_paging_stops_at_the_last_page_or_the_cap() {
    assert_eq!(hosts_next(0, None), HostsNext::Done);
    assert_eq!(hosts_next(0, Some("")), HostsNext::Done);
    assert_eq!(hosts_next(0, Some("c2")), HostsNext::Read { cursor: "c2".into() });
    assert_eq!(hosts_next(HOSTS_PAGE_CAP - 2, Some("c")), HostsNext::Read { cursor: "c".into() });
    // The twentieth page still names a next one: a partial read.
    assert_eq!(hosts_next(HOSTS_PAGE_CAP - 1, Some("c")), HostsNext::TooMany);
    assert_eq!(hosts_next(HOSTS_PAGE_CAP - 1, None), HostsNext::Done);
}

#[test]
fn a_lookup_refuses_by_the_owners_code() {
    assert_eq!(
        refusal(Stage::Lookup, &owner("selector.not_found", "x")),
        Refusal { key: "pairNotFound", message: None, cause: None }
    );
    assert_eq!(
        refusal(Stage::Lookup, &owner("server.expired", "The code expired")),
        Refusal { key: "pairFailed", message: Some("The code expired".into()), cause: None }
    );
    assert_eq!(refusal(Stage::Lookup, &Failure::KeyUnchecked).key, "pairKeyUnchecked");
}

#[test]
fn not_the_owners_failures_show_fixed_text() {
    for stage in [Stage::Lookup, Stage::Approve, Stage::Revoke] {
        assert_eq!(refusal(stage, &Failure::SignedOut).key, SIGNED_OUT);
        assert_eq!(refusal(stage, &Failure::Other).key, UNREACHABLE);
        assert_eq!(refusal(stage, &Failure::Other).message, None);
    }
}

#[test]
fn approve_and_revoke_name_the_owners_message() {
    // An approve's not-found is still "Could not add the server" (only a lookup says no server waits).
    assert_eq!(
        refusal(Stage::Approve, &owner("selector.not_found", "gone")),
        Refusal { key: "pairFailed", message: Some("gone".into()), cause: None }
    );
    assert_eq!(
        refusal(Stage::Revoke, &owner("x", "no access")),
        Refusal { key: "revokeFailed", message: Some("no access".into()), cause: None }
    );
}

#[test]
fn a_chief_that_could_not_move_names_why() {
    assert_eq!(
        refusal(Stage::PlaceChief, &owner("x", "busy")),
        Refusal { key: "chiefNotMoved", message: Some("busy".into()), cause: None }
    );
    assert_eq!(refusal(Stage::PlaceChief, &Failure::NoInstall).cause, Some("noInstall"));
    assert_eq!(refusal(Stage::PlaceChief, &Failure::SignedOut).cause, Some(SIGNED_OUT));
    assert_eq!(refusal(Stage::PlaceChief, &Failure::Other).cause, Some(UNREACHABLE));
}

#[test]
fn the_wire_shapes() {
    let request: Request = serde_json::from_value(json!({"kind": "hostsPage"})).unwrap();
    assert_eq!(request, Request::HostsPage { cursor: None });
    let failure: Failure =
        serde_json::from_value(json!({"kind": "owner", "code": "c", "message": "m"})).unwrap();
    assert_eq!(failure, owner("c", "m"));
    assert_eq!(
        serde_json::to_value(refusal(Stage::Lookup, &Failure::SignedOut)).unwrap(),
        json!({"key": "pairSignedOut"})
    );
    assert_eq!(
        serde_json::to_value(hosts_next(0, Some("c"))).unwrap(),
        json!({"kind": "read", "cursor": "c"})
    );
    assert_eq!(
        serde_json::to_value(reply(&json!({"value": 1}))).unwrap(),
        json!({"kind": "ok", "value": 1})
    );
}
