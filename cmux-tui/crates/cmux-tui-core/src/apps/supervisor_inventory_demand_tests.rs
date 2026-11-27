//! Verified inventory invalidations and readable-subscription demand over real host queues.

use super::super::provider::ProviderClaim;
use super::super::supervisor::HostKey;
use super::*;

const PROVIDER: u64 = 9;
const APP: ProviderClaim = ProviderClaim { agent: false, verified_app: true };
const STREAM: &str = "agent_cli.changed";

fn inventory_fixture() -> Fixture {
    let root = temp_dir();
    write_app(
        &root.0.join("bundled"),
        "demo",
        "cmux/demo",
        json!({"agent_cli:read":"cached inventory"}),
    );
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/demo");
    f.mount("live", "cmux/demo", "cmux.section/1", json!({}));
    f.supervisor.logs(CLIENT, "cmux/demo", true);
    f
}

fn provider(f: &Fixture, client: u64) -> Receiver<Value> {
    let (tx, rx) = channel();
    let tx = Mutex::new(tx);
    f.supervisor
        .register_client(client, Arc::new(move |v| tx.lock().unwrap().send(v.clone()).is_ok()));
    assert_eq!(
        f.supervisor.register_provider(client, APP, vec!["agent_cli".into()]).unwrap(),
        json!({"families":["agent_cli"]})
    );
    rx
}

fn demand(rx: &Receiver<Value>, enabled: bool) -> u64 {
    loop {
        let event = rx.recv_timeout(Duration::from_secs(10)).expect("inventory demand");
        if event["event"] == "apps-agent-inventory-demand" {
            assert_eq!(
                event.as_object().unwrap().len(),
                3,
                "demand exposes no app, owner or inventory rows"
            );
            assert_eq!(event["enabled"], enabled);
            return event["sequence"].as_u64().unwrap();
        }
    }
}

fn no_demand(rx: &Receiver<Value>) {
    assert!(!rx.try_iter().any(|event| event["event"] == "apps-agent-inventory-demand"));
}

fn host_message(f: &Fixture, message: FromHost) {
    let key = HostKey { app: "cmux/demo".into(), preview: false };
    let generation = f.supervisor.inner.lock().unwrap().hosts[&key].generation;
    f.supervisor.on_host_message(&key, generation, message);
}

fn subscribe(f: &Fixture, sub: u64) {
    host_message(f, FromHost::Subscribe { sub, stream: STREAM.into(), filter: json!({}) });
}

#[test]
fn cmux_next_agent_inventory_demand_optin_registration_returns_the_current_snapshot() {
    let f = inventory_fixture();
    let rx = provider(&f, PROVIDER);
    let idle = demand(&rx, false);
    let register = || {
        f.supervisor.register_inventory_provider(PROVIDER, APP, vec!["agent_cli".into()]).unwrap()
    };
    assert_eq!(
        register(),
        json!({"families":["agent_cli"],"inventory_demand":{"sequence":idle,"enabled":false}})
    );
    subscribe(&f, 41);
    let live = demand(&rx, true);
    assert_eq!(register()["inventory_demand"], json!({"sequence":live,"enabled":true}));
    no_demand(&rx);
    assert_eq!(
        f.supervisor
            .register_inventory_provider(PROVIDER, APP, vec!["fs".into()])
            .unwrap_err()
            .code,
        "bad-request"
    );
    assert_eq!(
        f.supervisor
            .register_inventory_provider(99, APP, vec!["agent_cli".into()])
            .unwrap_err()
            .code,
        "apps.provider.unknown"
    );
}

#[test]
fn cmux_next_agent_inventory_demand_tracks_first_and_last_readable_subscriber() {
    let f = inventory_fixture();
    let rx = provider(&f, PROVIDER);
    let idle = demand(&rx, false);
    subscribe(&f, 41);
    let live = demand(&rx, true);
    assert!(live > idle);
    subscribe(&f, 42);
    no_demand(&rx);
    f.supervisor.agent_inventory_changed(PROVIDER, APP, live).unwrap();
    f.wait("empty fixed invalidation", |e| {
        e["event"] == "apps-log" && e["message"] == "event-body 42 {}"
    });
    host_message(&f, FromHost::Unsubscribe { sub: 41 });
    no_demand(&rx);
    host_message(&f, FromHost::Unsubscribe { sub: 42 });
    let stopped = demand(&rx, false);
    assert!(stopped > live);
    for sequence in [idle, live, stopped, u64::MAX] {
        assert_eq!(
            f.supervisor.agent_inventory_changed(PROVIDER, APP, sequence).unwrap_err().code,
            "apps.provider.stale_demand"
        );
    }
    subscribe(&f, 43);
    let fresh = demand(&rx, true);
    assert!(fresh > stopped);
    assert_eq!(
        f.supervisor.agent_inventory_changed(PROVIDER, APP, live).unwrap_err().code,
        "apps.provider.stale_demand"
    );
    f.supervisor.agent_inventory_changed(PROVIDER, APP, fresh).unwrap();
    f.wait("fresh subscription", |e| {
        e["event"] == "apps-log" && e["message"] == "event-body 43 {}"
    });
    assert!(f.router.calls.lock().unwrap().is_empty(), "invalidating starts no read, CLI or job");
}

