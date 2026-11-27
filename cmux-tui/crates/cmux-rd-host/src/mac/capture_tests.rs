use super::*;

#[test]
fn a_frame_from_before_the_newest_exclusion_list_is_dropped() {
    // The stream opened with no list (generation 0); the app's first list is generation 1.
    assert!(frame_current(0, 0, 0, Some(5)));
    assert!(!frame_current(0, 0, 1, Some(5)), "the filter does not leave out list 1 yet");
    // List 1 took effect at mach 100: frames composited before it still show the windows.
    assert!(!frame_current(1, 100, 1, Some(99)));
    assert!(frame_current(1, 100, 1, Some(100)));
    assert!(frame_current(1, 100, 1, None), "no display time: the filter's generation decides");
    assert!(!frame_current(1, 100, 2, Some(200)), "a newer list is not applied yet");
}

#[test]
fn an_older_list_never_replaces_a_newer_on_a_stream() {
    let filter = FilterGen::new(0, 0);
    filter.applied(2, 300);
    filter.applied(1, 400);
    assert_eq!(filter.generation.load(Ordering::Acquire), 2);
    assert_eq!(filter.since_mach.load(Ordering::Acquire), 300);
    filter.applied(3, 500);
    assert_eq!(filter.generation.load(Ordering::Acquire), 3);
    assert_eq!(filter.since_mach.load(Ordering::Acquire), 500);
}

#[test]
fn a_session_starts_only_on_a_frame_filtered_with_the_newest_list() {
    let requested = requested_generation();
    let mut shared = Shared::default();
    assert!(!filtered_with_newest_list(&shared), "no frame yet");
    shared.newest_generation = requested;
    assert!(!filtered_with_newest_list(&shared), "still no frame");
    shared.dropped = true;
    assert!(!filtered_with_newest_list(&shared), "a dropped frame is not one");
}

#[test]
fn a_stop_from_the_menu_bar_ends_the_share() {
    let mut at = Vec::new();
    let ended = restart_allowed(STOPPED_BY_PERSON, "stopped", &mut at, Instant::now());
    assert_eq!(ended.unwrap_err().to_string(), "sharing was stopped from the macOS menu bar");
    assert!(at.is_empty());
}

#[test]
fn other_stops_restart_until_they_repeat_too_often() {
    let start = Instant::now();
    let mut at = Vec::new();
    for i in 0..MAX_RESTARTS as u64 {
        let now = start + Duration::from_secs(i);
        assert!(restart_allowed(-3821, "display changed", &mut at, now).is_ok());
    }
    let now = start + Duration::from_secs(MAX_RESTARTS as u64);
    let ended = restart_allowed(-3821, "display changed", &mut at, now).unwrap_err();
    assert_eq!(ended.to_string(), "the screen capture keeps stopping (display changed)");
    // Once the window has passed, a stop restarts again.
    let later = start + RESTART_WINDOW + Duration::from_secs(MAX_RESTARTS as u64);
    assert!(restart_allowed(-3821, "display changed", &mut at, later).is_ok());
}

#[test]
fn sizes_fit_the_decoder_and_stay_even() {
    assert_eq!(fit(3456, 2234, None), (3342, 2160));
    assert_eq!(fit(1920, 1080, Some(1280)), (1280, 720));
    assert_eq!(fit(1366, 768, None), (1366, 768));
}

#[test]
fn refresh_rates_round_and_zero_means_unknown() {
    assert_eq!(hz_to_fps(120.0), Some(120));
    assert_eq!(hz_to_fps(119.88), Some(120));
    assert_eq!(hz_to_fps(59.94), Some(60));
    assert_eq!(hz_to_fps(0.0), None);
    assert_eq!(hz_to_fps(f64::NAN), None);
    assert_eq!(hz_to_fps(500.0), Some(MAX_REFRESH_FPS));
}

#[test]
fn the_minimum_frame_interval_stays_clear_of_the_display_cadence() {
    let seconds = |t: CMTime| t.value as f64 / f64::from(t.timescale);
    // 60 fps on a 120 Hz panel: below two refreshes (16.67 ms), above one (8.33 ms).
    let at_60 = seconds(min_frame_interval(60));
    assert!(at_60 < 2.0 / 120.0 - 0.001 && at_60 > 1.0 / 120.0, "{at_60}");
    // At the refresh rate itself: below one refresh.
    assert!(seconds(min_frame_interval(120)) < 1.0 / 120.0 - 0.0005);
    assert!(seconds(min_frame_interval(0)) > 0.0);
    assert_eq!(min_frame_interval(1000).timescale, (MAX_REFRESH_FPS * 10) as i32);
}

#[test]
fn exclusion_lists_are_sorted_unique_and_skip_zero() {
    assert_eq!(exclusion_list([456, 0, 123, 456]), vec![123, 456]);
    assert_eq!(exclusion_list([]), Vec::<u32>::new());
    assert!(exclusion_list([9, 3, 7]).binary_search(&7).is_ok());
}

#[test]
fn dirty_points_become_clamped_pixels() {
    let rect = to_pixels((10.0, 20.0, 5.0, 5.0), 2.0, (100, 100));
    assert_eq!(rect, Some(Rect { x: 20, y: 40, width: 10, height: 10 }));
    assert_eq!(to_pixels((60.0, 60.0, 10.0, 10.0), 2.0, (100, 100)), None);
}
