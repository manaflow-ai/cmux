//! Supervisor tests of overlays (`presentation.overlay`, `overlay.rs`): only
//! the person's gesture opens one, and an open one redraws on a save.

use super::*;

/// The local apps' fingerprints (`local_reload.rs`).
type Prints = std::collections::HashMap<String, u64>;

/// Makes `local/spy` draw a `cmux.pane/1` scene (export `export`) that may
/// open as an overlay, then reloads it; returns the new fingerprints.
fn spy_with_overlay(f: &Fixture, prints: &Prints, export: &str) -> Prints {
    let path = f.state.join("apps/local/spy/cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["implements"]["cmux.pane/1"] = json!({ "export": export, "title": "Spy" });
    manifest["presentation"] = json!({ "overlay": { "width": 360, "height": 240 } });
    std::fs::write(&path, manifest.to_string()).unwrap();
    f.supervisor.reload_local_apps(prints)
}

fn overlay() -> Value {
    json!({ "surface": "overlay", "contribution": "local/spy#cmux.pane/1" })
}

/// An overlay asked for by anyone but the person (a script, the CLI, an
/// agent through MCP, the app itself) is refused, and nothing mounts (base
/// red: every mount was taken, so any caller could float a panel in front
/// of the person).
#[test]
fn an_overlay_without_a_gesture_is_refused() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    spy_with_overlay(&f, &prints, "renderPane");
    f.install("local/spy");
    let refused =
        f.supervisor.mount(CLIENT, "o1", "local/spy", "cmux.pane/1", overlay()).unwrap_err();
    assert_eq!(refused.code, "apps.overlay_gesture", "{}", refused.message);
}

/// The person's own gesture (origin `user`, which the server admits only
/// from the verified cmux app) opens it; the CLI and MCP claiming the
/// person do not.
#[test]
fn an_overlay_opens_from_the_persons_gesture_only() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    spy_with_overlay(&f, &prints, "renderPane");
    f.install("local/spy");
    for origin in [Origin::Cli, Origin::Mcp, Origin::Remote] {
        let refused = f
            .supervisor
            .mount_as(CLIENT, "o1", "local/spy", "cmux.pane/1", overlay(), origin)
            .unwrap_err();
        assert_eq!(refused.code, "apps.overlay_gesture", "{origin:?}");
    }
    f.supervisor
        .mount_as(CLIENT, "o1", "local/spy", "cmux.pane/1", overlay(), Origin::User)
        .unwrap();
    let scene =
        f.wait("the overlay's scene", |e| e["event"] == "apps-scene" && e["mount_id"] == "o1");
    assert_eq!(scene["ops"][0]["props"]["text"], "renderPane", "{scene}");
}

/// An app that declares no overlay never opens one, gesture or not; its
/// pane still mounts as a tab.
#[test]
fn an_app_without_an_overlay_declares_none() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    spy_with_overlay(&f, &prints, "renderPane");
    let path = f.state.join("apps/local/spy/cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest.as_object_mut().unwrap().remove("presentation");
    std::fs::write(&path, manifest.to_string()).unwrap();
    f.supervisor.reload_local_apps(&prints);
    f.install("local/spy");
    let refused = f
        .supervisor
        .mount_as(CLIENT, "o1", "local/spy", "cmux.pane/1", overlay(), Origin::User)
        .unwrap_err();
    assert_eq!(refused.code, "apps.overlay_undeclared");
    f.supervisor
        .mount_as(
            CLIENT,
            "t1",
            "local/spy",
            "cmux.pane/1",
            json!({ "surface": "pane" }),
            Origin::Script,
        )
        .unwrap();
}

/// Hot reload: a save of the manifest (a renamed export) or of the code
/// redraws the open overlay with no relaunch and no new gesture; the
/// supervisor remounts it from its own mount table.
#[test]
fn an_open_overlay_redraws_on_a_save() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    let prints = spy_with_overlay(&f, &prints, "renderPane");
    f.install("local/spy");
    f.supervisor
        .mount_as(CLIENT, "o1", "local/spy", "cmux.pane/1", overlay(), Origin::User)
        .unwrap();
    f.wait("the overlay's scene", |e| e["event"] == "apps-scene" && e["mount_id"] == "o1");
    let prints = spy_with_overlay(&f, &prints, "renderPaneAgain");
    let scene = f.wait("the manifest save's scene", |e| {
        e["event"] == "apps-scene" && e["mount_id"] == "o1" && e["ops"][0]["op"] == "create"
    });
    assert_eq!(scene["ops"][0]["props"]["text"], "renderPaneAgain", "{scene}");
    std::fs::write(f.state.join("apps/local/spy/dist/main.js"), "var __cmuxAppExports = { v: 2 };")
        .unwrap();
    f.supervisor.reload_local_apps(&prints);
    let scene = f.wait("the code save's scene", |e| {
        e["mount_id"] == "o1" && (e["event"] == "apps-scene" || e["event"] == "apps-mount-failed")
    });
    assert_eq!(scene["event"], "apps-scene", "{scene}");
    assert_eq!(scene["ops"][0]["op"], "create", "{scene}");
}
