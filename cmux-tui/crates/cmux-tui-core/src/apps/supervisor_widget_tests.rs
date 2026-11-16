//! Supervisor tests of widgets (`widgets.rs`): the listing of installed widgets, the person's
//! layout (edits, refusals, persistence and the broadcast every page hears), the mount context a
//! placed tile gets, and the host-owned clock with its visibility and meter.

use super::*;

/// Writes a local app `local/<name>` whose `cmux.widget/1` draws with `export` and `options`.
fn write_widget(state: &Path, name: &str, export: &str, options: Value) {
    let id = format!("local/{name}");
    write_app(&state.join("apps/local"), name, &id, json!({}));
    let path = state.join("apps/local").join(name).join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["implements"]["cmux.widget/1"] = json!({ "export": export, "title": { "en": "Clock" }, "symbol": "clock", "options": options });
    std::fs::write(&path, manifest.to_string()).unwrap();
}

fn call(
    f: &Fixture,
    op: &str,
    args: Value,
    origin: Origin,
) -> Result<Value, super::super::supervisor::ApiError> {
    f.supervisor.store_call(CLIENT, op, args, origin)
}

fn edit(
    f: &Fixture,
    key: &str,
    place: &str,
    edit: Value,
) -> Result<Value, super::super::supervisor::ApiError> {
    call(
        f,
        "apps.widgets.layout.edit",
        json!({ "place": place, "edit": edit, "idempotency_key": key }),
        Origin::User,
    )
}

fn setup() -> Fixture {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    write_widget(
        &f.state,
        "clock",
        "renderClock",
        json!({ "sizes": ["small", "medium", "large"], "refresh": { "everySeconds": 5 } }),
    );
    write_widget(
        &f.state,
        "todo",
        "renderTodo",
        json!({ "sizes": ["large"], "places": ["newtab"] }),
    );
    f.supervisor.reload_local_apps(&prints);
    f
}

