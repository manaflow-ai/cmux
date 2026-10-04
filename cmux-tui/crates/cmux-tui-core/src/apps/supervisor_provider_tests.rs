//! Supervisor tests of the provider channel (app-op-routing.md, APP-R1).

use super::*;

const PROVIDER: u64 = 9;
const APP: super::super::provider::ProviderClaim =
    super::super::provider::ProviderClaim { agent: false, app_kind: true };

/// Registers a provider connection and returns its event stream.
fn provider(f: &Fixture, families: &[&str]) -> Receiver<Value> {
    let (tx, rx) = channel();
    let tx = Mutex::new(tx);
    f.supervisor.register_client(
        PROVIDER,
        Arc::new(move |v: &Value| tx.lock().unwrap().send(v.clone()).is_ok()),
    );
    f.supervisor
        .register_provider(PROVIDER, APP, families.iter().map(|s| s.to_string()).collect())
        .unwrap();
    rx
}

fn next_request(rx: &Receiver<Value>) -> Value {
    loop {
        let event = rx.recv_timeout(Duration::from_secs(10)).expect("provider request");
        if event["event"] == "apps-provider-request" {
            return event;
        }
    }
}

#[test]
fn provider_calls_carry_the_stamped_actor_and_answer_the_app() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let rx = provider(&f, &["action"]);
    f.supervisor
        .dispatch(
            CLIENT,
            "m1",
            "n1",
            "tap",
            json!({ "op": "action.run", "params": { "id": "newWindow" } }),
            true,
        )
        .unwrap();
    let request = next_request(&rx);
    assert_eq!(
        (
            request["app"].clone(),
            request["actor"].clone(),
            request["origin"].clone(),
            request["op"].clone()
        ),
        (
            json!("cmux/demo"),
            json!({
                "kind": "app",
                "id": "cmux/demo",
                "host": crate::machine_name::machine_name(),
                "version": "1.0.0",
                "on_behalf_of": { "kind": "user", "id": "user_local" }
            }),
            json!("user"),
            json!("action.run")
        )
    );
    assert!(request["idempotency_key"].as_str().is_some_and(|k| k.starts_with("app:cmux/demo:")));
    let id = request["request_id"].as_u64().unwrap();
    // Only the connection the call went to may answer it.
    assert_eq!(
        f.supervisor.provider_result(CLIENT, id, true, json!({ "value": 1 })).unwrap_err().code,
        "apps.provider.unknown"
    );
    f.supervisor.provider_result(PROVIDER, id, true, json!({ "value": "opened" })).unwrap();
    let update =
        f.wait("call result", |e| e["event"] == "apps-scene" && e["ops"][0]["op"] == "update");
    assert_eq!(
        update["ops"][0]["props"]["result"],
        json!({ "ok": true, "body": { "value": "opened" } })
    );
}

#[test]
fn no_provider_fails_at_once_and_a_provider_leaving_fails_its_pending_calls() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let started = Instant::now();
    let missing = f.call("m1", "action.run", json!({ "id": "newWindow" }), true);
    assert_eq!(missing["body"]["code"], "provider.unavailable");
    assert!(
        started.elapsed() < Duration::from_millis(400),
        "no wait for a provider that is not there"
    );
    let rx = provider(&f, &["action"]);
    f.supervisor
        .dispatch(
            CLIENT,
            "m1",
            "n1",
            "tap",
            json!({ "op": "action.run", "params": { "id": "newWindow" } }),
            true,
        )
        .unwrap();
    next_request(&rx);
    f.supervisor.disconnect(PROVIDER);
    let update =
        f.wait("call result", |e| e["event"] == "apps-scene" && e["ops"][0]["op"] == "update");
    let body = update["ops"][0]["props"]["result"]["body"].clone();
    assert_eq!(
        (body["code"].clone(), body["retryable"].clone(), body["details"]["family"].clone()),
        (json!("provider.unavailable"), json!(true), json!("action"))
    );
    // The family went with the connection.
    assert_eq!(
        f.call("m1", "action.run", json!({ "id": "newWindow" }), true)["body"]["code"],
        "provider.unavailable"
    );
}

#[test]
fn a_provider_that_does_not_answer_times_out_and_is_told() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let rx = provider(&f, &["action"]);
    f.supervisor
        .dispatch(
            CLIENT,
            "m1",
            "n1",
            "tap",
            json!({ "op": "action.run", "params": { "id": "newWindow" } }),
            true,
        )
        .unwrap();
    let id = next_request(&rx)["request_id"].clone();
    let update = f.wait("timeout", |e| e["event"] == "apps-scene" && e["ops"][0]["op"] == "update");
    assert_eq!(update["ops"][0]["props"]["result"]["body"]["details"]["reason"], "timeout");
    let cancel = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(
        (cancel["event"].clone(), cancel["request_id"].clone()),
        (json!("apps-provider-cancel"), id)
    );
    assert_eq!(
        f.supervisor.register_provider(PROVIDER, APP, vec!["shell".into()]).unwrap_err().code,
        "bad-request"
    );
}

