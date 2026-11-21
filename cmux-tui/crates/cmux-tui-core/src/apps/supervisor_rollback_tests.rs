//! Rollback tolerance of `apps.json` (lane c-survive, routed from c-persist).
//! A newer build may add a record field, a source kind or a mirror field. An
//! older build that the person rolls back to could not read such a file: it
//! renamed it to `apps.json.corrupt` and started with no installs, so every
//! app grant (security state) was gone, also after the next update. Now a
//! record this build cannot read stays as it is (the app counts as not
//! installed here, so it holds no grant), a record it reads but did not change
//! keeps the fields it does not know, and the file is never set aside for it.

use super::*;

/// An `apps.json` as a newer build may write it.
fn newer_apps_json() -> Value {
    json!({
        "version": 1,
        "mirror": {
            "revision": 4,
            "apps": {
                // A source kind this build does not know.
                "cmux/team-app": {
                    "installed": true, "source": "team", "enabled": true, "hidden": false,
                    "sandboxed": false, "grants": ["workspace:read"]
                },
                // A record this build reads, with one more field.
                "cmux/demo": {
                    "installed": true, "source": "user", "enabled": true, "hidden": false,
                    "sandboxed": false, "grants": ["workspace:read"], "pinned_at_ms": 7
                }
            },
            "applied": [],
            "team_policy": {"locked": true}
        }
    })
}

#[test]
fn an_apps_json_from_a_newer_build_is_kept() {
    let root = temp_dir();
    let state = root.0.join("state");
    std::fs::create_dir_all(&state).unwrap();
    let written = newer_apps_json();
    std::fs::write(state.join("apps.json"), written.to_string()).unwrap();

    let f = fixture_with(&[], Duration::from_secs(60), root);
    assert!(
        !f.state.join("apps.json.corrupt").exists(),
        "an apps.json from a newer build was set aside as corrupt"
    );
    let list = f.supervisor.list();
    assert_eq!(app_entry(&list, "cmux/demo")["installed"], true, "{list}");

    // A change to another app saves the mirror: the records this build did not
    // change, and the fields it does not know, are written back as they were.
    f.install("local/spy");
    let saved: Value =
        serde_json::from_slice(&std::fs::read(f.state.join("apps.json")).unwrap()).unwrap();
    assert_eq!(
        saved["mirror"]["apps"]["cmux/team-app"],
        written["mirror"]["apps"]["cmux/team-app"]
    );
    assert_eq!(saved["mirror"]["apps"]["cmux/demo"], written["mirror"]["apps"]["cmux/demo"]);
    assert_eq!(saved["mirror"]["team_policy"], written["mirror"]["team_policy"]);
    assert_eq!(saved["mirror"]["apps"]["local/spy"]["installed"], true, "{saved}");
}
