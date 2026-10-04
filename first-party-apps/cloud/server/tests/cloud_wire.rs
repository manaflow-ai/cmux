//! The Cloud ops on the cmux.wire/1 backend, driven through the vectors
//! fake (`backend/catalog/cloud-vectors.json`, contract 1.3 and 1.4): list
//! pages, per-key replay, the same-key retry after `mutation.indeterminate`,
//! typed plan and quota errors, agent refusals, and team wire events applied
//! to the projection by revision.

mod wire_common;

use cmux_cloud::ops::WatchEvent;
use cmux_cloud::{CloudError, Origin, Request, Server};
use serde_json::{Value, json};
use wire_common::{WireFake, host, snap, vm};

fn server() -> Server<WireFake> {
    Server::new(WireFake::load())
}

/// A server whose projection holds the three listed machines.
fn listed() -> Server<WireFake> {
    let mut s = server();
    let out = s.handle(&Request::new("cloud.machine.list", json!({})));
    assert!(out.is_ok(), "list: {out:?}");
    s.take_events();
    s
}

fn record(s: &Server<WireFake>, id: &str) -> Value {
    s.projection().get(id).map_or(Value::Null, |m| serde_json::to_value(m).expect("record"))
}

fn ids(page: &Value) -> Vec<String> {
    page["machines"]
        .as_array()
        .map(|a| a.iter().map(|m| m["id"].as_str().unwrap_or_default().to_owned()).collect())
        .unwrap_or_default()
}

fn mutation(op: &str, args: Value, key: &str) -> Request {
    Request::new(op, args).key(key).origin(Origin::User)
}

fn err_json(out: Result<Value, CloudError>) -> Value {
    match out {
        Ok(v) => json!({ "unexpected_ok": v }),
        Err(e) => serde_json::to_value(&e).expect("error"),
    }
}

#[test]
fn list_pages_follow_the_cursor() {
    let mut s = server();
    let first = s.handle(&Request::new("cloud.machine.list", json!({ "limit": 2 })));
    assert!(first.is_ok(), "first page: {first:?}");
    let first = first.unwrap();
    assert_eq!(ids(&first), [vm(1), vm(2)]);
    assert_eq!(first["next_cursor"], "cur_page2");
    let second =
        s.handle(&Request::new("cloud.machine.list", json!({ "cursor": "cur_page2", "limit": 2 })));
    assert!(second.is_ok(), "second page: {second:?}");
    let second = second.unwrap();
    assert_eq!(ids(&second), [vm(3)]);
    assert_eq!(second["next_cursor"], Value::Null);
    assert_eq!(s.projection().len(), 3, "both pages fill the projection");
    let sent: Vec<Value> = s.control_plane().calls.iter().map(|c| c.params.clone()).collect();
    assert_eq!(sent, [json!({ "limit": 2 }), json!({ "cursor": "cur_page2", "limit": 2 })]);
    assert!(
        s.control_plane().calls.iter().all(|c| c.idempotency_key.is_none()),
        "reads carry no key"
    );
    // A limit outside 1..=100 or an empty cursor is refused before any call.
    for bad in [json!({ "limit": 0 }), json!({ "limit": 101 }), json!({ "cursor": "" })] {
        let out = s.handle(&Request::new("cloud.machine.list", bad.clone()));
        assert_eq!(err_json(out)["code"], "cmux.cloud.invalid_args", "{bad}");
    }
    assert_eq!(s.control_plane().calls.len(), 2);
}

