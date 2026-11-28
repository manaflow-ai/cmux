//! `TitleRoll.swift`, `TitleFade.swift` and `MarqueeLabel.swift`.

use cmux_design_core::ops::call;
use cmux_design_core::tokens::text::title::*;
use serde_json::json;

fn roll(old: &str, new: &str) -> RollInput {
    RollInput {
        has_host: true,
        hidden: false,
        opacity: 1.0,
        old: old.into(),
        new: new.into(),
        animates_movement: true,
        can_animate: true,
        fade_in_duration: 0.18,
    }
}

#[test]
fn constants() {
    assert_eq!(ROLL_OUT_NAME, "cmux.titleRoll.out");
    assert_eq!(ROLL_KEYS, ["opacity", "transform.translation.y", "filters.blur.inputRadius"]);
    assert_eq!((ROLL_RISE_EM, ROLL_BLUR_RADIUS), (0.6, 2.0));
    assert_eq!(
        (FADE_KEY_PATH, FADE_KEY, FADE_EDGE_KEY, FADE_FOLLOW_KEY),
        ("transform.translation.x", "marquee", "marquee.edge", "follow.")
    );
    assert_eq!(FADE_MASK_ALPHAS, [0.0, 1.0, 1.0, 0.0, 0.0]);
    assert_eq!((FADE_MASK_START, FADE_MASK_END), ((0.0, 0.5), (1.0, 0.5)));
    assert_eq!(SPRING_BACK_THRESHOLD, 0.5);
}

/// TitleRollTests: a changed shown title rolls; hidden, reduce-motion, empty or same words do not.
#[test]
fn roll_guard() {
    assert!(rolls(&roll("main", "feature")));
    assert!(!rolls(&RollInput { opacity: 0.0, ..roll("a", "b") }));
    assert!(!rolls(&RollInput { hidden: true, ..roll("a", "b") }));
    assert!(!rolls(&RollInput { has_host: false, ..roll("a", "b") }));
    assert!(!rolls(&RollInput { animates_movement: false, ..roll("a", "b") }));
    assert!(!rolls(&RollInput { can_animate: false, ..roll("a", "b") }));
    assert!(!rolls(&RollInput { fade_in_duration: 0.0, ..roll("a", "b") }));
    assert!(!rolls(&roll("", "b")));
    assert!(!rolls(&roll("a", "")));
    assert!(!rolls(&roll("same", "same")));
}

/// TitleRollTests: the rise is up on screen, negative when the host is flipped.
#[test]
fn roll_rise_pins() {
    // 13 * 0.6 = 7.8 -> 8.
    assert_eq!(roll_rise(13.0, false), 8.0);
    assert_eq!(roll_rise(13.0, true), -8.0);
    // 15 * 0.6 = 9 (no rounding); 11 * 0.6 = 6.6 -> 7.
    assert_eq!(roll_rise(15.0, true), -9.0);
    assert_eq!(roll_rise(11.0, false), 7.0);
    let plan = roll_plan(13.0, true, 0.7, 1.0);
    assert_eq!(plan.rise, -8.0);
    assert_eq!(plan.out_opacity, Span { from: 1.0, to: 0.0 });
    assert_eq!(plan.out_translation_y, Span { from: 0.0, to: -8.0 });
    assert_eq!(plan.out_blur, Span { from: 0.0, to: 2.0 });
    assert_eq!(plan.text_opacity, Span { from: 0.0, to: 0.7 });
    assert_eq!(plan.text_translation_y, Span { from: 9.0, to: 1.0 });
    assert_eq!(plan.text_blur, Span { from: 2.0, to: 0.0 });
}

#[test]
fn roll_end() {
    assert!(roll_end_clears_blur(false, true));
    assert!(!roll_end_clears_blur(true, true));
    assert!(!roll_end_clears_blur(false, false));
}

#[test]
fn unclipped_fade() {
    assert_eq!(open_locations(8.0, 200.0), [0.0, 0.04, 1.0, 1.0, 1.0]);
    assert_eq!(open_locations(8.0, 0.0), [0.0, 8.0, 1.0, 1.0, 1.0]);
    assert!(unclipped_keeps_mask(true, false, true));
    assert!(unclipped_keeps_mask(false, true, true));
    assert!(!unclipped_keeps_mask(true, true, false));
    assert!(!unclipped_keeps_mask(false, false, true));
    let open = open_locations(8.0, 200.0);
    assert_eq!(unclipped_from(Some(&[0.0, 0.1, 0.7, 0.8, 1.0]), open), [0.0, 0.1, 1.0, 1.0, 1.0]);
    assert_eq!(unclipped_from(Some(&[0.0, 0.1]), open), open);
    assert_eq!(unclipped_from(None, open), open);
    assert!(unclipped_settled(Some(&open), open));
    assert!(!unclipped_settled(None, open));
}

