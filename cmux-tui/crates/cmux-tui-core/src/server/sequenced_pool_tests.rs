//! The sequenced pool: per-sequence FIFO with no overlap,
//! independent sequences, blocking compensation from the blocking sites,
//! fences, caps, worker start failures, no idle wakeups and a thread count
//! independent of the number of sequences; delayed tasks.

use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use proptest::prelude::*;

use super::*;
use crate::request_path::{note, will_block};

const WAIT: Duration = Duration::from_secs(5);

fn pool(config: PoolConfig) -> SequencedPool {
    SequencedPool::new(config)
}

/// Waits (bounded) until `done` holds.
fn eventually(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + WAIT;
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting until {what}");
        std::thread::sleep(Duration::from_millis(1));
    }
}

/// The median of `samples`.
fn median(mut samples: Vec<Duration>) -> Duration {
    samples.sort();
    samples[samples.len() / 2]
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 24, ..ProptestConfig::default() })]

    /// Tasks posted to one sequence run in post order and never two at once,
    /// however posts to several sequences interleave.
    #[test]
    fn each_sequence_runs_its_tasks_in_post_order_one_at_a_time(
        posts in proptest::collection::vec(0usize..5, 1..200),
    ) {
        let pool = pool(PoolConfig::for_cores(8));
        let sequences: Vec<Sequence> =
            (0..5).map(|_| pool.sequence_with_cap(SequencePriority::Control, 1024)).collect();
        let running: Arc<Vec<AtomicBool>> = Arc::new((0..5).map(|_| AtomicBool::new(false)).collect());
        let ran = Arc::new(Mutex::new(vec![Vec::new(); 5]));
        let overlapped = Arc::new(AtomicBool::new(false));
        let (done_tx, done_rx) = mpsc::channel();
        let mut posted = [0usize; 5];
        for &sequence in &posts {
            let index = posted[sequence];
            posted[sequence] += 1;
            let (running, ran, overlapped, done) =
                (running.clone(), ran.clone(), overlapped.clone(), done_tx.clone());
            sequences[sequence]
                .post(move || {
                    if running[sequence].swap(true, Ordering::AcqRel) {
                        overlapped.store(true, Ordering::Release);
                    }
                    ran.lock().unwrap()[sequence].push(index);
                    std::thread::yield_now();
                    running[sequence].store(false, Ordering::Release);
                    done.send(()).unwrap();
                })
                .unwrap();
        }
        for _ in &posts {
            done_rx.recv_timeout(WAIT).expect("every task runs");
        }
        prop_assert!(!overlapped.load(Ordering::Acquire), "two tasks of one sequence overlapped");
        let ran = ran.lock().unwrap();
        for (sequence, order) in ran.iter().enumerate() {
            let expected: Vec<usize> = (0..posted[sequence]).collect();
            prop_assert_eq!(order, &expected, "sequence {} ran out of order", sequence);
        }
    }
}

/// A task of stream A that waits (a PTY write blocked on POLLOUT) holds
/// only A: a task on stream B and one on a control sequence start within
/// 2 ms of their post.
#[test]
fn a_blocked_sequence_does_not_delay_another_or_control() {
    let pool = pool(PoolConfig::for_cores(8));
    let stream_a = pool.sequence(SequencePriority::Input);
    let stream_b = pool.sequence(SequencePriority::Input);
    let control = pool.sequence(SequencePriority::Control);
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (blocked_tx, blocked_rx) = mpsc::channel();
    stream_a
        .post(move || {
            blocked_tx.send(()).unwrap();
            let _ = release_rx.recv();
        })
        .unwrap();
    blocked_rx.recv_timeout(WAIT).expect("stream A's task starts");
    let (started_tx, started_rx) = mpsc::channel();
    let mut stream_waits = Vec::new();
    let mut control_waits = Vec::new();
    for _ in 0..21 {
        for (sequence, waits) in [(&stream_b, &mut stream_waits), (&control, &mut control_waits)] {
            let started = started_tx.clone();
            let posted = Instant::now();
            sequence.post(move || started.send(Instant::now()).unwrap()).unwrap();
            let ran = started_rx.recv_timeout(WAIT).expect("the task runs while A waits");
            waits.push(ran.saturating_duration_since(posted));
        }
    }
    assert!(stream_a.depth() == 1, "stream A still waits");
    release_tx.send(()).unwrap();
    let (stream, control) = (median(stream_waits), median(control_waits));
    assert!(stream < Duration::from_millis(2), "stream B waited {stream:?}");
    assert!(control < Duration::from_millis(2), "control waited {control:?}");
}

