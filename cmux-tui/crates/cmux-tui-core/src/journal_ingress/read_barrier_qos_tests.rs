//! A thread blocked on the journal writer donates its class to the writer's
//! attempt (p05-ipc-137): the attempt runs at the highest blocked class while
//! it lasts and at its own class again after; with nothing blocked no
//! override starts.
//!
//! On Linux an override lowers the writer's nice value, which only root or an
//! `RLIMIT_NICE` that allows it may do; elsewhere it is refused and counted,
//! and the writer stays where it was.

use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

use cmux_threads::{BoostCounts, LiveQos, ThreadQos, current_effective};

use super::super::JournalIngressSender;
use super::RequestWaits;
use crate::resource::TerminalPublicId;
use crate::{Mux, SurfaceOptions};

/// How long the writer runs with the waiter blocked on it.
const SPIN: Duration = Duration::from_millis(20);

/// What `current_effective` reads for a thread at `qos`.
fn runs_at(qos: ThreadQos) -> LiveQos {
    #[cfg(target_vendor = "apple")]
    return LiveQos::Class(qos);
    #[cfg(any(target_os = "linux", target_os = "android"))]
    return LiveQos::Nice(qos.linux_nice());
    #[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
    return {
        let _ = qos;
        LiveQos::Unknown
    };
}

/// True when this process can raise a thread at `from` to `to`.
fn can_raise(from: ThreadQos, to: ThreadQos) -> bool {
    cfg!(target_vendor = "apple")
        || (cfg!(any(target_os = "linux", target_os = "android"))
            && cmux_threads::reversible(from)
            && cmux_threads::reversible(to))
}

/// The writer's live QoS around one attempt.
#[derive(Debug)]
struct WriterReads {
    before: LiveQos,
    during: LiveQos,
    after: LiveQos,
}

/// A Utility writer attempt and a `waiter_qos` thread blocked on it. With
/// `waiter_first` the waiter blocks before the attempt starts (the attempt
/// raises itself), else while it runs.
fn writer_with_waiter(waiter_qos: ThreadQos, waiter_first: bool) -> (WriterReads, BoostCounts) {
    let waits = RequestWaits::default();
    let (blocked_tx, blocked_rx) = channel();
    let (answer_tx, answer_rx) = channel::<()>();
    let waiter_waits = waits.clone();
    let mut start_waiter = Some(move || {
        cmux_threads::spawn("read-barrier-qos-waiter", waiter_qos, move || {
            let _donated = waiter_waits.donate();
            blocked_tx.send(()).expect("blocked");
            answer_rx.recv().expect("answer");
        })
        .expect("spawn waiter")
    });
    let mut waiter = None;
    if waiter_first {
        waiter = start_waiter.take().map(|start| start());
        blocked_rx.recv().expect("the waiter blocked");
    }
    let (started_tx, started_rx) = channel();
    let writer_waits = waits.clone();
    let writer = cmux_threads::spawn("read-barrier-qos-writer", ThreadQos::Utility, move || {
        let before = current_effective();
        let attempt = writer_waits.writer_attempt();
        started_tx.send(()).expect("started");
        if !waiter_first {
            blocked_rx.recv().expect("the waiter blocked");
        }
        let spin_until = Instant::now() + SPIN;
        while Instant::now() < spin_until {
            std::hint::spin_loop();
        }
        let during = current_effective();
        answer_tx.send(()).expect("answer");
        drop(attempt);
        WriterReads { before, during, after: current_effective() }
    })
    .expect("spawn writer");
    started_rx.recv().expect("the attempt started");
    let waiter =
        waiter.or_else(|| start_waiter.take().map(|start| start())).expect("the waiter started");
    let reads = writer.join().expect("writer");
    waiter.join().expect("waiter");
    (reads, waits.donations())
}

fn assert_raised(waiter_qos: ThreadQos, reads: &WriterReads, boosts: BoostCounts) {
    #[cfg(target_vendor = "apple")]
    assert_eq!(reads.before, runs_at(ThreadQos::Utility), "{reads:?}");
    if can_raise(ThreadQos::Utility, waiter_qos) {
        assert_eq!(reads.during, runs_at(waiter_qos), "{reads:?}");
        assert_eq!(boosts, BoostCounts { started: 1, refused: 0 });
    } else {
        assert_eq!(reads.during, reads.before, "{reads:?}");
        assert_eq!(boosts, BoostCounts { started: 0, refused: 1 });
    }
    assert_eq!(reads.after, reads.before, "{reads:?}");
}