#[test]
fn clipped_fade() {
    let stops = [0.0, 0.04, 0.8, 0.95, 1.0];
    assert_eq!(clipped_stops(false, None, stops, false), ClippedStops::Set);
    assert_eq!(clipped_stops(true, Some(&stops), stops, true), ClippedStops::Set);
    assert_eq!(clipped_stops(true, None, stops, true), ClippedStops::Fade { from: None });
    assert_eq!(
        clipped_stops(true, None, stops, false),
        ClippedStops::Fade { from: Some([0.0, 0.04, 1.0, 1.0, 1.0]) }
    );
    assert!(restarts_marquee(true, None, 30.0));
    assert!(restarts_marquee(true, Some(20.0), 30.0));
    assert!(!restarts_marquee(true, Some(30.0), 30.0));
    assert!(!restarts_marquee(false, Some(20.0), 30.0));
}

#[test]
fn follow() {
    let mask = [0.0, 0.1, 0.8, 0.9, 1.0];
    assert_eq!(follow_locations(true, mask, 8.0, 92.0), mask);
    assert_eq!(follow_locations(false, mask, 8.0, 92.0), [0.0, 0.08, 1.0, 1.0, 1.0]);
    assert_eq!(follow_width(80.2, &[60.0, 90.0]), 90.0);
    assert_eq!(follow_width(80.2, &[60.0]), 81.0);
    assert_eq!(follow_filled(&[false, true, false, true, false]), Some(vec![1, 1, 1, 3, 3]));
    assert_eq!(follow_filled(&[false, false]), None);
    assert_eq!(follow_filled(&[]), None);
    assert!(follow_changes(&[1.0, 1.0, 2.0]));
    assert!(!follow_changes(&[1.0, 1.0]));
    assert!(!follow_changes::<f64>(&[]));
    assert!(follow_changes(&[mask, [0.0; 5]]));
}

#[test]
fn marquee_rules() {
    let all = MarqueeStart {
        active: false,
        has_geometry: true,
        truncated: true,
        masked: true,
        animations: true,
    };
    assert!(starts_marquee(&all));
    assert!(!starts_marquee(&MarqueeStart { active: true, ..all }));
    assert!(!starts_marquee(&MarqueeStart { truncated: false, ..all }));
    assert!(!starts_marquee(&MarqueeStart { masked: false, ..all }));
    assert!(!starts_marquee(&MarqueeStart { animations: false, ..all }));
    assert!(!starts_marquee(&MarqueeStart { has_geometry: false, ..all }));
    let rest = [0.0, 0.04, 0.8, 0.95, 1.0];
    assert_eq!(marquee_edge(rest, rest, 12.0, 8.0), None);
    assert_eq!(marquee_edge(rest, [0.06, 0.1, 0.8, 0.95, 1.0], 12.0, 8.0), Some(12.0));
    assert_eq!(marquee_edge(rest, [0.0; 5], 6.0, 8.0), Some(8.0));
    assert!(springs_back(true, -0.6, true));
    assert!(!springs_back(true, 0.5, true));
    assert!(!springs_back(false, 20.0, true));
    assert!(!springs_back(true, 20.0, false));
    assert!(eases_edge_back(Some(&[0.1]), Some(&[0.0])));
    assert!(!eases_edge_back(Some(&[0.0]), Some(&[0.0])));
    assert!(!eases_edge_back(None, Some(&[0.0])));
    assert!(drops_open_mask(Some(false), true, false, false));
    assert!(!drops_open_mask(None, true, false, false));
    assert!(!drops_open_mask(Some(true), true, false, false));
    assert!(!drops_open_mask(Some(false), false, false, false));
    assert!(!drops_open_mask(Some(false), true, true, false));
    assert!(!drops_open_mask(Some(false), true, false, true));
}

#[test]
fn marquee_label() {
    // 12.38 + 3.15 + 0.1 = 15.63 -> 16.
    assert_eq!(marquee_intrinsic_size(80.2, 12.38, -3.15, 0.1), (81.0, 16.0));
    let g = marquee_geometry_input(120.0, 100.0, 30.0, 8.0, 12.0);
    assert_eq!(
        g,
        MarqueeGeometryInput {
            text_width: 120.0,
            span: 100.0,
            visible_width: 70.0,
            leading_padding: 8.0,
            trailing_padding: 0.0,
            fade_width: 12.0
        }
    );
    assert_eq!(marquee_geometry_input(120.0, 20.0, 30.0, 8.0, 12.0).visible_width, 0.0);
}

