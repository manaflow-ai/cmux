//! Ported from the app's Swift tests (CEFWindowPolicyTests, CmdClickLinkPlacementTests), plus the
//! table of every gesture and disposition the Swift rules answered, pinned here.

use crate::links::*;
use crate::ops;
use serde_json::json;

fn mods(command: bool, shift: bool, option: bool) -> Modifiers {
    Modifiers { command, shift, option }
}

fn tab(disposition: NewTabDisposition) -> LinkPlacement {
    LinkPlacement::Tab { disposition }
}

fn user_mapping() -> ClickMapping {
    ClickMapping {
        cmd_click: LinkAction::LinkPlacement,
        cmd_shift_click: LinkAction::ForegroundTab,
        shift_click: LinkAction::NewWindow,
        option_click: LinkAction::Download,
        middle_click: LinkAction::BackgroundTab,
    }
}

fn click(gesture: Gesture) -> Option<ClickRecord> {
    Some(ClickRecord { gesture, timestamp: 1.0 })
}

fn placement(disposition: CefDisposition, gesture: Gesture) -> LinkPlacement {
    cef_placement(disposition, true, click(gesture), 1.0, &user_mapping())
}

fn request(disposition: CefDisposition) -> WindowRequest {
    WindowRequest {
        kind: WindowKind::Tab,
        disposition,
        source_browser: 11,
        url: "https://example.com/".into(),
        user_gesture: true,
        profile_path: "/profile".into(),
        persistent_profile: true,
    }
}

fn candidate(anchor: i32, profile: &str) -> WindowCandidate {
    WindowCandidate {
        anchor,
        profile_path: profile.into(),
        holds_source: false,
        last_shown: false,
        visible: false,
    }
}

#[test]
fn gestures_follow_command_then_middle_then_shift_or_option_alone() {
    assert_eq!(Gesture::of(mods(false, false, false), 0), Gesture::Plain);
    assert_eq!(Gesture::of(mods(true, false, false), 0), Gesture::Cmd);
    assert_eq!(Gesture::of(mods(true, true, false), 0), Gesture::CmdShift);
    assert_eq!(Gesture::of(mods(true, true, true), 2), Gesture::CmdShift);
    assert_eq!(Gesture::of(mods(true, false, true), 2), Gesture::Cmd);
    assert_eq!(Gesture::of(mods(false, false, false), 2), Gesture::Middle);
    assert_eq!(Gesture::of(mods(false, true, false), 2), Gesture::MiddleShift);
    assert_eq!(Gesture::of(mods(false, false, true), 2), Gesture::Middle);
    assert_eq!(Gesture::of(mods(false, true, false), 0), Gesture::Shift);
    assert_eq!(Gesture::of(mods(false, false, true), 0), Gesture::Option);
    // Shift and Option together are neither: a plain click.
    assert_eq!(Gesture::of(mods(false, true, true), 0), Gesture::Plain);
    assert_eq!(Gesture::of(mods(false, false, false), 1), Gesture::Plain);
}

#[test]
fn the_mapping_answers_each_gesture_and_middle_shift_follows_cmd_shift() {
    let mapping = user_mapping();
    assert_eq!(mapping.action(Gesture::Plain), LinkAction::CurrentTab);
    assert_eq!(mapping.action(Gesture::Cmd), LinkAction::LinkPlacement);
    assert_eq!(mapping.action(Gesture::CmdShift), LinkAction::ForegroundTab);
    assert_eq!(mapping.action(Gesture::MiddleShift), LinkAction::ForegroundTab);
    assert_eq!(mapping.action(Gesture::Shift), LinkAction::NewWindow);
    assert_eq!(mapping.action(Gesture::Option), LinkAction::Download);
    assert_eq!(mapping.action(Gesture::Middle), LinkAction::BackgroundTab);
}