#[test]
fn a_live_provider_cannot_be_taken_over() {
    let f = fixture();
    let _rx = provider(&f, &["action"]);
    let thief = 10;
    f.supervisor.register_client(thief, Arc::new(|_: &Value| true));
    assert_eq!(
        f.supervisor.register_provider(thief, APP, vec!["action".into()]).unwrap_err().code,
        "apps.provider.taken"
    );
    // The holder may register again; after it leaves the family is free.
    f.supervisor.register_provider(PROVIDER, APP, vec!["action".into(), "fs".into()]).unwrap();
    f.supervisor.disconnect(PROVIDER);
    f.supervisor.register_provider(thief, APP, vec!["action".into()]).unwrap();
}

#[test]
fn routed_params_are_bounded_and_integration_methods_are_explicit() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let rx = provider(&f, &["action", "integration"]);
    let big = "x".repeat(70 * 1024);
    let refused =
        f.call("m1", "action.run", json!({ "id": "newWindow", "args": { "blob": big } }), true);
    assert_eq!(refused["body"]["code"], "validation.invalid");
    f.supervisor
        .dispatch(
            CLIENT,
            "m1",
            "n1",
            "tap",
            json!({ "op": "integration.request", "params": { "provider": "github", "path": "/user" } }),
            false,
        )
        .unwrap();
    let request = next_request(&rx);
    assert_eq!(request["params"]["method"], "GET", "the read grant's method reaches the provider");
}

#[test]
fn disabling_cancels_provider_calls_and_errors_reach_the_app_in_abi_shape() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let rx = provider(&f, &["action"]);
    let tap = json!({ "op": "action.run", "params": { "id": "newWindow" } });
    f.supervisor.dispatch(CLIENT, "m1", "n1", "tap", tap.clone(), true).unwrap();
    let id = next_request(&rx)["request_id"].as_u64().unwrap();
    // A malformed provider error still reaches the app as {code, message, retryable}.
    f.supervisor.provider_result(PROVIDER, id, false, json!("nope")).unwrap();
    let update = f.wait("error", |e| e["event"] == "apps-scene" && e["ops"][0]["op"] == "update");
    let body = update["ops"][0]["props"]["result"]["body"].clone();
    assert_eq!(
        (body["code"].clone(), body["retryable"].clone()),
        (json!("operation.failed"), json!(false))
    );
    f.supervisor.dispatch(CLIENT, "m1", "n1", "tap", tap, true).unwrap();
    let id = next_request(&rx)["request_id"].clone();
    // First-party apps are hide-only; disabling stops the app the same way.
    f.set("off", "cmux/demo", Origin::User, |o| o.enabled = Some(false)).unwrap();
    let cancel = loop {
        let event = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        if event["event"] == "apps-provider-cancel" {
            break event;
        }
    };
    assert_eq!(
        (cancel["request_id"].clone(), cancel["reason"].clone()),
        (id.clone(), json!("revoked"))
    );
    let late = f.supervisor.provider_result(PROVIDER, id.as_u64().unwrap(), true, json!({}));
    assert_eq!(late.unwrap_err().code, "apps.provider.unknown");
}

#[test]
fn the_idle_stop_waits_for_a_provider_call_in_flight() {
    let f = fixture_with(&[], Duration::from_millis(50), temp_dir());
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    let rx = provider(&f, &["action"]);
    let tap = json!({ "op": "action.run", "params": { "id": "newWindow" } });
    f.supervisor.dispatch(CLIENT, "m1", "n1", "tap", tap, true).unwrap();
    let id = next_request(&rx)["request_id"].as_u64().unwrap();
    f.supervisor.unmount(CLIENT, "m1").unwrap();
    let early = Instant::now() + Duration::from_millis(200);
    while let Ok(event) = f.events.recv_timeout(early.saturating_duration_since(Instant::now())) {
        let stopped = event["event"] == "apps-host" && event["state"] == "stopped";
        assert!(!stopped, "stopped with a call in flight");
    }
    f.supervisor.provider_result(PROVIDER, id, true, json!({ "value": null })).unwrap();
    f.wait("idle stop after the answer", |e| e["event"] == "apps-host" && e["state"] == "stopped");
}

#[test]
fn only_the_cmux_app_and_never_an_agent_may_provide() {
    let f = fixture();
    let agent = super::super::provider::ProviderClaim { agent: true, app_kind: true };
    let undeclared = super::super::provider::ProviderClaim { agent: false, app_kind: false };
    for claim in [agent, undeclared] {
        let refused =
            f.supervisor.register_provider(PROVIDER, claim, vec!["action".into()]).unwrap_err();
        assert_eq!(refused.code, "apps.provider.forbidden", "{claim:?}");
    }
    // Nothing was registered: calls still find no provider.
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    assert_eq!(
        f.call("m1", "action.run", json!({ "id": "newWindow" }), true)["body"]["code"],
        "provider.unavailable"
    );
}
