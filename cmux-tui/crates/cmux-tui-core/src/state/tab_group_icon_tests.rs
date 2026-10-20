//! `tab-group-icon-v1` over `cmux.protocol/2`: a tab group's icon
//! (`tab_group.update {icon}`), the shared icon string (one emoji, an SF
//! Symbol name or a stored image or SVG, `icon-assets-v1`), kept by a saved
//! tab group and by an ungroup's closed record.

use std::sync::Arc;

use serde_json::{Value, json};

use super::tests::{
    Session, changes_after, error_code, mutate, pane_id, read, revision, send, tab_id,
    terminal_tabs,
};
use crate::SurfaceId;
use crate::mux::Mux;
use crate::workspace_registry::WorkspaceRegistry;

/// One pane of three tabs, the last two grouped; returns the tabs and the
/// group id.
fn grouped_tabs(mux: &Arc<Mux>) -> (Vec<SurfaceId>, String) {
    let tabs = terminal_tabs(mux, 3);
    let ids = tabs.iter().map(|tab| tab_id(mux, *tab)).collect::<Vec<_>>();
    let created = mutate(
        mux,
        "tab_group.create",
        json!({"tabs": [ids[1], ids[2]], "name": "Build", "color": "blue"}),
        "create-group",
    );
    assert!(created["icon"].is_null(), "a new tab group has no icon: {created}");
    (tabs, created["id"].as_str().unwrap().to_string())
}

