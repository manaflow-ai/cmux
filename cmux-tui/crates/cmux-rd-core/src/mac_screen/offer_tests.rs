use super::*;

const KEY: &str = "abababababababababababababababababababababababababababababababab";

/// MacScreenRdWishTests.autoFollowsThePaneWidthAndTheFixedPresetsDoNot
#[test]
fn auto_follows_the_pane_width_and_the_fixed_presets_do_not() {
    assert_eq!(wish(Quality::Auto, 60, None, None).max_width, None, "no pane yet");
    assert_eq!(wish(Quality::Auto, 60, Some(2081), None).max_width, Some(2096), "up to 16");
    assert_eq!(wish(Quality::Auto, 60, Some(600), None).max_width, Some(1280), "never < 1280");
    assert_eq!(wish(Quality::High, 60, Some(1000), None).max_width, None, "High: full size");
    assert_eq!(
        wish(Quality::Smooth, 120, Some(1000), None),
        Wish { max_width: Some(1920), max_fps: 120 }
    );
}

/// MacScreenRemoteDesktopDefaultsTests.theFrameRateLimitOnlyLowers
#[test]
fn the_frame_rate_limit_only_lowers() {
    assert_eq!(wish(Quality::Low, 120, None, Some(90)).max_fps, 60);
    assert_eq!(wish(Quality::Auto, 120, None, Some(15)).max_fps, 15, "not floored at 30");
    assert_eq!(wish(Quality::Auto, 120, None, None).max_fps, 120);
    assert_eq!(wish(Quality::Auto, 240, None, None).max_fps, 120, "a display over 120");
    assert_eq!(wish(Quality::Auto, 24, None, None).max_fps, 30, "a display under 30");
    assert_eq!(wish(Quality::Auto, 60, None, Some(0)).max_fps, 1, "never 0");
    assert_eq!(
        wish(Quality::Medium, 120, Some(1), None),
        Wish { max_width: Some(1920), max_fps: 60 }
    );
}

/// MacScreenRemoteDesktopDefaultsTests.theLimitsReachTheOffer
#[test]
fn the_limits_reach_the_offer() {
    let inputs = OfferInputs {
        quality: Quality::Smooth,
        refresh: 120,
        pane_width: Some(1000),
        max_fps: Some(30),
        customize: Customize { max_kbps: Some(4000), show_cursor: true },
        encode_profile: None,
    };
    let (offer, wish) = make_offer(KEY, &inputs, None, None);
    assert_eq!(wish, Wish { max_width: Some(1920), max_fps: 30 });
    let text = offer.text();
    assert!(text.contains("a=cmux-rd-max-fps:30\r\n"));
    assert!(text.contains("a=cmux-rd-max-kbps:4000\r\n"));
    assert!(!text.contains("cmux-rd-cursor") && !text.contains("encode-profile"));
    assert_eq!(RdDocument::parse(&text), Some(offer));
}

/// MacScreenRdCustomizeTests.customizeWishesRoundTripAndDefaultsAddNothing
#[test]
fn customize_wishes_round_trip_and_defaults_add_nothing() {
    let mut doc = RdDocument { key: KEY.into(), ..RdDocument::default() };
    customize(&mut doc, Customize::default());
    assert!(!doc.text().contains("max-kbps") && !doc.text().contains("cmux-rd-cursor"));
    customize(&mut doc, Customize { max_kbps: Some(10_000), show_cursor: false });
    assert!(doc.text().contains("a=cmux-rd-max-kbps:10000\r\n"));
    assert!(doc.text().contains("a=cmux-rd-cursor:0\r\n"));
    assert_eq!(RdDocument::parse(&doc.text()), Some(doc));
}

/// MacScreenRunLinkTests.theOfferNamesTheDisplayAndTheAnswerListsTheIDs
#[test]
fn the_offer_names_the_display_and_the_answer_lists_the_ids() {
    let (offer, _) = make_offer(KEY, &OfferInputs::default(), None, Some(69_734_208));
    assert!(offer.text().contains("a=cmux-rd-display-id:69734208\r\n"));
    assert_eq!(RdDocument::parse(&offer.text()).unwrap().display_id, Some(69_734_208));
    // A picked display wins over the run's.
    let (picked, _) = make_offer(KEY, &OfferInputs::default(), Some(1), Some(69_734_208));
    assert_eq!((picked.display, picked.display_id), (Some(1), None));
    let mut answer = RdDocument {
        key: "cd".repeat(32),
        displays: vec![(3024, 1964), (1920, 1080)],
        display_ids: vec![1, 69_734_208],
        current_display: Some(1),
        ..RdDocument::default()
    };
    let parsed = RdDocument::parse(&answer.text()).unwrap();
    assert_eq!(
        (parsed.display_ids.clone(), parsed.current_display),
        (vec![1, 69_734_208], Some(1))
    );
    assert!(!lacks_display(&parsed, 69_734_208) && lacks_display(&parsed, 7));
    answer.display_ids.clear();
    assert!(!answer.text().contains("display-ids"));
    assert!(!lacks_display(&RdDocument::parse(&answer.text()).unwrap(), 69_734_208));
}

#[test]
fn ultra_rides_the_offer_and_balanced_sends_no_line() {
    let inputs = OfferInputs { encode_profile: Some("ultra".into()), ..OfferInputs::default() };
    assert!(
        make_offer(KEY, &inputs, None, None)
            .0
            .text()
            .contains("a=cmux-rd-encode-profile:ultra\r\n")
    );
    assert!(
        !make_offer(KEY, &OfferInputs::default(), None, None).0.text().contains("encode-profile")
    );
}
