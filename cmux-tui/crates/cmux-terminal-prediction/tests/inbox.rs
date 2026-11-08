//! Port of classic cmux's PredictionOutputInboxTests.swift. Surfaces are
//! keyed by `u64` here (UUIDs in the app).

use cmux_terminal_prediction::{PredictionOutputBatch, PredictionOutputInbox};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

const ZERO: Duration = Duration::ZERO;

fn ms(value: u64) -> Duration {
    Duration::from_millis(value)
}

/// An inbox that already accepts `surfaces`.
fn inbox(surfaces: &[u64]) -> PredictionOutputInbox<u64> {
    let inbox = PredictionOutputInbox::default();
    for &surface in surfaces {
        inbox.accept(surface);
    }
    inbox
}

fn bytes_of(batches: Option<&Vec<PredictionOutputBatch>>) -> Option<Vec<u8>> {
    batches.map(|batches| batches.iter().flat_map(|b| b.bytes.iter().copied()).collect())
}

#[test]
fn the_first_deposit_owns_scheduling_and_later_ones_do_not() {
    let (surface, other) = (1, 2);
    let inbox = inbox(&[surface, other]);

    assert!(inbox.deposit(&surface, &[0x61], ZERO));
    assert!(!inbox.deposit(&surface, &[0x62], ms(1)));
    assert!(!inbox.deposit(&other, &[0x63], ms(2)));
}

#[test]
fn draining_re_arms_scheduling() {
    let surface = 1;
    let inbox = inbox(&[surface]);

    assert!(inbox.deposit(&surface, &[0x61], ZERO));
    let _ = inbox.drain();
    assert!(inbox.deposit(&surface, &[0x62], ms(1)));
}

#[test]
fn chunks_keep_their_arrival_order_and_instants() {
    let surface = 1;
    let inbox = inbox(&[surface]);

    let _ = inbox.deposit(&surface, &[0x61], ms(1));
    let _ = inbox.deposit(&surface, &[0x62, 0x63], ms(9));

    let drained = inbox.drain();
    assert_eq!(
        drained.get(&surface),
        Some(&vec![
            PredictionOutputBatch::new(ms(1), vec![0x61], false),
            PredictionOutputBatch::new(ms(9), vec![0x62, 0x63], false),
        ])
    );
}

#[test]
fn surfaces_do_not_mix() {
    let (first, second) = (1, 2);
    let inbox = inbox(&[first, second]);

    let _ = inbox.deposit(&first, &[0x61], ZERO);
    let _ = inbox.deposit(&second, &[0x62], ZERO);

    let drained = inbox.drain();
    assert_eq!(bytes_of(drained.get(&first)), Some(vec![0x61]));
    assert_eq!(bytes_of(drained.get(&second)), Some(vec![0x62]));
}

#[test]
fn draining_leaves_nothing_behind() {
    let surface = 1;
    let inbox = inbox(&[surface]);
    let _ = inbox.deposit(&surface, &[0x61], ZERO);

    let _ = inbox.drain();
    assert!(inbox.drain().is_empty());
}

#[test]
fn forgetting_a_surface_keeps_the_others() {
    let (gone, kept) = (1, 2);
    let inbox = inbox(&[gone, kept]);
    let _ = inbox.deposit(&gone, &[0x61], ZERO);
    let _ = inbox.deposit(&kept, &[0x62], ZERO);

    inbox.forget(&gone);

    let drained = inbox.drain();
    assert!(!drained.contains_key(&gone));
    assert_eq!(drained.get(&kept).map(Vec::len), Some(1));
}

#[test]
fn a_surface_that_was_never_accepted_deposits_nothing() {
    // Local terminals register too. Their output must not be copied or
    // hop to the main thread just because prediction is turned on.
    let inbox: PredictionOutputInbox<u64> = PredictionOutputInbox::default();

    assert!(!inbox.deposit(&7, &[0x61], ZERO));
    assert!(inbox.drain().is_empty());
}

#[test]
fn a_forgotten_surface_stops_depositing_until_accepted_again() {
    let surface = 1;
    let inbox = inbox(&[surface]);

    inbox.forget(&surface);
    assert!(!inbox.deposit(&surface, &[0x61], ZERO));

    inbox.accept(surface);
    assert!(inbox.deposit(&surface, &[0x62], ZERO));
    assert_eq!(bytes_of(inbox.drain().get(&surface)), Some(vec![0x62]));
}

#[test]
fn forgetting_every_surface_drops_buffered_output() {
    let (first, second) = (1, 2);
    let inbox = inbox(&[first, second]);
    let _ = inbox.deposit(&first, &[0x61], ZERO);

    inbox.forget_all();

    assert!(inbox.drain().is_empty());
    assert!(!inbox.deposit(&second, &[0x62], ZERO));
}

#[test]
fn concurrent_deposits_schedule_exactly_one_drain() {
    let surface = 1;
    let inbox = Arc::new(inbox(&[surface]));
    let schedule_count = Arc::new(AtomicUsize::new(0));

    let threads: Vec<_> = (0..8)
        .map(|thread| {
            let inbox = Arc::clone(&inbox);
            let schedule_count = Arc::clone(&schedule_count);
            std::thread::spawn(move || {
                for index in (thread..500).step_by(8) {
                    let byte = u8::try_from(index % 256).expect("byte");
                    if inbox.deposit(&surface, &[byte], ZERO) {
                        schedule_count.fetch_add(1, Ordering::Relaxed);
                    }
                }
            })
        })
        .collect();
    for thread in threads {
        thread.join().expect("depositor");
    }

    assert_eq!(schedule_count.load(Ordering::Relaxed), 1);
    assert_eq!(inbox.drain().get(&surface).map(Vec::len), Some(500));
}

#[test]
fn a_surface_that_outruns_the_drain_keeps_only_its_newest_output() {
    let surface = 1;
    let inbox = PredictionOutputInbox::new(8);
    inbox.accept(surface);
    let _ = inbox.deposit(&surface, b"abcdef", ms(1));
    let _ = inbox.deposit(&surface, b"ghijk", ms(2));
    let drained = inbox.drain().remove(&surface).unwrap_or_default();
    assert_eq!(drained.iter().map(|b| b.bytes.clone()).collect::<Vec<_>>(), [b"ghijk".to_vec()]);
    assert_eq!(drained.iter().map(|b| b.follows_dropped_output).collect::<Vec<_>>(), [true]);

    let _ = inbox.deposit(&surface, b"xy", ms(3));
    let flags = inbox.drain().get(&surface).map(|batches| batches.iter().map(|b| b.follows_dropped_output).collect());
    assert_eq!(flags, Some(vec![false]));
}

#[test]
fn draining_one_surface_leaves_the_rest_and_the_schedule() {
    // Not in the Swift suite: the presented-frame catch-up drains one
    // surface without re-arming scheduling for the others.
    let (first, second) = (1, 2);
    let inbox = inbox(&[first, second]);
    assert!(inbox.deposit(&first, &[0x61], ZERO));
    let _ = inbox.deposit(&second, &[0x62], ZERO);

    assert_eq!(inbox.drain_surface(&first).len(), 1);
    assert!(inbox.drain_surface(&first).is_empty());
    assert!(!inbox.deposit(&first, &[0x63], ZERO));
    let drained = inbox.drain();
    assert_eq!(bytes_of(drained.get(&second)), Some(vec![0x62]));
    assert_eq!(bytes_of(drained.get(&first)), Some(vec![0x63]));
}
