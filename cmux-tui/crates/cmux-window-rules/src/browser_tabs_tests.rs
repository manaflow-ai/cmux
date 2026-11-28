use super::*;

fn tab(id: &str, engine: Option<&str>, profile: &str, shown: Option<&str>) -> Candidate {
    Candidate {
        id: id.into(),
        engine: engine.map(Into::into),
        profile: profile.into(),
        shown: shown.map(Into::into),
    }
}

fn web(id: &str, shown: &str) -> Candidate {
    tab(id, None, DEFAULT_PROFILE, Some(shown))
}

fn first<'a>(
    tabs: &'a [Candidate],
    url: &str,
    engine: &str,
    profile: Option<&str>,
) -> Option<&'a str> {
    first_match(tabs, url, engine, profile).map(|tab| tab.id.as_str())
}

fn facts(default_engine: DefaultEngine) -> Resolve {
    Resolve {
        default_engine,
        cef_unavailable: false,
        requested: None,
        inherited: None,
        site_engine: None,
    }
}

fn open(outcome: Outcome) -> Choice {
    match outcome {
        Outcome::Open(choice) => choice,
        Outcome::Refuse => panic!("refused"),
    }
}

#[test]
fn a_protected_media_site_opens_in_webkit_and_is_pinned() {
    let opened = open(resolve(&Resolve {
        site_engine: Some(DefaultEngine::Webkit),
        ..facts(DefaultEngine::Chromium)
    }));
    assert_eq!(opened.engine, Engine::Webkit);
    assert!(opened.pinned);
    assert!(!opened.fallback);
}

#[test]
fn another_site_follows_the_default_engine() {
    let opened = open(resolve(&facts(DefaultEngine::Chromium)));
    assert_eq!(opened.engine, Engine::Cef);
    assert!(!opened.pinned);
}

#[test]
fn an_explicit_engine_beats_the_site_rule() {
    let opened = open(resolve(&Resolve {
        requested: Some("chromium".into()),
        site_engine: Some(DefaultEngine::Webkit),
        ..facts(DefaultEngine::Chromium)
    }));
    assert_eq!(opened.engine, Engine::Cef);
    assert!(opened.pinned);
}

#[test]
fn an_inherited_engine_beats_the_site_rule() {
    let opened = open(resolve(&Resolve {
        inherited: Some("cef".into()),
        site_engine: Some(DefaultEngine::Webkit),
        ..facts(DefaultEngine::Chromium)
    }));
    assert_eq!(opened.engine, Engine::Cef);
    assert!(opened.inherited);
    assert!(!opened.pinned);
}

#[test]
fn a_chromium_site_rule_falls_back_to_webkit_when_chromium_is_missing() {
    let opened = open(resolve(&Resolve {
        cef_unavailable: true,
        site_engine: Some(DefaultEngine::Chromium),
        ..facts(DefaultEngine::Webkit)
    }));
    assert_eq!(opened.engine, Engine::Webkit);
    assert!(opened.fallback);
    assert!(!opened.pinned);
}

#[test]
fn a_chromium_site_rule_beats_a_webkit_default() {
    let opened = open(resolve(&Resolve {
        site_engine: Some(DefaultEngine::Chromium),
        ..facts(DefaultEngine::Webkit)
    }));
    assert_eq!(opened.engine, Engine::Cef);
    assert!(opened.pinned);
}

#[test]
fn an_explicit_chromium_request_chromium_cannot_serve_is_refused() {
    let ask = Resolve {
        requested: Some("Chrome".into()),
        cef_unavailable: true,
        ..facts(DefaultEngine::Webkit)
    };
    assert_eq!(resolve(&ask), Outcome::Refuse);
    let webkit = Resolve { requested: Some("SAFARI".into()), ..ask };
    assert_eq!(open(resolve(&webkit)).engine, Engine::Webkit);
    assert_eq!(requested_engine(Some("firefox")), None);
}

#[test]
fn a_typed_address_or_one_after_a_non_web_page_arrives_fresh() {
    let typed = committed(
        &PageMemory { last: Some("https://example.com/".into()), typed: true },
        "https://open.spotify.com/",
    );
    assert_eq!(typed.check, Some(true));
    assert_eq!(
        typed.memory,
        PageMemory { last: Some("https://open.spotify.com/".into()), typed: false }
    );
    let redirect = committed(&typed.memory, "https://accounts.example.com/");
    assert_eq!(redirect.check, Some(false), "a redirect from a web page is no fresh arrival");
    let again = committed(&redirect.memory, "https://accounts.example.com/");
    assert_eq!(again.check, None, "the same page again is not checked");
    let new_tab = committed(
        &PageMemory { last: Some("chrome://newtab/".into()), typed: false },
        "https://a.com/",
    );
    assert_eq!(new_tab.check, Some(true));
    assert_eq!(committed(&PageMemory::default(), "https://a.com/").check, Some(true));
}

#[test]
fn only_a_fresh_unpinned_chromium_page_with_a_webkit_rule_reopens() {
    let moves = SiteEngineMove {
        site_engine: Some(DefaultEngine::Webkit),
        engine_is_chromium: true,
        arrived_fresh: true,
        ..SiteEngineMove::default()
    };
    assert!(moves.reopens_in_webkit());
    for stays in [
        SiteEngineMove { keeps_opener: true, ..moves },
        SiteEngineMove { engine_pinned: true, ..moves },
        SiteEngineMove { already_reopened: true, ..moves },
        SiteEngineMove { agent_driven: true, ..moves },
        SiteEngineMove { arrived_fresh: false, ..moves },
        SiteEngineMove { engine_is_chromium: false, ..moves },
        SiteEngineMove { site_engine: Some(DefaultEngine::Chromium), ..moves },
        SiteEngineMove { site_engine: None, ..moves },
    ] {
        assert!(!stays.reopens_in_webkit(), "{stays:?}");
    }
}