/// With one worker, a task that waits without saying so holds the worker:
/// the next sequence waits for it. This is what `will_block` is for.
#[test]
fn a_task_that_waits_unannounced_holds_its_worker() {
    let pool = pool(PoolConfig::for_cores(8).with_workers(SequencePriority::Input, 1));
    let first = pool.sequence(SequencePriority::Input);
    let second = pool.sequence(SequencePriority::Input);
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (blocked_tx, blocked_rx) = mpsc::channel();
    first
        .post(move || {
            blocked_tx.send(()).unwrap();
            let _ = release_rx.recv();
        })
        .unwrap();
    blocked_rx.recv_timeout(WAIT).unwrap();
    let (ran_tx, ran_rx) = mpsc::channel();
    second.post(move || ran_tx.send(()).unwrap()).unwrap();
    assert!(ran_rx.recv_timeout(Duration::from_millis(100)).is_err(), "no second worker");
    release_tx.send(()).unwrap();
    ran_rx.recv_timeout(WAIT).expect("it runs once the worker is free");
}

/// A task inside `request_path::will_block` starts one temporary worker for
/// the ready sequence; once it leaves, the pool goes back to its fixed
/// workers.
#[test]
fn will_block_starts_a_temporary_worker() {
    let pool = pool(PoolConfig::for_cores(8).with_workers(SequencePriority::Input, 1));
    let first = pool.sequence(SequencePriority::Input);
    let second = pool.sequence(SequencePriority::Input);
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (blocked_tx, blocked_rx) = mpsc::channel();
    first
        .post(move || {
            will_block(|| {
                blocked_tx.send(()).unwrap();
                let _ = release_rx.recv();
            });
        })
        .unwrap();
    blocked_rx.recv_timeout(WAIT).unwrap();
    let (ran_tx, ran_rx) = mpsc::channel();
    second.post(move || ran_tx.send(()).unwrap()).unwrap();
    ran_rx.recv_timeout(WAIT).expect("a temporary worker runs it while the first waits");
    assert_eq!(pool.worker_count(SequencePriority::Input), 2);
    release_tx.send(()).unwrap();
    eventually("the temporary worker exits", || {
        pool.worker_count(SequencePriority::Input) == 1 && first.is_idle()
    });
}

/// `will_block` off a pool worker only runs its closure.
#[test]
fn will_block_off_a_worker_runs_the_closure() {
    assert_eq!(will_block(|| 7), 7);
}

/// A task that notes a request-path blocking kind (here `network`, a
/// loopback connect) is blocked until it ends: a temporary worker runs the
/// ready sequence meanwhile, and exits after.
#[test]
fn a_noted_blocking_kind_starts_a_temporary_worker() {
    let pool = pool(PoolConfig::for_cores(8).with_workers(SequencePriority::Input, 1));
    let first = pool.sequence(SequencePriority::Input);
    let second = pool.sequence(SequencePriority::Input);
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (blocked_tx, blocked_rx) = mpsc::channel();
    first
        .post(move || {
            note(BlockingKind::Network);
            blocked_tx.send(()).unwrap();
            let _ = release_rx.recv();
        })
        .unwrap();
    blocked_rx.recv_timeout(WAIT).unwrap();
    let (ran_tx, ran_rx) = mpsc::channel();
    second.post(move || ran_tx.send(()).unwrap()).unwrap();
    ran_rx.recv_timeout(WAIT).expect("a temporary worker runs it while the first waits");
    release_tx.send(()).unwrap();
    eventually("the temporary worker exits", || {
        pool.worker_count(SequencePriority::Input) == 1 && first.is_idle()
    });
    // The block ended with its task: the next unannounced wait holds the
    // one worker again.
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (blocked_tx, blocked_rx) = mpsc::channel();
    first
        .post(move || {
            blocked_tx.send(()).unwrap();
            let _ = release_rx.recv();
        })
        .unwrap();
    blocked_rx.recv_timeout(WAIT).unwrap();
    let (ran_tx, ran_rx) = mpsc::channel();
    second.post(move || ran_tx.send(()).unwrap()).unwrap();
    assert!(ran_rx.recv_timeout(Duration::from_millis(100)).is_err(), "no block is left over");
    release_tx.send(()).unwrap();
    ran_rx.recv_timeout(WAIT).unwrap();
}

