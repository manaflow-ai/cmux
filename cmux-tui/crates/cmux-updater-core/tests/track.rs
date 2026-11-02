//! Ported from the Swift `TipAppTrackTests`, the track and test-feed columns
//! of `UpdateTrackMatrixTests`, and the default checks of
//! `SilentBackgroundUpdateTests` / `UpdateAsksBeforeInstallTests`. The feed
//! channel is what Swift's `UpdateFeedResolver` classifies (it stays Swift:
//! Sparkle's delegate reads it).

mod updater_core_track {
    use cmux_updater_core::track::{
        BuildFacts, DisabledReason, FeedChannel, InfoStrings, UpdateTrack, build_info, build_rules,
        has_public_key, is_development_bundle, is_tip_build, offers_channel_switch,
        sparkle_disabled_reason, track,
    };
    use cmux_updater_core::version::SystemVersion;

    const TIP_FEED: &str = "https://files.cmux.com/nightly-next/tip/appcast-arm64.xml";
    const STABLE_FEED: &str =
        "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml";

    /// `UpdateFeedResolver.Channel.classify` for the feeds below.
    fn channel(feed: Option<&str>) -> FeedChannel {
        match feed {
            Some(feed) if feed.contains("/nightly-next/") => FeedChannel::NightlyNext,
            Some(feed) if feed.contains("/nightly/") => FeedChannel::Nightly,
            Some(feed) if feed.contains("/rc/") => FeedChannel::Rc,
            _ => FeedChannel::Stable,
        }
    }

    fn facts(bundle: &str, feed: Option<&str>, has_key: bool) -> BuildFacts {
        BuildFacts {
            bundle_identifier: Some(bundle.to_owned()),
            info_feed_url: feed.filter(|feed| !feed.is_empty()).map(str::to_owned),
            has_public_key: has_key,
            feed_channel: channel(feed.filter(|feed| !feed.is_empty())),
            managed_policy_disables_updates: false,
        }
    }

    #[test]
    fn the_tip_stamped_dev_app_is_nightly_and_runs_sparkle() {
        let tip = facts("com.cmuxterm.app.debug.next", Some(TIP_FEED), true);
        assert!(is_tip_build(tip.bundle_identifier.as_deref(), tip.info_feed_url.as_deref()));
        assert_eq!(track(&tip), UpdateTrack::NightlyNext);
        assert_eq!(sparkle_disabled_reason(&tip), None);
        // A managed DisableAutoUpdate still wins.
        let managed = BuildFacts { managed_policy_disables_updates: true, ..tip.clone() };
        assert_eq!(sparkle_disabled_reason(&managed), Some(DisabledReason::ManagedPolicy));
        assert!(offers_channel_switch(&tip));
    }

    #[test]
    fn the_tip_app_without_a_key_does_not_run_sparkle() {
        let tip = facts("com.cmuxterm.app.debug.next", Some(TIP_FEED), false);
        assert_eq!(track(&tip), UpdateTrack::NightlyNext);
        assert_eq!(sparkle_disabled_reason(&tip), Some(DisabledReason::MissingPublicKey));
    }

    /// `reload.sh --tag next` builds the same bundle id with the default (stable) feed.
    #[test]
    fn the_dev_app_with_any_other_feed_stays_development() {
        for feed in [
            Some(STABLE_FEED),
            None,
            Some(""),
            Some("https://files-next.cmux.com/nightly-next/appcast-arm64.xml"),
            Some("https://files.cmux.com/nightly/appcast-arm64.xml"),
            Some("https://example.com/nightly-next/tip/appcast-arm64.xml"),
        ] {
            let dev = facts("com.cmuxterm.app.debug.next", feed, true);
            assert!(
                !is_tip_build(dev.bundle_identifier.as_deref(), dev.info_feed_url.as_deref()),
                "{feed:?}"
            );
            assert_eq!(track(&dev), UpdateTrack::Development, "{feed:?}");
            assert_eq!(
                sparkle_disabled_reason(&dev),
                Some(DisabledReason::DevelopmentBuild),
                "{feed:?}"
            );
            assert!(!offers_channel_switch(&dev), "{feed:?}");
        }
    }

    #[test]
    fn other_dev_and_staging_builds_with_the_tip_feed_stay_development() {
        for bundle in [
            "com.cmuxterm.app.debug",
            "com.cmuxterm.app.debug.next.other",
            "com.cmuxterm.app.debug.nextx",
            "com.cmuxterm.app.debug.tip",
            "com.cmuxterm.app.staging",
            "com.cmuxterm.app.staging.next",
        ] {
            let other = facts(bundle, Some(TIP_FEED), true);
            assert!(
                !is_tip_build(other.bundle_identifier.as_deref(), other.info_feed_url.as_deref()),
                "{bundle}"
            );
            assert_eq!(track(&other), UpdateTrack::Development, "{bundle}");
            assert_eq!(
                sparkle_disabled_reason(&other),
                Some(DisabledReason::DevelopmentBuild),
                "{bundle}"
            );
        }
    }

    #[test]
    fn release_apps_keep_their_tracks() {
        assert_eq!(
            track(&facts(
                "com.cmuxterm.app.nightly",
                Some("https://files.cmux.com/nightly/appcast-arm64.xml"),
                true
            )),
            UpdateTrack::Nightly
        );
        assert_eq!(track(&facts("com.cmuxterm.app", Some(STABLE_FEED), true)), UpdateTrack::Stable);
        // A release id reading the tip feed is not "the tip app", but its feed still classifies it.
        let next = facts("com.cmuxterm.app.nightly.cmux-next", Some(TIP_FEED), true);
        assert!(!is_tip_build(next.bundle_identifier.as_deref(), next.info_feed_url.as_deref()));
        assert_eq!(track(&next), UpdateTrack::NightlyNext);
    }

