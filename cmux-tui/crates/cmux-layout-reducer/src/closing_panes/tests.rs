use super::*;

fn e(min_x: f64, max_x: f64, min_y: f64, max_y: f64) -> Edges {
    Edges { min_x, max_x, min_y, max_y }
}

fn pane(id: u64, edges: Edges) -> PaneFact {
    PaneFact { id, edges, scrolls: true, area: 0, row_column: 0 }
}

fn live(id: u64, now: Edges, target: Edges) -> FrameFact {
    FrameFact {
        id,
        now,
        target,
        moving: now != target,
        vx: 0.0,
        vy: 0.0,
        vw: 0.0,
        vh: 0.0,
        scrolls: true,
    }
}

/// p1 | p2 | p3 with 4 pt gaps: closing p2 with the divider x (p2 | p3) kept and the one before it gone.
fn three() -> (ClosingPanes, [PaneFact; 3]) {
    let panes = [
        pane(1, e(0.0, 100.0, 0.0, 300.0)),
        pane(2, e(104.0, 200.0, 0.0, 300.0)),
        pane(3, e(204.0, 300.0, 0.0, 300.0)),
    ];
    let gone = HandleFact {
        kind: HandleKind::Split,
        horizontal: true,
        hit: e(98.0, 106.0, 0.0, 300.0),
        mid_x: 102.0,
        mid_y: 150.0,
        kept: false,
        fixed_split: false,
        area: 0,
        docked: false,
        column: 0,
    };
    let kept = HandleFact { hit: e(198.0, 206.0, 0.0, 300.0), mid_x: 202.0, kept: true, ..gone };
    let mut closing = ClosingPanes::new();
    assert!(closing.begin(2, panes[1].edges, &panes, &[gone, kept], 9.0, None, 0.0));
    (closing, panes)
}

/// Swift skips a row travel with `guard abs(target - now) >= 0.5 else { continue }`, so a NaN travel (no finite
/// distance) is no travel. Rust must skip it too, or the pane rides a NaN scroll.
#[test]
fn a_nan_row_travel_is_no_travel_as_in_swift() {
    let top = PaneFact { row_column: 7, ..pane(1, e(0.0, 300.0, 0.0, 100.0)) };
    let closing_pane = PaneFact { row_column: 7, ..pane(2, e(0.0, 300.0, 104.0, 200.0)) };
    let panes = [top, closing_pane];
    let mut closing = ClosingPanes::new();
    assert!(closing.begin(2, closing_pane.edges, &panes, &[], 9.0, None, 0.0));
    let entry = &closing.entries()[&2];
    assert!(
        !entry.min_y.neighbours.is_empty() && entry.max_y.neighbours.is_empty(),
        "one row side only"
    );
    let frames = [live(1, top.edges, top.edges)];
    let nan = [RowTravel { column: 7, now: f64::NAN, target: 50.0 }];
    closing.settle(&frames, &nan);
    if let Some(entry) = closing.entries().get(&2) {
        assert_eq!(entry.row_travel, None);
    }
}

#[test]
fn a_side_keeps_the_gap_of_a_kept_handle_and_covers_a_gone_one() {
    let (closing, _) = three();
    let entry = &closing.entries()[&2];
    assert_eq!((entry.min_x.neighbours.as_slice(), entry.min_x.gap), (&[1][..], 0.0));
    assert_eq!((entry.max_x.neighbours.as_slice(), entry.max_x.gap), (&[3][..], 4.0));
    assert!(entry.min_y.neighbours.is_empty() && entry.max_y.neighbours.is_empty());
}

#[test]
fn a_pane_rides_its_neighbours_and_rests_at_zero_size() {
    let (mut closing, _) = three();
    let frames = [
        live(1, e(0.0, 150.0, 0.0, 300.0), e(0.0, 200.0, 0.0, 300.0)),
        live(3, e(204.0, 300.0, 0.0, 300.0), e(204.0, 300.0, 0.0, 300.0)),
    ];
    assert!(closing.settle(&frames, &[]).is_empty(), "p1 springs over it");
    let placed = closing.rects(&frames, &[], 0.0, 0.0).to_vec();
    assert_eq!(placed, vec![(2, Placed { x: 150.0, y: 0.0, width: 50.0, height: 300.0 })]);
    let rest = [live(1, e(0.0, 200.0, 0.0, 300.0), e(0.0, 200.0, 0.0, 300.0)), frames[1]];
    assert_eq!(
        closing.rects(&rest, &[], 0.0, 0.0),
        &[(2, Placed { x: 200.0, y: 0.0, width: 0.0, height: 300.0 })]
    );
}

#[test]
fn a_pane_nothing_moves_over_goes_at_once() {
    let (mut closing, panes) = three();
    let frames = [live(1, panes[0].edges, panes[0].edges), live(3, panes[2].edges, panes[2].edges)];
    assert_eq!(closing.settle(&frames, &[]), vec![2]);
    assert!(!closing.has_awaiting());
}

#[test]
fn a_taken_back_close_starts_with_its_neighbours_speed() {
    let (mut closing, _) = three();
    let mut moving = live(1, e(0.0, 150.0, 0.0, 300.0), e(0.0, 200.0, 0.0, 300.0));
    moving.vw = 30.0;
    let frames = [moving, live(3, e(204.0, 300.0, 0.0, 300.0), e(204.0, 300.0, 0.0, 300.0))];
    closing.rects(&frames, &[], 0.0, 0.0);
    let taken = closing.remove(2, &frames, 0.0).expect("closing");
    assert_eq!((taken.rect.x, taken.vx, taken.vw), (150.0, 30.0, -30.0));
    assert!(closing.is_empty() && closing.order().is_empty());
    assert_eq!(closing.remove(2, &frames, 0.0), None);
}

#[test]
fn swift_min_and_max_keep_swift_s_answer_on_a_tie_and_nan() {
    // On a tie Swift's min keeps its first argument and max its second.
    assert_eq!(swift_min(0.0, -0.0).to_bits(), 0.0f64.to_bits());
    assert_eq!(swift_min(-0.0, 0.0).to_bits(), (-0.0f64).to_bits());
    assert_eq!(swift_max(-0.0, 0.0).to_bits(), 0.0f64.to_bits());
    assert_eq!(swift_max(0.0, -0.0).to_bits(), (-0.0f64).to_bits());
    assert!(swift_min(f64::NAN, 1.0).is_nan());
    assert_eq!(swift_max(0.0, f64::NAN), 0.0);
    assert_eq!(least(&[2.0, f64::NAN, 1.0]), Some(1.0));
    assert_eq!(most(&[]), None);
}