/// A PTY input writer that waits, as a write to a child that does not read
/// its input waits for POLLOUT: it says it entered, then waits for release.
struct StalledInput {
    entered: mpsc::Sender<()>,
    release: Arc<(Mutex<bool>, Condvar)>,
}

impl Write for StalledInput {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let _ = self.entered.send(());
        let (released, changed) = &*self.release;
        let mut released = released.lock().unwrap();
        while !*released {
            released = changed.wait(released).unwrap();
        }
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// With a priority at its fewest workers, `send`-class tasks blocked in a
/// real PTY input write on more sequences than there are workers neither
/// stop each other nor delay a ping on another sequence (2 ms): the write
/// site itself tells the pool it blocks. Control and input alike (stream
/// items post at input).
#[test]
fn blocked_pty_writes_at_the_fewest_workers_delay_no_other_sequence() {
    cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Record);
    let mux =
        crate::Mux::new_for_test("sequenced-pool-pty-writes", crate::SurfaceOptions::default());
    for priority in [SequencePriority::Control, SequencePriority::Input] {
        let pool = pool(PoolConfig::for_cores(2));
        let fewest = pool.config().workers(priority);
        assert_eq!(fewest, 2, "{priority:?} is at its fewest workers");
        let release = Arc::new((Mutex::new(false), Condvar::new()));
        let (entered_tx, entered_rx) = mpsc::channel();
        let senders: Vec<Sequence> = (0..fewest + 2).map(|_| pool.sequence(priority)).collect();
        for sender in &senders {
            let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
            surface.replace_input_writer_for_test(Box::new(StalledInput {
                entered: entered_tx.clone(),
                release: release.clone(),
            }));
            sender.post(move || surface.write_bytes(b"x").unwrap()).unwrap();
        }
        for _ in &senders {
            entered_rx.recv_timeout(WAIT).expect("every send reaches its PTY write");
        }
        let ping = pool.sequence(priority);
        let (ran_tx, ran_rx) = mpsc::channel();
        let mut waits = Vec::new();
        for _ in 0..21 {
            let ran = ran_tx.clone();
            let posted = Instant::now();
            ping.post(move || ran.send(Instant::now()).unwrap()).unwrap();
            let started = ran_rx.recv_timeout(WAIT).expect("the ping runs while the sends wait");
            waits.push(started.saturating_duration_since(posted));
        }
        assert!(senders.iter().all(|sender| !sender.is_idle()), "the sends still wait");
        let (released, changed) = &*release;
        *released.lock().unwrap() = true;
        changed.notify_all();
        let waited = median(waits);
        assert!(waited < Duration::from_millis(2), "{priority:?} ping waited {waited:?}");
        eventually("the sends end", || senders.iter().all(Sequence::is_idle));
    }
}

/// A spawner whose first `allowed` starts succeed and every later one fails.
fn spawner_allowing(allowed: usize) -> WorkerSpawner {
    let started = AtomicUsize::new(0);
    let default = WorkerSpawner::default();
    WorkerSpawner::new(move |name, qos, body| {
        if started.fetch_add(1, Ordering::AcqRel) >= allowed {
            return Err(io::Error::other("thread limit reached"));
        }
        (default.0)(name, qos, body)
    })
}

