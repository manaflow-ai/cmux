//! The rules' tests: the default (a hidden tab past the timeout is discarded; audio, unsaved form
//! input and pinned tabs are kept), then the ranking, pacing and keep rules ported 1:1 from the
//! app's HibernationRankingTests and MemorySaverKeepRulesTests.

use crate::ops::TabDiscard;
use crate::plan::{Candidate, Exemption, Pace, Pressure, exemption, freeze_plan, plan};
use crate::probe::{PageProbe, ProbeHistory, Step};
use crate::setting::{Mode, Setting};
use serde_json::json;

fn page(key: &str, minutes: f64) -> Candidate {
    Candidate { key: key.to_owned(), hidden_for: minutes * 60.0, ..Candidate::default() }
}

fn moderate() -> Setting {
    Setting { mode: Some(Mode::Moderate), ..Setting::default() }
}

const PRESSURES: [Pressure; 3] = [Pressure::Normal, Pressure::Warning, Pressure::Critical];

// MARK: The default (Leo, 2026-11-14: "4 yes")

/// With `browser.hibernation` unset, a hidden tab past the timeout is discarded, at every memory
/// pressure; a pinned tab is kept by the plan, and a tab that plays audio or holds the person's
/// unsaved form input (an edited field, or a `beforeunload` that asks) is kept by its probe.
/// Before: unset kept every hidden tab loaded (`keeps_state`) and only froze it.
#[test]
fn hidden_tabs_past_the_threshold_are_discarded_by_default_and_audio_form_and_pinned_are_kept() {
    let setting = Setting::default();
    assert!(setting.is_enabled());
    for pressure in PRESSURES {
        let pinned = Candidate { is_pinned: true, ..page("pinned", 45.0) };
        let candidates = [page("plain", 45.0), page("audio", 44.0), page("form", 43.0), pinned];
        let plan = plan(&setting, pressure, &candidates);
        assert!(
            plan.due.contains(&"plain".to_owned()),
            "{pressure:?}: the plain hidden tab is due: {plan:?}"
        );
        assert_eq!(plan.exemptions.get("pinned"), Some(&Exemption::Pinned), "{pressure:?}");
        assert!(!plan.due.contains(&"pinned".to_owned()), "{pressure:?}");
        assert!(!plan.exemptions.contains_key("plain"), "{pressure:?}: {plan:?}");
    }
    // The probe right before the discard: audio and unsaved form input keep the tab, at every pressure.
    let mut rules = TabDiscard::new();
    for pressure in PRESSURES {
        for (key, probe, reason) in [
            ("audio", json!({"playing_media": true}), "audio"),
            ("form", json!({"edited_form": true}), "form_input"),
            ("unload", json!({"before_unload": true}), "before_unload"),
        ] {
            let reply = rules
                .call(
                    "tab_discard_probe",
                    json!({"key": key, "probe": probe, "pressure": pressure}),
                )
                .unwrap();
            assert_eq!(reply, json!({"exemption": reason}), "{key} at {pressure:?}");
        }
        let plain = rules
            .call("tab_discard_probe", json!({"key": "plain", "probe": {}, "pressure": pressure}))
            .unwrap();
        assert_eq!(plain, json!({"exemption": null}), "the plain tab goes at {pressure:?}");
    }
}

/// The setting still turns it off: "off" discards nothing, at any pressure.
#[test]
fn off_discards_nothing_at_any_pressure() {
    let setting = Setting { mode: Some(Mode::Off), ..Setting::default() };
    for pressure in PRESSURES {
        let plan = plan(&setting, pressure, &[page("old", 600.0)]);
        assert!(plan.due.is_empty(), "{pressure:?}");
        assert_eq!(plan.exemptions.get("old"), Some(&Exemption::Disabled));
        assert_eq!(plan.next_check, None);
    }
}

