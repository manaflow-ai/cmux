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