#[test]
fn create_replays_on_the_same_key_and_never_creates_twice() {
    let mut s = server();
    let args =
        json!({ "name": "new box", "size": { "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 } });
    let first = s.handle(&mutation("cloud.machine.create", args.clone(), "key-create-1"));
    assert!(first.is_ok(), "create: {first:?}");
    let again = s.handle(&mutation("cloud.machine.create", args.clone(), "key-create-1"));
    assert_eq!(first, again, "the same key answers the same machine");
    let first = first.unwrap();
    assert_eq!(first["machine"]["id"], vm(4));
    assert_eq!(first["machine"]["status"], "provisioning");
    assert!(
        s.control_plane()
            .keys("cloud.machine.create")
            .iter()
            .all(|k| k.as_deref() == Some("key-create-1"))
    );
    assert!(s.control_plane().attempts("machine.create") <= 1, "the backend saw one create");
    assert_eq!(s.projection().len(), 1);

    // A lost answer: the retry sends the same key, the backend replays it.
    let mut s = server();
    s.control_plane_mut().lose_next = 1;
    let lost = s.handle(&mutation("cloud.machine.create", args.clone(), "key-create-1"));
    assert_eq!(err_json(lost)["retryable"], true);
    let retry = s.handle(&mutation("cloud.machine.create", args, "key-create-1"));
    assert!(retry.is_ok(), "retry: {retry:?}");
    assert_eq!(retry.unwrap()["machine"]["id"], vm(4));
    assert_eq!(
        s.control_plane().keys("cloud.machine.create"),
        [Some("key-create-1".to_owned()), Some("key-create-1".to_owned())]
    );
    assert_eq!(s.projection().len(), 1, "one machine, not two");
}

#[test]
fn an_indeterminate_create_is_retried_with_the_same_key() {
    let mut s = server();
    let args =
        json!({ "name": "cut box", "size": { "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 } });
    let cut = err_json(s.handle(&mutation("cloud.machine.create", args.clone(), "key-create-cut")));
    assert_eq!(cut["code"], "cmux.cloud.indeterminate", "{cut}");
    assert_eq!(cut["retryable"], true);
    let retry = s.handle(&mutation("cloud.machine.create", args, "key-create-cut"));
    assert!(retry.is_ok(), "retry: {retry:?}");
    assert_eq!(retry.unwrap()["machine"]["id"], vm(5));
    assert_eq!(
        s.control_plane().keys("cloud.machine.create"),
        [Some("key-create-cut".to_owned()), Some("key-create-cut".to_owned())]
    );
}

#[test]
fn a_delete_after_mutation_indeterminate_retries_with_the_same_key() {
    let mut s = listed();
    let delete = mutation("cloud.machine.delete", json!({ "machine": vm(3) }), "key-delete-cut");
    let cut = err_json(s.handle(&delete));
    assert_eq!(cut["code"], "cmux.cloud.indeterminate", "{cut}");
    assert_eq!(cut["retryable"], true);
    assert!(s.projection().get(&vm(3)).is_some(), "an unknown outcome removes nothing");
    let retry = s.handle(&delete);
    assert_eq!(retry, Ok(json!({ "deleted": true })));
    assert_eq!(
        s.control_plane().keys("cloud.machine.delete"),
        [Some("key-delete-cut".to_owned()), Some("key-delete-cut".to_owned())],
        "the retry reuses the key and never makes a new one"
    );
    assert!(s.projection().get(&vm(3)).is_none());
    let removed: Vec<WatchEvent> = s.take_events();
    assert_eq!(removed.len(), 1, "one removed event: {removed:?}");
    assert!(matches!(&removed[0], WatchEvent::Removed { id, .. } if *id == vm(3)));
}

#[test]
fn a_delete_retry_after_the_delete_answers_deleted() {
    let mut s = listed();
    let first = mutation("cloud.machine.delete", json!({ "machine": vm(2) }), "key-delete-1");
    assert_eq!(s.handle(&first), Ok(json!({ "deleted": true })));
    assert_eq!(s.handle(&first), Ok(json!({ "deleted": true })), "same key");
    let other = mutation("cloud.machine.delete", json!({ "machine": vm(2) }), "key-delete-2");
    assert_eq!(s.handle(&other), Ok(json!({ "deleted": true })), "tombstone, new key");
    assert!(s.projection().get(&vm(2)).is_none());
}

#[test]
fn quota_and_plan_errors_map_to_typed_cloud_errors() {
    let mut s = server();
    let size = json!({ "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 });
    let quota = err_json(s.handle(&mutation(
        "cloud.machine.create",
        json!({ "name": "sixth box", "size": size }),
        "key-create-quota",
    )));
    assert_eq!(quota["code"], "cmux.cloud.quota_exceeded", "{quota}");
    assert_eq!(quota["details"]["limit"], 5);
    assert_eq!(quota["details"]["used"], 5);
    assert_eq!(quota["upstream_code"], "cloud.quota.exceeded");

    let start = err_json(s.handle(&mutation(
        "cloud.machine.start",
        json!({ "machine": vm(2) }),
        "key-start-quota",
    )));
    assert_eq!(start["code"], "cmux.cloud.quota_exceeded", "{start}");
    assert_eq!(
        (start["details"]["limit"].clone(), start["details"]["used"].clone()),
        (json!(2), json!(2))
    );

    let plan = err_json(s.handle(&mutation(
        "cloud.machine.create",
        json!({ "name": "big box", "size": { "cpu": 4, "memory_mb": 8192, "disk_mb": 32768 } }),
        "key-create-plan",
    )));
    assert_eq!(plan["code"], "cmux.cloud.plan_required", "{plan}");

    let locked = err_json(s.handle(&mutation(
        "cloud.machine.resize",
        json!({ "machine": vm(1), "size": { "cpu": 16, "memory_mb": 65536, "disk_mb": 262144 } }),
        "key-resize-locked",
    )));
    assert_eq!(locked["code"], "cmux.cloud.size_locked", "{locked}");

    let snap_quota = err_json(s.handle(&mutation(
        "cloud.snapshot.create",
        json!({ "machine": vm(1), "name": "one more" }),
        "key-snap-quota",
    )));
    assert_eq!(snap_quota["code"], "cmux.cloud.quota_exceeded", "{snap_quota}");
    assert_eq!(snap_quota["details"]["limit"], 10);
}

#[test]
fn an_agent_principal_refusal_surfaces_as_forbidden() {
    let mut s = server();
    s.control_plane_mut().agent = true;
    let size = json!({ "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 });
    let create = err_json(s.handle(&mutation(
        "cloud.machine.create",
        json!({ "name": "agent box", "size": size }),
        "key-create-agent",
    )));
    assert_eq!(create["code"], "cmux.cloud.forbidden", "{create}");
    assert_eq!(create["upstream_code"], "auth.forbidden");
    let delete = err_json(s.handle(&mutation(
        "cloud.machine.delete",
        json!({ "machine": vm(1) }),
        "key-delete-agent",
    )));
    assert_eq!(delete["code"], "cmux.cloud.forbidden", "{delete}");
    let checkout = err_json(s.handle(&mutation(
        "cloud.billing.checkout",
        json!({ "plan": "pro" }),
        "key-checkout-agent",
    )));
    assert_eq!(checkout["code"], "cmux.cloud.forbidden", "{checkout}");
    let migrate =
        err_json(s.handle(&mutation("cloud.migration.start", json!({}), "key-migrate-agent")));
    assert_eq!(migrate["code"], "cmux.cloud.forbidden", "{migrate}");
}

#[test]
fn a_backend_idempotency_conflict_is_typed() {
    // A fresh server: its own ledger does not know the key, the backend does.
    let mut s = server();
    let size = json!({ "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 });
    let out = err_json(s.handle(&mutation(
        "cloud.machine.create",
        json!({ "name": "other box", "size": size }),
        "key-create-1",
    )));
    assert_eq!(out["code"], "cmux.cloud.idempotency_conflict", "{out}");
}

#[test]
fn events_update_the_projection_by_revision() {
    let mut s = listed();
    let (event, data) = WireFake::event("machine.upsert.newer");
    assert!(s.team_event(&event, &data).is_ok());
    assert_eq!(record(&s, &vm(1))["status"], "pausing");
    assert_eq!(record(&s, &vm(1))["revision"], "55");
    let events = s.take_events();
    assert_eq!(events.len(), 1, "{events:?}");

    let (event, data) = WireFake::event("machine.upsert.stale");
    assert!(s.team_event(&event, &data).is_ok());
    assert_eq!(record(&s, &vm(1))["status"], "pausing", "an older upsert is dropped");
    assert!(s.take_events().is_empty());

    let (event, data) = WireFake::event("machine.removed.stale");
    assert!(s.team_event(&event, &data).is_ok());
    assert!(s.projection().get(&vm(1)).is_some(), "an older removal is dropped");

    let (event, data) = WireFake::event("machine.removed");
    assert!(s.team_event(&event, &data).is_ok());
    assert!(s.projection().get(&vm(3)).is_none());
    assert!(matches!(&s.take_events()[..], [WatchEvent::Removed { id, .. }] if *id == vm(3)));

    let (event, data) = WireFake::event("machine.upsert.bound");
    assert!(s.team_event(&event, &data).is_ok());
    assert_eq!(record(&s, &vm(4))["host"], host(4));
    assert_eq!(record(&s, &vm(4))["status"], "running");

    // Events of other entities change no machine.
    let before = s.projection().revision();
    let (event, data) = WireFake::event("plan.changed");
    assert!(s.team_event(&event, &data).is_ok());
    assert_eq!(s.projection().revision(), before);
}

#[test]
fn a_mutation_answer_older_than_the_projection_is_dropped() {
    let mut s = listed();
    let (event, data) = WireFake::event("machine.upsert.newer");
    assert!(s.team_event(&event, &data).is_ok());
    s.take_events();
    // The rename answer carries revision 47; the event already brought 55.
    let out = s.handle(&mutation(
        "cloud.machine.rename",
        json!({ "machine": vm(1), "name": "renamed box" }),
        "key-rename-1",
    ));
    assert!(out.is_ok(), "rename: {out:?}");
    assert_eq!(record(&s, &vm(1))["revision"], "55");
    assert_eq!(record(&s, &vm(1))["status"], "pausing");
    assert!(s.take_events().is_empty());
}

#[test]
fn machine_ops_follow_the_contract_shapes() {
    let mut s = listed();
    let get = s.handle(&Request::new("cloud.machine.get", json!({ "machine": vm(1) })));
    assert!(get.is_ok(), "get: {get:?}");
    assert_eq!(get.unwrap()["size"]["memory_mb"], 4096);

    let rename = s.handle(&mutation(
        "cloud.machine.rename",
        json!({ "machine": vm(1), "name": "renamed box" }),
        "key-rename-1",
    ));
    assert!(rename.is_ok(), "rename: {rename:?}");
    assert_eq!(rename.unwrap()["machine"]["name"], "renamed box");

    let resize = s.handle(&mutation(
        "cloud.machine.resize",
        json!({ "machine": vm(1), "size": { "cpu": 4, "memory_mb": 8192, "disk_mb": 32768 } }),
        "key-resize-1",
    ));
    assert!(resize.is_ok(), "resize: {resize:?}");
    let idle = s.handle(&mutation(
        "cloud.machine.idle_policy.set",
        json!({ "machine": vm(1), "idle_seconds": 3600 }),
        "key-idle-1",
    ));
    assert!(idle.is_ok(), "idle: {idle:?}");

    let info = s.handle(&Request::new("cloud.machine.connect_info", json!({ "machine": vm(1) })));
    assert_eq!(
        info,
        Ok(
            json!({ "host": host(1), "daemon_version": "0.40.0", "capabilities": ["terminal", "files", "ports"] })
        )
    );
    let unbound = err_json(
        s.handle(&Request::new("cloud.machine.connect_info", json!({ "machine": vm(4) }))),
    );
    assert_eq!(unbound["code"], "cmux.cloud.not_bound", "{unbound}");
    let paused = err_json(
        s.handle(&Request::new("cloud.machine.connect_info", json!({ "machine": vm(2) }))),
    );
    assert_eq!(paused["code"], "cmux.cloud.machine_paused", "{paused}");
}

#[test]
fn a_typed_not_found_removes_the_machine_and_a_signed_out_read_clears() {
    let mut s = listed();
    let gone = err_json(s.handle(&Request::new("cloud.machine.get", json!({ "machine": vm(3) }))));
    assert_eq!(gone["code"], "cmux.cloud.not_found", "{gone}");
    assert!(s.projection().get(&vm(3)).is_none());

    let out = err_json(s.handle(&Request::new("cloud.machine.list", json!({ "limit": 1 }))));
    assert_eq!(out["code"], "cmux.cloud.auth_required", "{out}");
    assert!(s.projection().is_empty(), "signed out: no machines");
}

#[test]
fn snapshots_plan_billing_migration_and_upgrade() {
    let mut s = listed();
    let list = s.handle(&Request::new("cloud.snapshot.list", json!({ "machine": vm(1) })));
    assert!(list.is_ok(), "{list:?}");
    assert_eq!(list.unwrap()["snapshots"][0]["id"], snap(1));
    let all = s.handle(&Request::new("cloud.snapshot.list", json!({})));
    assert_eq!(all.map(|v| v["snapshots"].as_array().map_or(0, Vec::len)), Ok(2));
    let created = s.handle(&mutation(
        "cloud.snapshot.create",
        json!({ "machine": vm(1), "name": "checkpoint" }),
        "key-snap-1",
    ));
    assert!(created.is_ok(), "{created:?}");
    let restored = s.handle(&mutation(
        "cloud.snapshot.restore",
        json!({ "snapshot": snap(1), "name": "restored box" }),
        "key-restore-1",
    ));
    assert!(restored.is_ok(), "{restored:?}");
    assert!(s.projection().get(&vm(6)).is_some(), "the restored machine is projected");
    let deleted = s.handle(&mutation(
        "cloud.snapshot.delete",
        json!({ "snapshot": snap(1) }),
        "key-snap-delete-1",
    ));
    assert_eq!(deleted, Ok(json!({ "deleted": true })));

    let plan = s.handle(&Request::new("cloud.plan.get", json!({})));
    assert!(plan.is_ok(), "{plan:?}");
    let plan = plan.unwrap();
    assert_eq!(plan["limits"]["max_active"], 5);
    assert_eq!(plan["usage"]["active"], 2, "usage folds into the plan");
    let checkout =
        s.handle(&mutation("cloud.billing.checkout", json!({ "plan": "pro" }), "key-checkout-1"));
    assert_eq!(
        checkout,
        Ok(json!({ "url": "https://checkout.example.com/session/cs_vector_0001" }))
    );

    let status = s.handle(&Request::new("cloud.migration.status", json!({})));
    assert!(status.is_ok(), "{status:?}");
    assert_eq!(status.unwrap()["classic_count"], 1);
    let start = s.handle(&mutation("cloud.migration.start", json!({}), "key-migrate-1"));
    assert_eq!(start, Ok(json!({ "state": "moving" })));
    let none =
        err_json(s.handle(&mutation("cloud.migration.start", json!({}), "key-migrate-none")));
    assert_eq!(none["code"], "cmux.cloud.migration_unavailable", "{none}");

    let upgrade =
        s.handle(&mutation("cloud.machine.upgrade", json!({ "machine": vm(7) }), "key-upgrade-1"));
    assert!(upgrade.is_ok(), "{upgrade:?}");
    assert_eq!(upgrade.unwrap()["machine"]["classic"], false);
    let not_classic = err_json(s.handle(&mutation(
        "cloud.machine.upgrade",
        json!({ "machine": vm(1) }),
        "key-upgrade-new",
    )));
    assert_eq!(not_classic["code"], "cmux.cloud.not_classic", "{not_classic}");
    let failed = err_json(s.handle(&mutation(
        "cloud.machine.upgrade",
        json!({ "machine": vm(7) }),
        "key-upgrade-fail",
    )));
    assert_eq!(failed["code"], "cmux.cloud.upgrade_failed", "{failed}");
}

#[test]
fn every_vector_op_the_server_serves_reaches_the_backend_by_its_wire_name() {
    // Each served vector case, sent as the vectors say, is answered from
    // that case (no `vector.missing`): the server forwards params unchanged.
    let doc = wire_common::vectors();
    for case in doc["cases"].as_array().expect("cases") {
        let op = case["op"].as_str().expect("op");
        if op == "cloud.shell.open" {
            continue; // request and response only in this slice
        }
        let mut s = server();
        s.control_plane_mut().agent = case["principal"].get("agent").is_some();
        let mut request = Request::new(op, case["params"].clone()).origin(Origin::User);
        if let Some(key) = case["idempotency_key"].as_str() {
            request = request.key(key);
        }
        let out = s.handle(&request);
        let calls = &s.control_plane().calls;
        assert_eq!(calls.len(), 1, "{}: one backend call, got {calls:?} ({out:?})", case["name"]);
        assert_eq!(calls[0].op, op, "{}", case["name"]);
        assert_eq!(calls[0].params, case["params"], "{}", case["name"]);
        assert_eq!(
            calls[0].idempotency_key.as_deref(),
            case["idempotency_key"].as_str(),
            "{}",
            case["name"]
        );
        if let Err(e) = &out {
            assert_ne!(e.upstream_code.as_deref(), Some("vector.missing"), "{}", case["name"]);
        }
    }
}