#[test]
fn read_barrier_qos_a_waiter_blocked_during_a_lowered_attempt_raises_it_until_it_ends() {
    let (reads, boosts) = writer_with_waiter(ThreadQos::UserInitiated, false);
    assert_raised(ThreadQos::UserInitiated, &reads, boosts);
}

#[test]
fn read_barrier_qos_an_attempt_started_while_a_thread_blocks_raises_itself() {
    let (reads, boosts) = writer_with_waiter(ThreadQos::UserInitiated, true);
    assert_raised(ThreadQos::UserInitiated, &reads, boosts);
}

#[test]
fn read_barrier_qos_a_user_interactive_waiter_raises_the_writer_to_user_interactive() {
    let (reads, boosts) = writer_with_waiter(ThreadQos::UserInteractive, false);
    assert_raised(ThreadQos::UserInteractive, &reads, boosts);
}

#[test]
fn read_barrier_qos_a_waiter_at_the_writers_class_starts_no_override() {
    let (reads, boosts) = writer_with_waiter(ThreadQos::Utility, false);
    assert_eq!(reads.during, reads.before, "{reads:?}");
    assert_eq!(reads.after, reads.before, "{reads:?}");
    assert_eq!(boosts, BoostCounts::default());
}

/// A journaled mux whose writer runs attempts at utility between waits.
fn journaled_mux(name: &str) -> (Arc<Mux>, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!(
        "cmux-read-barrier-qos-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = Mux::open_persistent(name, SurfaceOptions::default(), &root).expect("mux");
    mux.set_request_qos_for_test(true);
    (mux, root)
}

fn terminal(seed: u32) -> Arc<TerminalPublicId> {
    Arc::new(TerminalPublicId::parse(format!("term_{seed:032x}")).expect("terminal id"))
}

/// Background batches nobody waits on start no override.
#[test]
fn read_barrier_qos_idle_writer_takes_no_override() {
    let (mux, root) = journaled_mux("read-barrier-qos-idle");
    let terminal_id = terminal(1370);
    let producer = mux.clone();
    cmux_threads::spawn("read-barrier-qos-producer", ThreadQos::Utility, move || {
        for round in 0..256_u32 {
            producer.journal_terminal_output(
                terminal_id.clone(),
                Arc::from("read-barrier-qos"),
                round.to_le_bytes().to_vec(),
            );
        }
    })
    .expect("spawn producer")
    .join()
    .expect("producer");
    mux.shutdown();
    assert_eq!(mux.journal_writer_donations_for_test(), BoostCounts::default());
    let _ = std::fs::remove_dir_all(root);
}

/// A barrier sent through the ingress donates from before its event is
/// queued until its receipt: the attempt that takes the event starts raised
/// to the waiter's class and is back at its own once it ends. The writer
/// drops the event unanswered, so the waiter receives no message (one
/// received from below would record a Debug `priority-inversion` site in the
/// process-wide table other tests read).
#[test]
fn read_barrier_qos_a_queued_barrier_raises_the_attempt_that_takes_it() {
    let (sender, receivers) = JournalIngressSender::new(true);
    let receivers = receivers.expect("journal receivers");
    let waits = receivers.state.request_waits.clone();
    let waiter =
        cmux_threads::spawn("read-barrier-qos-ui", ThreadQos::UserInteractive, move || {
            sender.flush_terminal().is_err()
        })
        .expect("spawn waiter");
    let writer = cmux_threads::spawn("read-barrier-qos-writer", ThreadQos::Utility, move || {
        let before = current_effective();
        let queued = receivers.terminal.recv().expect("the barrier was queued");
        let attempt = receivers.state.request_waits.writer_attempt();
        let during = current_effective();
        drop(attempt);
        let after = current_effective();
        drop(queued);
        WriterReads { before, during, after }
    })
    .expect("spawn writer");
    let reads = writer.join().expect("writer");
    assert!(waiter.join().expect("waiter"), "a dropped barrier reported success");
    assert_raised(ThreadQos::UserInteractive, &reads, waits.donations());
}

/// p50, p99 and max of `samples`, in microseconds.
fn percentiles(mut samples: Vec<Duration>) -> (u128, u128, u128) {
    samples.sort_unstable();
    let at = |q: f64| {
        let index = ((samples.len() as f64 - 1.0) * q).round() as usize;
        samples[index].as_micros()
    };
    (at(0.50), at(0.99), samples.last().map_or(0, Duration::as_micros))
}

/// `rounds` barriers from a UserInitiated thread while utility output keeps
/// the writer busy: registered, the thread donates; unregistered (same
/// kernel class, no registry row) it donates nothing.
fn barrier_waits(mux: &Arc<Mux>, rounds: usize, donating: bool) -> Vec<Duration> {
    let waiter = mux.clone();
    let run = move || {
        let terminal_id = terminal(1373);
        (0..rounds)
            .map(|round| {
                waiter.journal_terminal_output(
                    terminal_id.clone(),
                    Arc::from("read-barrier-qos"),
                    round.to_le_bytes().to_vec(),
                );
                let started = Instant::now();
                waiter.flush_terminal_journal().expect("barrier");
                started.elapsed()
            })
            .collect::<Vec<_>>()
    };
    if donating {
        cmux_threads::spawn("read-barrier-qos-bench", ThreadQos::UserInitiated, run)
            .expect("spawn")
            .join()
            .expect("bench waiter")
    } else {
        std::thread::spawn(move || {
            cmux_threads::set_current(ThreadQos::UserInitiated);
            run()
        })
        .join()
        .expect("bench waiter")
    }
}

/// Bench (acceptance numbers, run on macOS): barrier wait p50/p99/max under
/// utility hogs on every core (at least 8), without and with donation.
/// `cargo test -p cmux-tui-core --release read_barrier_qos_bench -- --ignored --nocapture`
#[test]
#[ignore = "bench: prints barrier wait percentiles under utility hogs"]
fn read_barrier_qos_bench_barrier_p99_under_utility_hogs() {
    let (mux, root) = journaled_mux("read-barrier-qos-bench");
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let hogs = std::thread::available_parallelism().map_or(8, |cores| cores.get().max(8));
    let mut threads = (0..hogs)
        .map(|index| {
            let stop = stop.clone();
            cmux_threads::spawn(
                format!("read-barrier-qos-hog-{index}"),
                ThreadQos::Utility,
                move || {
                    while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                        std::hint::spin_loop();
                    }
                },
            )
            .expect("spawn hog")
        })
        .collect::<Vec<_>>();
    let producer_mux = mux.clone();
    let producer_stop = stop.clone();
    threads.push(
        cmux_threads::spawn("read-barrier-qos-output", ThreadQos::Utility, move || {
            let terminal_id = terminal(1372);
            let mut round = 0_u64;
            while !producer_stop.load(std::sync::atomic::Ordering::Relaxed) {
                // Never blocks on a full lane: a blocked producer would count
                // as a wait and keep every attempt at the writer's class.
                let _ = producer_mux.try_journal_terminal_output(
                    terminal_id.clone(),
                    Arc::from("read-barrier-qos"),
                    round,
                    vec![b'x'; 4096],
                );
                round += 1;
                std::thread::yield_now();
            }
        })
        .expect("spawn producer"),
    );
    let rounds = 500;
    let without = percentiles(barrier_waits(&mux, rounds, false));
    let with = percentiles(barrier_waits(&mux, rounds, true));
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    for thread in threads {
        thread.join().expect("hog");
    }
    let donations = mux.journal_writer_donations_for_test();
    mux.shutdown();
    println!(
        "read_barrier_qos: {hogs} utility hogs, {rounds} barriers; \
         no donation p50 {} us p99 {} us max {} us; \
         donation p50 {} us p99 {} us max {} us; overrides {donations:?}",
        without.0, without.1, without.2, with.0, with.1, with.2
    );
    let _ = std::fs::remove_dir_all(root);
}
