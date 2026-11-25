//! Extension signal sources through the supervisor (`signal_sources.rs`): the declaring app
//! publishes, a reader holding the source's scope hears `<name>.changed` and reads the value,
//! a reader without it hears nothing and is refused, and publishes inside the floor coalesce.
//! Bundled test apps must be published by `cmux` (the repository owner rule), so the ids are `cmux/*`.

use super::super::supervisor::HostKey;
use super::*;

const SOURCE: &str = "cmux/src";
const NAME: &str = "cmux.src.open";
const STREAM: &str = "cmux.src.open.changed";

/// `cmux/src` declares `open` (floor `floor` s); `cmux/reader` asks for `cmux.src:read`;
/// `cmux/nosy` does not. Each mounts a view that subscribes to the source's stream.
fn sources_fixture(floor: u64) -> Fixture {
    let root = temp_dir();
    let bundled = root.0.join("bundled");
    write_app(&bundled, "src", SOURCE, json!({}));
    write_app(&bundled, "reader", "cmux/reader", json!({ "cmux.src:read": "Show open tickets." }));
    write_app(&bundled, "nosy", "cmux/nosy", json!({}));
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
    // Every install first: an install can regrant (and restart) a running host, which drops
    // its subscriptions until it mounts again.
    for app in [SOURCE, "cmux/reader", "cmux/nosy"] {
        f.install(app);
    }
    for app in [SOURCE, "cmux/reader", "cmux/nosy"] {
        f.supervisor.logs(CLIENT, app, true);
        let view = app.replace('/', "-");
        f.mount(&view, app, "cmux.palette.scope/1", json!({ "stream": STREAM }));
    }
    f
}

/// How many source changes `app` has logged. Read from the app's log, not the event stream: the
/// fan-out runs inside the publish call, so a reader's log line can come before the call's own
/// result, and `Fixture::call` drops the events it passes over while it waits for that result.
fn changes(f: &Fixture, app: &str) -> usize {
    let lines = f.supervisor.logs(CLIENT, app, false)["lines"].clone();
    lines.as_array().unwrap().iter().filter(|l| l["message"] == "event-body 1 {}").count()
}

/// Blocks until `app` has logged `n` changes (or fails after 10 s).
fn wait_changes(f: &Fixture, app: &str, n: usize) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while changes(f, app) < n {
        assert!(Instant::now() < deadline, "{app} heard {} changes, not {n}", changes(f, app));
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn publish(f: &Fixture, count: Value) -> Value {
    f.call(
        "cmux-src",
        "signal.publish",
        json!({ "name": NAME, "value": { "count": count } }),
        false,
    )
}

#[test]
fn a_published_value_reaches_only_readers_holding_the_sources_scope() {
    let f = sources_fixture(1);
    let listed = f.call("cmux-reader", "signal.sources.list", json!({}), false);
    assert_eq!(listed["body"]["sources"][0]["name"], NAME, "{listed}");
    assert_eq!(listed["body"]["sources"][0]["readable"], true);
    let before = f.call("cmux-reader", "signal.read", json!({ "name": NAME }), false);
    assert_eq!(before["body"]["value"], Value::Null, "{before}");

    let told = publish(&f, json!(3));
    assert_eq!(told["ok"], true, "{told}");
    assert_eq!(told["body"]["told"], true);
    wait_changes(&f, "cmux/reader", 1);
    let read = f.call("cmux-reader", "signal.read", json!({ "name": NAME }), false);
    assert_eq!(read["body"]["value"], json!({ "count": 3 }), "{read}");

    let refused = f.call("cmux-nosy", "signal.read", json!({ "name": NAME }), false);
    assert_eq!(refused["ok"], false);
    assert_eq!(refused["body"]["code"], "scope.missing", "{refused}");
    let spoof = f.call(
        "cmux-reader",
        "signal.publish",
        json!({ "name": NAME, "value": { "count": 0 } }),
        false,
    );
    assert_eq!(spoof["body"]["code"], "scope.missing", "only the declaring app publishes: {spoof}");
    let bad = publish(&f, json!("three"));
    assert_eq!(bad["body"]["code"], "validation.invalid", "{bad}");
    let unknown = f.call("cmux-reader", "signal.read", json!({ "name": "cmux.src.closed" }), false);
    assert_eq!(unknown["body"]["code"], "signal.unknown");

    // A barrier the nosy app hears after any event it could have been sent.
    let key = HostKey { app: "cmux/nosy".into(), preview: false };
    let process = f.supervisor.inner.lock().unwrap().hosts[&key].process.clone().unwrap();
    process.send(&ToHost::Settings { values: json!({ "test_event_barrier": "barrier" }) });
    f.wait("the nosy app's barrier", |e| e["app"] == "cmux/nosy" && e["message"] == "barrier");
    assert_eq!(changes(&f, "cmux/nosy"), 0, "an app without the scope hears no change");
}

#[test]
fn publishes_inside_the_floor_reach_readers_once_with_the_newest_value() {
    let f = sources_fixture(1);
    assert_eq!(publish(&f, json!(1))["body"]["told"], true);
    wait_changes(&f, "cmux/reader", 1);
    for n in 2..=20 {
        assert_eq!(publish(&f, json!(n))["body"]["told"], false, "inside the floor");
    }
    wait_changes(&f, "cmux/reader", 2);
    let read = f.call("cmux-reader", "signal.read", json!({ "name": NAME }), false);
    assert_eq!(read["body"]["value"], json!({ "count": 20 }));
    // Only one floored tell: nothing more arrives within the next floor.
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(changes(&f, "cmux/reader"), 2, "a second floored tell");
}

#[test]
fn a_disabled_source_is_gone_for_its_readers() {
    let f = sources_fixture(1);
    publish(&f, json!(5));
    f.set("disable-src", SOURCE, Origin::User, |o| o.enabled = Some(false)).unwrap();
    let read = f.call("cmux-reader", "signal.read", json!({ "name": NAME }), false);
    assert_eq!(read["body"]["code"], "signal.unknown", "{read}");
}
