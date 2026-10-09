//! `sidebar_layout.get` / `.update` (sidebar-layout-v1) through
//! `cmux.protocol/2` requests: the commit path, replay, rejects, the event
//! feed, persistence across a reopen, and L5 (a newer app's values and keys
//! pass the catalog and come back verbatim, also after a reopen).

use serde_json::json;

use super::tests::{Session, error_code, read, send, snapshot};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;
use crate::workspace_registry::WorkspaceRegistry;

fn update(mux: &Arc<Mux>, key: &str, op: Value) -> Result<Value, ResourceError> {
    send(mux, "sidebar_layout.update", json!({"op": op}), Some(key))
}

/// L5 over the wire: a section and item with values and keys this build does
/// not know pass the catalog, are stored, and come back verbatim from
/// `sidebar_layout.get`, the session snapshot, and after a reopen.
#[test]
fn newer_app_values_and_keys_round_trip_through_the_protocol_and_a_reopen() {
    let session = Session::new("sidebar-layout-l5");
    let section = json!({
        "id": "sec_new", "title": "New", "region": "top", "look": "glass", "content": "items",
        "arrangement": {"layout": "carousel", "align": "fill", "speed": 2},
        "pinned_to": "edge",
        "items": [{"id": "itm_new", "ref": {"kind": "hologram", "value": "x", "tint": 1},
                   "span": 2, "glow": true}],
    });
    let expected = json!({
        "id": "sec_new", "title": "New", "shows_title": true, "region": "top", "look": "glass",
        "arrangement": {"layout": "carousel", "align": "fill", "speed": 2},
        "content": "items", "pinned_to": "edge",
        "items": [{"id": "itm_new", "ref": {"kind": "hologram", "value": "x", "tint": 1},
                   "shows_label": true, "span": 2, "glow": true}],
    });
    {
        let mux = session.open();
        let added =
            update(&mux, "l5-1", json!({"kind": "section.add", "section": section, "index": 9}))
                .unwrap();
        assert_eq!(added["value"]["sections"][1], expected);
        let patched = update(
            &mux,
            "l5-2",
            json!({"kind": "section.update", "id": "sec_new", "patch": {"layout": "orbit"}}),
        )
        .unwrap();
        assert_eq!(patched["value"]["sections"][1]["arrangement"]["layout"], "orbit");
        assert_eq!(patched["value"]["sections"][1]["arrangement"]["speed"], 2);
    }
    let mux = session.open();
    // The app decodes region and content strictly, so the wire refuses an
    // op that would store a value it cannot read.
    let side = json!({"id": "sec_side", "region": "side", "look": "list", "content": "items"});
    let feed = json!({"id": "sec_feed", "region": "top", "look": "list", "content": "feed"});
    for (key, op) in [
        ("l5-3", json!({"kind": "section.add", "section": side, "index": 0})),
        ("l5-4", json!({"kind": "section.add", "section": feed, "index": 0})),
        ("l5-5", json!({"kind": "section.move", "id": "sec_new", "region": "side", "index": 0})),
    ] {
        assert_eq!(error_code(update(&mux, key, op)), "validation.invalid", "{key}");
    }
    let mut expected = expected;
    expected["arrangement"]["layout"] = json!("orbit");
    assert_eq!(read(&mux, "sidebar_layout.get", json!({}))["sections"][1], expected);
    assert_eq!(snapshot(&mux)["extra"]["state"]["sidebar_layout"]["sections"][1], expected);
}

/// The layout survives a reopen; a reused key with another op is
/// `idempotency.conflict`; reset goes through the protocol; a row that no
/// longer parses reads as the defaults instead of breaking snapshots.
#[test]
fn sidebar_layout_persists_conflicts_resets_and_survives_a_damaged_row() {
    let session = Session::new("sidebar-layout-reopen");
    {
        let mux = session.open();
        update(&mux, "r-1", json!({"kind": "item.remove", "id": "itm_home"})).unwrap();
        assert_eq!(
            error_code(update(&mux, "r-1", json!({"kind": "item.remove", "id": "itm_app_store"}))),
            "idempotency.conflict"
        );
    }
    {
        let mux = session.open();
        let got = read(&mux, "sidebar_layout.get", json!({}));
        assert_eq!(got["revision"], "1");
        assert_eq!(got["sections"][0]["items"][0]["id"], "itm_app_store");
        let reset = update(&mux, "r-2", json!({"kind": "layout.reset"})).unwrap();
        assert_eq!(reset["value"]["revision"], "2");
        assert_eq!(reset["value"]["sections"][0]["items"][0]["id"], "itm_home");
    }
    {
        let registry = WorkspaceRegistry::open(&session.root, session.name).unwrap();
        registry
            .read_state(|connection| {
                connection.execute(
                    "UPDATE sidebar_layout SET document_json = '{not json' WHERE id = 1",
                    [],
                )?;
                Ok(())
            })
            .unwrap();
    }
    let mux = session.open();
    assert_eq!(read(&mux, "sidebar_layout.get", json!({}))["revision"], "0");
    assert_eq!(snapshot(&mux)["extra"]["state"]["sidebar_layout"]["revision"], "0");
}

/// The app appends with `index: Int.max` (SidebarLayoutPlanner, section
/// moves); the catalog and the reducer accept it and clamp it to the end.
#[test]
fn int_max_index_appends_through_the_protocol() {
    let mux = Mux::new_for_test("state-sidebar-layout-int-max", SurfaceOptions::default());
    let item = json!({"id": "itm_ws", "ref": {"kind": "workspace", "value": "local:ws_1"}});
    let added = update(
        &mux,
        "m-1",
        json!({"kind": "item.add", "item": item, "section": "sec_bottom", "index": i64::MAX}),
    )
    .unwrap();
    assert_eq!(added["value"]["sections"][3]["items"][1]["id"], "itm_ws");
    let moved = update(
        &mux,
        "m-2",
        json!({"kind": "section.move", "id": "sec_top", "region": "middle", "index": i64::MAX}),
    )
    .unwrap();
    let middle = moved["value"]["sections"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|s| s["region"] == "middle")
        .map(|s| s["id"].clone())
        .collect::<Vec<_>>();
    assert_eq!(middle, [json!("sec_workspaces"), json!("sec_recents"), json!("sec_top")]);
    let section = json!({"id": "sec_m", "region": "bottom", "look": "list", "content": "items"});
    let float = update(
        &mux,
        "m-3",
        json!({"kind": "section.add", "section": section, "index": 9.223372036854776e18}),
    )
    .unwrap();
    assert_eq!(float["value"]["sections"].as_array().unwrap().last().unwrap()["id"], "sec_m");
    assert_eq!(
        error_code(update(
            &mux,
            "m-4",
            json!({"kind": "item.move", "id": "itm_ws", "section": "sec_bottom", "index": 1.5})
        )),
        "validation.invalid"
    );
}
