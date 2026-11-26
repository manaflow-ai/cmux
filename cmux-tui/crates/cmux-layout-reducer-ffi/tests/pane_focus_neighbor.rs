//! The focus keys' rule (`layout_pane_neighbor`, cmux-layout-reducer
//! `pane_focus`), replayed against schemas/pane-focus-neighbor/vectors.json.
//!
//! The vectors were written from a transliteration of the Swift
//! `FocusNavigation.neighbor` before the Mac app moved to the Rust rule: random
//! split screens (gaps, uneven splits, an overlapping pane, ids whose text
//! order breaks ties), with and without focus history and columns. Each layout
//! is sent as the app's `FocusNavigation` sends it: one row per pane that has a
//! frame or a column, `order` the place of its id among the ids in text order,
//! `recency` its first place in the history, `column` the first column that
//! holds it. CmuxNextAppTests' `PaneFocusNeighborVectorTests` replays the same
//! file through `FocusNavigation`.

use cmux_layout_reducer_ffi::{ERR_BUFFER, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::collections::BTreeSet;

const VECTORS: &str = include_str!("../../../../schemas/pane-focus-neighbor/vectors.json");

fn call(operation: &std::ffi::CStr, request: &Value) -> Value {
    let request = serde_json::to_vec(request).unwrap();
    let mut capacity = 4096;
    loop {
        let mut output = vec![0u8; capacity];
        let mut len = 0usize;
        let code = unsafe {
            cmux_layout_reducer_json(
                request.as_ptr(),
                request.len(),
                operation.as_ptr(),
                output.as_mut_ptr(),
                output.len(),
                &mut len,
            )
        };
        if code == ERR_BUFFER && len > capacity {
            capacity = len;
            continue;
        }
        assert_eq!(code, OK, "{operation:?} refused {}", String::from_utf8_lossy(&request));
        return serde_json::from_slice(&output[..len]).unwrap();
    }
}

fn strings(value: &Value) -> Vec<&str> {
    value.as_array().unwrap().iter().map(|item| item.as_str().unwrap()).collect()
}

#[test]
fn every_focus_key_lands_where_the_swift_rule_did() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    assert_eq!(vectors["v"], 1);
    let layouts = vectors["cases"].as_array().unwrap();
    assert!(layouts.len() >= 150);
    let mut moved = 0;
    for (number, layout) in layouts.iter().enumerate() {
        let frames = layout["frames"].as_object().unwrap();
        let recency = strings(&layout["recency"]);
        let columns: Vec<Vec<&str>> =
            layout["columns"].as_array().unwrap().iter().map(strings).collect();
        let ids: Vec<&str> = frames
            .keys()
            .map(String::as_str)
            .chain(columns.iter().flatten().copied())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let panes: Vec<Value> = ids
            .iter()
            .enumerate()
            .map(|(order, id)| {
                let frame = frames.get(*id).map(
                    |frame| json!({"x": frame[0], "y": frame[1], "w": frame[2], "h": frame[3]}),
                );
                json!({
                    "frame": frame,
                    "column": columns.iter().position(|column| column.contains(id)),
                    "recency": recency.iter().position(|recent| recent == id),
                    "order": order,
                })
            })
            .collect();
        for step in layout["moves"].as_array().unwrap() {
            let (pane, direction, want) = (step[0].as_str().unwrap(), &step[1], &step[2]);
            let context = format!("layout {number}: {pane} {direction}");
            // The app asks only for a pane with a frame (`FocusNavigation` answers nil before).
            let got =
                match ids.iter().position(|id| *id == pane).filter(|_| frames.contains_key(pane)) {
                    Some(source) => {
                        let answer = call(
                            c"layout_pane_neighbor",
                            &json!({"panes": panes, "source": source, "direction": direction}),
                        );
                        answer["index"].as_u64().map(|index| json!(ids[index as usize]))
                    }
                    None => None,
                };
            assert_eq!(got.as_ref().unwrap_or(&Value::Null), want, "{context}");
            moved += usize::from(!want.is_null());
        }
    }
    assert!(moved > 1000, "the vectors move the focus {moved} times");
}

#[test]
fn a_request_with_no_rows_finds_nothing_and_a_bad_one_is_refused() {
    let answer =
        call(c"layout_pane_neighbor", &json!({"panes": [], "source": 0, "direction": "left"}));
    assert_eq!(answer, json!({"index": null}));
    let request = br#"{"panes": [], "source": 0, "direction": "sideways"}"#;
    let mut output = [0u8; 64];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"layout_pane_neighbor".as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    assert_ne!(code, OK);
}