    /// cmux NEXT Stable: a nightly-kind bundle id with the stable feed under /nightly-next/.
    #[test]
    fn cmux_next_stable_is_a_nightly_track_on_its_own_feed() {
        let stable = facts(
            "com.cmuxterm.app.nightly.cmux-next-stable",
            Some("https://files-next.cmux.com/nightly-next/stable/appcast-arm64.xml"),
            true,
        );
        assert_eq!(track(&stable), UpdateTrack::NightlyNext);
        assert_eq!(sparkle_disabled_reason(&stable), None);
    }

    /// UpdateTrackMatrixTests: the track on the wire and test-feed availability per release identity.
    #[test]
    fn each_release_identity_has_its_track_and_test_feed_rule() {
        let rows = [
            ("com.cmuxterm.app", STABLE_FEED, "stable", false),
            ("com.cmuxterm.app.rc", "https://files.cmux.com/rc/appcast-arm64.xml", "rc", false),
            (
                "com.cmuxterm.app.nightly",
                "https://files.cmux.com/nightly/appcast-arm64.xml",
                "nightly",
                true,
            ),
            (
                "com.cmuxterm.app.nightly.cmux-next",
                "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml",
                "nightly-next",
                true,
            ),
            (
                "com.cmuxterm.app.nightly",
                "https://files-next.cmux.com/nightly-next/appcast-arm64.xml",
                "nightly-next",
                true,
            ),
            ("com.cmuxterm.app.debug.next", TIP_FEED, "nightly-next", true),
            ("com.cmuxterm.app.debug.next", STABLE_FEED, "development", true),
            ("com.cmuxterm.app.debug", STABLE_FEED, "development", true),
        ];
        for (bundle, feed, wire, test_feed) in rows {
            let rules = build_rules(&facts(bundle, Some(feed), true));
            assert_eq!(
                serde_json::to_value(rules.track).unwrap(),
                serde_json::json!(wire),
                "{bundle} {feed}"
            );
            assert_eq!(rules.allows_test_feed, test_feed, "{bundle} {feed}");
        }
    }

    /// Every track asks before it downloads by default (the download opt-in is off).
    #[test]
    fn no_track_downloads_by_itself_by_default() {
        for track in [
            UpdateTrack::Stable,
            UpdateTrack::Rc,
            UpdateTrack::Nightly,
            UpdateTrack::NightlyNext,
            UpdateTrack::Development,
        ] {
            assert!(!track.downloads_automatically_by_default(), "{track:?}");
        }
    }

    #[test]
    fn existing_track_names_are_unchanged() {
        for (track, name) in [
            (UpdateTrack::Stable, "stable"),
            (UpdateTrack::Nightly, "nightly"),
            (UpdateTrack::Rc, "rc"),
            (UpdateTrack::Development, "development"),
            (UpdateTrack::NightlyNext, "nightly-next"),
        ] {
            assert_eq!(serde_json::to_value(track).unwrap(), serde_json::json!(name));
        }
    }

    #[test]
    fn development_bundles_are_debug_or_staging_with_an_optional_tag() {
        assert!(is_development_bundle(Some("com.cmuxterm.app.debug")));
        assert!(is_development_bundle(Some("com.cmuxterm.app.debug.my-tag")));
        assert!(is_development_bundle(Some("com.cmuxterm.app.staging.next")));
        assert!(!is_development_bundle(Some("com.cmuxterm.app.debugger")));
        assert!(!is_development_bundle(Some("com.cmuxterm.app")));
        assert!(!is_development_bundle(None));
    }

    /// `UpdateBuildIdentity(infoDictionary:)`, the identity TipAppTrackTests builds.
    #[test]
    fn the_info_dictionary_reads_defaults_the_floor_and_the_key() {
        let info = InfoStrings {
            bundle_identifier: Some("com.cmuxterm.app.debug.next".to_owned()),
            short_version: Some("0.1.0".to_owned()),
            build: Some("24950001".to_owned()),
            minimum_system_version: Some("26.0".to_owned()),
            feed_url: Some(TIP_FEED.to_owned()),
            public_key: Some("dGVzdC1rZXktbm90LXJlYWwtYnV0LW5vbi1lbXB0eQ==".to_owned()),
        };
        let identity = build_info(&info);
        assert_eq!(identity.build, "24950001");
        assert_eq!(identity.minimum_system_version, Some(SystemVersion::new(26, 0, 0)));
        assert!(identity.has_public_key);
        let empty = build_info(&InfoStrings::default());
        assert_eq!((empty.short_version.as_str(), empty.build.as_str()), ("0", "0"));
        assert!(!empty.has_public_key);
    }

    /// An unsubstituted `$(SPARKLE_PUBLIC_KEY)` or blank value is not a key; only spaces and tabs are trimmed.
    #[test]
    fn a_public_key_must_be_real() {
        assert!(has_public_key(Some("abc")));
        assert!(has_public_key(Some(" \tabc ")));
        assert!(!has_public_key(Some("$(SPARKLE_PUBLIC_KEY)")));
        assert!(!has_public_key(Some("  $(X)")));
        assert!(!has_public_key(Some(" \t ")));
        assert!(!has_public_key(None));
        assert!(has_public_key(Some("\n")), "newlines are not trimmed");
    }
}
