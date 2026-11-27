use super::*;

fn apply(target: &mut Value, patch: &Value) {
    assert!(super::apply(target, patch), "{patch} applies to {target}");
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

/// A change row that does not owe the chart leaves it out: the patch keeps it (no `null`),
/// and the next turn's chart splices onto the held one instead of going out whole.
#[test]
fn a_left_out_breakdown_stays_held_and_the_next_one_splices() {
    let mut rows = SentRows::default();
    let first = json!({"title": "a", "timeBreakdown": {"totalMs": 1, "spans": spans(0..512, 511)}});
    assert!(matches!(rows.change("s", true, &first), Change::Whole { .. }));
    let mut held = first.clone();
    let Change::Patch { patch, .. } = rows.change("s", true, &json!({"title": "b"})) else {
        panic!("a patch")
    };
    assert_eq!(patch, json!({"title": "b"}), "no null for the left-out chart");
    apply(&mut held, &patch);
    assert_eq!(held["timeBreakdown"], first["timeBreakdown"]);
    let next = json!({"title": "b", "timeBreakdown": {"totalMs": 2, "spans": spans(1..513, 512)}});
    let Change::Patch { patch, .. } = rows.change("s", true, &next) else { panic!("a patch") };
    assert_eq!(patch["timeBreakdown"]["spans"]["$splice"][0], 1, "{patch}");
    assert!(patch.to_string().len() < 400, "{patch}");
    apply(&mut held, &patch);
    assert_eq!(held, next);
}

#[test]
fn a_new_kind_of_row_or_a_forgotten_one_goes_out_whole() {
    let mut rows = SentRows::default();
    assert!(matches!(rows.change("s", false, &json!({"a": 1})), Change::Whole { row_seq: 1 }));
    assert!(matches!(rows.change("s", true, &json!({"a": 1})), Change::Whole { row_seq: 2 }));
    assert!(matches!(rows.change("s", true, &json!({"a": 2})), Change::Patch { row_seq: 3, .. }));
    // A resync: whole, numbered on; patches after it.
    rows.resend("s");
    assert!(matches!(rows.change("s", true, &json!({"a": 2})), Change::Whole { row_seq: 4 }));
    assert!(matches!(rows.change("s", true, &json!({"a": 3})), Change::Patch { row_seq: 5, .. }));
    rows.forget("s");
    assert!(matches!(rows.change("s", true, &json!({"a": 2})), Change::Whole { row_seq: 1 }));
    for i in 0..MAX_ROWS + 10 {
        rows.change(&format!("c{i}"), true, &json!({}));
    }
    assert!(rows.rows.len() <= MAX_ROWS);
}
/// A client asks with `true` (version 1) or a version; a daemon before version 2 took only
/// `true`, so a link's `2` reads there as not asking.
#[test]
fn a_client_asks_with_true_or_a_version() {
    assert!(allowed(&json!({"_meta": {"acpmux": {"sessionChangedDelta": true}}})));
    assert!(allowed(&json!({"_meta": {"acpmux": {"sessionChangedDelta": VERSION}}})));
    assert!(!allowed(&json!({"_meta": {"acpmux": {"sessionChangedDelta": false}}})));
    assert!(!allowed(&json!({"_meta": {"acpmux": {"sessionChangedDelta": 0}}})));
    assert!(!allowed(&json!({})));
}

/// A splice that does not fit the held array is refused, not a panic: the client reads the
/// row whole instead.
#[test]
fn a_patch_that_does_not_fit_is_refused() {
    let mut held = json!({"a": [1, 2]});
    assert!(!super::apply(&mut held, &json!({"a": {"$splice": [1, 5, []]}})));
    let mut held = json!({"a": 1});
    assert!(!super::apply(&mut held, &json!({"a": {"$splice": [0, 0, []]}})));
    let mut held = json!({"a": [1]});
    assert!(!super::apply(&mut held, &json!({"a": {"$splice": ["x", 0, []]}})));
}

/// A peer reads rows masked: the patches between two masked rows take the masked old row to
/// the masked new one, and never carry the secret the raw row has.
#[test]
fn a_masked_rows_patch_takes_the_masked_row_on_and_carries_no_secret() {
    let token = format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234");
    let row = |title: &str, prompt: &str| {
        json!({"sessionId": "s", "harness": "claude", "lastSeq": 1, "title": title,
               "lastPrompt": prompt, "status": "running"})
    };
    let old = row("plain", "hello");
    let new = row(&format!("fix {token}"), &format!("use {token} now"));
    let masked = |v: &Value| crate::server::peer_text::masked_row(v).unwrap_or(v.clone());
    let mut rows = SentRows::default();
    assert!(matches!(rows.change("s", true, &masked(&old)), Change::Whole { row_seq: 1 }));
    let Change::Patch { patch, .. } = rows.change("s", true, &masked(&new)) else {
        panic!("a patch")
    };
    assert!(!patch.to_string().contains(&token), "{patch}");
    let mut held = masked(&old);
    apply(&mut held, &patch);
    assert_eq!(held, masked(&new));
    assert_ne!(held["title"], new["title"], "the title is masked");
}

/// A watcher of more busy chats than a peer's link holds settles on patches: after each
/// chat's first row, every change of 370 chats changing in turn is a patch (an idle app,
/// 2026-11-27: 370 chats changed within two minutes, and the bound of 256 sent most
/// changes whole forever). A peer's link keeps its bound, the one its side holds.
#[test]
fn a_local_watcher_of_many_busy_chats_hears_patches_after_the_first_row() {
    let chats = 370;
    let mut local = SentRows::bounded(bound(true));
    let mut link = SentRows::bounded(bound(false));
    let (mut local_whole, mut link_whole) = (0, 0);
    for round in 0..5u64 {
        for i in 0..chats {
            let row = json!({"sessionId": format!("c{i}"), "eventCount": round, "preview": "x".repeat(200)});
            if matches!(local.change(&format!("c{i}"), false, &row), Change::Whole { .. }) {
                local_whole += 1;
            }
            if matches!(link.change(&format!("c{i}"), false, &row), Change::Whole { .. }) {
                link_whole += 1;
            }
        }
    }
    assert_eq!(local_whole, chats, "only each chat's first row goes whole");
    assert!(local.rows.len() == chats);
    assert!(link.rows.len() <= MAX_ROWS);
    assert!(link_whole > chats, "past its bound a link hears rows whole again");
}

/// Past the bound the row sent longest ago goes, never one just sent.
#[test]
fn the_row_sent_longest_ago_goes_first() {
    let mut rows = SentRows::bounded(3);
    for id in ["a", "b", "c"] {
        rows.change(id, false, &json!({"n": 0}));
    }
    // `a` changes again: `b` is now the one sent longest ago.
    assert!(matches!(rows.change("a", false, &json!({"n": 1})), Change::Patch { .. }));
    rows.change("d", false, &json!({"n": 0}));
    assert!(rows.rows.contains_key("a") && !rows.rows.contains_key("b"));
    assert!(matches!(rows.change("a", false, &json!({"n": 2})), Change::Patch { .. }));
    assert!(matches!(rows.change("b", false, &json!({"n": 1})), Change::Whole { row_seq: 1 }));
}