/// A priority whose first worker cannot start refuses the post: the task is
/// taken back (dropped unrun) and the sequence is idle, so its owner answers
/// with an error instead of waiting for a task nothing runs.
#[test]
fn a_post_no_worker_can_run_is_refused() {
    let pool = SequencedPool::with_spawner(PoolConfig::for_cores(4), spawner_allowing(0));
    let sequence = pool.sequence(SequencePriority::Control);
    let ran = Arc::new(AtomicBool::new(false));
    let task_ran = ran.clone();
    assert_eq!(
        sequence.post(move || task_ran.store(true, Ordering::Release)),
        Err(PostError::NoWorker)
    );
    assert!(sequence.is_idle(), "the refused task is not queued");
    assert_eq!(pool.worker_count(SequencePriority::Control), 0);
    // A later post tries again, and is refused the same way.
    assert_eq!(sequence.post(|| {}), Err(PostError::NoWorker));
    assert!(!ran.load(Ordering::Acquire));
}

/// A temporary or later worker that cannot start leaves the work to the
/// live one: the post is accepted and runs once that worker is free.
#[test]
fn a_later_worker_that_cannot_start_leaves_the_work_to_the_live_one() {
    let pool = SequencedPool::with_spawner(
        PoolConfig::for_cores(4).with_workers(SequencePriority::Input, 2),
        spawner_allowing(1),
    );
    let first = pool.sequence(SequencePriority::Input);
    let second = pool.sequence(SequencePriority::Input);
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (blocked_tx, blocked_rx) = mpsc::channel();
    first
        .post(move || {
            will_block(|| {
                blocked_tx.send(()).unwrap();
                let _ = release_rx.recv();
            });
        })
        .unwrap();
    blocked_rx.recv_timeout(WAIT).unwrap();
    let (ran_tx, ran_rx) = mpsc::channel();
    assert_eq!(second.post(move || ran_tx.send(()).unwrap()), Ok(()));
    assert!(ran_rx.recv_timeout(Duration::from_millis(50)).is_err(), "no second worker");
    assert_eq!(pool.worker_count(SequencePriority::Input), 1);
    release_tx.send(()).unwrap();
    ran_rx.recv_timeout(WAIT).expect("the live worker runs it");
}

/// Idle workers wait with no timeout: nothing wakes them until a post.
#[test]
fn idle_workers_never_wake() {
    let pool = pool(PoolConfig::for_cores(8));
    let sequence = pool.sequence(SequencePriority::Control);
    let (done_tx, done_rx) = mpsc::channel();
    for _ in 0..8 {
        let done = done_tx.clone();
        sequence.post(move || done.send(()).unwrap()).unwrap();
    }
    for _ in 0..8 {
        done_rx.recv_timeout(WAIT).unwrap();
    }
    eventually("the sequence drains", || sequence.is_idle());
    // A worker that finished its task goes back to its wait.
    std::thread::sleep(Duration::from_millis(20));
    let before = pool.idle_wakeups();
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(pool.idle_wakeups(), before, "an idle worker woke with nothing posted");
}

/// 200 sequences (connections) with a task each run on the priority's
/// fixed workers: the thread count does not follow the sequences.
#[test]
fn thread_count_is_independent_of_sequences() {
    let pool = pool(PoolConfig::for_cores(4));
    let workers = pool.config().workers(SequencePriority::Control);
    let sequences: Vec<Sequence> =
        (0..200).map(|_| pool.sequence(SequencePriority::Control)).collect();
    let (done_tx, done_rx) = mpsc::channel();
    for sequence in &sequences {
        let done = done_tx.clone();
        sequence.post(move || done.send(()).unwrap()).unwrap();
    }
    for _ in &sequences {
        done_rx.recv_timeout(WAIT).unwrap();
    }
    assert!(pool.total_workers() <= workers, "{} workers", pool.total_workers());
    assert!(pool.workers_started() <= workers as u64, "{} started", pool.workers_started());
}

