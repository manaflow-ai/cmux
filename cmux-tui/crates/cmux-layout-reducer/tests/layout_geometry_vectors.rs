//! The layout geometry rules' vectors (`tests/data/layout_geometry_vectors.json`): random requests for
//! every `layout_geometry_*` operation, answered by a line-by-line transliteration of the Swift
//! (`CmuxNextLayout/Geometry` DropZoneGeometry, DockStripGeometry, DividerBand, PaneChromeGeometry;
//! `layout_geometry_split_vectors.json`: SplitGeometry, EvenSplitRatios, PushResize, RowStackGeometry,
//! RowResize, StripStart, UniformEdge, KeepAliveBand; `layout_geometry_strip_vectors.json`: ColumnGeometry,
//! StripScrollbarGeometry, ColumnEqualizer, ScrollAreaGeometry, WindowFrameGeometry, MovedWindowPlacement,
//! ColumnWidthLedger).
//! Every case answers the Swift's reply; numbers compare as f64.

use cmux_layout_reducer::geometry::wire;
use serde_json::Value;

fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => {
            let (x, y) = (x.as_f64().expect("f64"), y.as_f64().expect("f64"));
            x == y || (x - y).abs() <= 1e-9 * x.abs().max(y.abs()).max(1.)
        }
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(x, y)| same(x, y))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

fn replay(vectors: &str) {
    let cases: Vec<Value> = serde_json::from_str(vectors).expect("vectors");
    assert!(cases.len() >= 1000, "the vectors lost cases: {}", cases.len());
    for (index, case) in cases.iter().enumerate() {
        let op = case["op"].as_str().expect("op");
        assert!(wire::serves(op), "{index}: {op} is not served");
        let answer = wire::call(op, case["request"].clone())
            .unwrap_or_else(|e| panic!("{index} {op}: refused: {e}"));
        assert!(
            same(&answer, &case["response"]),
            "{index} {op}\nrequest {}\nswift   {}\nrust    {}",
            case["request"],
            case["response"],
            answer
        );
    }
}

#[test]
fn layout_geometry_vectors_answer_the_swift_rules() {
    replay(include_str!("data/layout_geometry_vectors.json"));
}

#[test]
fn layout_geometry_split_vectors_answer_the_swift_rules() {
    replay(include_str!("data/layout_geometry_split_vectors.json"));
}

#[test]
fn layout_geometry_strip_vectors_answer_the_swift_rules() {
    replay(include_str!("data/layout_geometry_strip_vectors.json"));
}

#[test]
fn layout_geometry_refuses_an_unknown_op_and_a_bad_request() {
    assert!(wire::call("layout_geometry_nope", Value::Null).is_err());
    assert!(wire::call("layout_geometry_drop_zone", Value::Null).is_err());
}