/// Only installed, enabled and visible apps' widgets are listed, with the spec Add Widget reads
/// (refresh raised to the floor); a place lists only the widgets that go there.
#[test]
fn installed_widgets_are_listed_with_their_spec_per_place() {
    let f = setup();
    let list = call(&f, "apps.widgets.list", json!({}), Origin::Script).unwrap();
    assert_eq!(list["widgets"], json!([]), "nothing installed: nothing to add");
    f.install("local/clock");
    f.install("local/todo");
    let list = call(&f, "apps.widgets.list", json!({}), Origin::Script).unwrap();
    let clock = list["widgets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|w| w["app"] == "local/clock")
        .unwrap()
        .clone();
    assert_eq!(clock["title"], "Clock");
    assert_eq!(clock["symbol"], "clock");
    assert_eq!(clock["sizes"], json!(["small", "medium", "large"]));
    assert_eq!(clock["defaultSize"], "small");
    assert_eq!(clock["places"], json!(["newtab", "sidebar"]));
    assert_eq!(clock["refresh"], json!({ "everySeconds": 60 }));
    let sidebar =
        call(&f, "apps.widgets.list", json!({ "place": "sidebar" }), Origin::Script).unwrap();
    let apps: Vec<&str> =
        sidebar["widgets"].as_array().unwrap().iter().filter_map(|w| w["app"].as_str()).collect();
    assert_eq!(apps, ["local/clock"], "todo is New Tab only");
    assert_eq!(sidebar["layout"], json!({ "revision": 0, "sidebar": [] }));
    f.set("hide", "local/clock", Origin::User, |op| op.hidden = Some(true)).unwrap();
    let list = call(&f, "apps.widgets.list", json!({}), Origin::Script).unwrap();
    assert!(list["widgets"].as_array().unwrap().iter().all(|w| w["app"] != "local/clock"));
}

/// The person's edits change one layout, saved in the state directory and broadcast to every
/// client; an agent cannot place a widget, a replay is the same edit, and the layout survives a
/// daemon restart.
#[test]
fn layout_edits_are_the_persons_saved_and_broadcast() {
    let f = setup();
    f.install("local/clock");
    f.install("local/todo");
    let refused = call(
        &f,
        "apps.widgets.layout.edit",
        json!({ "place": "newtab", "edit": { "op": "add", "app": "local/clock" }, "idempotency_key": "k0" }),
        Origin::Script,
    )
    .unwrap_err();
    assert_eq!(refused.code, "apps.origin");

    let added = edit(&f, "k1", "newtab", json!({ "op": "add", "app": "local/clock" })).unwrap();
    assert_eq!(
        added["layout"]["newtab"],
        json!([{ "instance": "w1", "app": "local/clock", "size": "small" }])
    );
    let changed = f.wait_event("apps-widgets-changed");
    assert_eq!(changed["revision"], 1);
    assert_eq!(changed["place"], "newtab");
    // A replay of the same key changes nothing more.
    assert_eq!(
        edit(&f, "k1", "newtab", json!({ "op": "add", "app": "local/clock" })).unwrap(),
        added
    );

    edit(&f, "k2", "newtab", json!({ "op": "add", "app": "local/todo", "before": "w1" })).unwrap();
    edit(&f, "k3", "newtab", json!({ "op": "resize", "instance": "w1", "size": "medium" }))
        .unwrap();
    edit(&f, "k4", "sidebar", json!({ "op": "add", "app": "local/clock", "size": "medium" }))
        .unwrap();
    let refused =
        edit(&f, "k5", "sidebar", json!({ "op": "add", "app": "local/todo" })).unwrap_err();
    assert_eq!(refused.code, "apps.widgets.edit");
    let refused =
        edit(&f, "k6", "sidebar", json!({ "op": "resize", "instance": "w3", "size": "large" }))
            .unwrap_err();
    assert_eq!(refused.code, "apps.widgets.edit");

    let list = call(&f, "apps.widgets.list", json!({}), Origin::Script).unwrap();
    assert_eq!(
        list["layout"],
        json!({
            "revision": 4,
            "newtab": [
                { "instance": "w2", "app": "local/todo", "size": "large" },
                { "instance": "w1", "app": "local/clock", "size": "medium" }
            ],
            "sidebar": [{ "instance": "w3", "app": "local/clock", "size": "medium" }]
        })
    );
    assert!(f.state.join("apps-widgets-layout.json").exists());

    // An uninstalled app's tiles are left out of the listing, and come back with it.
    f.set("off", "local/todo", Origin::User, |op| op.installed = Some(false)).unwrap();
    let list = call(&f, "apps.widgets.list", json!({ "place": "newtab" }), Origin::Script).unwrap();
    assert_eq!(list["layout"]["newtab"].as_array().unwrap().len(), 1);

    // A new daemon on the same state directory reads the same layout.
    let state = f.state.clone();
    let again =
        fixture_with(&[], Duration::from_secs(60), TempDir(state.parent().unwrap().to_path_buf()));
    let layout =
        call(&again, "apps.widgets.list", json!({}), Origin::Script).unwrap()["layout"].clone();
    assert_eq!(layout["revision"], 4);
}

/// A page mounts a placed tile with `{place, size, instance}`; the render gets the context built
/// here (with the tile's own settings), a size the widget does not draw is refused, and the
/// host's clock reaches the render while the tile is shown.
#[test]
fn a_placed_tile_mounts_with_the_context_built_here_and_ticks_while_shown() {
    let f = setup();
    f.install("local/clock");
    edit(&f, "k1", "sidebar", json!({ "op": "add", "app": "local/clock" })).unwrap();
    edit(
        &f,
        "k2",
        "sidebar",
        json!({ "op": "configure", "instance": "w1", "settings": { "zone": "UTC" } }),
    )
    .unwrap();

    let refused = f
        .supervisor
        .mount(
            CLIENT,
            "t0",
            "local/clock",
            "cmux.widget/1",
            json!({ "place": "sidebar", "size": "large", "instance": "w1" }),
        )
        .unwrap_err();
    assert_eq!(refused.code, "apps.widgets.size");

    f.mount(
        "t1",
        "local/clock",
        "cmux.widget/1",
        json!({ "place": "sidebar", "size": "small", "instance": "w1" }),
    );
    let context = {
        let inner = f.supervisor.inner.lock().unwrap();
        let key = super::super::supervisor::MountKey { client: CLIENT, mount_id: "t1".into() };
        inner.mounts.get(&key).unwrap().context.clone()
    };
    assert_eq!(
        context,
        json!({ "surface": "widget", "place": "sidebar", "size": "small", "instance": "w1",
                "settings": { "zone": "UTC" }, "refresh": { "everySeconds": 60 } })
    );

    // The host's tick reaches the render, which redraws.
    f.supervisor.widget_tick_now(CLIENT, "t1");
    let scene = f.wait("the tick's redraw", |e| {
        e["event"] == "apps-scene" && e["mount_id"] == "t1" && e["ops"][0]["props"]["tick"].is_u64()
    });
    assert_eq!(scene["ops"][0]["id"], "n1");

    // Hidden: no tick is armed; the meter says so and counts the tick.
    call(&f, "apps.widgets.visible", json!({ "mount_id": "t1", "visible": false }), Origin::Script)
        .unwrap();
    let meters = call(&f, "apps.widgets.meters", json!({}), Origin::Script).unwrap();
    let meter = &meters["meters"][0];
    assert_eq!(meter["mount_id"], "t1");
    assert_eq!(meter["visible"], false);
    assert_eq!(meter["ticks"], 1);
    assert_eq!(meter["everySeconds"], 60);
    assert!(f.supervisor.widget_armed(CLIENT, "t1") == Some(false));
    call(&f, "apps.widgets.visible", json!({ "mount_id": "t1", "visible": true }), Origin::Script)
        .unwrap();
    assert!(f.supervisor.widget_armed(CLIENT, "t1") == Some(true));

    // Not a widget mount: refused.
    f.mount("s1", "local/clock", "cmux.section/1", json!({}));
    let refused = call(
        &f,
        "apps.widgets.visible",
        json!({ "mount_id": "s1", "visible": false }),
        Origin::Script,
    )
    .unwrap_err();
    assert_eq!(refused.code, "apps.widgets.mount");
}

/// Let it crash: a widget whose render throws keeps its mount (the page keeps its last good scene,
/// marked stale) and is mounted again after a backoff that doubles, instead of failing the tile.
#[test]
fn a_widget_that_throws_goes_stale_and_is_mounted_again_with_a_backoff() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    write_widget(&f.state, "broken", "renderFail", json!({ "sizes": ["small"] }));
    f.supervisor.reload_local_apps(&prints);
    f.install("local/broken");
    edit(&f, "k1", "newtab", json!({ "op": "add", "app": "local/broken" })).unwrap();

    f.supervisor
        .mount(
            CLIENT,
            "w",
            "local/broken",
            "cmux.widget/1",
            json!({ "place": "newtab", "size": "small", "instance": "w1" }),
        )
        .unwrap();
    let not_failed = |e: &Value| {
        assert!(e["event"] != "apps-mount-failed", "a widget never fails its tile: {e}")
    };
    let first = f.wait("the first stale", |e| {
        not_failed(e);
        e["event"] == "apps-widget-health" && e["failures"] == 1
    });
    assert_eq!(first["mount_id"], "w");
    assert_eq!(first["stale"], true);
    assert_eq!(first["reason"], "render failed");
    assert_eq!(first["retry_ms"], 1000);
    // The tile is not failed: no apps-mount-failed, and the mount is still metered.
    let meters = call(&f, "apps.widgets.meters", json!({}), Origin::Script).unwrap();
    assert_eq!(meters["meters"][0]["mount_id"], "w");
    assert_eq!(meters["meters"][0]["failures"], 1);

    // The retry mounts it again; it throws again, and the next wait doubles.
    let second = f.wait("the retry's stale", |e| {
        not_failed(e);
        e["event"] == "apps-widget-health" && e["failures"] == 2
    });
    assert_eq!(second["retry_ms"], 2000);

    // Unmounting cancels the pending retry.
    f.supervisor.unmount(CLIENT, "w").unwrap();
    assert_eq!(f.supervisor.widget_armed(CLIENT, "w"), None);
}