/// Each priority has its own workers: a busy control priority never
/// takes the utility worker, and utility work never waits for control.
#[test]
fn priorities_have_their_own_workers() {
    let pool = pool(PoolConfig::for_cores(4).with_workers(SequencePriority::Control, 1));
    let control = pool.sequence(SequencePriority::Control);
    let utility = pool.sequence(SequencePriority::Utility);
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (blocked_tx, blocked_rx) = mpsc::channel();
    control
        .post(move || {
            blocked_tx.send(()).unwrap();
            let _ = release_rx.recv();
        })
        .unwrap();
    blocked_rx.recv_timeout(WAIT).unwrap();
    let (ran_tx, ran_rx) = mpsc::channel();
    utility
        .post(move || ran_tx.send(std::thread::current().name().map(str::to_owned)).unwrap())
        .unwrap();
    let name = ran_rx.recv_timeout(WAIT).expect("utility runs while control waits");
    assert_eq!(name.as_deref(), Some("mux-seq-utility"));
    release_tx.send(()).unwrap();
}

/// A sequence queues at most its cap: the next post is refused, known not
/// delivered, and the running task does not count.
#[test]
fn a_full_sequence_refuses_the_post() {
    let pool = pool(PoolConfig::for_cores(4));
    let sequence = pool.sequence_with_cap(SequencePriority::Control, 2);
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (blocked_tx, blocked_rx) = mpsc::channel();
    sequence
        .post(move || {
            blocked_tx.send(()).unwrap();
            let _ = release_rx.recv();
        })
        .unwrap();
    blocked_rx.recv_timeout(WAIT).unwrap();
    assert_eq!(sequence.post(|| {}), Ok(()));
    assert_eq!(sequence.post(|| {}), Ok(()));
    assert_eq!(sequence.post(|| {}), Err(PostError::Full));
    assert_eq!(sequence.depth(), 3);
    release_tx.send(()).unwrap();
    eventually("the sequence drains", || sequence.is_idle());
}

/// The default sequence cap is the connection queue's.
#[test]
fn the_default_cap_is_the_connection_queue_capacity() {
    let pool = pool(PoolConfig::for_cores(4));
    let sequence = pool.sequence(SequencePriority::Control);
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (blocked_tx, blocked_rx) = mpsc::channel();
    sequence
        .post(move || {
            blocked_tx.send(()).unwrap();
            let _ = release_rx.recv();
        })
        .unwrap();
    blocked_rx.recv_timeout(WAIT).unwrap();
    for _ in 0..CONNECTION_SURFACE_QUEUE_CAPACITY {
        sequence.post(|| {}).unwrap();
    }
    assert_eq!(sequence.post(|| {}), Err(PostError::Full));
    release_tx.send(()).unwrap();
}

/// A fence runs after every task its sequences held when it was taken,
/// and not before; later posts do not hold it.
#[test]
fn a_fence_runs_after_the_earlier_tasks_of_each_sequence() {
    let pool = pool(PoolConfig::for_cores(8));
    let first = pool.sequence(SequencePriority::Input);
    let second = pool.sequence(SequencePriority::Input);
    let log = Arc::new(Mutex::new(Vec::new()));
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (blocked_tx, blocked_rx) = mpsc::channel();
    {
        let log = log.clone();
        first
            .post(move || {
                blocked_tx.send(()).unwrap();
                let _ = release_rx.recv();
                log.lock().unwrap().push("first");
            })
            .unwrap();
    }
    blocked_rx.recv_timeout(WAIT).unwrap();
    {
        let log = log.clone();
        second.post(move || log.lock().unwrap().push("second")).unwrap();
    }
    let (fenced_tx, fenced_rx) = mpsc::channel();
    let fence_log = log.clone();
    let fenced = pool.fence(&[&first, &second], move || {
        fence_log.lock().unwrap().push("fence");
        fenced_tx.send(()).unwrap();
    });
    assert!(matches!(fenced, Fenced::Waiting));
    // Posted after the fence: never waited for.
    let (later_tx, later_rx) = mpsc::channel();
    second.post(move || later_tx.send(()).unwrap()).unwrap();
    later_rx.recv_timeout(WAIT).expect("a later post runs while the fence waits");
    assert!(fenced_rx.recv_timeout(Duration::from_millis(50)).is_err(), "fence ran early");
    release_tx.send(()).unwrap();
    fenced_rx.recv_timeout(WAIT).expect("the fence runs");
    let log = log.lock().unwrap();
    assert_eq!(log.last(), Some(&"fence"), "{log:?}");
    assert!(log.contains(&"first") && log.contains(&"second"), "{log:?}");
}

