//! Ported from the Swift `RingReturnTests` (the decision; the card text and
//! the probe wiring stay in Swift).

mod updater_core_ring_return {
    use cmux_updater_core::ring_return::{RingReturn, decide};
    use std::collections::BTreeSet;

    fn list(builds: &[&str]) -> Vec<String> {
        builds.iter().map(|build| (*build).to_owned()).collect()
    }

    fn set(builds: &[&str]) -> BTreeSet<String> {
        builds.iter().map(|build| (*build).to_owned()).collect()
    }

    /// Nightly's view of a feed where 500 is a Dev build and 300 the newest promoted one.
    fn nightly_offered() -> Vec<String> {
        list(&["300", "200"])
    }

    #[test]
    fn a_dev_build_nightly_has_not_reached_goes_back_to_the_newest_kept_nightly_build() {
        let way =
            decide("500", &nightly_offered(), &set(&[]), &set(&[]), &list(&["450", "300", "200"]));
        // 450 was a Dev build: not on Nightly, so the way back skips it.
        assert_eq!(way, RingReturn::GoBack { kept: 1 });
    }

    #[test]
    fn a_kept_build_the_canary_passed_counts_as_nightly_after_it_leaves_the_feed() {
        let way =
            decide("500", &nightly_offered(), &set(&["120"]), &set(&[]), &list(&["450", "120"]));
        assert_eq!(way, RingReturn::GoBack { kept: 1 });
    }

    #[test]
    fn a_pulled_build_is_never_the_way_back_even_with_its_canary_pass() {
        let way = decide(
            "500",
            &nightly_offered(),
            &set(&["320", "300"]),
            &set(&["320"]),
            &list(&["320", "300"]),
        );
        assert_eq!(way, RingReturn::GoBack { kept: 1 });
        assert_eq!(
            decide("500", &list(&["200"]), &set(&["320"]), &set(&["320"]), &list(&["320"])),
            RingReturn::Waits
        );
    }

    #[test]
    fn nothing_kept_on_the_ring_waits_for_it_to_pass_the_running_build() {
        assert_eq!(
            decide("500", &nightly_offered(), &set(&[]), &set(&[]), &list(&["450"])),
            RingReturn::Waits
        );
        assert_eq!(decide("500", &nightly_offered(), &set(&[]), &set(&[]), &[]), RingReturn::Waits);
    }

    #[test]
    fn the_running_build_on_the_ring_or_behind_it_takes_the_normal_update_path() {
        // On the ring (in the feed, or promoted since): nothing to go back to.
        assert_eq!(
            decide("300", &nightly_offered(), &set(&[]), &set(&[]), &list(&["200"])),
            RingReturn::None
        );
        assert_eq!(
            decide("500", &nightly_offered(), &set(&["500"]), &set(&[]), &list(&["300"])),
            RingReturn::None
        );
        // The ring has a newer build: Sparkle offers it.
        assert_eq!(
            decide("250", &nightly_offered(), &set(&[]), &set(&[]), &list(&["200"])),
            RingReturn::None
        );
    }

    /// A kept build newer than the running one is never "back".
    #[test]
    fn a_kept_build_newer_than_the_running_one_is_skipped() {
        assert_eq!(
            decide("500", &list(&["600"]), &set(&[]), &set(&[]), &list(&["600"])),
            RingReturn::None
        );
        assert_eq!(
            decide("500", &list(&[]), &set(&["700", "300"]), &set(&[]), &list(&["700", "300"])),
            RingReturn::GoBack { kept: 1 }
        );
    }
}
