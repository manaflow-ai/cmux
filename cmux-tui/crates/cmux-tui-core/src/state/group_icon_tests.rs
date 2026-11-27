//! `workspace-group-icon-v1` over `cmux.protocol/2`: a personal workspace
//! group's icon (`workspace_group.update {icon}`), the shared icon string of
//! ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS (one emoji or an SF Symbol name).

use serde_json::json;

use super::tests::{Session, changes_after, error_code, mutate, read, revision, send};

fn group_icons(mux: &std::sync::Arc<crate::mux::Mux>) -> Vec<serde_json::Value> {
    read(mux, "workspace_group.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .map(|group| group["icon"].clone())
        .collect()
}

/// An icon sets, shows on the snapshot, the list and `session.events`,
/// survives a restart through the registry file, and null clears it.
#[test]
fn a_group_icon_sets_publishes_survives_a_restart_and_clears() {
    let session = Session::new("group-icon");
    let mux = session.open();
    let created = mutate(&mux, "workspace_group.create", json!({"name": "Work"}), "create-work");
    let group = created["id"].as_str().unwrap().to_string();
    assert!(created["icon"].is_null(), "a new group has no icon: {created}");

    let before = revision(&mux);
    let rocket = mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": group, "icon": "🚀"}),
        "icon-rocket",
    );
    assert_eq!(rocket["icon"], "🚀");
    assert_eq!(rocket["name"], "Work", "an icon update keeps the name");
    assert!(
        changes_after(&mux, before).iter().any(|change| change["kind"] == "state_upsert"
            && change["resource"] == "workspace_group"
            && change["value"]["icon"] == "🚀"),
        "session.events carries the icon"
    );
    let symbol = mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": group, "icon": "folder.fill"}),
        "icon-symbol",
    );
    assert_eq!(symbol["icon"], "folder.fill");
    assert_eq!(group_icons(&mux), [json!("folder.fill")]);
    drop(mux);

    let mux = session.open();
    assert_eq!(group_icons(&mux), [json!("folder.fill")], "the icon is in the registry file");
    let cleared = mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": group, "icon": null}),
        "icon-clear",
    );
    assert!(cleared["icon"].is_null());
    assert_eq!(group_icons(&mux), [json!(null)]);
    mux.shutdown();
}

/// The daemon is the authority on the icon string: anything that is not one
/// emoji or an SF Symbol name is refused and changes nothing.
#[test]
fn a_group_icon_that_is_not_an_emoji_or_a_symbol_name_is_refused() {
    let session = Session::new("group-icon-bad");
    let mux = session.open();
    let group = mutate(&mux, "workspace_group.create", json!({"name": "Work"}), "create")["id"]
        .as_str()
        .unwrap()
        .to_string();
    for (index, bad) in ["Not An Icon", "", "🚀🚀"].into_iter().enumerate() {
        assert_eq!(
            error_code(send(
                &mux,
                "workspace_group.update",
                json!({"workspace_group": group, "icon": bad}),
                Some(&format!("bad-{index}")),
            )),
            "validation.invalid",
            "{bad:?}"
        );
    }
    assert_eq!(group_icons(&mux), [json!(null)]);
    mux.shutdown();
}

/// A stored image or SVG (`icon-assets-v1`) is a group icon too (cx-qno.11.1): it sets when the
/// daemon stores the asset, a missing one is refused, and the blob outlives the sweep while the
/// group names it.
#[test]
fn a_group_icon_takes_a_stored_asset_and_keeps_it_from_the_sweep() {
    use crate::workspace_registry::personal_store::blobs::{prepare_blob, sweep_blobs};
    let session = Session::new("group-icon-asset");
    let mux = session.open();
    let group = mutate(&mux, "workspace_group.create", json!({"name": "Work"}), "create")["id"]
        .as_str()
        .unwrap()
        .to_string();
    let svg = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z"/></svg>"#;
    let icon = mux
        .with_icon_registry(|registry| registry.put_blob(prepare_blob("image/svg+xml", svg)?))
        .unwrap()
        .icon();

    let set = mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": group, "icon": icon}),
        "icon-asset",
    );
    assert_eq!(set["icon"], json!(icon));
    let missing = format!("svg:sha256-{}", "0".repeat(64));
    assert_eq!(
        error_code(send(
            &mux,
            "workspace_group.update",
            json!({"workspace_group": group, "icon": missing}),
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
