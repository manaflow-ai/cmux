use super::*;

/// Applies `patch` (this module's form) to `target`: the client's side of the contract, kept here
/// so the tests check the two against each other.
fn apply(target: &mut Value, patch: &Value) {
    match patch {
        Value::Object(p) if p.len() == 1 && p.contains_key("$splice") => {
            let args = &p["$splice"];
            let (from, keep) =
                (args[0].as_u64().unwrap() as usize, args[1].as_u64().unwrap() as usize);
            let held = target.as_array().cloned().unwrap_or_default();
            let mut out: Vec<Value> = held[from..from + keep].to_vec();
            out.extend(args[2].as_array().unwrap().iter().cloned());
            *target = Value::Array(out);
        }
        Value::Object(p) => {
            if !target.is_object() {
                *target = Value::Object(Map::new());
            }
            let obj = target.as_object_mut().unwrap();
            for (k, v) in p {
                if v.is_null() {
                    obj.remove(k);
                } else {
                    apply(obj.entry(k.clone()).or_insert(Value::Null), v);
                }
            }
        }
        other => *target = other.clone(),
    }
}

fn roundtrip(old: Value, new: Value) -> Value {
    let mut rows = SentRows::default();
    assert!(matches!(rows.change("s", true, &old), Change::Whole { row_seq: 1 }));
    let Change::Patch { patch, row_seq } = rows.change("s", true, &new) else {
        panic!("a second row of the same kind is a patch")
    };
    assert_eq!(row_seq, 2);
    let mut held = old;
    apply(&mut held, &patch);
    assert_eq!(strip_nulls(held), strip_nulls(new), "patch {patch}");
    patch
}

/// Absent and null are the same row.
fn strip_nulls(v: Value) -> Value {
    match v {
        Value::Object(o) => Value::Object(
            o.into_iter().filter(|(_, v)| !v.is_null()).map(|(k, v)| (k, strip_nulls(v))).collect(),
        ),
        Value::Array(a) => Value::Array(a.into_iter().map(strip_nulls).collect()),
        v => v,
    }
}

fn spans(range: std::ops::Range<u64>, open_end: u64) -> Vec<Value> {
    range
        .map(|i| json!({"turnSeq": i, "turnId": format!("t{i}"), "category": "model", "startAt": i * 10, "endAt": if i == open_end { i * 10 + 7 } else { i * 10 + 5 }}))
        .collect()
}

#[test]
fn a_patch_takes_the_held_row_to_the_new_one() {
    roundtrip(json!({"a": 1, "b": {"c": "x", "d": [1, 2]}}), json!({"a": 2, "b": {"c": "x"}}));
    roundtrip(json!({"a": null}), json!({"a": {"b": null, "c": 1}}));
    roundtrip(json!({"a": [1, 2, 3]}), json!({"a": "now a string"}));
    roundtrip(json!({"a": "x"}), json!({"a": ["x", {"y": null}]}));
    roundtrip(json!({"a": [1, 2, 3, 4, 5]}), json!({"a": [5, 4, 3]}));
    roundtrip(json!({"a": 1}), json!({}));
    let same = roundtrip(json!({"a": 1, "b": null}), json!({"a": 1}));
    assert_eq!(same, json!({}));
}

/// The breakdown's spans as a running turn moves them: the open span's end moves, and a full
/// window drops its oldest when a new one starts. Only the moved items go out.
#[test]
fn spans_go_out_as_a_splice() {
    let old = json!({"timeBreakdown": {"totalMs": 1, "spans": spans(0..512, 511)}});
    let mut grown = spans(0..512, 999);
    grown[511]["endAt"] = json!(511 * 10 + 9);
    let new = json!({"timeBreakdown": {"totalMs": 2, "spans": grown}});
    let patch = roundtrip(old.clone(), new);
    assert_eq!(patch["timeBreakdown"]["spans"]["$splice"][1], 511, "{patch}");
    assert!(patch.to_string().len() < 300, "{patch}");

    let slid = json!({"timeBreakdown": {"totalMs": 2, "spans": spans(1..513, 512)}});
    let patch = roundtrip(old, slid);
    assert_eq!(patch["timeBreakdown"]["spans"]["$splice"][0], 1, "{patch}");
    assert!(patch.to_string().len() < 400, "{patch}");
}

#[test]
fn a_new_kind_of_row_or_a_forgotten_one_goes_out_whole() {
    let mut rows = SentRows::default();
    assert!(matches!(rows.change("s", false, &json!({"a": 1})), Change::Whole { row_seq: 1 }));
    assert!(matches!(rows.change("s", true, &json!({"a": 1})), Change::Whole { row_seq: 2 }));
    assert!(matches!(rows.change("s", true, &json!({"a": 2})), Change::Patch { row_seq: 3, .. }));
    rows.forget("s");
    assert!(matches!(rows.change("s", true, &json!({"a": 2})), Change::Whole { row_seq: 1 }));
    for i in 0..MAX_ROWS + 10 {
        rows.change(&format!("c{i}"), true, &json!({}));
    }
    assert!(rows.rows.len() <= MAX_ROWS);
}
/// A peer link's rows are masked whole (`peer_text.rs`); a patch of the raw row would skip
/// the masker, so a masked connection never gets patches even when it asks.
#[test]
fn only_a_raw_text_connection_gets_patches() {
    let asks = json!({"_meta": {"acpmux": {"sessionChangedDelta": true}}});
    let raw = |o| !crate::server::peer_text::masks(o);
    assert!(!allowed(&asks, raw(crate::server::Origin::Peer)));
    assert!(allowed(&asks, raw(crate::server::Origin::Local)));
    assert!(!allowed(&json!({}), raw(crate::server::Origin::Local)));
}