/// Pinned tabs go too only when `browser.hibernatePinnedTabs` says so.
#[test]
fn pinned_tabs_go_only_when_the_setting_includes_them() {
    let pinned = Candidate { is_pinned: true, ..page("pinned", 45.0) };
    let setting = Setting { includes_pinned_tabs: true, ..moderate() };
    assert_eq!(plan(&setting, Pressure::Normal, std::slice::from_ref(&pinned)).due, ["pinned"]);
    assert_eq!(exemption(&pinned, &Setting::default()), Some(Exemption::Pinned));
}

// MARK: Ranking and pacing (HibernationRankingTests)

#[test]
fn the_default_idle_timeout_is_thirty_minutes() {
    assert_eq!(Setting::default().effective_mode().hidden_minutes(), Some(30.0));
    let plan = plan(&moderate(), Pressure::Normal, &[page("old", 31.0), page("young", 29.0)]);
    assert_eq!(plan.due, ["old"]);
    assert!((plan.next_check.unwrap() - 60.0).abs() < 1e-6);
}

#[test]
fn never_all_at_once() {
    let candidates: Vec<_> = (0..50).map(|i| page(&format!("t{i}"), 40.0 + f64::from(i))).collect();
    let plan = plan(&moderate(), Pressure::Normal, &candidates);
    assert_eq!(plan.due, ["t49", "t48"], "the longest idle go first");
    assert_eq!(plan.next_check, Some(Pace::NORMAL.interval));
}

#[test]
fn critical_pressure_still_goes_in_batches() {
    let candidates: Vec<_> = (0..20).map(|i| page(&format!("t{i}"), 2.0 + f64::from(i))).collect();
    let plan = plan(&moderate(), Pressure::Critical, &candidates);
    assert_eq!(plan.due.len(), Pace::CRITICAL.per_pass);
    assert_eq!(plan.next_check, Some(Pace::CRITICAL.interval));
}

#[test]
fn frequently_focused_tabs_go_later() {
    let once = Candidate { recent_focus_count: 1, ..page("once", 36.0) };
    let often = Candidate { recent_focus_count: 15, ..page("often", 35.0) };
    assert_eq!(plan(&moderate(), Pressure::Normal, &[once, often]).due, ["once"]);
}

#[test]
fn under_pressure_the_heaviest_of_equal_pages_goes_first() {
    let mb = |key: &str, megabytes: u64| Candidate {
        memory_bytes: Some(megabytes << 20),
        ..page(key, 5.0)
    };
    let plan = plan(
        &moderate(),
        Pressure::Warning,
        &[mb("light", 80), mb("heavy", 900), mb("medium", 300)],
    );
    assert_eq!(plan.due, ["heavy"]);
}

#[test]
fn warning_pressure_relieves_one_page_at_a_time() {
    let just_left = Candidate { memory_bytes: Some(2_000 << 20), ..page("just-left", 0.2) };
    let plan = plan(&moderate(), Pressure::Warning, &[just_left, page("a", 3.0), page("b", 6.0)]);
    assert_eq!(plan.due, ["b"]);
    assert_eq!(plan.next_check, Some(Pace::WARNING.interval));
}

#[test]
fn no_pressure_no_early_discard() {
    let heavy = Candidate { memory_bytes: Some(4_000 << 20), ..page("heavy", 10.0) };
    assert!(plan(&moderate(), Pressure::Normal, &[heavy]).due.is_empty());
}

#[test]
fn a_recently_kept_page_does_not_block_relief() {
    let playing = Candidate { recently_kept: true, ..page("playing", 20.0) };
    let plan_both = plan(&moderate(), Pressure::Warning, &[playing.clone(), page("quiet", 5.0)]);
    assert_eq!(plan_both.due, ["quiet"]);
    assert_eq!(plan(&moderate(), Pressure::Warning, &[playing]).due, ["playing"]);
}

#[test]
fn downloads_and_agent_leases_never_go() {
    for pressure in PRESSURES {
        let dl = Candidate { is_downloading: true, ..page("dl", 500.0) };
        let agent = Candidate { has_agent_lease: true, ..page("agent", 500.0) };
        let plan = plan(&moderate(), pressure, &[dl, agent]);
        assert!(plan.due.is_empty(), "{pressure:?}");
        assert_eq!(plan.exemptions.get("dl"), Some(&Exemption::Downloading));
        assert_eq!(plan.exemptions.get("agent"), Some(&Exemption::AgentLease));
    }
}