#[test]
fn chromes_mapping_keeps_the_background_tab() {
    assert_eq!(ClickMapping::CHROME.cmd_click, LinkAction::BackgroundTab);
    assert_eq!(ClickMapping::default(), ClickMapping::CHROME);
}

#[test]
fn new_tab_dispositions_of_each_action() {
    assert_eq!(LinkAction::CurrentTab.new_tab_disposition(), None);
    assert_eq!(LinkAction::Download.new_tab_disposition(), None);
    assert_eq!(
        LinkAction::LinkPlacement.new_tab_disposition(),
        Some(NewTabDisposition::LinkPlacement)
    );
    assert_eq!(LinkAction::NewWindow.new_tab_disposition(), Some(NewTabDisposition::NewWindow));
}

#[test]
fn middle_click_uses_its_background_tab_setting() {
    assert_eq!(
        placement(CefDisposition::NewBackgroundTab, Gesture::Middle),
        tab(NewTabDisposition::BackgroundTab)
    );
}

#[test]
fn command_click_uses_its_own_setting() {
    assert_eq!(
        placement(CefDisposition::NewBackgroundTab, Gesture::Cmd),
        tab(NewTabDisposition::LinkPlacement)
    );
}

#[test]
fn shifted_command_and_middle_clicks_open_foreground_tabs() {
    assert_eq!(
        placement(CefDisposition::NewForegroundTab, Gesture::CmdShift),
        tab(NewTabDisposition::ForegroundTab)
    );
    assert_eq!(
        placement(CefDisposition::NewForegroundTab, Gesture::MiddleShift),
        tab(NewTabDisposition::ForegroundTab)
    );
}

#[test]
fn shift_click_uses_its_new_window_setting() {
    assert_eq!(
        placement(CefDisposition::NewWindow, Gesture::Shift),
        tab(NewTabDisposition::NewWindow)
    );
}

#[test]
fn option_click_uses_its_download_setting() {
    assert_eq!(placement(CefDisposition::SaveToDisk, Gesture::Option), LinkPlacement::Download {});
}

#[test]
fn a_cmd_click_mapped_to_the_current_tab_loads_in_the_opener() {
    let mapping = ClickMapping { cmd_click: LinkAction::CurrentTab, ..ClickMapping::CHROME };
    assert_eq!(
        cef_placement(CefDisposition::NewBackgroundTab, true, None, 0.0, &mapping),
        LinkPlacement::Opener {}
    );
}

#[test]
fn chromium_command_click_asks_for_the_pane_on_the_right() {
    let mapping = ClickMapping { cmd_click: LinkAction::LinkPlacement, ..ClickMapping::CHROME };
    assert_eq!(
        cef_placement(CefDisposition::NewBackgroundTab, true, None, 0.0, &mapping),
        tab(NewTabDisposition::LinkPlacement)
    );
}

#[test]
fn a_scripts_background_tab_keeps_chromes_default() {
    let mapping = ClickMapping { cmd_click: LinkAction::LinkPlacement, ..ClickMapping::CHROME };
    assert_eq!(
        cef_placement(
            CefDisposition::NewBackgroundTab,
            false,
            click(Gesture::Middle),
            1.0,
            &mapping
        ),
        tab(NewTabDisposition::BackgroundTab)
    );
}

#[test]
fn a_stale_or_future_click_falls_back_to_cmd_click() {
    let mapping = user_mapping();
    let stale = Some(ClickRecord { gesture: Gesture::Middle, timestamp: 1.0 });
    assert_eq!(
        cef_placement(CefDisposition::NewBackgroundTab, true, stale, 2.5, &mapping),
        tab(NewTabDisposition::LinkPlacement)
    );
    let future = Some(ClickRecord { gesture: Gesture::Middle, timestamp: 3.0 });
    assert_eq!(
        cef_placement(CefDisposition::NewBackgroundTab, true, future, 2.5, &mapping),
        tab(NewTabDisposition::LinkPlacement)
    );
    let edge = Some(ClickRecord { gesture: Gesture::Middle, timestamp: 1.5 });
    assert_eq!(
        cef_placement(CefDisposition::NewBackgroundTab, true, edge, 2.5, &mapping),
        tab(NewTabDisposition::BackgroundTab)
    );
}

