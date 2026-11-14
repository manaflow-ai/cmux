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
