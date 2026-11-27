//! Replays schemas/agent-cursor-visibility/vectors.json against the Rust
//! rules: every rule of the agent cursor's visibility (CURSOR-HIDDEN,
//! CURSOR-SHOW, CURSOR-SCREENS). The macOS app's Swift resolver replayed the
//! same file (AgentCursorVisibilityVectorTests, deleted 2026-10-10 with the
//! CmuxNext unit suites); its vector test is ported here as it was, plus the
//! page scale the Swift resolver added later (cx-d077f).

use cmux_focus_core::agent_cursor_visibility::{
    Anchor, Edge, NotDrawnReason, Page, Rect, Snapshot, Visibility, resolve,
};
use serde::Deserialize;

const VECTORS: &str = include_str!("../../../../schemas/agent-cursor-visibility/vectors.json");

#[derive(Deserialize)]
struct Case {
    name: String,
    target: String,
    snapshot: Snapshot,
    /// The same shape the `agent_cursor_visibility` operation answers; a
    /// `visible` case without `scale` expects 1.
    expect: Visibility,
}

#[derive(Deserialize)]
struct Vectors {
    v: u32,
    cases: Vec<Case>,
}

fn vectors() -> Vectors {
    serde_json::from_str(VECTORS).expect("schemas/agent-cursor-visibility/vectors.json parses")
}

#[test]
fn agent_cursor_visibility_every_shared_vector_resolves() {
    let vectors = vectors();
    assert_eq!(vectors.v, 1);
    assert!(vectors.cases.len() >= 26, "{} cases", vectors.cases.len());
    let failed: Vec<String> = vectors
        .cases
        .iter()
        .filter_map(|case| {
            let got = resolve(&case.target, &case.snapshot);
            (got != case.expect)
                .then(|| format!("{}: got {got:?}, expected {:?}", case.name, case.expect))
        })
        .collect();
    assert!(
        failed.is_empty(),
        "{} of {} vectors differ:\n{}",
        failed.len(),
        vectors.cases.len(),
        failed.join("\n")
    );
}

/// The answer serializes to the vectors' `expect` shape (what the app decodes).
#[test]
fn agent_cursor_visibility_answer_round_trips_the_expect_shape() {
    for case in vectors().cases {
        let json = serde_json::to_value(&case.expect).unwrap();
        let back: Visibility = serde_json::from_value(json.clone()).unwrap();
        assert_eq!(back, case.expect, "{}: {json}", case.name);
        let kind = json["kind"].as_str().unwrap();
        assert!(["visible", "hidden", "notDrawn"].contains(&kind), "{}: {kind}", case.name);
    }
    for anchor in [
        Anchor::TabChip,
        Anchor::TabStrip,
        Anchor::ColumnEdge(Edge::Leading),
        Anchor::ColumnEdge(Edge::Trailing),
        Anchor::ColumnEdge(Edge::Top),
        Anchor::ColumnEdge(Edge::Bottom),
        Anchor::WorkspaceRow,
        Anchor::WindowEdge,
    ] {
        assert_eq!(Anchor::parse(anchor.as_str()), Some(anchor));
    }
    let not_drawn =
        serde_json::to_value(Visibility::NotDrawn { reason: NotDrawnReason::OtherSpace });
    assert_eq!(not_drawn.unwrap(), serde_json::json!({"kind": "notDrawn", "reason": "otherSpace"}));
}

/// A fitted page's emulation scale comes back as `scale`; no scale is 1.
#[test]
fn agent_cursor_visibility_visible_page_reports_its_scale() {
    let base = vectors().cases.into_iter().find(|c| c.name == "selected_tab_visible").unwrap();
    let mut snapshot = base.snapshot;
    let page: &mut Option<Page> = &mut snapshot.windows[0].panes[0].page;
    page.as_mut().unwrap().scale = Some(0.5);
    let viewport = Rect { x: 0.0, y: 72.0, w: 500.0, h: 628.0 };
    assert_eq!(
        resolve(&base.target, &snapshot),
        Visibility::Visible {
            window: "w1".into(),
            viewport,
            clip: viewport,
            zoom: 1.0,
            scale: 0.5
        }
    );
    snapshot.windows[0].panes[0].page.as_mut().unwrap().scale = None;
    let Visibility::Visible { scale, .. } = resolve(&base.target, &snapshot) else {
        panic!("not visible")
    };
    assert_eq!(scale, 1.0);
}

