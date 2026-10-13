//! `screen-group-icon-v1` over `cmux.protocol/2`: a screen group's icon
//! (`screen_group.update {icon}`), the shared icon string (one emoji, an SF
//! Symbol name or a stored image or SVG, `icon-assets-v1`).

use std::sync::Arc;

use serde_json::{Value, json};

use super::tests::{Session, changes_after, error_code, mutate, read, revision, send};
use crate::mux::Mux;
use crate::workspace_registry::WorkspaceRegistry;

/// A workspace of three screens grouped two and one; returns the group id.
fn grouped_screens(mux: &Arc<Mux>) -> String {
    mux.new_workspace(None, None).unwrap();
    let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    for _ in 0..2 {
        mux.new_screen(Some(workspace), None).unwrap();
    }
    let screens = mux.with_state(|state| {
        let index = state.workspace_index(workspace).unwrap();
        state.workspaces[index]
            .screens
            .iter()
            .map(|screen| screen.public_id.to_string())
            .collect::<Vec<_>>()
    });
    let created = mutate(
        mux,
        "screen_group.create",
        json!({"screens": [screens[0], screens[1]], "name": "Agents"}),
        "create-group",
    );
    assert!(created["icon"].is_null(), "a new screen group has no icon: {created}");
    created["id"].as_str().unwrap().to_string()
}

fn group_icons(mux: &Arc<Mux>) -> Vec<Value> {
    read(mux, "screen_group.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .map(|group| group["icon"].clone())
        .collect()
}

/// An icon sets, shows on the snapshot, the list and `session.events`, is
/// in the registry file after the daemon stops, and null clears it.
#[test]
fn a_screen_group_icon_sets_publishes_survives_a_restart_and_clears() {
    let session = Session::new("screen-group-icon");
    let mux = session.open();
    let group = grouped_screens(&mux);

    let before = revision(&mux);
    let rocket = mutate(
        &mux,
        "screen_group.update",
        json!({"screen_group": group, "icon": "🚀"}),
        "icon-rocket",
    );
    assert_eq!(rocket["icon"], "🚀");
    assert_eq!(rocket["name"], "Agents", "an icon update keeps the name");
    assert!(
        changes_after(&mux, before).iter().any(|change| change["kind"] == "state_upsert"
            && change["resource"] == "screen_group"
            && change["value"]["icon"] == "🚀"),
        "session.events carries the icon"
    );
    assert_eq!(read(&mux, "screen_group.get", json!({"screen_group": group}))["icon"], "🚀");

    let cleared =
        mutate(&mux, "screen_group.update", json!({"screen_group": group, "icon": null}), "clear");
    assert!(cleared["icon"].is_null());
    assert_eq!(group_icons(&mux), [json!(null)]);

    let symbol = mutate(
        &mux,
        "screen_group.update",
        json!({"screen_group": group, "icon": "folder.fill"}),
        "icon-symbol",
    );
    assert_eq!(symbol["icon"], "folder.fill");
    assert_eq!(group_icons(&mux), [json!("folder.fill")]);
    drop(mux);

    let registry = WorkspaceRegistry::open(&session.root, session.name).unwrap();
    let snapshot = registry.presentation_snapshot().unwrap();
    assert_eq!(
        snapshot.screens.groups[&group].icon.as_deref(),
        Some("folder.fill"),
        "the icon is in the registry file"
    );
}

/// Anything that is not one emoji, an SF Symbol name or an asset reference
/// is refused and changes nothing.
#[test]
fn a_screen_group_icon_that_is_not_an_icon_is_refused() {
    let mux = Mux::new_for_test("screen-group-icon-bad", crate::SurfaceOptions::default());
    let group = grouped_screens(&mux);
    for (index, bad) in ["Not An Icon", "", "🚀🚀"].into_iter().enumerate() {
        assert_eq!(
            error_code(send(
                &mux,
                "screen_group.update",
                json!({"screen_group": group, "icon": bad}),
                Some(&format!("bad-{index}")),
            )),
            "validation.invalid",
            "{bad:?}"
        );
    }
    assert_eq!(group_icons(&mux), [json!(null)]);
    mux.shutdown();
}

/// A stored image or SVG is a screen group icon too: it sets when the daemon
/// stores the asset, a missing one is refused, and the blob outlives the
/// sweep while the group names it.
#[test]
fn a_screen_group_icon_takes_a_stored_asset_and_keeps_it_from_the_sweep() {
    use crate::workspace_registry::personal_store::blobs::{prepare_blob, sweep_blobs};
    let mux = Mux::new_for_test("screen-group-icon-asset", crate::SurfaceOptions::default());
    let group = grouped_screens(&mux);
    let svg = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z"/></svg>"#;
    let icon = mux
        .with_icon_registry(|registry| registry.put_blob(prepare_blob("image/svg+xml", svg)?))
        .unwrap()
        .icon();

    let set = mutate(
        &mux,
        "screen_group.update",
        json!({"screen_group": group, "icon": icon}),
        "icon-asset",
    );
    assert_eq!(set["icon"], json!(icon));
    let missing = format!("svg:sha256-{}", "0".repeat(64));
    assert_eq!(
        error_code(send(
            &mux,
            "screen_group.update",
            json!({"screen_group": group, "icon": missing}),
            Some("icon-missing"),
        )),
        "validation.invalid"
    );
    assert_eq!(group_icons(&mux), [json!(icon)]);

    // Long after the put, only the group's reference keeps the blob.
    mux.with_icon_registry(|registry| sweep_blobs(&registry.connection.get(), u64::MAX / 2))
        .unwrap();
    mux.with_icon_registry(|registry| registry.get_blob(&icon)).unwrap();
    mux.shutdown();
}
