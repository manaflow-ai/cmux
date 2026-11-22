//! `palette_usage.get` / `.record` / `.import` (palette-usage-v1) through
//! `cmux.protocol/2` requests: the commit path, small results, replay,
//! rejects, the event feed, a one-time import, and persistence across a
//! reopen.

use serde_json::json;

use super::tests::{Session, changes_after, error_code, read, revision, send};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

fn record(
    mux: &Arc<Mux>,
    idempotency: &str,
    key: &str,
    query: &str,
) -> Result<Value, ResourceError> {
    send(mux, "palette_usage.record", json!({"key": key, "query": query}), Some(idempotency))
}

#[test]
fn palette_usage_records_replays_rejects_and_emits_one_small_upsert() {
    let mux = Mux::new_for_test("state-palette-usage", SurfaceOptions::default());
    let before = revision(&mux);
    let empty = read(&mux, "palette_usage.get", json!({}));
    assert_eq!(empty["revision"], "0");
    assert_eq!(empty["entries"], json!([]));
    assert_eq!(empty["picks"], json!([]));

    let first = record(&mux, "u-1", "action:splitRight", "Sp").unwrap();
    assert_eq!(first["replayed"], false);
    assert_eq!(first["value"], json!({"revision": "1"}), "a record result carries no usage data");
    let after = read(&mux, "palette_usage.get", json!({}));
    assert_eq!(after["entries"][0]["key"], "action:splitRight");
    assert_eq!(after["entries"][0]["score"], 1.0);
    let prefixes: Vec<&str> =
        after["picks"].as_array().unwrap().iter().map(|p| p["prefix"].as_str().unwrap()).collect();
    assert_eq!(prefixes, ["s", "sp"]);
    assert!(after["picks"].as_array().unwrap().iter().all(|p| p["last"] == true));

    let replay = record(&mux, "u-1", "action:splitRight", "Sp").unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(error_code(record(&mux, "u-2", "  ", "")), "validation.invalid");
    assert_eq!(error_code(record(&mux, "u-1", "action:other", "")), "idempotency.conflict");

    record(&mux, "u-3", "action:splitDown", "s").unwrap();
    let snapshot = read(&mux, "palette_usage.get", json!({}));
    assert_eq!(snapshot["revision"], "2");
    let keys: Vec<&str> = snapshot["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["key"].as_str().unwrap())
        .collect();
    assert_eq!(keys.len(), 2);
    let s_picks: Vec<(&str, bool)> = snapshot["picks"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|p| p["prefix"] == "s")
        .map(|p| (p["key"].as_str().unwrap(), p["last"].as_bool().unwrap()))
        .collect();
    assert_eq!(s_picks.len(), 2);
    assert!(s_picks.contains(&("action:splitDown", true)));
    assert!(s_picks.contains(&("action:splitRight", false)));

    let changes: Vec<Value> = changes_after(&mux, before)
        .into_iter()
        .filter(|change| change["resource"] == "palette_usage")
        .collect();
    assert_eq!(
        changes.len(),
        2,
        "one upsert per committed record, none for the replay or the reject"
    );
    assert_eq!(changes[1]["kind"], "state_upsert");
    assert_eq!(changes[1]["id"], "user");
    assert_eq!(changes[1]["value"], json!({"revision": "2"}), "the event carries no usage data");
}

#[test]
fn palette_usage_imports_once_per_source_and_survives_a_reopen() {
    let session = Session::new("palette-usage-reopen");
    let entries = json!([
        {"key": "action:newColumn", "score": 31.5, "last_used_ms": "1000"},
        {"key": "action:palette.newAgentChat", "score": 15.0, "last_used_ms": "2000"},
    ]);
    {
        let mux = session.open();
        let imported = send(
            &mux,
            "palette_usage.import",
            json!({"source": "com.cmuxterm.app.debug.nxdog70.v1", "entries": entries}),
            Some("i-1"),
        )
        .unwrap();
        assert_eq!(imported["value"], json!({"revision": "1", "imported": true}));
        let after = read(&mux, "palette_usage.get", json!({}));
        assert_eq!(after["imported"], json!(["com.cmuxterm.app.debug.nxdog70.v1"]));
        assert_eq!(after["entries"].as_array().unwrap().len(), 2);
        let again = send(
            &mux,
            "palette_usage.import",
            json!({"source": "com.cmuxterm.app.debug.nxdog70.v1", "entries": entries}),
            Some("i-2"),
        )
        .unwrap();
        assert_eq!(
            again["value"],
            json!({"revision": "1", "imported": false}),
            "a source imports once"
        );
        assert_eq!(
            error_code(send(
                &mux,
                "palette_usage.import",
                json!({"source": "", "entries": []}),
                Some("i-3")
            )),
            "validation.invalid"
        );
        record(&mux, "u-1", "action:newColumn", "new").unwrap();
    }
    let mux = session.open();
    let snapshot = read(&mux, "palette_usage.get", json!({}));
    assert_eq!(snapshot["revision"], "2");
    assert_eq!(snapshot["imported"], json!(["com.cmuxterm.app.debug.nxdog70.v1"]));
    assert_eq!(snapshot["entries"][0]["key"], "action:newColumn");
    assert!(
        snapshot["picks"]
            .as_array()
            .unwrap()
            .iter()
            .any(|p| p["prefix"] == "new" && p["last"] == true)
    );
}