#[test]
fn a_plain_target_blank_is_a_selected_tab_whatever_the_mapping() {
    let mapping = ClickMapping { cmd_shift_click: LinkAction::NewWindow, ..ClickMapping::CHROME };
    assert_eq!(
        cef_placement(CefDisposition::NewForegroundTab, true, None, 0.0, &mapping),
        tab(NewTabDisposition::ForegroundTab)
    );
    assert_eq!(
        cef_placement(CefDisposition::NewForegroundTab, true, click(Gesture::Cmd), 1.0, &mapping),
        tab(NewTabDisposition::ForegroundTab)
    );
}

#[test]
fn every_other_disposition_keeps_chromiums_meaning() {
    let mapping = user_mapping();
    let at = |raw: i64| cef_placement(CefDisposition::from_raw(raw), true, None, 0.0, &mapping);
    assert_eq!(at(5), tab(NewTabDisposition::Popup));
    for raw in [0, 2, 8, 10, 12, 99, -1] {
        assert_eq!(at(raw), tab(NewTabDisposition::ForegroundTab), "raw {raw}");
    }
    for raw in [1, 9, 11] {
        assert_eq!(at(raw), LinkPlacement::Chromium {}, "raw {raw}");
    }
}

#[test]
fn policy_keeps_middle_click_background_disposition_when_it_inserts() {
    let links = LinkContext { mapping: user_mapping(), click: click(Gesture::Middle), now: 1.0 };
    let mut chosen = candidate(7, "/profile");
    chosen.holds_source = true;
    chosen.last_shown = true;
    chosen.visible = true;
    assert_eq!(
        decide_window(&request(CefDisposition::NewBackgroundTab), &[chosen], &links),
        WindowDecision::Insert { anchor: 7, disposition: NewTabDisposition::BackgroundTab }
    );
}

#[test]
fn the_window_is_the_sources_then_last_shown_then_visible_then_first_of_the_profile() {
    let links = LinkContext::default();
    let req = request(CefDisposition::NewForegroundTab);
    let other = WindowCandidate { holds_source: true, ..candidate(1, "/other") };
    let first = candidate(2, "/profile");
    let visible = WindowCandidate { visible: true, ..candidate(3, "/profile") };
    let shown = WindowCandidate { last_shown: true, ..candidate(4, "/profile") };
    let source = WindowCandidate { holds_source: true, ..candidate(5, "/profile") };
    let insert =
        |anchor| WindowDecision::Insert { anchor, disposition: NewTabDisposition::ForegroundTab };
    let all = [other, first, visible, shown, source];
    assert_eq!(decide_window(&req, &all, &links), insert(5));
    assert_eq!(decide_window(&req, &all[..4], &links), insert(4));
    assert_eq!(decide_window(&req, &all[..3], &links), insert(3));
    assert_eq!(decide_window(&req, &all[..2], &links), insert(2));
    assert_eq!(
        decide_window(&req, &all[..1], &links),
        WindowDecision::OpenInNewTab {
            url: "https://example.com/".into(),
            disposition: NewTabDisposition::ForegroundTab
        }
    );
}

#[test]
fn an_off_the_record_store_without_a_window_is_refused() {
    let req =
        WindowRequest { persistent_profile: false, ..request(CefDisposition::NewForegroundTab) };
    assert_eq!(
        decide_window(&req, &[], &LinkContext::default()),
        WindowDecision::Refuse { refusal: WindowRefusal::NoWindow }
    );
}