fn group_icons(mux: &Arc<Mux>) -> Vec<Value> {
    read(mux, "tab_group.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .map(|group| group["icon"].clone())
        .collect()
}

/// An icon sets, shows on the snapshot, the list and `session.events`, is
/// in the registry file after the daemon stops, and null clears it.
#[test]
fn a_tab_group_icon_sets_publishes_survives_a_restart_and_clears() {
    let session = Session::new("tab-group-icon");
    let mux = session.open();
    let (_, group) = grouped_tabs(&mux);

    let before = revision(&mux);
    let rocket =
        mutate(&mux, "tab_group.update", json!({"tab_group": group, "icon": "🚀"}), "icon-rocket");
    assert_eq!(rocket["icon"], "🚀");
    assert_eq!(rocket["name"], "Build", "an icon update keeps the name");
    assert!(
        changes_after(&mux, before).iter().any(|change| change["kind"] == "state_upsert"
            && change["resource"] == "tab_group"
            && change["value"]["icon"] == "🚀"),
        "session.events carries the icon"
    );
    assert_eq!(read(&mux, "tab_group.get", json!({"tab_group": group}))["icon"], "🚀");

    let cleared =
        mutate(&mux, "tab_group.update", json!({"tab_group": group, "icon": null}), "clear");
    assert!(cleared["icon"].is_null());
    assert_eq!(group_icons(&mux), [json!(null)]);

    let symbol = mutate(
        &mux,
        "tab_group.update",
        json!({"tab_group": group, "icon": "hammer.fill"}),
        "icon-symbol",
    );
    assert_eq!(symbol["icon"], "hammer.fill");
    assert_eq!(group_icons(&mux), [json!("hammer.fill")]);
    drop(mux);

    let registry = WorkspaceRegistry::open(&session.root, session.name).unwrap();
    let snapshot = registry.presentation_snapshot().unwrap();
    assert_eq!(
        snapshot.tab_groups.groups[&group].icon.as_deref(),
        Some("hammer.fill"),
        "the icon is in the registry file"
    );
}

/// Anything that is not one emoji, an SF Symbol name or an asset reference
/// is refused and changes nothing.
#[test]
fn a_tab_group_icon_that_is_not_an_icon_is_refused() {
    let mux = Mux::new_for_test("tab-group-icon-bad", crate::SurfaceOptions::default());
    let (_, group) = grouped_tabs(&mux);
    for (index, bad) in ["Not An Icon", "", "🚀🚀"].into_iter().enumerate() {
        assert_eq!(
            error_code(send(
                &mux,
                "tab_group.update",
                json!({"tab_group": group, "icon": bad}),
                Some(&format!("bad-{index}")),
            )),
            "validation.invalid",
            "{bad:?}"
        );
    }
    assert_eq!(group_icons(&mux), [json!(null)]);
    mux.shutdown();
}

/// A stored image or SVG is a tab group icon too: it sets when the daemon
/// stores the asset, a missing one is refused, and the blob outlives the
/// sweep while the group names it.
#[test]
fn a_tab_group_icon_takes_a_stored_asset_and_keeps_it_from_the_sweep() {
    use crate::workspace_registry::personal_store::blobs::{prepare_blob, sweep_blobs};
    let mux = Mux::new_for_test("tab-group-icon-asset", crate::SurfaceOptions::default());
    let (_, group) = grouped_tabs(&mux);
    let svg = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z"/></svg>"#;
    let icon = mux
        .with_icon_registry(|registry| registry.put_blob(prepare_blob("image/svg+xml", svg)?))
        .unwrap()
        .icon();

    let set =
        mutate(&mux, "tab_group.update", json!({"tab_group": group, "icon": icon}), "icon-asset");
    assert_eq!(set["icon"], json!(icon));
    let missing = format!("svg:sha256-{}", "0".repeat(64));
    assert_eq!(
        error_code(send(
            &mux,
            "tab_group.update",
            json!({"tab_group": group, "icon": missing}),
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

/// Saving a group keeps its icon, a later icon change follows into the
/// saved record, and reopening the saved group after its live group closed
/// restores the icon.
#[test]
fn a_saved_tab_group_keeps_its_icon_and_reopens_with_it() {
    let mux = Mux::new_for_test("tab-group-icon-saved", crate::SurfaceOptions::default());
    let (tabs, group) = grouped_tabs(&mux);
    mutate(&mux, "tab_group.update", json!({"tab_group": group, "icon": "🚀"}), "icon");
    let saved = mutate(&mux, "saved_tab_group.save", json!({"tab_group": group}), "save");
    let saved_id = saved["id"].as_str().unwrap().to_string();
    assert_eq!(saved["icon"], "🚀", "the saved record keeps the icon: {saved}");

    mutate(&mux, "tab_group.update", json!({"tab_group": group, "icon": "hammer.fill"}), "icon-2");
    assert_eq!(
        read(&mux, "saved_tab_group.list", json!({}))[0]["icon"],
        "hammer.fill",
        "the saved record follows its live group"
    );

    mutate(&mux, "tab_group.close", json!({"tab_group": group}), "close");
    let reopened = mutate(
        &mux,
        "saved_tab_group.reopen",
        json!({"saved_tab_group": saved_id, "pane_id": pane_id(&mux, tabs[0])}),
        "reopen",
    );
    assert_eq!(reopened["tab_group"]["icon"], "hammer.fill");
    assert_eq!(reopened["tab_group"]["saved_tab_group_id"], saved_id);
    assert_eq!(read(&mux, "saved_tab_group.list", json!({}))[0]["icon"], "hammer.fill");
    mux.shutdown();
}

/// An ungrouped group's closed record keeps its icon: reopening it forms
/// the group again with the icon.
#[test]
fn reopening_an_ungrouped_tab_group_restores_its_icon() {
    let mux = Mux::new_for_test("tab-group-icon-ungroup", crate::SurfaceOptions::default());
    let (_, group) = grouped_tabs(&mux);
    mutate(&mux, "tab_group.update", json!({"tab_group": group, "icon": "🚀"}), "icon");
    mutate(&mux, "tab_group.ungroup", json!({"tab_group": group}), "ungroup");
    assert_eq!(
        error_code(send(&mux, "tab_group.get", json!({"tab_group": group}), None)),
        "resource.not_found"
    );

    let closed = read(&mux, "closed.list", json!({}));
    mutate(&mux, "closed.reopen", json!({"closed": closed[0]["id"]}), "reopen");
    let restored = read(&mux, "tab_group.get", json!({"tab_group": group}));
    assert_eq!(restored["name"], "Build");
    assert_eq!(restored["icon"], "🚀");
    mux.shutdown();
}
