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