#[test]
fn ops() {
    let r = json!({"hasHost": true, "opacity": 1, "old": "a", "new": "b", "animatesMovement": true, "canAnimate": true, "fadeInDuration": 0.2});
    assert_eq!(call("tokens.text_roll", &r).unwrap(), json!({"rolls": true}));
    let mut hidden = r;
    hidden["opacity"] = json!(0);
    assert_eq!(call("tokens.text_roll", &hidden).unwrap(), json!({"rolls": false}));
    let plan = call(
        "tokens.text_roll_plan",
        &json!({"pointSize": 13, "flipped": true, "opacity": 1, "rest": 0}),
    )
    .unwrap();
    assert_eq!(plan["rise"], json!(-8.0));
    assert_eq!(plan["textTranslationY"], json!({"from": 8.0, "to": 0.0}));
    assert_eq!(
        call("tokens.text_roll_end", &json!({"hostHasRollOut": false, "textInHost": true}))
            .unwrap(),
        json!({"clearsBlur": true})
    );
    assert_eq!(
        call("tokens.text_roll_constants", &json!({})).unwrap()["cancelKeys"],
        json!(ROLL_KEYS)
    );
    assert_eq!(
        call("tokens.text_fade_unclipped", &json!({"animated": true, "masked": true, "leadingPadding": 8, "width": 200, "current": [0, 0.04, 1, 1, 1]})).unwrap(),
        json!({"keepsMask": true, "open": [0.0, 0.04, 1.0, 1.0, 1.0], "settled": true, "from": [0.0, 0.04, 1.0, 1.0, 1.0]})
    );
    assert_eq!(
        call("tokens.text_fade_clipped", &json!({"animated": true, "locations": [0, 0.04, 0.8, 0.95, 1], "marqueeActive": true, "travel": 30})).unwrap(),
        json!({"stops": {"kind": "fade", "from": [0.0, 0.04, 1.0, 1.0, 1.0]}, "restartsMarquee": true})
    );
    let follow = call(
        "tokens.text_fade_follow",
        &json!({"targetTextWidth": 80.2, "samples": [
            {"shown": false, "span": 10},
            {"shown": true, "span": 92, "leadingPadding": 8},
            {"shown": true, "span": 60, "truncated": true, "maskLocations": [0, 0.1, 0.8, 0.9, 1]}
        ]}),
    )
    .unwrap();
    assert_eq!(follow["filled"], json!([1, 1, 2]));
    assert_eq!(follow["width"], json!(92.0));
    assert_eq!(follow["stopsChange"], json!(true));
    assert_eq!(follow["stops"][0], json!([0.0, 0.08, 1.0, 1.0, 1.0]));
    assert_eq!(
        call(
            "tokens.text_fade_follow",
            &json!({"targetTextWidth": 10, "samples": [{"shown": false}]})
        )
        .unwrap(),
        json!({"width": null, "filled": null, "stopsChange": null, "stops": null})
    );
    assert_eq!(
        call("tokens.text_fade_marquee_start", &json!({"hasGeometry": true, "truncated": true, "masked": true, "animations": true, "rest": [0, 0, 1, 1, 1], "scrolled": [0.1, 0.2, 1, 1, 1], "fadeWidth": 12, "leadingPadding": 8})).unwrap(),
        json!({"starts": true, "edgeReach": 12.0})
    );
    assert_eq!(
        call("tokens.text_fade_stop", &json!({"animated": true, "shown": -3, "animatesMovement": true, "shownStops": [0.1], "rest": [0]})).unwrap(),
        json!({"springsBack": true, "easesEdgeBack": true})
    );
    assert_eq!(
        call("tokens.text_fade_drop_mask", &json!({"truncated": false, "masked": true})).unwrap(),
        json!({"drops": true})
    );
    assert_eq!(
        call(
            "tokens.text_marquee_intrinsic",
            &json!({"textWidth": 80.2, "ascender": 12.38, "descender": -3.15, "leading": 0.1})
        )
        .unwrap(),
        json!({"width": 81.0, "height": 16.0})
    );
    assert_eq!(
        call("tokens.text_marquee_geometry", &json!({"textWidth": 120, "boundsWidth": 100, "trailingOcclusion": 30, "leadingPadding": 8, "fadeWidth": 12})).unwrap(),
        json!({"textWidth": 120.0, "span": 100.0, "visibleWidth": 70.0, "leadingPadding": 8.0, "trailingPadding": 0.0, "fadeWidth": 12.0})
    );
}
