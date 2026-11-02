//! Ported from the Swift `ChannelTrackTests` (the tracks and their links; the
//! verdict and pulled-list downloads stay in Swift).

mod updater_core_channel_track {
    use cmux_updater_core::channel_track::{
        ChannelBuild, ChannelTrack, FeedEntry, Health, IndexEntry, Ring, TracksRequest, commit_url,
        compare_url, tracks,
    };
    use cmux_updater_core::pulled::PulledBuild;
    use std::collections::{BTreeMap, BTreeSet};

    fn entry(build: &str, date: &str, head: Option<&str>) -> IndexEntry {
        IndexEntry {
            build: build.to_owned(),
            short_version: format!("1.0.0-nightly.{build}"),
            date: date.to_owned(),
            head: head.map(str::to_owned),
        }
    }

    fn index() -> Vec<IndexEntry> {
        vec![
            entry("300", "2026-10-21", Some("cccccccc")),
            entry("200", "2026-10-20", Some("bbbbbbbb")),
            entry("100", "2026-10-19", None),
        ]
    }

    fn pulled(build: &str, reason: &str) -> PulledBuild {
        PulledBuild {
            build: build.to_owned(),
            reason: reason.to_owned(),
            pulled_at: None,
            serve: None,
        }
    }

    fn request(installed: &str, followed: Ring, limit: i64) -> TracksRequest {
        let verdicts: BTreeMap<String, String> =
            [("300", "fail"), ("200", "pass"), ("100", "skipped")]
                .iter()
                .map(|(b, v)| ((*b).to_owned(), (*v).to_owned()))
                .collect();
        TracksRequest {
            index: index(),
            verdicts,
            pulled: vec![pulled("300", "crashes on launch")],
            installed_build: installed.to_owned(),
            kept_builds: ["100".to_owned()].into_iter().collect(),
            followed,
            limit,
            feed_items: Vec::new(),
        }
    }

    fn track(tracks: &[ChannelTrack], ring: Ring) -> ChannelTrack {
        tracks.iter().find(|track| track.ring == ring).cloned().unwrap()
    }

    fn installed(track: &ChannelTrack) -> Option<&ChannelBuild> {
        track.builds.iter().find(|build| build.is_installed)
    }

    #[test]
    fn one_track_per_ring_slowest_first_and_only_the_followed_one_marked() {
        let tracks = tracks(&request("200", Ring::Canary, 10));
        let rings: Vec<Ring> = tracks.iter().map(|track| track.ring).collect();
        assert_eq!(rings, vec![Ring::Stable, Ring::Nightly, Ring::Canary, Ring::Dev]);
        let followed: Vec<Ring> =
            tracks.iter().filter(|track| track.is_followed).map(|track| track.ring).collect();
        assert_eq!(followed, vec![Ring::Canary]);
        // Dev takes every published build; Stable and Canary have none until CI publishes them.
        let counts: Vec<usize> = tracks.iter().map(|track| track.builds.len()).collect();
        assert_eq!(counts, vec![0, 3, 0, 3]);
    }

    #[test]
    fn each_build_carries_its_verdict_pull_and_kept_copy() {
        let nightly = track(&tracks(&request("200", Ring::Nightly, 10)), Ring::Nightly);
        let health: Vec<Health> = nightly.builds.iter().map(|build| build.health).collect();
        assert_eq!(health, vec![Health::Pulled, Health::Promoted, Health::Pending]);
        assert_eq!(
            nightly.builds.first().unwrap().pulled_reason.as_deref(),
            Some("crashes on launch")
        );
        let kept: Vec<bool> = nightly.builds.iter().map(|build| build.is_kept).collect();
        assert_eq!(kept, vec![false, false, true]);
        assert_eq!(installed(&nightly).map(|build| build.build.as_str()), Some("200"));
        assert_eq!(
            nightly.release_url.as_deref(),
            Some("https://github.com/manaflow-ai/cmux/releases/tag/nightly-next")
        );
    }