/// A fence over idle sequences hands its callback back unrun.
#[test]
fn a_fence_over_idle_sequences_is_drained() {
    let pool = pool(PoolConfig::for_cores(4));
    let sequence = pool.sequence(SequencePriority::Input);
    let ran = Arc::new(AtomicBool::new(false));
    let flag = ran.clone();
    match pool.fence(&[&sequence], move || flag.store(true, Ordering::Release)) {
        Fenced::Drained(then) => {
            assert!(!ran.load(Ordering::Acquire), "a drained fence does not run its callback");
            then();
            assert!(ran.load(Ordering::Acquire));
        }
        Fenced::Waiting => panic!("an idle sequence fenced"),
    }
}

/// A dropped sequence handle still runs what it holds, then a fence on it
/// passes.
#[test]
fn a_dropped_sequence_runs_what_it_holds() {
    let pool = pool(PoolConfig::for_cores(4));
    let sequence = pool.sequence(SequencePriority::Input);
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (ran_tx, ran_rx) = mpsc::channel();
    sequence
        .post(move || {
            let _ = release_rx.recv();
        })
        .unwrap();
    sequence.post(move || ran_tx.send(()).unwrap()).unwrap();
    drop(sequence);
    release_tx.send(()).unwrap();
    ran_rx.recv_timeout(WAIT).expect("the queued task runs after the handle drops");
}

/// A task that panics leaves its sequence and worker running.
#[test]
fn a_panicking_task_leaves_the_sequence_running() {
    let pool = pool(PoolConfig::for_cores(4).with_workers(SequencePriority::Control, 1));
    let sequence = pool.sequence(SequencePriority::Control);
    sequence.post(|| panic!("a task panics")).unwrap();
    let (ran_tx, ran_rx) = mpsc::channel();
    sequence.post(move || ran_tx.send(()).unwrap()).unwrap();
    ran_rx.recv_timeout(WAIT).expect("the next task runs");
    assert_eq!(pool.worker_count(SequencePriority::Control), 1);
}

/// Control and input workers are request threads: blocking is disallowed
/// on them for life, at the request QoS.
#[test]
fn control_workers_are_request_threads() {
    let pool = pool(PoolConfig::for_cores(4));
    let sequence = pool.sequence(SequencePriority::Control);
    let (ran_tx, ran_rx) = mpsc::channel();
    sequence
        .post(move || {
            let name = std::thread::current().name().map(str::to_owned);
            ran_tx.send((cmux_threads::blocking::is_blocking_disallowed(), name)).unwrap();
        })
        .unwrap();
    let (disallowed, name) = ran_rx.recv_timeout(WAIT).unwrap();
    assert!(disallowed);
    assert_eq!(name.as_deref(), Some("mux-seq-control"));
}

/// A dropped pool refuses posts.
#[test]
fn a_dropped_pool_refuses_posts() {
    let pool = pool(PoolConfig::for_cores(4));
    let sequence = pool.sequence(SequencePriority::Control);
    drop(pool);
    assert_eq!(sequence.post(|| {}), Err(PostError::ShutDown));
}

/// The machine config: input 2, control the cores minus two (at least 2),
/// utility 2, background 1.
#[test]
fn the_config_follows_the_cores() {
    let config = PoolConfig::for_cores(10);
    let workers: Vec<usize> =
        SequencePriority::ALL.iter().map(|priority| config.workers(*priority)).collect();
    assert_eq!(workers, [2, 8, 2, 1]);
    assert_eq!(PoolConfig::for_cores(2).workers(SequencePriority::Control), 2);
}

#[test]
fn a_delayed_task_runs_after_its_delay_behind_earlier_posts() {
    let pool = pool(PoolConfig::for_cores(4));
    let sequence = pool.sequence(SequencePriority::Input);
    let (tx, rx) = mpsc::channel();
    let posted = Instant::now();
    let delayed = tx.clone();
    sequence
        .post_delayed(Duration::from_millis(60), move || {
            delayed.send(("delayed", posted.elapsed())).unwrap();
        })
        .unwrap();
    sequence.post(move || tx.send(("now", posted.elapsed())).unwrap()).unwrap();
    let first = rx.recv_timeout(WAIT).unwrap();
    let second = rx.recv_timeout(WAIT).unwrap();
    assert_eq!(first.0, "now");
    assert_eq!(second.0, "delayed");
    assert!(second.1 >= Duration::from_millis(60), "ran after {:?}", second.1);
}