fn raw_case(name: &str) -> serde_json::Value {
    let vectors: serde_json::Value = serde_json::from_str(VECTORS).unwrap();
    vectors["cases"].as_array().unwrap().iter().find(|c| c["name"] == name).unwrap().clone()
}

fn resolve_raw(case: &serde_json::Value) -> Visibility {
    let snapshot: Snapshot = serde_json::from_value(case["snapshot"].clone()).unwrap();
    resolve(case["target"].as_str().unwrap(), &snapshot)
}

/// Non-finite numbers cross the wire as "inf", "-inf" and "nan" (the app's JSONEncoder refuses
/// them as numbers) and keep the Swift rules' results: a `CGRect.null` the app converted
/// (x and y infinite, no size) never shows, an anchor built from one keeps its infinite origin,
/// and an infinite page scale comes back as it went in.
#[test]
fn agent_cursor_visibility_non_finite_numbers_cross_the_wire() {
    let null = serde_json::json!({"x": "inf", "y": "inf", "w": 0, "h": 0});
    let inf = f64::INFINITY;

    // A null chip does not show: the strip anchors.
    let mut case = raw_case("background_tab_points_at_its_chip");
    case["snapshot"]["windows"][0]["panes"][0]["chips"]["tab-a"] = null.clone();
    assert_eq!(
        resolve_raw(&case),
        Visibility::Hidden {
            window: "w1".into(),
            anchor: Anchor::TabStrip,
            rect: Rect { x: 0.0, y: 0.0, w: 500.0, h: 36.0 }
        }
    );

    // A null sidebar row is still the row anchor, at its infinite origin.
    let mut case = raw_case("other_workspace_same_window_points_at_sidebar_row");
    case["snapshot"]["windows"][0]["sidebarRows"]["ws1"] = null.clone();
    let answer = resolve_raw(&case);
    assert_eq!(
        answer,
        Visibility::Hidden {
            window: "w1".into(),
            anchor: Anchor::WorkspaceRow,
            rect: Rect { x: inf, y: inf, w: 0.0, h: 0.0 }
        }
    );
    let wire = serde_json::to_value(&answer).unwrap();
    assert_eq!(wire["rect"], serde_json::json!({"x": "inf", "y": "inf", "w": 0.0, "h": 0.0}));

    // A null overlay: the window edge at the overlay's infinite origin, 4 wide, 0 high.
    let mut case = raw_case("target_pane_missing_points_at_window_edge");
    case["snapshot"]["windows"][0]["overlay"] = null;
    assert_eq!(
        resolve_raw(&case),
        Visibility::Hidden {
            window: "w1".into(),
            anchor: Anchor::WindowEdge,
            rect: Rect { x: inf, y: inf, w: 4.0, h: 0.0 }
        }
    );

    // An infinite scale and a NaN zoom come back as they went in.
    let mut case = raw_case("selected_tab_visible");
    case["snapshot"]["windows"][0]["panes"][0]["page"]["scale"] = "inf".into();
    case["snapshot"]["windows"][0]["panes"][0]["page"]["zoom"] = "nan".into();
    let answer = resolve_raw(&case);
    let Visibility::Visible { zoom, scale, .. } = answer.clone() else { panic!("not visible") };
    assert!(zoom.is_nan());
    assert_eq!(scale, inf);
    let wire = serde_json::to_value(&answer).unwrap();
    assert_eq!(wire["zoom"], "nan");
    assert_eq!(wire["scale"], "inf");
    let back: Visibility = serde_json::from_value(wire).unwrap();
    let Visibility::Visible { zoom, scale, .. } = back else { panic!("not visible") };
    assert!(zoom.is_nan() && scale == inf);
    assert_eq!(
        serde_json::from_value::<Rect>(serde_json::json!({"x": "-inf", "y": 1, "w": 2.5, "h": 3}))
            .unwrap(),
        Rect { x: f64::NEG_INFINITY, y: 1.0, w: 2.5, h: 3.0 }
    );
}