    #[test]
    fn the_dev_track_also_lists_the_feeds_builds_the_index_lacks_newest_first() {
        // The published DEV app's tip feed has no notes index: its builds come from the feed alone.
        let feed = |version: &str, display: Option<&str>, date: Option<f64>| FeedEntry {
            version: version.to_owned(),
            display_version: display.unwrap_or(version).to_owned(),
            date,
        };
        let request = TracksRequest {
            index: index(),
            verdicts: BTreeMap::new(),
            pulled: vec![pulled("250", "bad")],
            installed_build: "400".to_owned(),
            kept_builds: ["150".to_owned()].into_iter().collect::<BTreeSet<String>>(),
            followed: Ring::Dev,
            limit: 10,
            feed_items: vec![
                feed("400", Some("1.0.0-tip.400"), Some(1_793_558_519.0)), // 2026-11-01 UTC
                feed("300", None, None),
                feed("250", None, None),
                feed("150", Some("1.0.0-tip.150"), None),
            ],
        };
        let tracks = tracks(&request);
        let dev = track(&tracks, Ring::Dev);
        let builds: Vec<&str> = dev.builds.iter().map(|build| build.build.as_str()).collect();
        assert_eq!(builds, vec!["400", "300", "200", "150", "100"]);
        assert_eq!(
            installed(&dev).map(|build| build.short_version.as_str()),
            Some("1.0.0-tip.400")
        );
        assert_eq!(installed(&dev).map(|build| build.date.as_str()), Some("2026-11-01"));
        assert_eq!(
            dev.builds.iter().find(|build| build.build == "150").map(|build| build.is_kept),
            Some(true)
        );
        // Nightly stays the index alone.
        let nightly: Vec<String> =
            track(&tracks, Ring::Nightly).builds.iter().map(|build| build.build.clone()).collect();
        assert_eq!(nightly, vec!["300", "200", "100"]);
    }

    #[test]
    fn the_running_build_off_the_recent_list_marks_nothing() {
        assert!(
            tracks(&request("50", Ring::Nightly, 10))
                .iter()
                .all(|track| installed(track).is_none())
        );
        let nightly = track(&tracks(&request("200", Ring::Nightly, 2)), Ring::Nightly);
        let builds: Vec<&str> = nightly.builds.iter().map(|build| build.build.as_str()).collect();
        assert_eq!(builds, vec!["300", "200"]);
        assert!(
            tracks(&request("200", Ring::Nightly, -1)).iter().all(|track| track.builds.is_empty())
        );
    }

    #[test]
    fn compare_goes_from_the_installed_builds_commit() {
        let nightly = track(&tracks(&request("200", Ring::Nightly, 10)), Ring::Nightly);
        let first = nightly.builds.first().unwrap();
        assert_eq!(
            first.compare_url.as_deref(),
            Some("https://github.com/manaflow-ai/cmux/compare/bbbbbbbb...cccccccc")
        );
        assert_eq!(nightly.builds.get(1).unwrap().compare_url, None);
        // No commit in the index: no compare and no commit link.
        assert_eq!(nightly.builds.get(2).unwrap().compare_url, None);
        assert_eq!(nightly.builds.get(2).unwrap().commit_url, None);
        assert_eq!(
            first.commit_url.as_deref(),
            Some("https://github.com/manaflow-ai/cmux/commit/cccccccc")
        );
    }

    #[test]
    fn a_feed_value_that_is_not_a_commit_never_becomes_a_link() {
        assert_eq!(commit_url(Some("../../evil")), None);
        assert_eq!(compare_url(Some("abcdef12"), Some("../../evil")), None);
        assert_eq!(commit_url(Some("abc12")), None, "shorter than 7");
        assert_eq!(commit_url(Some(&"a".repeat(41))), None, "longer than 40");
        assert_eq!(compare_url(Some("abcdef12"), Some("abcdef12")), None, "the same commit");
        assert_eq!(compare_url(None, Some("abcdef12")), None);
    }
}
