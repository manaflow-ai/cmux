use std::sync::atomic::AtomicBool;

use super::*;

const INDEX: [u8; 4] = [1, 2, 3, 4];

fn meter_of(counters: &[u64]) -> (LossMeter, LossSample) {
    let mut meter = LossMeter::default();
    for counter in counters {
        meter.observe(INDEX, *counter, false);
    }
    let sample = meter.take();
    (meter, sample)
}

#[test]
fn choices_parse_and_the_environment_wins() {
    assert_eq!(UltraChoice::parse("auto"), Some(UltraChoice::AUTO));
    assert_eq!(UltraChoice::parse(" Always "), Some(UltraChoice::ALWAYS));
    assert_eq!(UltraChoice::parse("off"), Some(UltraChoice::Off));
    assert_eq!(
        UltraChoice::parse("fec:8:2"),
        Some(UltraChoice::Always(UltraMode::Fec { group: 8, parity: 2 }))
    );
    assert_eq!(UltraChoice::parse("brutal"), None);
    let auto = UltraChoice::AUTO;
    assert_eq!(UltraChoice::resolve_with(None, auto), auto);
    assert_eq!(UltraChoice::resolve_with(Some(" "), auto), auto);
    assert_eq!(UltraChoice::resolve_with(Some("off"), auto), UltraChoice::Off);
    assert_eq!(UltraChoice::resolve_with(Some("rs"), auto), UltraChoice::ALWAYS);
    assert_eq!(UltraChoice::resolve_with(Some("auto"), UltraChoice::Off), auto);
    assert_eq!(UltraChoice::resolve_with(Some("bogus"), auto), auto);
    assert_eq!(UltraChoice::AUTO.start_mode(), UltraMode::Off, "Auto starts with no repair");
    assert_eq!(UltraChoice::ALWAYS.start_mode(), UltraMode::SETTING);
    assert!(UltraChoice::Off.auto().is_none() && UltraChoice::ALWAYS.auto().is_none());
    static METERED: AtomicBool = AtomicBool::new(false);
    let metered = UltraChoice::Auto { metered: Some(&METERED) };
    assert_eq!(metered, UltraChoice::Auto { metered: Some(&METERED) });
    assert_ne!(metered, UltraChoice::AUTO);
}

#[test]
fn the_meter_sees_no_loss_on_a_clean_link() {
    let (_, sample) = meter_of(&(0..500).collect::<Vec<_>>());
    assert_eq!(sample, LossSample { gaps: 0, late: 0, lost: 0, received: 500 });
}

#[test]
fn a_gap_is_seen_at_the_next_datagram_and_ages_into_a_loss() {
    let (mut meter, sample) = meter_of(&[0, 1, 2, 4]);
    assert_eq!((sample.gaps, sample.lost), (1, 0), "counter 3 skipped");
    for counter in 5..5 + WINDOW {
        meter.observe(INDEX, counter, false);
    }
    assert_eq!(meter.take().lost, 1, "and never arrived while 64 newer did");
}

#[test]
fn a_late_datagram_is_reordering_and_a_rebuilt_one_is_loss() {
    let (mut meter, _) = meter_of(&[0, 1, 3, 5]);
    meter.observe(INDEX, 2, false);
    meter.observe(INDEX, 4, true);
    meter.observe(INDEX, 4, false); // a replay of what was rebuilt: no change
    let sample = meter.take();
    assert_eq!((sample.late, sample.lost), (1, 1));
}

#[test]
fn a_new_session_starts_over_and_the_old_one_is_not_counted() {
    let (mut meter, _) = meter_of(&[0, 1, 2]);
    let next = [9, 9, 9, 9];
    meter.observe(next, 0, false);
    meter.observe(INDEX, 7, false); // a late datagram of the old session
    meter.observe(next, 1, false);
    let sample = meter.take();
    assert_eq!((sample.gaps, sample.lost), (0, 0));
}

fn sample(gaps: u64, late: u64, lost: u64, received: u64) -> LossSample {
    LossSample { gaps, late, lost, received }
}

#[test]
fn auto_stays_off_on_a_clean_link() {
    let mut auto = UltraChoice::AUTO.auto().unwrap();
    let start = Instant::now();
    for second in 0..120 {
        let now = start + Duration::from_secs(second);
        assert!(!auto.observe(now, sample(0, 0, 0, 100), 0));
    }
    assert_eq!(auto.wanted(), (UltraMode::Off, false));
}

#[test]
fn auto_turns_on_at_the_first_loss_and_off_once_the_link_is_clean() {
    let mut auto = UltraChoice::AUTO.auto().unwrap();
    let start = Instant::now();
    assert!(auto.observe(start, sample(1, 0, 0, 10), 0), "on at the first gap");
    assert_eq!(auto.wanted().0, UltraMode::SETTING);
    assert!(!auto.observe(start, sample(0, 0, 1, 10), 0), "the gap was a loss: stays on");
    let soon = start + HOLD / 2;
    assert!(!auto.observe(soon, sample(0, 0, 0, 10), 0), "held");
    let idle = start + HOLD * 2;
    assert!(!auto.observe(idle, sample(0, 0, 0, 0), 0), "time alone: a quiet lossy link keeps it");
    let clean = idle + Duration::from_millis(1);
    assert!(auto.observe(clean, sample(0, 0, 0, CLEAN_DATAGRAMS), 0), "off when clean");
    assert_eq!(auto.wanted().0, UltraMode::Off);
}

#[test]
fn a_rebuilt_datagram_keeps_auto_on() {
    let mut auto = UltraChoice::AUTO.auto().unwrap();
    let start = Instant::now();
    auto.observe(start, sample(1, 0, 0, 1), 0);
    let later = start + HOLD * 2;
    assert!(!auto.observe(later, sample(0, 0, 1, CLEAN_DATAGRAMS * 3), 0));
    assert!(auto.is_on(), "repaired loss is still loss");
}

#[test]
fn reordering_turns_auto_back_off_at_once() {
    let mut auto = UltraChoice::AUTO.auto().unwrap();
    let start = Instant::now();
    assert!(auto.observe(start, sample(2, 0, 0, 3), 0));
    assert!(!auto.observe(start, sample(0, 1, 0, 1), 0), "one gap still open");
    assert!(auto.observe(start, sample(0, 1, 0, 1), 0), "both filled late: off");
    assert!(!auto.observe(start, sample(1, 1, 0, 2), 0), "a gap filled in the same pass");
    assert!(!auto.is_on());
}

#[test]
fn a_segment_sent_again_turns_auto_on() {
    let mut auto = UltraChoice::AUTO.auto().unwrap();
    let start = Instant::now();
    assert!(auto.observe(start, sample(0, 0, 0, 5), 1));
    assert!(!auto.observe(start, sample(0, 0, 0, 5), 0), "a resend is not reordering");
    assert!(auto.is_on());
}

#[test]
fn a_metered_network_is_told_without_loss() {
    static CELLULAR: AtomicBool = AtomicBool::new(true);
    let mut auto = UltraChoice::Auto { metered: Some(&CELLULAR) }.auto().unwrap();
    let start = Instant::now();
    assert!(auto.observe(start, sample(0, 0, 0, 1), 0), "the first pass says metered");
    assert_eq!(auto.wanted(), (UltraMode::Off, true));
    assert!(!auto.observe(start, sample(0, 0, 0, 1), 0));
    CELLULAR.store(false, Ordering::Relaxed);
    assert!(auto.observe(start, sample(0, 0, 0, 1), 0), "a move to Wi-Fi is told");
    assert_eq!(auto.wanted(), (UltraMode::Off, false));
}