#[test]
fn incognito_requests_open_off_the_record() {
    let by_kind =
        WindowRequest { kind: WindowKind::OffTheRecord, ..request(CefDisposition::NewWindow) };
    let by_disposition = request(CefDisposition::OffTheRecord);
    let expected = WindowDecision::OpenOffTheRecord { url: "https://example.com/".into() };
    assert_eq!(decide_window(&by_kind, &[], &LinkContext::default()), expected);
    assert_eq!(decide_window(&by_disposition, &[], &LinkContext::default()), expected);
}

#[test]
fn opener_and_download_need_a_source_and_a_url() {
    let links = LinkContext {
        mapping: ClickMapping { cmd_click: LinkAction::CurrentTab, ..ClickMapping::CHROME },
        ..LinkContext::default()
    };
    let req = request(CefDisposition::NewBackgroundTab);
    assert_eq!(
        decide_window(&req, &[], &links),
        WindowDecision::LoadInSource { url: "https://example.com/".into() }
    );
    let no_url = WindowRequest { url: String::new(), ..req.clone() };
    assert_eq!(window_placement(&no_url, &links), tab(NewTabDisposition::ForegroundTab));
    let no_source = WindowRequest { source_browser: 0, ..req };
    assert_eq!(window_placement(&no_source, &links), tab(NewTabDisposition::ForegroundTab));
    let download = request(CefDisposition::SaveToDisk);
    assert_eq!(
        decide_window(&download, &[], &LinkContext::default()),
        WindowDecision::DownloadInSource { url: "https://example.com/".into() }
    );
}

#[test]
fn windows_and_popups_place_by_kind() {
    let links = LinkContext { mapping: user_mapping(), ..LinkContext::default() };
    let popup =
        WindowRequest { kind: WindowKind::Popup, ..request(CefDisposition::NewBackgroundTab) };
    assert_eq!(window_placement(&popup, &links), tab(NewTabDisposition::Popup));
    let window = WindowRequest { kind: WindowKind::Window, ..request(CefDisposition::NewWindow) };
    assert_eq!(window_placement(&window, &links), tab(NewTabDisposition::NewWindow));
    let app_no_source = WindowRequest {
        kind: WindowKind::App,
        source_browser: 0,
        ..request(CefDisposition::NewWindow)
    };
    assert_eq!(window_placement(&app_no_source, &links), tab(NewTabDisposition::ForegroundTab));
    let window_not_link =
        WindowRequest { kind: WindowKind::Window, ..request(CefDisposition::NewPopup) };
    assert_eq!(window_placement(&window_not_link, &links), tab(NewTabDisposition::ForegroundTab));
    // A Chromium-only placement still opens a selected tab when it reaches the window decision.
    let current = request(CefDisposition::CurrentTab);
    assert_eq!(window_placement(&current, &links), LinkPlacement::Chromium {});
    assert_eq!(
        decide_window(&current, &[candidate(9, "/profile")], &links),
        WindowDecision::Insert { anchor: 9, disposition: NewTabDisposition::ForegroundTab }
    );
}

#[test]
fn webkit_link_clicks() {
    let mapping = ClickMapping { cmd_click: LinkAction::LinkPlacement, ..ClickMapping::CHROME };
    assert_eq!(
        webkit_link_click(mods(false, false, false), 0, &mapping),
        WebKitLinkClick::PageDefault {}
    );
    assert_eq!(
        webkit_link_click(mods(true, false, false), 0, &mapping),
        WebKitLinkClick::Open { disposition: NewTabDisposition::LinkPlacement }
    );
    assert_eq!(
        webkit_link_click(mods(false, false, true), 0, &mapping),
        WebKitLinkClick::Download {}
    );
    let navigate = ClickMapping { shift_click: LinkAction::CurrentTab, ..ClickMapping::CHROME };
    assert_eq!(
        webkit_link_click(mods(false, true, false), 0, &navigate),
        WebKitLinkClick::Navigate {}
    );
}

