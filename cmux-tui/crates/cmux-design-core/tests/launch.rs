//! Parity with LaunchDisplayTests, LaunchLayoutSettleTests, LaunchPageDeferralTests,
//! LaunchShellTests (the pure parts) and BrowserPageFramesTests' frame file names, value for
//! value, plus the `launch.*` ops through `ops::call`.

use cmux_design_core::launch::deferral::{Event, MARK_CREATED, MARK_DEFERRED, PageDeferral};
use cmux_design_core::launch::display::LaunchDisplay;
use cmux_design_core::launch::files;
use cmux_design_core::launch::record::LaunchRecordRequest;
use cmux_design_core::launch::settle::{self, Move, Tally};
use cmux_design_core::launch::shell::{self, FrameRequest};
use cmux_design_core::ops;
use serde_json::{Value, json};
use std::collections::HashMap;

// BrowserPageFramesTests (LaunchFrameFiles)

#[test]
fn frame_files_are_named_per_scale_and_owned_by_their_key() {
    assert_eq!(files::name("tab_ab12", 2), "tab_ab12@2x.jpg");
    assert_eq!(files::name("tab_ab12", 9), "tab_ab12@3x.jpg");
    assert_eq!(files::name("tab_ab12", 0), "tab_ab12@1x.jpg");
    assert_eq!(files::owner("tab_ab12@1x.jpg").as_deref(), Some("tab_ab12"));
    assert_eq!(files::owner("tab_ab12@2x.jpg.sb-1234"), None, "a temp file is no frame");
    assert_eq!(files::owner("tab_ab12@4x.jpg"), None);
    assert_eq!(files::owner("a@b@3x.jpg").as_deref(), Some("a@b"));
    assert_eq!(files::owner("tab@22x.jpg"), None);
    assert_eq!(files::owner("tab2x.jpg"), None);
    assert!(!files::is_file_safe("../escape"));
    assert!(files::is_file_safe("tab_0f9e-1"));
    assert!(!files::is_file_safe(""));
    assert!(files::is_file_safe(&"a".repeat(128)));
    assert!(!files::is_file_safe(&"a".repeat(129)));
    assert!(!files::is_file_safe("tab é"));
}

// LaunchDisplayTests (frame and ownerScreen stay with the window placement)

#[test]
fn a_tagged_dev_build_defaults_to_the_built_in_display() {
    assert_eq!(LaunchDisplay::parse(None, true), Some(LaunchDisplay::BuiltIn));
    assert_eq!(LaunchDisplay::parse(Some("  "), true), Some(LaunchDisplay::BuiltIn));
    assert_eq!(LaunchDisplay::parse(Some("BuiltIn"), true), Some(LaunchDisplay::BuiltIn));
}

#[test]
fn nightly_and_stable_keep_the_usual_placement_unless_asked() {
    assert_eq!(LaunchDisplay::parse(None, false), None);
    assert_eq!(LaunchDisplay::parse(Some("builtin"), false), Some(LaunchDisplay::BuiltIn));
}

#[test]
fn the_environment_overrides_the_default() {
    assert_eq!(LaunchDisplay::parse(Some("off"), true), None);
    assert_eq!(LaunchDisplay::parse(Some("main"), true), Some(LaunchDisplay::Index(0)));
    assert_eq!(LaunchDisplay::parse(Some("1"), true), Some(LaunchDisplay::Index(1)));
    assert_eq!(LaunchDisplay::parse(Some("-1"), true), None);
    assert_eq!(LaunchDisplay::parse(Some("xdr"), true), None);
    assert_eq!(LaunchDisplay::parse(Some("\u{a0}Internal\t"), false), Some(LaunchDisplay::BuiltIn));
    assert_eq!(LaunchDisplay::parse(Some("built-in"), false), Some(LaunchDisplay::BuiltIn));
    assert_eq!(LaunchDisplay::parse(Some("\n1"), true), None, "whitespaces trims no line break");
}