#[test]
fn leased_pages_do_not_freeze() {
    let agent = Candidate { has_agent_lease: true, ..page("agent", 5.0) };
    assert!(freeze_plan(&Setting::default(), &[agent]).due.is_empty());
}

#[test]
fn hidden_pages_freeze_after_freeze_seconds() {
    let setting = Setting::default();
    let plan = freeze_plan(
        &setting,
        &[
            Candidate { hidden_for: 31.0, ..page("a", 0.0) },
            Candidate { hidden_for: 10.0, ..page("b", 0.0) },
        ],
    );
    assert_eq!(plan.due, ["a"]);
    assert_eq!(plan.next_check, Some(20.0));
    let off = Setting { freeze_seconds: None, ..setting };
    assert!(freeze_plan(&off, &[page("a", 60.0)]).due.is_empty());
}

#[test]
fn exclusions_match_the_host_and_its_subdomains() {
    let setting = Setting {
        exclusions: vec!["mail.google.com".into(), "*.example.com".into()],
        ..Setting::default()
    };
    assert!(setting.excludes(Some("mail.google.com")));
    assert!(setting.excludes(Some("Inbox.Mail.Google.com")));
    assert!(!setting.excludes(Some("google.com")));
    assert!(setting.excludes(Some("docs.example.com")));
    assert!(!setting.excludes(Some("example.com")));
    assert!(!setting.excludes(None));
    let excluded = Candidate { host: Some("docs.example.com".into()), ..page("x", 60.0) };
    assert_eq!(
        plan(&setting, Pressure::Critical, &[excluded]).exemptions.get("x"),
        Some(&Exemption::Excluded)
    );
}

// MARK: Notifications (MemorySaverNotificationsTests)

#[test]
fn the_timeout_keeps_a_tab_that_may_show_notifications_and_pressure_takes_it() {
    let chat = Candidate { allows_notifications: true, ..page("chat", 60.0) };
    let normal = plan(&moderate(), Pressure::Normal, &[chat.clone(), page("docs", 60.0)]);
    assert_eq!(normal.due, ["docs"]);
    assert_eq!(normal.exemptions.get("chat"), Some(&Exemption::Notifications));
    for pressure in [Pressure::Warning, Pressure::Critical] {
        assert_eq!(plan(&moderate(), pressure, std::slice::from_ref(&chat)).due, ["chat"]);
    }
}

// MARK: Keep rules (MemorySaverKeepRulesTests)

#[test]
fn every_keep_reason_holds_at_every_pressure() {
    let cases = [
        (PageProbe { playing_media: true, ..PageProbe::default() }, Exemption::Audio),
        (PageProbe { edited_form: true, ..PageProbe::default() }, Exemption::FormInput),
        (PageProbe { capturing: true, ..PageProbe::default() }, Exemption::Capturing),
        (PageProbe { before_unload: true, ..PageProbe::default() }, Exemption::BeforeUnload),
        (PageProbe { web_rtc: true, ..PageProbe::default() }, Exemption::WebRtc),
        (PageProbe { connected_device: true, ..PageProbe::default() }, Exemption::ConnectedDevice),
        (PageProbe { unreadable_frame: true, ..PageProbe::default() }, Exemption::UnreadableFrame),
        (PageProbe { web_audio: true, ..PageProbe::default() }, Exemption::WebAudio),
    ];
    for pressure in PRESSURES {
        for (probe, reason) in cases {
            assert_eq!(probe.keep_reason(pressure, false, false), Some(reason), "{pressure:?}");
        }
        assert_eq!(
            PageProbe::default().keep_reason(pressure, false, true),
            Some(Exemption::FormSubmission)
        );
        assert_eq!(PageProbe::default().keep_reason(pressure, false, false), None);
    }
}