#[test]
fn ops_answer_in_the_shape_swifts_codable_reads() {
    let reply =
        ops::call("browser_rules_link_gesture", json!({"command": true, "button": 0})).unwrap();
    assert_eq!(reply, json!("cmd"));
    let reply =
        ops::call("browser_rules_link_gesture", json!({"shift": true, "button": 2})).unwrap();
    assert_eq!(reply, json!("middleShift"));
    let reply = ops::call(
        "browser_rules_link_action",
        json!({"mapping": {"cmdClick": "linkPlacement", "cmdShiftClick": "foregroundTab",
                           "shiftClick": "newWindow", "optionClick": "download",
                           "middleClick": "backgroundTab"},
               "gesture": "cmd"}),
    )
    .unwrap();
    assert_eq!(reply, json!("linkPlacement"));
    let reply = ops::call(
        "browser_rules_webkit_link_click",
        json!({"option": true, "button": 0, "mapping": {}}),
    )
    .unwrap();
    assert_eq!(reply, json!({"download": {}}));
    let reply = ops::call(
        "browser_rules_webkit_link_click",
        json!({"command": true, "button": 0, "mapping": {"cmdClick": "linkPlacement"}}),
    )
    .unwrap();
    assert_eq!(reply, json!({"open": {"_0": "linkPlacement"}}));
    let reply = ops::call(
        "browser_rules_cef_link_placement",
        json!({"disposition": 4, "userGesture": true,
               "click": {"gesture": "middle", "timestamp": 1.0}, "now": 1.2}),
    )
    .unwrap();
    assert_eq!(reply, json!({"tab": {"_0": "backgroundTab"}}));
    let reply = ops::call("browser_rules_cef_link_placement", json!({"disposition": 1})).unwrap();
    assert_eq!(reply, json!({"chromium": {}}));
    // CEFWindowRequest as Swift encodes it: Kind and CEFDisposition by raw value, bounds ignored.
    let reply = ops::call(
        "browser_rules_window_decide",
        json!({
            "request": {"kind": 0, "disposition": 4, "sourceBrowser": 11,
                        "bounds": [[0, 0], [10, 10]], "url": "https://example.com/",
                        "userGesture": true, "profilePath": "/p", "persistentProfile": true},
            "candidates": [{"anchor": 7, "profilePath": "/p", "holdsSource": true,
                            "lastShown": false, "visible": false}],
            "links": {"mapping": {"cmdClick": "linkPlacement"}, "now": 0.0},
        }),
    )
    .unwrap();
    assert_eq!(reply, json!({"insert": {"anchor": 7, "disposition": "linkPlacement"}}));
    let reply = ops::call(
        "browser_rules_window_decide",
        json!({"request": {"kind": 0, "disposition": 3, "profilePath": "/p",
                           "persistentProfile": false}}),
    )
    .unwrap();
    assert_eq!(reply, json!({"refuse": {"_0": "noWindow"}}));
    let reply = ops::call(
        "browser_rules_window_decide",
        json!({"request": {"kind": 3, "disposition": 6, "url": "https://a/", "profilePath": "/p"}}),
    )
    .unwrap();
    assert_eq!(reply, json!({"openOffTheRecord": {"url": "https://a/"}}));
    let reply = ops::call(
        "browser_rules_window_placement",
        json!({"request": {"kind": 2, "disposition": 5, "profilePath": "/p"}}),
    )
    .unwrap();
    assert_eq!(reply, json!({"tab": {"_0": "popup"}}));
    assert!(
        ops::call(
            "browser_rules_window_placement",
            json!({"request": {"kind": 9, "disposition": 5}})
        )
        .is_err()
    );
}

#[test]
fn ops_refuse_unknown_ops_and_bad_requests() {
    assert!(ops::serves("browser_rules_window_decide"));
    assert!(!ops::serves("tab_discard_plan"));
    assert!(matches!(ops::call("browser_rules_nope", json!({})), Err(ops::OpError::UnknownOp(_))));
    assert!(matches!(
        ops::call("browser_rules_link_action", json!({"gesture": "wave"})),
        Err(ops::OpError::Invalid(_))
    ));
}