#[test]
fn cmux_next_agent_inventory_demand_provider_replacement_fences_old_callbacks() {
    let f = inventory_fixture();
    subscribe(&f, 41);
    let rx = provider(&f, PROVIDER);
    let old = demand(&rx, true);
    for claim in [
        ProviderClaim { agent: true, verified_app: true },
        ProviderClaim { agent: false, verified_app: false },
    ] {
        assert_eq!(
            f.supervisor.agent_inventory_changed(PROVIDER, claim, old).unwrap_err().code,
            "apps.provider.forbidden"
        );
    }
    assert_eq!(
        f.supervisor.agent_inventory_changed(10, APP, old).unwrap_err().code,
        "apps.provider.unknown"
    );
    f.supervisor.disconnect(PROVIDER);
    let replacement = provider(&f, 10);
    let fresh = demand(&replacement, true);
    assert!(fresh > old);
    assert_eq!(
        f.supervisor.agent_inventory_changed(PROVIDER, APP, old).unwrap_err().code,
        "apps.provider.unknown"
    );
    assert_eq!(
        f.supervisor.agent_inventory_changed(10, APP, old).unwrap_err().code,
        "apps.provider.stale_demand"
    );
    f.supervisor.agent_inventory_changed(10, APP, fresh).unwrap();
}

#[test]
fn cmux_next_agent_inventory_demand_revocation_and_readmission_need_a_fresh_subscription() {
    let f = inventory_fixture();
    let rx = provider(&f, PROVIDER);
    demand(&rx, false);
    subscribe(&f, 41);
    let old = demand(&rx, true);
    let key = HostKey { app: "cmux/demo".into(), preview: false };
    let old_generation = f.supervisor.inner.lock().unwrap().hosts[&key].generation;
    f.set("revoke-inventory", "cmux/demo", Origin::User, |o| {
        o.grant = Some(("agent_cli:read".into(), false));
    })
    .unwrap();
    let revoked = demand(&rx, false);
    assert!(revoked > old);
    assert_eq!(
        f.supervisor.agent_inventory_changed(PROVIDER, APP, old).unwrap_err().code,
        "apps.provider.stale_demand"
    );
    f.wait("revoked replacement", |e| e["event"] == "apps-scene" && e["reset"] == true);
    subscribe(&f, 42);
    no_demand(&rx);
    f.set("grant-inventory", "cmux/demo", Origin::User, |o| {
        o.grant = Some(("agent_cli:read".into(), true));
    })
    .unwrap();
    f.wait("granted replacement", |e| e["event"] == "apps-scene" && e["reset"] == true);
    no_demand(&rx);
    f.supervisor.on_host_message(
        &key,
        old_generation,
        FromHost::Subscribe { sub: 43, stream: STREAM.into(), filter: json!({}) },
    );
    no_demand(&rx);
    subscribe(&f, 44);
    assert!(demand(&rx, true) > revoked);
}

#[test]
fn cmux_next_agent_inventory_demand_disable_and_host_exit_retire_demand() {
    for disable in [false, true] {
        let f = inventory_fixture();
        let rx = provider(&f, PROVIDER);
        demand(&rx, false);
        subscribe(&f, 41);
        let old = demand(&rx, true);
        if disable {
            f.set("disable-inventory", "cmux/demo", Origin::User, |o| o.enabled = Some(false))
                .unwrap();
        } else {
            let key = HostKey { app: "cmux/demo".into(), preview: false };
            f.supervisor.inner.lock().unwrap().hosts[&key].process.clone().unwrap().kill();
        }
        assert!(demand(&rx, false) > old);
        assert_eq!(
            f.supervisor.agent_inventory_changed(PROVIDER, APP, old).unwrap_err().code,
            "apps.provider.stale_demand"
        );
    }
}

#[test]
fn cmux_next_agent_inventory_demand_generic_events_cannot_impersonate_the_provider() {
    let f = inventory_fixture();
    let rx = provider(&f, PROVIDER);
    demand(&rx, false);
    subscribe(&f, 41);
    demand(&rx, true);
    f.supervisor.publish(STREAM, json!({"clis":[{"cli":"fake"}],"machine":"foreign"}));
    let key = HostKey { app: "cmux/demo".into(), preview: false };
    let process = f.supervisor.inner.lock().unwrap().hosts[&key].process.clone().unwrap();
    process
        .send(&ToHost::Settings { values: json!({"test_event_barrier":"generic feed barrier"}) });
    f.wait("generic feed barrier", |e| {
        e["event"] == "apps-log" && e["message"] == "generic feed barrier"
    });
    assert!(
        !f.supervisor.logs(CLIENT, "cmux/demo", false)["lines"]
            .as_array()
            .unwrap()
            .iter()
            .any(|line| line["message"] == "event 41")
    );
}