#[test]
fn an_unanswered_probe_keeps_the_page_without_pressure_or_while_doubted() {
    let unanswered = PageProbe { answered: false, ..PageProbe::default() };
    assert_eq!(unanswered.keep_reason(Pressure::Normal, false, false), Some(Exemption::Unanswered));
    assert_eq!(
        unanswered.keep_reason(Pressure::Critical, true, false),
        Some(Exemption::Unanswered)
    );
    assert_eq!(unanswered.keep_reason(Pressure::Critical, false, false), None);
}

#[test]
fn a_page_whose_last_answer_was_form_input_stays_while_it_does_not_answer() {
    let mut history = ProbeHistory::default();
    history.record(PageProbe { edited_form: true, ..PageProbe::default() }, "page", Step::Discard);
    for _ in 0..ProbeHistory::UNANSWERED_LIMIT + 2 {
        assert!(history.record(
            PageProbe { answered: false, ..PageProbe::default() },
            "page",
            Step::Discard
        ));
    }
}

#[test]
fn a_page_that_never_said_it_was_busy_loses_the_doubt() {
    let mut history = ProbeHistory::default();
    history.record(PageProbe::default(), "page", Step::Discard);
    for _ in 0..ProbeHistory::UNANSWERED_LIMIT {
        history.record(
            PageProbe { answered: false, ..PageProbe::default() },
            "page",
            Step::Discard,
        );
    }
    assert!(!history.doubted("page", Step::Discard));
    history.record(PageProbe::default(), "page", Step::Discard);
    assert!(history.doubted("page", Step::Discard));
}

#[test]
fn a_freeze_keeps_only_what_stops_while_frozen() {
    let mut rules = TabDiscard::new();
    let keep = |rules: &mut TabDiscard, probe| {
        rules.call("tab_discard_freeze_probe", json!({"key": "p", "probe": probe})).unwrap()
    };
    assert_eq!(keep(&mut rules, json!({"playing_media": true})), json!({"keep": true}));
    assert_eq!(keep(&mut rules, json!({"edited_form": true})), json!({"keep": false}));
    assert_eq!(keep(&mut rules, json!({"before_unload": true})), json!({"keep": false}));
    // A paused media session the person resumes from outside the page (issue 51079).
    assert_eq!(keep(&mut rules, json!({"media_session": true})), json!({"keep": true}));
}

/// A media session keeps a page from a freeze only: a discard ends the session with the page, and
/// a page that last said it holds one keeps the freeze's doubt while it does not answer.
#[test]
fn a_media_session_keeps_a_page_from_a_freeze_not_a_discard() {
    let probe = PageProbe { media_session: true, ..PageProbe::default() };
    assert!(probe.stops_when_frozen());
    assert_eq!(probe.exemption(), None);
    let mut history = ProbeHistory::default();
    history.record(probe, "page", Step::Freeze);
    let silent = PageProbe { answered: false, ..PageProbe::default() };
    for _ in 0..ProbeHistory::UNANSWERED_LIMIT + 2 {
        assert!(history.record(silent, "page", Step::Freeze));
    }
}

/// Without `discards_automatically` hidden pages only freeze: none is due at any pressure, each
/// keeps its own exemption or `keeps_state`, and freezing goes on.
#[test]
fn a_setting_that_keeps_state_never_discards_on_its_own() {
    let setting = Setting { discards_automatically: false, ..moderate() };
    let pinned = Candidate { is_pinned: true, ..page("pinned", 120.0) };
    for pressure in PRESSURES {
        let result = plan(&setting, pressure, &[page("old", 120.0), pinned.clone()]);
        assert!(result.due.is_empty(), "{pressure:?}");
        assert_eq!(result.next_check, None);
        assert_eq!(result.exemptions["old"], Exemption::KeepsState);
        assert_eq!(result.exemptions["pinned"], Exemption::Pinned);
    }
    assert_eq!(freeze_plan(&setting, &[page("old", 120.0)]).due, vec!["old".to_owned()]);
    let off =
        Setting { mode: Some(Mode::Off), discards_automatically: false, ..Setting::default() };
    assert_eq!(
        plan(&off, Pressure::Normal, &[page("old", 120.0)]).exemptions["old"],
        Exemption::Disabled
    );
    let wire = TabDiscard::new()
        .call("tab_discard_plan", json!({"setting": {"mode": "moderate", "discards_automatically": false}, "candidates": [{"key": "a", "hidden_for": 9000.0}]}))
        .unwrap();
    assert_eq!(wire["exemptions"], json!({"a": "keeps_state"}));
}