#[test]
fn an_index_picks_that_screen_and_one_past_the_end_picks_the_last() {
    assert_eq!(LaunchDisplay::Index(0).screen_index(&[false, true]), Some(0));
    assert_eq!(LaunchDisplay::Index(5).screen_index(&[false, true]), Some(1));
    assert_eq!(LaunchDisplay::BuiltIn.screen_index(&[false, true]), Some(1));
    assert_eq!(LaunchDisplay::BuiltIn.screen_index(&[false]), None);
    assert_eq!(LaunchDisplay::Index(0).screen_index(&[]), None);
}

// LaunchRecordRequest (DebugLaunchRecordTests' parse cases)

fn args(a: &[&str]) -> Vec<String> {
    a.iter().map(|s| s.to_string()).collect()
}

#[test]
fn the_record_request_reads_its_flags() {
    let r = LaunchRecordRequest::parse(&args(&["cmux", "--record-launch", "~/rec"]), "/Users/me")
        .unwrap();
    assert_eq!(r, LaunchRecordRequest { dir: "/Users/me/rec".into(), seconds: 6. });
    let r = LaunchRecordRequest::parse(
        &args(&["--record-launch", "/tmp/r", "--record-launch-seconds", "30"]),
        "/h",
    )
    .unwrap();
    assert_eq!((r.dir.as_str(), r.seconds), ("/tmp/r", 12.));
    let r = LaunchRecordRequest::parse(
        &args(&["--record-launch", "~", "--record-launch-seconds", "0"]),
        "/h",
    )
    .unwrap();
    assert_eq!((r.dir.as_str(), r.seconds), ("/h", 0.1));
    let r = LaunchRecordRequest::parse(
        &args(&["--record-launch", "d", "--record-launch-seconds", "x"]),
        "/h",
    )
    .unwrap();
    assert_eq!(r.seconds, 6.);
    assert_eq!(LaunchRecordRequest::parse(&args(&["--record-launch"]), "/h"), None);
    assert_eq!(LaunchRecordRequest::parse(&args(&["--record-launch", "--other"]), "/h"), None);
    assert_eq!(LaunchRecordRequest::parse(&args(&["cmux"]), "/h"), None);
}

// LaunchLayoutSettleTests (WindowViewGeometry stays with the views)

fn marks(t: &Tally) -> HashMap<String, f64> {
    t.marks().into_iter().collect()
}

#[test]
fn a_launch_with_no_change_settles_at_its_first_frame() {
    let mut t = Tally::default();
    t.first(500.);
    assert!(!t.is_over(1_999.));
    assert!(t.is_over(2_000.));
    let m = marks(&t);
    assert_eq!(m["layout.first_frame"], 500.);
    assert_eq!(m["layout.settle"], 500.);
    assert_eq!(m["layout.max_move"], 0.);
    assert_eq!(m["layout.changed_frames"], 0.);
    assert!(!m.contains_key("layout.capped"));
}

#[test]
fn the_last_change_is_the_settle_and_the_largest_move_is_named() {
    let mut t = Tally::default();
    t.first(500.);
    let mv = |n: &str, p| Some(Move { name: n.into(), points: p });
    t.note(600., "SidebarContainerView", mv("SidebarContainerView", 40.));
    t.note(900., "TabStripView", mv("TabStripView", 6.));
    assert!(!t.is_over(2_100.));
    assert!(t.is_over(2_400.));
    let m = marks(&t);
    assert_eq!(m["layout.settle"], 900.);
    assert_eq!(m["layout.max_move"], 40.);
    assert_eq!(m["layout.max_move.SidebarContainerView"], 40.);
    assert_eq!(m["layout.last.TabStripView"], 900.);
    assert_eq!(m["layout.changed_frames"], 2.);
    let names: Vec<_> = t.marks().into_iter().map(|(n, _)| n).collect();
    assert_eq!(
        names,
        [
            "layout.first_frame",
            "layout.settle",
            "layout.max_move",
            "layout.changed_frames",
            "layout.max_move.SidebarContainerView",
            "layout.last.TabStripView",
        ]
    );
}

#[test]
fn a_launch_still_changing_stops_at_the_cap_and_says_so() {
    let mut t = Tally::default();
    t.first(0.);
    for i in 1..=50 {
        t.note(f64::from(i) * 100., "window", None);
    }
    assert!(t.is_over(settle::CAP_MS));
    let m = marks(&t);
    assert_eq!(m["layout.capped"], 5_000.);
    assert_eq!(m["layout.max_move"], 0.);
    assert_eq!(m["layout.last.window"], 5_000.);
}