#[test]
fn a_machine_that_is_not_connected_is_refused_and_a_chromium_tab_never_stands_in() {
    assert_eq!(route(false, false, true), Route::RefuseNotConnected);
    assert_eq!(route(true, false, true), Route::Daemon);
    assert_eq!(route(false, true, false), Route::SessionLocal);
    assert!(allows_session_local_tab(None, false));
    assert!(allows_session_local_tab(Some("webkit"), false));
    assert!(!allows_session_local_tab(Some("CEF"), false));
    assert!(!allows_session_local_tab(None, true));
}

#[test]
fn the_first_tab_showing_the_page_in_strip_order_matches() {
    let tabs = [
        web("a", "https://other.com/"),
        web("b", "https://example.com/"),
        web("c", "https://example.com/"),
    ];
    assert_eq!(first(&tabs, "https://EXAMPLE.com/#section", "webkit", None), Some("b"));
}

#[test]
fn another_profile_or_engine_never_matches() {
    let tabs = [
        tab("a", None, "work", Some("https://example.com/")),
        tab("b", Some("cef"), DEFAULT_PROFILE, Some("https://example.com/")),
    ];
    assert_eq!(first(&tabs, "https://example.com/", "webkit", None), None);
    assert_eq!(first(&tabs, "https://example.com/", "webkit", Some("work")), Some("a"));
    assert_eq!(first(&tabs, "https://example.com/", "cef", None), Some("b"));
}

#[test]
fn a_record_without_an_engine_is_webkit() {
    let named = [tab("a", Some("webkit"), DEFAULT_PROFILE, Some("https://example.com/"))];
    assert_eq!(first(&named, "https://example.com/", "webkit", None), Some("a"));
    assert_eq!(
        first(&[web("a", "https://example.com/")], "https://example.com/", "webkit", None),
        Some("a")
    );
}

#[test]
fn a_tab_with_no_page_or_another_page_never_matches() {
    let tabs = [
        tab("a", None, DEFAULT_PROFILE, None),
        web("b", "https://example.com/other"),
        web("c", "https://example.com/?q=1"),
    ];
    assert_eq!(first(&tabs, "https://example.com/", "webkit", None), None);
}

#[test]
fn only_a_changed_fragment_navigates() {
    let shown = Some("https://example.com/#top");
    assert!(navigates(shown, "https://example.com/#section"));
    assert!(navigates(shown, "https://example.com/"));
    assert!(!navigates(shown, "https://example.com/#top"));
}

#[test]
fn same_page_ignores_case_of_scheme_and_host_a_trailing_slash_and_the_fragment() {
    assert!(same_page("HTTPS://Example.COM/docs/", "https://example.com/docs#intro"));
    assert!(same_page("https://example.com", "https://example.com/"));
    assert!(!same_page("https://example.com/Docs", "https://example.com/docs"));
    assert!(!same_page("https://example.com/a?x=1", "https://example.com/a?x=2"));
    assert!(!same_page("http://example.com/", "https://example.com/"));
}

#[test]
fn a_machine_browser_record_names_its_machine_and_a_web_first_page() {
    let record =
        machine_record("cmux://remote-browser?machine=m1&url=https%3A%2F%2Fexample.com%2F")
            .unwrap();
    assert_eq!(
        record,
        MachineRecord { machine: "m1".into(), initial_url: Some("https://example.com/".into()) }
    );
    assert_eq!(
        machine_record("CMUX://Remote-Browser?machine=m1&url=file:///etc/passwd")
            .unwrap()
            .initial_url,
        None,
        "only an http or https first page"
    );
    assert_eq!(machine_record("cmux://remote-browser?machine=m1&address=127.0.0.1"), None);
    assert_eq!(machine_record("cmux://remote-browser?machine="), None);
    assert_eq!(machine_record("cmux://remote-browser"), None);
    assert_eq!(machine_record("cmux://settings?machine=m1"), None);
    assert_eq!(machine_record("https://remote-browser?machine=m1"), None);
    assert!(owned_record(Some("cmux://remote-browser?machine=m1"), "m1").is_some());
    assert!(owned_record(Some("cmux://remote-browser?machine=m1"), "m2").is_none());
    assert!(owned_record(None, "m1").is_none());
}

#[test]
fn with_the_browser_off_only_cmux_pages_open() {
    assert!(allows(true, Some("https://example.com/")));
    assert!(allows(true, None));
    assert!(!allows(false, Some("https://example.com/")));
    assert!(!allows(false, None));
    assert!(allows(false, Some("cmux-page://settings")));
    assert!(allows(false, Some("cmux://settings")));
    assert!(
        !allows(false, Some("cmux://remote-browser?machine=m1")),
        "a machine's browser is a browser"
    );
}

#[test]
fn an_address_splits_as_rfc_3986_does() {
    let url = Url::split("https://user@[::1]:8080/a/b?x=1#frag");
    assert_eq!(url.scheme, Some("https"));
    assert_eq!(url.authority, Some("user@[::1]:8080"));
    assert_eq!(url.host(), Some("::1"));
    assert_eq!(url.path, "/a/b");
    assert_eq!(url.query, Some("x=1"));
    assert_eq!(url.fragment, Some("frag"));
    let bare = Url::split("about:blank");
    assert_eq!((bare.scheme, bare.authority, bare.path), (Some("about"), None, "blank"));
    assert_eq!(Url::split("/relative:path").scheme, None);
}