#[test]
fn an_idle_worker_wakes_for_a_delayed_task_and_not_before() {
    let pool = pool(PoolConfig::for_cores(4));
    let sequence = pool.sequence(SequencePriority::Input);
    let (tx, rx) = mpsc::channel();
    // A worker exists and is idle before the delayed post.
    let started = tx.clone();
    sequence.post(move || started.send(()).unwrap()).unwrap();
    rx.recv_timeout(WAIT).unwrap();
    eventually("the worker idles", || sequence.is_idle());
    let wakeups = pool.idle_wakeups();
    sequence.post_delayed(Duration::from_millis(80), move || tx.send(()).unwrap()).unwrap();
    std::thread::sleep(Duration::from_millis(30));
    assert!(rx.try_recv().is_err(), "a delayed task ran before its delay");
    rx.recv_timeout(WAIT).expect("the delayed task runs");
    // The post's notify and the due time: no polling in between.
    let woke = pool.idle_wakeups() - wakeups;
    assert!(woke <= 3, "{woke} wakeups");
}

#[test]
fn a_delayed_task_of_a_dropped_sequence_is_dropped_unrun() {
    let pool = pool(PoolConfig::for_cores(4));
    let sequence = pool.sequence(SequencePriority::Utility);
    let (tx, rx) = mpsc::channel::<()>();
    sequence.post_delayed(Duration::from_millis(20), move || tx.send(()).unwrap()).unwrap();
    drop(sequence);
    // The sender drops with the task: the channel disconnects, nothing ran.
    assert_eq!(rx.recv_timeout(WAIT), Err(mpsc::RecvTimeoutError::Disconnected));
}

/// A delayed post that no worker of its priority could ever promote is
/// refused like a plain post: the task is dropped unrun, not kept forever.
#[test]
fn a_delayed_post_no_worker_can_run_is_refused() {
    let pool = SequencedPool::with_spawner(PoolConfig::for_cores(4), spawner_allowing(0));
    let sequence = pool.sequence(SequencePriority::Input);
    let (tx, rx) = mpsc::channel::<()>();
    assert_eq!(
        sequence.post_delayed(Duration::from_millis(1), move || tx.send(()).unwrap()),
        Err(PostError::NoWorker)
    );
    assert_eq!(pool.worker_count(SequencePriority::Input), 0);
    // The sender dropped with the refused task: nothing will run it.
    assert_eq!(rx.recv_timeout(WAIT), Err(mpsc::RecvTimeoutError::Disconnected));
}

/// A connection's shape: an outside thread (the mux-io
/// loop) posts each line to one sequence, whose task posts the line's
/// request to a second sequence. At most two tasks are ever runnable at
/// once, so the pool starts at most two workers: a worker notified for a
/// sequence that another worker took first still takes the next one
/// posted (a wake goes to a ready sequence, not to a post; Chrome's
/// `ThreadGroupImpl` wakes workers for the task sources that are ready).
#[test]
fn a_notified_worker_takes_the_next_post_and_none_starts_for_it() {
    const LINES: usize = 4_000;
    let pool = pool(PoolConfig::for_cores(16));
    let lines = pool.sequence_with_cap(SequencePriority::Control, LINES);
    let requests = Arc::new(pool.sequence_with_cap(SequencePriority::Control, LINES));
    let (done_tx, done_rx) = mpsc::channel();
    for line in 0..LINES {
        let (requests, done) = (requests.clone(), done_tx.clone());
        lines
            .post(move || {
                requests.post(move || done.send(()).unwrap()).unwrap();
            })
            .unwrap();
        if line % 4 == 0 {
            std::thread::yield_now();
        }
    }
    for _ in 0..LINES {
        done_rx.recv_timeout(WAIT).unwrap();
    }
    assert!(pool.workers_started() <= 2, "{} workers started", pool.workers_started());
}
