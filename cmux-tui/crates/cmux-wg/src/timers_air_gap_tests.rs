use super::*;

const GAP: Duration = Duration::from_secs(20);

#[test]
fn no_gap_holds_nothing() {
    let mut gap = AirGap::default();
    gap.probed((0, 100), Instant::now());
    assert_eq!(gap.floor(100), None);
}

#[test]
fn own_sends_hold_the_next_until_the_gap_passed() {
    let now = Instant::now();
    let mut gap = AirGap::default();
    gap.set(Some(GAP));
    assert_eq!(gap.floor(0), None, "nothing sent yet");
    gap.probed((0, 100), now);
    assert_eq!(gap.floor(100), Some(now + GAP));
    // A pass that sent nothing of its own keeps the floor.
    gap.probed((100, 100), now + Duration::from_secs(5));
    assert_eq!(gap.floor(100), Some(now + GAP));
}

#[test]
fn data_since_the_last_pass_lifts_it() {
    let now = Instant::now();
    let mut gap = AirGap::default();
    gap.set(Some(GAP));
    gap.probed((0, 100), now);
    assert_eq!(gap.floor(180), None, "data left: probes ride along");
    gap.set(None);
    assert_eq!(gap.floor(100), None);
}
