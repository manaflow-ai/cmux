use std::net::IpAddr;
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

#[test]
fn the_first_missing_counter_turns_auto_on_at_the_next_datagram() {
    // The ramp: the datagram after a lost one shows the gap, and that same
    // pass turns repair on, well inside one round trip of the loss.
    let mut meter = LossMeter::default();
    let mut auto = UltraChoice::AUTO.auto().unwrap();
    let start = Instant::now();
    for counter in 0..10 {
        meter.observe(INDEX, counter, false);
    }
    assert!(!auto.observe(start, meter.take(), 0), "clean so far");
    // Counter 10 is lost; 11 arrives one datagram interval later.
    meter.observe(INDEX, 11, false);
    let next = start + Duration::from_millis(1);
    assert!(auto.observe(next, meter.take(), 0), "on at the next datagram");
    assert_eq!(auto.wanted().0, UltraMode::SETTING);
    // Counter 10 never comes: still on, a confirmed loss once it ages out.
    for counter in 12..12 + WINDOW + 1 {
        meter.observe(INDEX, counter, false);
    }
    assert!(!auto.observe(next, meter.take(), 0));
    assert!(auto.is_on());
}

#[test]
fn counters_sent_off_the_data_path_are_not_loss() {
    // Probes took 3 and 4 and went out on a dead path; the note naming them
    // arrives (as 5) before the meter sees the gap.
    let (mut meter, _) = meter_of(&[0, 1, 2]);
    meter.off_path(INDEX, &[3, 4]);
    for counter in 5..5 + WINDOW + 2 {
        meter.observe(INDEX, counter, false);
    }
    assert_eq!(
        meter.take(),
        LossSample { gaps: 0, late: 0, lost: 0, received: WINDOW + 2 },
        "no gap, and nothing ages into a loss"
    );
    // A real loss beside an off-path counter still counts.
    let newest = 5 + WINDOW + 1;
    meter.off_path(INDEX, &[newest + 1]);
    meter.observe(INDEX, newest + 3, false);
    assert_eq!(meter.take().gaps, 1, "one of the two skipped counters was off the data path");
}

#[test]
fn a_note_behind_its_gap_reads_as_reordering() {
    // The data path overtook the note: the gap was counted, and the note
    // explains it the way a late datagram does, so Auto turns off at once.
    let (mut meter, sample) = meter_of(&[0, 1, 3]);
    assert_eq!(sample.gaps, 1);
    meter.off_path(INDEX, &[2]);
    let note = meter.take();
    assert_eq!((note.late, note.lost), (1, 0));
    for counter in 4..4 + WINDOW {
        meter.observe(INDEX, counter, false);
    }
    assert_eq!(meter.take().lost, 0, "the explained gap never ages into a loss");
    let mut auto = UltraChoice::AUTO.auto().expect("auto");
    let now = Instant::now();
    assert!(auto.observe(now, sample, 0), "the gap turned Auto on");
    assert!(auto.observe(now, note, 0), "and the note turned it off again");
    assert!(!auto.is_on());
}

#[test]
fn a_note_for_another_session_is_kept_for_it() {
    let (mut meter, _) = meter_of(&[0, 1, 2]);
    let next = [9, 9, 9, 9];
    meter.off_path(next, &[1]);
    meter.observe(next, 0, false);
    meter.observe(next, 2, false);
    assert_eq!(meter.take().gaps, 0, "the new session's probe counter is skipped too");
}

#[test]
fn off_path_notes_round_trip_and_are_neither_probes_nor_hellos() {
    let local: IpAddr = "10.0.0.1".parse().unwrap();
    let remote: IpAddr = "10.0.0.2".parse().unwrap();
    let counters: Vec<u64> = (1..=20).map(|n| n * 1_000_003).collect();
    let packets = off_path_packets(local, remote, &counters);
    assert_eq!(packets.len(), 2, "sixteen counters a note");
    let decoded: Vec<u64> =
        packets.iter().flat_map(|packet| decode_off_path(packet).expect("a note")).collect();
    assert_eq!(decoded, counters);
    assert!(off_path_packets(local, remote, &[]).is_empty());
    for packet in &packets {
        assert!(crate::probing::decode(packet).is_none());
        assert!(crate::ultra_hello::decode(packet).is_none());
    }
    let negotiation = crate::ultra_hello::Negotiation::new(UltraMode::SETTING);
    let hello = negotiation.due(Instant::now()).expect("a first hello is due");
    let hello = crate::ultra_hello::packet(local, remote, hello);
    assert!(decode_off_path(&hello).is_none());
}
