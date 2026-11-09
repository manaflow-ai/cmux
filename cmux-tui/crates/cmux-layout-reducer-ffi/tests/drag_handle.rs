//! The drag handles (`cmux_sidebar_drag_*`, `cmux_sidebar_tab_drag_*`) answer
//! every move as the JSON ops they replace (`resolve_drag`, `tab_drop`,
//! `tab_refusal`) did, and a move whose reply is unchanged writes nothing.

use cmux_layout_reducer_ffi::drag_handle::*;
use cmux_layout_reducer_ffi::{ERR_BUFFER, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::time::Instant;

const ROW: f64 = 28.0;

/// `count` workspaces in groups of 10 on machine `m`, one other machine's
/// loose workspace last: the rows of the list and the sections they come from.
fn sidebar(count: usize) -> (Value, Value) {
    let mut rows = vec![
        json!({"key": {"kind": "section", "id": {"kind": "machine", "id": "m"}}, "y": 0.0, "height": ROW,
        "section": {"kind": "machine", "id": "m"}, "group": null, "sibling_index": 0, "parent_index": null,
        "is_last_in_group": false, "is_collapsed": false, "child_count": count.div_ceil(10)}),
    ];
    let mut nodes = vec![];
    for (group, start) in (0..count).step_by(10).enumerate() {
        let end = (start + 10).min(count);
        let id = format!("g{start}");
        rows.push(json!({"key": {"kind": "group", "id": id}, "y": rows.len() as f64 * ROW, "height": ROW,
            "section": {"kind": "machine", "id": "m"}, "group": null, "sibling_index": group, "parent_index": null,
            "is_last_in_group": false, "is_collapsed": false, "child_count": end - start}));
        for index in start..end {
            rows.push(json!({"key": {"kind": "workspace", "id": format!("w{index}")}, "y": rows.len() as f64 * ROW,
                "height": ROW, "section": {"kind": "machine", "id": "m"}, "group": id, "sibling_index": index - start,
                "parent_index": group, "is_last_in_group": index + 1 == end, "is_collapsed": false, "child_count": 0}));
        }
        nodes.push(json!({"kind": "group", "id": id, "machine": "m",
            "workspaces": (start..end).map(|i| json!({"id": format!("w{i}"), "machine": "m"})).collect::<Vec<_>>()}));
    }
    nodes.push(json!({"kind": "workspace", "workspace": {"id": "loose", "machine": "m"}}));
    rows.push(json!({"key": {"kind": "workspace", "id": "loose"}, "y": rows.len() as f64 * ROW, "height": ROW,
        "section": {"kind": "machine", "id": "m"}, "group": null, "sibling_index": nodes.len() - 1,
        "parent_index": null, "is_last_in_group": false, "is_collapsed": false, "child_count": 0}));
    (
        Value::Array(rows),
        json!([{"id": {"kind": "machine", "id": "m"}, "machine": "m", "nodes": nodes}]),
    )
}

fn drag_request(count: usize) -> Value {
    let (rows, sections) = sidebar(count);
    json!({"payload": {"kind": "workspaces", "ids": ["w0"]}, "rows": rows, "sections": sections,
        "workspace_onto_start": 0.3, "workspace_onto_end": 0.7})
}

fn tab_request(count: usize) -> Value {
    let (rows, sections) = sidebar(count);
    json!({"y": 0.0, "rows": rows, "sections": sections, "source_machine": "m"})
}

fn json_op(operation: &str, request: &Value) -> Value {
    let bytes = serde_json::to_vec(request).unwrap();
    let op = std::ffi::CString::new(operation).unwrap();
    let mut output = vec![0u8; 1 << 16];
    let mut len = 0;
    let code = unsafe {
        cmux_layout_reducer_json(
            bytes.as_ptr(),
            bytes.len(),
            op.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    assert_eq!(code, OK, "{operation}");
    serde_json::from_slice(&output[..len]).unwrap()
}

/// A handle reply: `Some(json)` when written, `None` for SAME.
fn read(call: impl FnOnce(*mut u8, usize, *mut usize) -> i32) -> Option<Value> {
    let mut output = vec![0u8; 4096];
    let mut len = 0;
    match call(output.as_mut_ptr(), output.len(), &mut len) {
        OK => Some(serde_json::from_slice(&output[..len]).unwrap()),
        SAME => None,
        code => panic!("drag handle answered {code}"),
    }
}

fn new_drag(request: &Value) -> *mut Drag {
    let bytes = serde_json::to_vec(request).unwrap();
    let drag = unsafe { cmux_sidebar_drag_new(bytes.as_ptr(), bytes.len()) };
    assert!(!drag.is_null());
    drag
}

fn new_tab_drag(request: &Value) -> *mut TabDrag {
    let bytes = serde_json::to_vec(request).unwrap();
    let drag = unsafe { cmux_sidebar_tab_drag_new(bytes.as_ptr(), bytes.len()) };
    assert!(!drag.is_null());
    drag
}

#[test]
fn a_drag_move_answers_as_resolve_drag_did_and_unchanged_replies_write_nothing() {
    let request = drag_request(40);
    let drag = new_drag(&request);
    let mut last: Option<Value> = None;
    let gap_y = 5.0 * ROW;
    for step in 0..400 {
        let centre = step as f64 * 0.37 * ROW / 4.0;
        let leading = centre + ROW / 2.0;
        let mut expected = request.clone();
        expected["centre_y"] = json!(centre);
        expected["leading_y"] = json!(leading);
        expected["gap_y"] = json!(gap_y);
        expected["gap_height"] = json!(ROW);
        let expected = json_op("resolve_drag", &expected);
        let reply = read(|o, c, l| unsafe {
            cmux_sidebar_drag_resolve(drag, centre, leading, 1, gap_y, ROW, o, c, l)
        });
        match reply {
            Some(reply) => {
                assert_ne!(Some(&reply), last.as_ref(), "a changed reply only, step {step}");
                assert_eq!(reply, expected, "step {step}");
                last = Some(reply);
            }
            None => {
                assert_eq!(last.as_ref(), Some(&expected), "SAME keeps the last reply, step {step}")
            }
        }
    }
    unsafe { cmux_sidebar_drag_free(drag) };
}

#[test]
fn a_move_keeps_the_handles_onto_band_for_the_next_move() {
    // The loose row is the last one; its middle groups, its top quarter does not.
    let request = drag_request(10);
    let rows = request["rows"].as_array().unwrap().len() as f64;
    let loose = (rows - 1.0) * ROW;
    let drag = new_drag(&request);
    let resolve = |y: f64| {
        read(|o, c, l| unsafe { cmux_sidebar_drag_resolve(drag, y, y, 0, 0.0, 0.0, o, c, l) })
    };
    let onto = resolve(loose + ROW / 2.0).unwrap();
    assert_eq!(onto["target"]["kind"], "onto_workspace");
    let edge = resolve(loose + 2.0).unwrap();
    assert_ne!(edge["target"]["kind"], "onto_workspace");
    assert_eq!(
        resolve(loose + ROW / 2.0).unwrap(),
        onto,
        "the band is the handle's after a move that cleared it"
    );
    unsafe { cmux_sidebar_drag_free(drag) };
}

#[test]
fn a_tab_drag_answers_as_tab_drop_and_tab_refusal_did() {
    let request = tab_request(40);
    let drag = new_tab_drag(&request);
    let (mut drops, mut wholes, mut refusals): (Option<Value>, Option<Value>, Option<Value>) =
        (None, None, None);
    for step in 0..300 {
        let y = step as f64 * 0.41 * ROW / 3.0;
        let mut at = request.clone();
        at["y"] = json!(y);
        let drop = json_op("tab_drop", &at);
        let refusal = json_op("tab_refusal", &at);
        at["tab_into_start"] = json!(0.0);
        at["tab_into_end"] = json!(1.0);
        let whole = json_op("tab_drop", &at);
        for (reply, expected, last) in [
            (
                read(|o, c, l| unsafe { cmux_sidebar_tab_drag_drop(drag, y, 0, o, c, l) }),
                drop,
                &mut drops,
            ),
            (
                read(|o, c, l| unsafe { cmux_sidebar_tab_drag_drop(drag, y, 1, o, c, l) }),
                whole,
                &mut wholes,
            ),
            (
                read(|o, c, l| unsafe { cmux_sidebar_tab_drag_refusal(drag, y, o, c, l) }),
                refusal,
                &mut refusals,
            ),
        ] {
            if let Some(reply) = reply {
                *last = Some(reply);
            }
            assert_eq!(last.as_ref(), Some(&expected), "step {step}");
        }
    }
    unsafe { cmux_sidebar_tab_drag_free(drag) };
}

#[test]
fn a_reply_larger_than_the_buffer_is_written_on_the_retry() {
    let drag = new_drag(&drag_request(10));
    let mut len = 0;
    let code = unsafe {
        cmux_sidebar_drag_resolve(drag, 40.0, 50.0, 0, 0.0, 0.0, std::ptr::null_mut(), 0, &mut len)
    };
    assert_eq!(code, ERR_BUFFER);
    assert!(len > 0);
    assert!(
        read(|o, c, l| unsafe {
            cmux_sidebar_drag_resolve(drag, 40.0, 50.0, 0, 0.0, 0.0, o, c, l)
        })
        .is_some()
    );
    unsafe { cmux_sidebar_drag_free(drag) };
}

#[test]
fn invalid_requests_make_no_handle_and_base_y_skips_the_gap() {
    assert!(unsafe { cmux_sidebar_drag_new(b"{".as_ptr(), 1) }.is_null());
    assert!(unsafe { cmux_sidebar_tab_drag_new(std::ptr::null(), 3) }.is_null());
    let mut y = -1.0;
    assert_eq!(unsafe { cmux_sidebar_base_y(10.0, 1, 20.0, 28.0, &mut y) }, 1);
    assert_eq!(y, 10.0);
    assert_eq!(unsafe { cmux_sidebar_base_y(30.0, 1, 20.0, 28.0, &mut y) }, 0);
    assert_eq!(unsafe { cmux_sidebar_base_y(60.0, 1, 20.0, 28.0, &mut y) }, 1);
    assert_eq!(y, 32.0);
    assert_eq!(unsafe { cmux_sidebar_base_y(60.0, 0, 20.0, 28.0, &mut y) }, 1);
    assert_eq!(y, 60.0);
}

/// The Rust half of one drag move at 50 to 5,000 rows: the JSON op (parse
/// every row, copy them, encode the reply) against the handle (numbers in,
/// the reply only when it changed). Prints `DRAG-HANDLE-COST` lines; the
/// handle must not cost more than the op at any size.
#[test]
fn drag_handle_cost_per_size() {
    for count in [50, 200, 1000, 5000] {
        let request = drag_request(count);
        let height = request["rows"].as_array().unwrap().len() as f64 * ROW;
        let moves = 200;
        let ys: Vec<f64> = (0..moves).map(|i| height * i as f64 / moves as f64).collect();
        let requests: Vec<Value> = ys
            .iter()
            .map(|&y| {
                let mut at = request.clone();
                at["centre_y"] = json!(y);
                at["leading_y"] = json!(y + ROW / 2.0);
                at["gap_y"] = Value::Null;
                at["gap_height"] = json!(ROW);
                at
            })
            .collect();
        let started = Instant::now();
        for at in &requests {
            // Encoding the request is the caller's share of the old crossing.
            let _ = json_op("resolve_drag", at);
        }
        let json_us = started.elapsed().as_secs_f64() * 1e6 / moves as f64;
        let drag = new_drag(&request);
        let mut output = vec![0u8; 4096];
        let started = Instant::now();
        for &y in &ys {
            let mut len = 0;
            let code = unsafe {
                cmux_sidebar_drag_resolve(
                    drag,
                    y,
                    y + ROW / 2.0,
                    0,
                    0.0,
                    ROW,
                    output.as_mut_ptr(),
                    output.len(),
                    &mut len,
                )
            };
            assert!(code == OK || code == SAME);
        }
        let handle_us = started.elapsed().as_secs_f64() * 1e6 / moves as f64;
        unsafe { cmux_sidebar_drag_free(drag) };
        println!("DRAG-HANDLE-COST rows={count} json_op={json_us:.1}us handle={handle_us:.1}us");
        assert!(
            handle_us <= json_us,
            "rows={count}: handle {handle_us:.1}us > json op {json_us:.1}us"
        );
    }
}
