//! Extension signal sources through the supervisor (`signal_sources.rs`): the declaring app
//! publishes, a reader holding the source's scope hears `<name>.changed` and reads the value,
//! a reader without it hears nothing and is refused, and publishes inside the floor coalesce.

use super::super::supervisor::HostKey;
use super::*;

const SOURCE: &str = "acme/src";
const NAME: &str = "acme.src.open";
const STREAM: &str = "acme.src.open.changed";

/// `acme/src` declares `open` (floor `floor` s); `acme/reader` asks for `acme.src:read`;
/// `acme/nosy` does not. Each mounts a view that subscribes to the source's stream.
fn sources_fixture(floor: u64) -> Fixture {
    let root = temp_dir();
    let bundled = root.0.join("bundled");
    write_app(&bundled, "src", SOURCE, json!({}));
    write_app(&bundled, "reader", "acme/reader", json!({ "acme.src:read": "Show open tickets." }));
    write_app(&bundled, "nosy", "acme/nosy", json!({}));
    let path = bundled.join("src/cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["implements"]["cmux.signal.source/1"] = json!({ "options": { "sources": { "open": {
        "docs": "Open tickets",
        "value": { "type": "object", "required": ["count"], "properties": { "count": { "type": "integer" } } },
        "pollFloorSeconds": floor
    } } } });
    std::fs::write(&path, manifest.to_string()).unwrap();
    let f = fixture_with(&[], Duration::from_secs(60), root);
    for app in [SOURCE, "acme/reader", "acme/nosy"] {
        f.install(app);
        f.supervisor.logs(CLIENT, app, true);
        let view = app.replace('/', "-");
        f.mount(&view, app, "cmux.palette.scope/1", json!({ "stream": STREAM }));
    }
    f
}

fn publish(f: &Fixture, count: Value) -> Value {
    f.call(
        "acme-src",
        "signal.publish",
        json!({ "name": NAME, "value": { "count": count } }),
        false,
    )
}

#[test]
fn a_published_value_reaches_only_readers_holding_the_sources_scope() {
    let f = sources_fixture(1);
    let listed = f.call("acme-reader", "signal.sources.list", json!({}), false);
    assert_eq!(listed["body"]["value"]["sources"][0]["name"], NAME, "{listed}");
    assert_eq!(listed["body"]["value"]["sources"][0]["readable"], true);
    let before = f.call("acme-reader", "signal.read", json!({ "name": NAME }), false);
    assert_eq!(before["body"]["value"]["value"], Value::Null, "{before}");

    let told = publish(&f, json!(3));
    assert_eq!(told["ok"], true, "{told}");
    assert_eq!(told["body"]["value"]["told"], true);
    f.wait("the reader's change event", |e| {
        e["event"] == "apps-log" && e["app"] == "acme/reader" && e["message"] == "event-body 1 {}"
    });
    let read = f.call("acme-reader", "signal.read", json!({ "name": NAME }), false);
    assert_eq!(read["body"]["value"]["value"], json!({ "count": 3 }), "{read}");

    let refused = f.call("acme-nosy", "signal.read", json!({ "name": NAME }), false);
    assert_eq!(refused["ok"], false);
    assert_eq!(refused["body"]["code"], "scope.missing", "{refused}");
    let spoof = f.call(
        "acme-reader",
        "signal.publish",
        json!({ "name": NAME, "value": { "count": 0 } }),
        false,
    );
    assert_eq!(spoof["body"]["code"], "scope.missing", "only the declaring app publishes: {spoof}");
    let bad = publish(&f, json!("three"));
    assert_eq!(bad["body"]["code"], "validation.invalid", "{bad}");
    let unknown = f.call("acme-reader", "signal.read", json!({ "name": "acme.src.closed" }), false);
    assert_eq!(unknown["body"]["code"], "signal.unknown");

    // A barrier the nosy app hears after any event it could have been sent.
    let key = HostKey { app: "acme/nosy".into(), preview: false };
    let process = f.supervisor.inner.lock().unwrap().hosts[&key].process.clone().unwrap();
    process.send(&ToHost::Settings { values: json!({ "test_event_barrier": "barrier" }) });
    let heard = f.wait("the nosy app's barrier", |e| {
        e["event"] == "apps-log"
            && e["app"] == "acme/nosy"
            && (e["message"] == "barrier" || e["message"] == "event 1")
    });
    assert_eq!(heard["message"], "barrier", "an app without the scope hears no change");
}

#[test]
fn publishes_inside_the_floor_reach_readers_once_with_the_newest_value() {
    let f = sources_fixture(1);
    assert_eq!(publish(&f, json!(1))["body"]["value"]["told"], true);
    f.wait("the first change", |e| e["app"] == "acme/reader" && e["message"] == "event 1");
    for n in 2..=20 {
        assert_eq!(publish(&f, json!(n))["body"]["value"]["told"], false, "inside the floor");
    }
    f.wait("the floored change", |e| e["app"] == "acme/reader" && e["message"] == "event 1");
    let read = f.call("acme-reader", "signal.read", json!({ "name": NAME }), false);
    assert_eq!(read["body"]["value"]["value"], json!({ "count": 20 }));
    // Only one floored tell: nothing more arrives within the next floor.
    let deadline = Instant::now() + Duration::from_millis(1500);
    while let Ok(e) = f.events.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
        assert!(!(e["app"] == "acme/reader" && e["message"] == "event 1"), "a second tell: {e}");
    }
}

#[test]
fn an_uninstalled_source_is_gone_for_its_readers() {
    let f = sources_fixture(1);
    publish(&f, json!(5));
    f.set("uninstall-src", SOURCE, Origin::User, |o| o.installed = Some(false)).unwrap();
    let read = f.call("acme-reader", "signal.read", json!({ "name": NAME }), false);
    assert_eq!(read["body"]["code"], "signal.unknown", "{read}");
}
