//! Subscription delivery across current authority changes, with a real host queue barrier.

use super::super::supervisor::{HostKey, HostState, Inner};
use super::*;

/// Hold the subscribed process alive while changing authoritative supervisor facts.
/// This isolates the delivery gate from the independent process-exit race.
fn delivery_after(change: impl FnOnce(&mut Inner, &HostKey)) {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("live", "cmux/demo", "cmux.palette.scope/1", json!({}));
    f.supervisor.logs(CLIENT, "cmux/demo", true);
    let key = HostKey { app: "cmux/demo".into(), preview: false };
    let process = f.supervisor.inner.lock().unwrap().hosts[&key].process.clone().unwrap();
    f.supervisor.publish("workspace.changed", json!({}));
    f.wait("initial subscription delivery", |e| {
        e["event"] == "apps-log" && e["message"] == "event 1"
    });
    change(&mut f.supervisor.inner.lock().unwrap(), &key);
    f.supervisor.publish("workspace.changed", json!({}));
    process.send(&ToHost::Settings { values: json!({"test_event_barrier":"delivery barrier"}) });
    f.wait("host queue barrier", |e| {
        e["event"] == "apps-log" && e["message"] == "delivery barrier"
    });
    let logs = f.supervisor.logs(CLIENT, "cmux/demo", false);
    let events = logs["lines"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|line| line["message"] == "event 1")
        .count();
    assert_eq!(events, 1, "a saved subscription outlived its current authority");
}

#[test]
fn cmux_next_agent_inventory_subscriptions_recheck_current_grants() {
    delivery_after(|inner, key| {
        inner.mirror.apps.get_mut(&key.app).unwrap().grants.remove("workspace:read");
    });
}

#[test]
fn cmux_next_agent_inventory_subscriptions_refuse_disabled_apps() {
    delivery_after(|inner, key| inner.mirror.apps.get_mut(&key.app).unwrap().enabled = false);
}

#[test]
fn cmux_next_agent_inventory_subscriptions_refuse_stopping_hosts() {
    delivery_after(|inner, key| inner.hosts.get_mut(key).unwrap().state = HostState::Stopping);
}

#[test]
fn cmux_next_agent_inventory_subscriptions_refuse_restarting_hosts() {
    delivery_after(|inner, key| inner.hosts.get_mut(key).unwrap().state = HostState::Restarting);
}

#[test]
fn cmux_next_agent_inventory_subscriptions_recheck_manifest_requests() {
    delivery_after(|inner, key| {
        inner.catalog.packages.remove(&key.app);
    });
}

#[test]
fn cmux_next_agent_inventory_subscriptions_keep_a_readable_running_host() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("live", "cmux/demo", "cmux.palette.scope/1", json!({}));
    f.supervisor.logs(CLIENT, "cmux/demo", true);
    f.supervisor.publish("workspace.changed", json!({}));
    f.wait("readable running subscriber", |e| {
        e["event"] == "apps-log" && e["message"] == "event 1"
    });
}
