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

fn lifecycle_observation(s: &mut Server<WireFake>, id: &str) {
    let value = if let Some(machine) = s.projection().get(id) {
        serde_json::to_value(machine).unwrap()
    } else {
        let vectors = wire_common::vectors();
        vectors["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["name"] == "machine.list.default")
            .unwrap()["responses"][0]["body"]["value"]["machines"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["id"] == id)
            .unwrap()
            .clone()
    };
    s.control_plane_mut().answer("cloud.machine.get", json!({"machine":id}), None, value);
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
fn pause_all_snapshots_every_page_and_preserves_partial_results() {
    let mut s = listed();
    let first = record(&s, &vm(1));
    let mut second = record(&s, &vm(2));
    second["status"] = json!("paused");
    let third = record(&s, &vm(3));
    s.control_plane_mut().calls.clear();
    s.control_plane_mut().answer(
        "cloud.machine.list",
        json!({"limit": 100}),
        None,
        json!({"machines": [first], "next_cursor": "next"}),
    );
    s.control_plane_mut().answer(
        "cloud.machine.list",
        json!({"limit": 100, "cursor": "next"}),
        None,
        json!({"machines": [second.clone(), third], "next_cursor": null}),
    );
    for (id, mut machine) in [(vm(1), first), (vm(2), second)] {
        let params = json!({"machine": id});
        let key =
            cmux_cloud::api::upstream_key("cloud.machine.pause_all", &params, "pause-all-key");
        machine["status"] = json!("paused");
        machine["revision"] = json!("20");
        s.control_plane_mut().answer(
            "cloud.machine.pause",
            params,
            Some(&key),
            json!({"machine": machine}),
        );
    }
    let params = json!({"machine": vm(3)});
    let key = cmux_cloud::api::upstream_key("cloud.machine.pause_all", &params, "pause-all-key");
    s.control_plane_mut().answer("cloud.machine.pause", params, Some(&key), json!({"error": {
        "code": "cloud.machine.not_running", "message": "The machine is starting", "retryable": false
    }}));
    let request =
        Request::new("cloud.machine.pause_all", json!({})).key("pause-all-key").origin(Origin::Cli);
    let answer = s.handle(&request).unwrap();
    assert_eq!(answer["machines"].as_array().unwrap().len(), 3);
    assert_eq!(answer["machines"][0]["status"], "paused");
    assert_eq!(
        answer["machines"][1]["status"], "paused",
        "already paused machines still get a person hold"
    );
    assert_eq!(answer["machines"][2]["status"], "failed");
    assert_eq!(answer["machines"][2]["error"]["code"], "cloud.machine.not_running");
    assert_eq!(s.handle(&request).unwrap(), answer);
    assert_eq!(
        s.control_plane().calls.len(),
        5,
        "same-key retry replays the completed bulk operation"
    );
    assert!(s.control_plane().calls[..2].iter().all(|call| call.idempotency_key.is_none()));
}

#[test]
fn pause_all_stops_on_temporary_failures_and_retries_only_unfinished_targets() {
    for code in ["mutation.indeterminate", "cloud.rate_limited", "unexpected.upstream_code"] {
        let mut s = listed();
        let mut first = record(&s, &vm(1));
        let mut second = record(&s, &vm(2));
        let mut third = record(&s, &vm(3));
        s.control_plane_mut().calls.clear();
        s.control_plane_mut().answer(
            "cloud.machine.list",
            json!({"limit":100}),
            None,
            json!({"machines":[first.clone(), second.clone(), third.clone()], "next_cursor":null}),
        );
        first["status"] = json!("paused");
        let first_params = json!({"machine":vm(1)});
        let first_key =
            cmux_cloud::api::upstream_key("cloud.machine.pause_all", &first_params, "partial-key");
        s.control_plane_mut().answer(
            "cloud.machine.pause",
            first_params,
            Some(&first_key),
            json!({"machine":first}),
        );
        let second_params = json!({"machine":vm(2)});
        let second_key =
            cmux_cloud::api::upstream_key("cloud.machine.pause_all", &second_params, "partial-key");
        s.control_plane_mut().answer(
            "cloud.machine.pause",
            second_params.clone(),
            Some(&second_key),
            json!({"error":{"code":code, "message":"answer lost", "retryable":true}}),
        );
        third["status"] = json!("paused");
        let third_params = json!({"machine":vm(3)});
        let third_key =
            cmux_cloud::api::upstream_key("cloud.machine.pause_all", &third_params, "partial-key");
        s.control_plane_mut().answer(
            "cloud.machine.pause",
            third_params,
            Some(&third_key),
            json!({"machine":third}),
        );
        let request = mutation("cloud.machine.pause_all", json!({}), "partial-key");
        let partial = s.handle(&request).unwrap();
        assert_eq!(partial["idempotency_key"], "partial-key");
        assert_eq!(partial["machines"][1]["error"]["retryable"], true);
        assert_eq!(partial["machines"][2]["error"]["code"], "cmux.cloud.batch_deferred");
        assert_eq!(s.control_plane().calls.len(), 3, "stop after the first batch-wide failure");
        second["status"] = json!("paused");
        s.control_plane_mut().answer(
            "cloud.machine.pause",
            second_params,
            Some(&second_key),
            json!({"machine":second}),
        );
        let completed = s.handle(&request).unwrap();
        assert_eq!(completed["machines"][1]["status"], "paused");
        assert_eq!(s.control_plane().calls.len(), 5, "no new list or repeated successful pause");
        assert_eq!(
            s.control_plane().calls[3].idempotency_key.as_deref(),
            Some(second_key.as_str())
        );
        assert_eq!(s.handle(&request).unwrap(), completed);
        assert_eq!(s.control_plane().calls.len(), 5);
    }
}

#[test]
fn pause_all_propagates_sign_out_and_stops_before_the_next_machine() {
    let mut s = listed();
    let machines = [record(&s, &vm(1)), record(&s, &vm(2))];
    s.control_plane_mut().calls.clear();
    s.control_plane_mut().answer(
        "cloud.machine.list",
        json!({"limit":100}),
        None,
        json!({"machines":machines, "next_cursor":null}),
    );
    let params = json!({"machine":vm(1)});
    let key = cmux_cloud::api::upstream_key("cloud.machine.pause_all", &params, "signout-key");
    s.control_plane_mut().answer(
        "cloud.machine.pause",
        params,
        Some(&key),
        json!({"error":{"code":"auth.unauthenticated", "message":"signed out", "retryable":false}}),
    );
    let error =
        s.handle(&mutation("cloud.machine.pause_all", json!({}), "signout-key")).unwrap_err();
    assert_eq!(error.code, "cmux.cloud.auth_required");
    assert!(s.projection().is_empty());
    assert_eq!(s.control_plane().calls.len(), 2);
}

#[test]
fn pause_all_refuses_agent_origin_before_listing_or_pausing() {
    let mut s = server();
    let error = s
        .handle(
            &Request::new("cloud.machine.pause_all", json!({}))
                .key("agent-key")
                .origin(Origin::Agent),
        )
        .unwrap_err();
    assert_eq!(error.code, "cmux.cloud.origin_refused");
    assert!(s.control_plane().calls.is_empty());
}

#[test]
fn pause_all_refuses_a_repeated_page_before_pausing_any_machine() {
    let mut s = listed();
    let machine = record(&s, &vm(1));
    s.control_plane_mut().calls.clear();
    for params in [json!({"limit": 100}), json!({"limit": 100, "cursor": "loop"})] {
        s.control_plane_mut().answer(
            "cloud.machine.list",
            params,
            None,
            json!({"machines": [machine.clone()], "next_cursor": "loop"}),
        );
    }
    let answer = s.handle(&mutation("cloud.machine.pause_all", json!({}), "loop-key")).unwrap_err();
    assert_eq!(answer.code, "cmux.cloud.bad_response");
    assert!(s.control_plane().calls.iter().all(|call| call.op == "cloud.machine.list"));
}

#[test]
fn create_options_reach_backend_and_preserve_its_capability_refusal() {
    let mut s = server();
    let args = json!({"name":"custom", "size":{"cpu":2,"memory_mb":4096,"disk_mb":16384},
        "size_name":"medium", "idle_seconds":0,
        "bootstrap":{"kind":"shell","contents_base64":"ZWNobyBvaw==","repo":null},
        "machine_config_base64":"e30="});
    s.control_plane_mut().answer("cloud.machine.create", args.clone(), Some("capabilities-key"),
        json!({"error":{"code":"validation.invalid","message":"Bootstrap is unavailable on this backend",
            "retryable":false,"details":{"capability":"create.bootstrap"}}}));
    let error =
        err_json(s.handle(&mutation("cloud.machine.create", args.clone(), "capabilities-key")));
    assert_eq!(s.control_plane().calls.last().unwrap().params, args);
    assert_eq!(error["message"], "Bootstrap is unavailable on this backend");
    assert_eq!(error["upstream_code"], "validation.invalid");
    assert_eq!(s.projection().len(), 0, "a refused option never creates a machine");
}

#[test]
fn create_origin_and_ttl_reach_backend_unchanged() {
    let mut s = server();
    let args = json!({"name":"probe", "size":{"cpu":2,"memory_mb":4096,"disk_mb":16384},
        "origin":{"kind":"workflow","label":"cloud round trip","url":"https://example.com/runs/1"},
        "ttl_seconds":3600});
    s.control_plane_mut().answer(
        "cloud.machine.create",
        args.clone(),
        Some("origin-key"),
        json!({"error":{"code":"validation.invalid","message":"invalid params","retryable":false}}),
    );
    let error = err_json(s.handle(&mutation("cloud.machine.create", args.clone(), "origin-key")));
    assert_eq!(s.control_plane().calls.last().unwrap().params, args);
    assert_eq!(error["upstream_code"], "validation.invalid");
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
fn machine_list_relays_disk_health_to_the_app() {
    let mut s = server();
    let disk_health = json!({
        "state": "healthy",
        "free_mb": 4096,
        "used_mb": 12288,
        "total_mb": 16384,
        "floor_mb": 1024,
        "top_users": [{ "path": "/home/cmux", "used_mb": 2048 }],
        "observed_at": 1_700_000_000_000i64
    });
    let machine = json!({
        "id": vm(9),
        "team": "team_t0000000000000000001",
        "creator": "user_u0000000000000000001",
        "name": "disk-health",
        "size": { "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 },
        "status": "running",
        "image": { "id": "img_i0000000000000000001", "daemon_version": "0.40.0" },
        "host": host(9),
        "classic": false,
        "created_at": 1_790_000_001_000i64,
        "last_active_at": null,
        "idle_policy": { "idle_seconds": 1800 },
        "error": null,
        "revision": "3",
        "disk_health": disk_health
    });
    s.control_plane_mut().answer(
        "cloud.machine.list",
        json!({}),
        None,
        json!({ "machines": [machine], "next_cursor": null, "revision": "3" }),
    );

    let page = s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    // The relay adds the disk bar: 12 of 16 GB used, no split reported.
    let mut relayed = disk_health;
    relayed["bar"] = page["machines"][0]["disk_health"]["bar"].clone();
    assert_eq!(relayed["bar"]["label"], "12 / 16 GB");
    assert_eq!(page["machines"][0]["disk_health"], relayed);
    assert_eq!(record(&s, &vm(9))["disk_health"], relayed);
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
    lifecycle_observation(&mut s, &vm(3));
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
    lifecycle_observation(&mut s, &vm(2));
    let first = mutation("cloud.machine.delete", json!({ "machine": vm(2) }), "key-delete-1");
    assert_eq!(s.handle(&first), Ok(json!({ "deleted": true })));
    assert_eq!(s.handle(&first), Ok(json!({ "deleted": true })), "same key");
    let other = mutation("cloud.machine.delete", json!({ "machine": vm(2) }), "key-delete-2");
    assert_eq!(s.handle(&other), Ok(json!({ "deleted": true })), "tombstone, new key");
    assert!(s.projection().get(&vm(2)).is_none());
}

/// At the plan's cap the backend pauses the person's idle machine, then
/// creates (leo-workspace design/cloud.md, "At the machine cap"): the answer
/// keeps `made_room` for the app's notice, and a refusal keeps `details.busy`
/// for its card.
#[test]
fn a_create_at_the_cap_keeps_made_room_and_the_busy_list() {
    // The vectors' create answers the machine; the test answers below add the room and the refusal.
    let args =
        json!({ "name": "new box", "size": { "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 } });
    let made =
        server().handle(&mutation("cloud.machine.create", args.clone(), "key-create-1")).unwrap();
    let mut paused = made["machine"].clone();
    paused["id"] = json!(vm(2));
    paused["status"] = json!("paused");
    let mut answer = made.clone();
    answer["made_room"] = json!({ "machine": paused });

    let mut s = server();
    s.control_plane_mut().answer("cloud.machine.create", args.clone(), Some("key-room"), answer);
    let out = s.handle(&mutation("cloud.machine.create", args.clone(), "key-room")).unwrap();
    assert_eq!(out["machine"]["id"], made["machine"]["id"]);
    assert_eq!(out["made_room"]["machine"]["id"], vm(2), "{out}");
    assert_eq!(out["made_room"]["machine"]["status"], "paused");
    assert!(s.projection().get(&vm(2)).is_some(), "the paused machine goes into the projection");

    let busy = json!([{ "machine": vm(3), "name": "busy box", "last_active_at": 1_000 }]);
    let error = json!({ "error": { "code": "cloud.quota.exceeded", "message": "at the cap",
        "retryable": false, "details": { "resource": "active", "limit": 5, "used": 5, "busy": busy } } });
    s.control_plane_mut().answer("cloud.machine.create", args.clone(), Some("key-busy"), error);
    let refused = err_json(s.handle(&mutation("cloud.machine.create", args, "key-busy")));
    assert_eq!(refused["code"], "cmux.cloud.quota_exceeded", "{refused}");
    assert_eq!(refused["details"]["busy"], busy);
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
    assert_eq!(quota["details"]["plan"], "max", "the plan that lifts the limit");

    lifecycle_observation(&mut s, &vm(2));
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
    assert_eq!(locked["details"]["plan"], "max", "the plan that unlocks the size");

    let snap_quota = err_json(s.handle(&mutation(
        "cloud.snapshot.create",
        json!({ "machine": vm(1), "name": "one more" }),
        "key-snap-quota",
    )));
    assert_eq!(snap_quota["code"], "cmux.cloud.quota_exceeded", "{snap_quota}");
    assert_eq!(snap_quota["details"]["limit"], 10);
}

/// A create the backend refuses with `error`, answered on its own key.
fn refused_create(error: Value, key: &str) -> Value {
    let mut s = server();
    let args = json!({ "name": "box", "size": { "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 } });
    s.control_plane_mut().answer("cloud.machine.create", args.clone(), Some(key), error);
    err_json(s.handle(&mutation("cloud.machine.create", args, key)))
}

#[test]
fn no_snapshot_configured_and_rate_limited_are_typed() {
    let none = refused_create(
        json!({ "error": { "code": "cloud.no_snapshot_configured",
            "message": "no machine image is configured", "retryable": false } }),
        "key-create-no-image",
    );
    assert_eq!(none["code"], "cmux.cloud.no_snapshot_configured", "{none}");
    assert_eq!(none["upstream_code"], "cloud.no_snapshot_configured");
    assert_eq!(none["retryable"], false);
    let limited = refused_create(
        json!({ "error": { "code": "cloud.rate_limited", "message": "slow down",
            "retryable": true, "details": { "retry_after_ms": 30000 } } }),
        "key-create-limited",
    );
    assert_eq!(limited["code"], "cmux.cloud.rate_limited", "{limited}");
    assert_eq!(limited["retryable"], true);
    assert_eq!(limited["details"]["retry_after_ms"], 30000);
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
    s.control_plane_mut().agent = false;
    lifecycle_observation(&mut s, &vm(1));
    s.control_plane_mut().agent = true;
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

    // The full 1.7 shape is tests/wire_contract.rs; here only the record.
    let info = s.handle(&Request::new("cloud.machine.connect_info", json!({ "machine": vm(1) })));
    assert_eq!(info.map(|v| v["host"].clone()), Ok(json!(host(1))));
    let unbound = err_json(
        s.handle(&Request::new("cloud.machine.connect_info", json!({ "machine": vm(4) }))),
    );
    assert_eq!(unbound["code"], "cmux.cloud.not_bound", "{unbound}");
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
    assert_eq!(plan["upgrade_plan"], "max", "the plan that lifts the limits (See plans)");
    let allotment = s.handle(&Request::new("cloud.allotment.get", json!({})));
    assert!(allotment.is_ok(), "{allotment:?}");
    let allotment = allotment.unwrap();
    assert_eq!(allotment["decision"]["position"], "up");
    // Micros are JSON numbers the wire types hold as f64.
    assert_eq!(allotment["decision"]["members"][0]["month_micros"].as_f64(), Some(96_000_000.0));
    assert_eq!(allotment["names"]["user_vec_2"], "Sam", "the directory's names ride along");
    let usage = s.handle(&Request::new("cloud.usage.current", json!({})));
    assert!(usage.is_ok(), "{usage:?}");
    let usage = usage.unwrap();
    assert_eq!(usage["usd"]["total"], 0.84, "the billing owner's price passes through");
    assert_eq!(usage["payment_method"]["last4"], "4242");
    assert_eq!(usage["stripe_mode"], "test");
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
fn allotment_set_passes_only_the_person_hold() {
    let mut s = server();
    let held = s.handle(&mutation(
        "cloud.allotment.set",
        json!({ "person_hold_seconds": 900 }),
        "key-allot-hold-1",
    ));
    assert!(held.is_ok(), "{held:?}");
    let held = held.unwrap();
    assert_eq!(held["allotment"]["person_hold_seconds"].as_f64(), Some(900.0));
    assert_eq!(held["allotment"]["mode"], "ask", "the platform's stored setting comes back");
    let cleared = s.handle(&mutation(
        "cloud.allotment.set",
        json!({ "person_hold_seconds": null }),
        "key-allot-hold-clear",
    ));
    assert!(cleared.is_ok(), "{cleared:?}");
    assert!(cleared.unwrap()["allotment"]["person_hold_seconds"].is_null(), "null clears the hold");
    let sent: Vec<Value> = s.control_plane().calls.iter().map(|c| c.params.clone()).collect();
    assert_eq!(
        sent,
        [json!({ "person_hold_seconds": 900 }), json!({ "person_hold_seconds": null })]
    );

    // The keys that move the monthly commit (money), a missing hold, or a hold
    // the platform does not offer never reach the wire.
    for bad in [
        json!({ "action": "up" }),
        json!({ "auto": true }),
        json!({ "person_hold_seconds": 900, "auto_max_micros": 0 }),
        json!({ "person_hold_seconds": 900, "action": "hold" }),
        json!({}),
        json!({ "person_hold_seconds": 600 }),
        json!({ "person_hold_seconds": 900.5 }),
        json!({ "person_hold_seconds": "900" }),
    ] {
        let out = s.handle(&mutation("cloud.allotment.set", bad.clone(), "key-allot-bad"));
        assert_eq!(err_json(out)["code"], "cmux.cloud.invalid_args", "{bad}");
    }
    assert_eq!(s.control_plane().count("cloud.allotment.set"), 2, "nothing refused is sent");
}

#[test]
fn every_vector_op_the_server_serves_reaches_the_backend_by_its_wire_name() {
    // Each served vector case, sent as the vectors say, is answered from
    // that case (no `vector.missing`): the server forwards params unchanged.
    let doc = wire_common::vectors();
    for case in doc["cases"].as_array().expect("cases") {
        let op = case["op"].as_str().expect("op");
        // Not served here: shell.open (later slice), link_token (cmux link
        // only), and the ops a VM calls about itself (cloud.vm.*).
        if cmux_cloud::ops::canonical_name(op).is_none() {
            continue;
        }
        let mut s = server();
        s.control_plane_mut().agent = case["principal"].get("agent").is_some();
        let mut request = Request::new(op, case["params"].clone()).origin(Origin::User);
        if let Some(key) = case["idempotency_key"].as_str() {
            request = request.key(key);
        }
        let lifecycle =
            matches!(op, "cloud.machine.start" | "cloud.machine.pause" | "cloud.machine.delete");
        if lifecycle {
            let id = case["params"]["machine"].as_str().expect("lifecycle machine");
            lifecycle_observation(&mut s, id);
        }
        let out = s.handle(&request);
        let calls = &s.control_plane().calls;
        if matches!(
            case["name"].as_str(),
            Some("machine.pause.not_running" | "machine.start.not_paused")
        ) {
            assert_eq!(calls.len(), 1, "invalid state must not send a mutation");
            assert_eq!(calls[0].op, "cloud.machine.get");
            assert_eq!(calls[0].params, case["params"]);
            let expected = if op == "cloud.machine.pause" {
                "cmux.cloud.not_running"
            } else {
                "cmux.cloud.not_paused"
            };
            assert_eq!(err_json(out)["code"], expected);
            continue;
        }
        let expected_calls = if lifecycle { 2 } else { 1 };
        assert_eq!(
            calls.len(),
            expected_calls,
            "{}: backend calls, got {calls:?} ({out:?})",
            case["name"]
        );
        let call = calls.last().expect("backend call");
        assert_eq!(call.op, op, "{}", case["name"]);
        assert_eq!(call.params, case["params"], "{}", case["name"]);
        assert_eq!(
            call.idempotency_key.as_deref(),
            case["idempotency_key"].as_str(),
            "{}",
            case["name"]
        );
        if let Err(e) = &out {
            assert_ne!(e.upstream_code.as_deref(), Some("vector.missing"), "{}", case["name"]);
        }
    }
}

/// A backend snapshot as `cloud.snapshot.list` and `create` answer it, at `revision`.
fn snapshot_at(revision: &str) -> Value {
    json!({ "id": snap(9), "machine": vm(1), "name": null, "size_mb": 512, "status": "ready",
        "created_at": 1_790_000_000_000i64, "revision": revision })
}

/// `cloud.snapshot.list` of one machine, when the backend lists `snapshot`.
fn list_answering(snapshot: Value) -> Result<Value, CloudError> {
    let mut s = server();
    let params = json!({ "machine": vm(1) });
    let answer = json!({ "snapshots": [snapshot] });
    s.control_plane_mut().answer("cloud.snapshot.list", params.clone(), None, answer);
    s.handle(&Request::new("cloud.snapshot.list", params))
}

/// `cloud.snapshot.create`, when the backend answers `snapshot`.
fn create_answering(snapshot: Value) -> Result<Value, CloudError> {
    let mut s = server();
    let args = json!({ "machine": vm(1), "name": "one" });
    let answer = json!({ "snapshot": snapshot });
    s.control_plane_mut().answer("cloud.snapshot.create", args.clone(), Some("key-rev"), answer);
    s.handle(&mutation("cloud.snapshot.create", args, "key-rev"))
}

#[test]
fn a_snapshot_revision_is_a_checked_decimal() {
    let list = list_answering(snapshot_at("007")).expect("lists");
    assert_eq!(list["snapshots"][0]["revision"], "7", "{list}");
    let made = create_answering(snapshot_at("007")).expect("creates");
    assert_eq!(made["snapshot"]["revision"], "7", "{made}");
    for bad in ["", "7a", "-1", "0x2"] {
        let listed = err_json(list_answering(snapshot_at(bad)));
        assert_eq!(listed["code"], "cmux.cloud.bad_response", "{bad:?}: {listed}");
        let created = err_json(create_answering(snapshot_at(bad)));
        assert_eq!(created["code"], "cmux.cloud.bad_response", "{bad:?}: {created}");
    }
}