// MARK: The wire

#[test]
fn the_wire_reads_cmux_json_values_and_answers_snake_case() {
    let mut rules = TabDiscard::new();
    let reply = rules
        .call(
            "tab_discard_plan",
            json!({
                "setting": {"mode": 10, "exclusions": [], "freeze_seconds": 30},
                "pressure": "normal",
                "candidates": [{"key": "a", "hidden_for": 601.0}, {"key": "b", "hidden_for": 30.0, "has_dev_tools": true}],
            }),
        )
        .unwrap();
    assert_eq!(reply["due"], json!(["a"]));
    assert_eq!(reply["exemptions"], json!({"b": "devtools"}));
    let setting = rules.call("tab_discard_setting", json!({"setting": {}})).unwrap();
    assert_eq!(
        setting,
        json!({"enabled": true, "mode": "moderate", "hidden_seconds": 1800.0, "discards_automatically": true})
    );
    let off = rules.call("tab_discard_setting", json!({"setting": {"mode": "off"}})).unwrap();
    assert_eq!(
        off,
        json!({"enabled": false, "mode": "off", "hidden_seconds": null, "discards_automatically": true})
    );
    let warning =
        rules.call("tab_discard_threshold", json!({"setting": {}, "pressure": "warning"})).unwrap();
    assert_eq!(warning, json!({"seconds": 600.0}));
    assert!(rules.call("tab_discard_nope", json!({})).is_err());
    assert!(rules.call("tab_discard_plan", json!({"setting": {"mode": "sometimes"}})).is_err());
}

#[test]
fn the_record_op_counts_a_miss_for_either_step() {
    let mut rules = TabDiscard::new();
    let record = |rules: &mut TabDiscard, probe, step| {
        rules.call("tab_discard_record", json!({"key": "p", "probe": probe, "step": step})).unwrap()
            ["doubted"]
            .as_bool()
            .unwrap()
    };
    assert!(!record(&mut rules, json!({}), "discard"));
    let silent = json!({"answered": false});
    let misses: Vec<bool> = (0..ProbeHistory::UNANSWERED_LIMIT)
        .map(|_| record(&mut rules, silent.clone(), "discard"))
        .collect();
    assert_eq!(misses, [true, true, false]);
    // A freeze miss counts in the same row (the step only changes what "said busy" means).
    assert!(!record(&mut rules, silent, "freeze"));
    let doubted = rules.call("tab_discard_probe_doubted", json!({"key": "p"})).unwrap();
    assert_eq!(doubted, json!({"doubted": false}));
}

#[test]
fn the_verdict_op_reads_one_answer_and_records_nothing() {
    let mut rules = TabDiscard::new();
    let verdict = rules
        .call(
            "tab_discard_probe_verdict",
            json!({"probe": {"media_session": true, "answered": false}, "pressure": "critical", "doubted": true}),
        )
        .unwrap();
    assert_eq!(
        verdict,
        json!({"exemption": null, "stops_when_frozen": true, "keep_reason": "unanswered"})
    );
    let form = rules
        .call("tab_discard_probe_verdict", json!({"probe": {}, "shows_form_submission": true}))
        .unwrap();
    assert_eq!(
        form,
        json!({"exemption": null, "stops_when_frozen": false, "keep_reason": "form_submission"})
    );
    assert_eq!(
        rules.call("tab_discard_probe_doubted", json!({"key": "x"})).unwrap(),
        json!({"doubted": true})
    );
}