#[test]
fn a_view_is_named_in_one_word() {
    assert_eq!(settle::mark_name("NSHostingView<ModifiedContent<A, B>>"), "NSHostingView");
    assert_eq!(settle::mark_name("TabStripView moved 0,0,10,10 -> 0,0,12,10"), "TabStripView");
    assert_eq!(settle::mark_name(""), "view");
    assert_eq!(settle::mark_name("<x>"), "view");
}

#[test]
fn nothing_is_over_before_a_first_frame() {
    let mut t = Tally::default();
    assert!(!t.is_over(60_000.));
    assert!(t.marks().is_empty());
    t.note(100., "window", None);
    assert_eq!(t.first_ms, Some(100.), "the first note only starts the tally");
    assert_eq!(t.changed_frames, 0);
}

// LaunchPageDeferralTests

#[test]
fn pages_wait_for_the_first_frame_then_show_once_in_order() {
    let mut d = PageDeferral::default();
    d.step(&Event::Bind { open: false });
    let mut shown = Vec::new();
    let mut marks = Vec::new();
    for key in ["chat", "browser", "chat"] {
        let e = d.step(&Event::Defer { key: key.into() });
        assert!(e.deferred);
        marks.extend(e.marks);
        shown.extend(e.show);
    }
    assert!(shown.is_empty());
    assert_eq!(marks, [MARK_DEFERRED]);
    let e = d.step(&Event::Open);
    marks.extend(e.marks);
    shown.extend(e.show);
    assert_eq!(shown, ["chat", "browser"]);
    assert_eq!(marks, [MARK_DEFERRED, MARK_CREATED]);
    assert!(!d.step(&Event::Defer { key: "p3".into() }).deferred);
}

#[test]
fn unbound_it_defers_nothing() {
    let mut d = PageDeferral::default();
    assert!(!d.step(&Event::Defer { key: "chat".into() }).deferred);
    assert!(!d.holds());
}

#[test]
fn a_frame_that_already_committed_defers_nothing() {
    let mut d = PageDeferral::default();
    d.step(&Event::Bind { open: true });
    let e = d.step(&Event::Defer { key: "chat".into() });
    assert!(!e.deferred && e.marks.is_empty() && !e.when_open);
}

// LaunchShellTests (the window and the replayed events stay in Swift)

#[test]
fn event_kinds_match_the_rust_input_kinds() {
    // NSEvent.EventType raw values.
    let (key_down, key_up, flags, right_down, other_up, left_drag, scroll, moved, appkit) =
        (10, 11, 12, 3, 26, 6, 22, 5, 13);
    assert!(shell::replay_kind(key_down) == 1 && shell::replay_kind(key_up) == 2);
    assert_eq!(shell::replay_kind(flags), 3);
    assert!(shell::replay_kind(right_down) == 4 && shell::replay_kind(other_up) == 5);
    assert!(shell::replay_kind(left_drag) == 6 && shell::replay_kind(scroll) == 7);
    assert!(shell::replay_kind(moved) == 8 && shell::replay_kind(appkit) == 0);
    let all: Vec<u8> =
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 25, 26, 27].iter().map(|t| shell::replay_kind(*t)).collect();
    assert_eq!(all, [4, 5, 4, 5, 8, 6, 6, 8, 8, 4, 5, 6]);
}

#[test]
fn the_build_key_keeps_only_key_characters() {
    assert_eq!(shell::build_key(Some("4294"), Some("abc123")), "4294+abc123");
    assert_eq!(shell::build_key(Some("1/../2 x"), None), "1..2x");
    assert_eq!(shell::build_key(None, None), "unknown");
    assert_eq!(shell::build_key(None, Some("é")), "unknown");
    assert_eq!(shell::build_key(Some(&"7".repeat(200)), None).len(), 128);
}

#[test]
fn stage_zero_frame_and_look() {
    let plan = FrameRequest {
        uses_default_frame: false,
        plan_frame: [1., 2., 3., 4.],
        ..Default::default()
    };
    assert_eq!(shell::frame(&plan), [1., 2., 3., 4.]);
    let cached =
        FrameRequest { uses_default_frame: true, cached_frame: Some([9., 9., 9., 9.]), ..plan };
    assert_eq!(shell::frame(&cached), [9., 9., 9., 9.]);
    let fallback = FrameRequest { uses_default_frame: true, ..Default::default() };
    assert_eq!(shell::frame(&fallback), [170., 90., 1100., 720.]);
    let odd = FrameRequest {
        uses_default_frame: true,
        visible: Some([0., 25., 1511., 957.]),
        ..Default::default()
    };
    assert_eq!(shell::frame(&odd), [205., 143., 1101., 721.]);
    assert_eq!(shell::color([255, 0, 51, 0]), [1., 0., 0.2, 1.]);
    assert_eq!(shell::color([0, 0, 0, 51]), [0., 0., 0., 0.2]);
    assert_eq!(shell::image_path(0, "/a.png").as_deref(), Some("/a.png"));
    assert_eq!(shell::image_path(1, "/a.png"), None);
    assert_eq!(shell::image_path(0, ""), None);
}

// The ops

fn call(op: &str, request: Value) -> Value {
    ops::call(op, &request).unwrap_or_else(|e| panic!("{op}: {e:?}"))
}

#[test]
fn ops_round_trip() {
    assert_eq!(call("launch.frameFileName", json!({ "key": "k", "scale": 2 })), "k@2x.jpg");
    assert_eq!(call("launch.frameFileOwner", json!({ "file": "k@3x.jpg" })), "k");
    assert_eq!(call("launch.frameFileOwner", json!({ "file": "k@4x.jpg" })), Value::Null);
    assert_eq!(call("launch.isFileSafe", json!({ "key": "../x" })), false);
    assert_eq!(call("launch.displayParse", json!({ "value": "main" })), json!({ "index": 0 }));
    assert_eq!(call("launch.displayParse", json!({ "isDevBuild": true })), "builtIn");
    assert_eq!(
        call(
            "launch.displayScreenIndex",
            json!({ "display": "builtIn", "builtIn": [false, true] })
        ),
        1
    );
    assert!(ops::call("launch.displayScreenIndex", &json!({})).is_err());
    assert_eq!(
        call(
            "launch.recordRequest",
            json!({ "arguments": ["--record-launch", "~/r"], "home": "/h" })
        ),
        json!({ "dir": "/h/r", "seconds": 6.0 })
    );
    assert_eq!(call("launch.markName", json!({ "name": "A<B>" })), "A");
    let tally = call(
        "launch.settleTally",
        json!({ "events": [
            { "kind": "first", "ms": 500 },
            { "kind": "note", "ms": 600, "change": "S", "move": { "name": "S", "points": 40 } }
        ], "at": 2100 }),
    );
    assert_eq!(tally["isOver"], true);
    assert_eq!(tally["marks"][0], json!(["layout.first_frame", 500.0]));
    assert_eq!(tally["tally"]["changedFrames"], 1);
    let deferral = call(
        "launch.pageDeferral",
        json!({ "events": [
            { "kind": "bind", "open": false },
            { "kind": "defer", "key": "chat" },
            { "kind": "open" }
        ] }),
    );
    assert_eq!(deferral["holds"], false);
    assert_eq!(deferral["effects"][1]["whenOpen"], true);
    assert_eq!(deferral["effects"][2]["show"], json!(["chat"]));
    assert_eq!(call("launch.shellBuildKey", json!({ "version": "1", "commit": "a" })), "1+a");
    assert_eq!(call("launch.replayKind", json!({ "eventType": 22 })), 7);
    assert_eq!(
        call("launch.shellFrame", json!({ "usesDefaultFrame": true })),
        json!([170.0, 90.0, 1100.0, 720.0])
    );
    let look = call(
        "launch.shellLook",
        json!({ "background": [0, 0, 0, 0], "bar": [255, 255, 255, 255], "appearance": 1 }),
    );
    assert_eq!(look["dark"], true);
    assert_eq!(look["imagePath"], Value::Null);
    assert_eq!(call("launch.constants", json!({}))["bareBoundMs"], 1500.0);
    assert!(ops::call("launch.nope", &json!({})).is_err());
}
