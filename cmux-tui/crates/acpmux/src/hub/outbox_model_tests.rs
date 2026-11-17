//! Model-based test of the outbox: random sends, attempts, acks (repeated, out of order),
//! failures, holds, requeues, reconnects, crashes, clean shutdowns, torn appends, a journal left
//! beside a newer snapshot, a disk that refuses writes and comes back, and update closures that
//! panic. After every step the real outbox's answers, its memory and what a restart would read
//! from disk are compared with the naive oracle (`hub/outbox_oracle.rs`).
//!
//! Past bugs of this store, each an operation here: a message answered as kept whose write failed
//! (#40357, `DiskFails` + `Send`); a prompt id to a second target answered with the first's
//! delivery, so it was never sent (a631eae3bf3, `Send` with one prompt id and two targets); a
//! journal replayed over a newer snapshot, taking deliveries back to waiting (#40378,
//! `StaleJournal`); a torn append swallowing the next line (#40378, `TornRestart` and a later
//! change); a change answered before its file held it (#24331, the durable check after each step).

use super::*;
use crate::hub::outbox_oracle::{Enqueued, Entry, OutboxOracle};
use proptest::prelude::*;

#[derive(Clone, Debug)]
enum Op {
    /// A send of prompt `p-{0}` to target `t-{1}`.
    Send(u8, u8),
    /// An attempt starts (a retry too): delivering, one more attempt.
    Attempt(u8),
    /// The target's acceptance; twice or out of order as the draw has it.
    Ack(u8),
    Fail(u8),
    Hold(u8),
    /// A failed attempt waits for its next try.
    Requeue(u8),
    /// A peer's link is ready again: retries wake, nothing changes.
    Reconnect,
    /// An update closure that changes the state and then panics.
    PanicUpdate(u8),
    /// Killed, started again (the disk works again).
    Restart,
    /// Killed in the middle of an append no one was answered for.
    TornRestart(u16),
    /// Shut down cleanly (`compact`), started again.
    Shutdown,
    /// Killed between a new snapshot and its journal's reset: the old journal is left beside it.
    StaleJournal,
    DiskFails,
    DiskHeals,
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        6 => (0u8..10, 0u8..3).prop_map(|(p, t)| Op::Send(p, t)),
        4 => (0u8..16).prop_map(Op::Attempt),
        4 => (0u8..16).prop_map(Op::Ack),
        2 => (0u8..16).prop_map(Op::Fail),
        1 => (0u8..16).prop_map(Op::Hold),
        2 => (0u8..16).prop_map(Op::Requeue),
        1 => Just(Op::Reconnect),
        1 => (0u8..16).prop_map(Op::PanicUpdate),
        2 => Just(Op::Restart),
        1 => (1u16..300).prop_map(Op::TornRestart),
        2 => Just(Op::Shutdown),
        1 => Just(Op::StaleJournal),
        2 => Just(Op::DiskFails),
        2 => Just(Op::DiskHeals),
    ]
}

/// The real outbox in a folder of its own, a disk that can refuse writes, and the oracle.
struct Harness {
    _dir: tempfile::TempDir,
    path: PathBuf,
    outbox: Outbox,
    oracle: OutboxOracle,
    /// Sends so far: a new message's id and its `createdAt`, so id order is send order.
    sent: u32,
    /// The journal moved aside while a folder in its place refuses every write.
    aside: Option<Option<Vec<u8>>>,
    log: Vec<String>,
}

impl Harness {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("outbox.json");
        let outbox = Outbox::default();
        assert!(outbox.open(&path).is_empty());
        Self {
            _dir: dir,
            path,
            outbox,
            oracle: OutboxOracle::new(),
            sent: 0,
            aside: None,
            log: Vec::new(),
        }
    }

    fn journal(&self) -> PathBuf {
        journal_path(&self.path)
    }

    /// A message the oracle holds, picked by `k` (or a name no message has, for a missing id).
    fn pick(&self, k: u8) -> String {
        let memory = self.oracle.memory();
        if memory.is_empty() || usize::from(k) >= memory.len() + 2 {
            return format!("d-missing-{k}");
        }
        memory[usize::from(k) % memory.len()].id.clone()
    }

    fn delivery(&self, id: &str, prompt: &str, target: &str) -> Delivery {
        let now = crate::store::now_ms();
        Delivery {
            id: id.to_owned(),
            target: target.to_owned(),
            request: json!({"sessionId": target, "prompt": [{"type": "text", "text": "hi"}],
                            "_meta": {"acpmux": {"promptId": prompt}}}),
            caller: None,
            unproven_caller: None,
            not_terminal: false,
            state: State::Queued,
            attempts: 0,
            never_sent: false,
            relay_post: None,
            open_on_peer: false,
            pin: None,
            proof: None,
            error: None,
            accepted: None,
            created_at: u64::from(self.sent),
            updated_at: now,
        }
    }

    fn disk_fails(&mut self) {
        if self.aside.is_some() {
            return;
        }
        let journal = self.journal();
        let kept = std::fs::read(&journal).ok();
        if kept.is_some() {
            std::fs::remove_file(&journal).unwrap();
        }
        // A folder that is not empty: no append opens it and no rename replaces it.
        std::fs::create_dir_all(journal.join("refuses")).unwrap();
        self.aside = Some(kept);
        self.oracle.set_disk(false);
    }

    fn disk_heals(&mut self) {
        let Some(kept) = self.aside.take() else { return };
        let journal = self.journal();
        std::fs::remove_dir_all(&journal).unwrap();
        if let Some(bytes) = kept {
            std::fs::write(&journal, bytes).unwrap();
        }
        self.oracle.set_disk(true);
    }

    /// A new process opens the files; what it resumes is the oracle's durable waiting list.
    fn reopen(&mut self) {
        self.outbox = Outbox::default();
        let resumed: Vec<String> = self.outbox.open(&self.path).into_iter().map(|d| d.id).collect();
        let want: Vec<String> = OutboxOracle::pending(self.oracle.durable())
            .into_iter()
            .map(|e| e.id.clone())
            .collect();
        assert_eq!(resumed, want, "a restart resumed other deliveries\n{}", self.log.join("\n"));
    }

    fn apply(&mut self, op: &Op) {
        self.log.push(format!("{op:?}"));
        match *op {
            Op::Send(p, t) => {
                let id = format!("d-{:04}", self.sent);
                let (prompt, target) = (format!("p-{p}"), format!("t-{t}"));
                let d = self.delivery(&id, &prompt, &target);
                self.sent += 1;
                let got = match self.outbox.add(d) {
                    Ok(d) if d.id == id => Enqueued::New(d.id),
                    Ok(d) => Enqueued::Existing(d.id),
                    Err(_) => Enqueued::Refused,
                };
                let want = self.oracle.enqueue(&id, &prompt, &target);
                assert_eq!(got, want, "a send was answered otherwise\n{}", self.log.join("\n"));
            }
            Op::Attempt(k) | Op::Ack(k) | Op::Fail(k) | Op::Hold(k) | Op::Requeue(k) => {
                let id = self.pick(k);
                let state = match op {
                    Op::Attempt(_) => State::Delivering,
                    Op::Ack(_) => State::Delivered,
                    Op::Fail(_) => State::Failed,
                    Op::Hold(_) => State::Held,
                    _ => State::Queued,
                };
                let attempt = matches!(op, Op::Attempt(_));
                let saved = self.outbox.update_saved(&id, |d| {
                    d.state = state;
                    d.attempts += u32::from(attempt);
                });
                let want = self.oracle.update(&id, |e| {
                    e.state = state;
                    e.attempts += u32::from(attempt);
                });
                assert_eq!(
                    saved,
                    want,
                    "an update's save was answered otherwise\n{}",
                    self.log.join("\n")
                );
            }
            Op::Reconnect => self.outbox.peer_ready.notify_waiters(),
            Op::PanicUpdate(k) => {
                let id = self.pick(k);
                let outbox = &self.outbox;
                let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    outbox.update(&id, |d| {
                        d.state = State::Delivered;
                        panic!("an update closure panicked");
                    })
                }));
                let present = self.oracle.memory().iter().any(|e| e.id == id);
                assert_eq!(panicked.is_err(), present, "the closure ran for a missing delivery");
                // What a panicking closure changed before its panic is a change like any other:
                // in memory, and on disk as the write allows.
                self.oracle.update(&id, |e| e.state = State::Delivered);
            }
            Op::Restart => {
                self.disk_heals();
                self.oracle.restart();
                self.reopen();
            }
            Op::TornRestart(n) => {
                self.disk_heals();
                let line = serde_json::to_vec(&self.delivery("d-torn", "p-torn", "t-0")).unwrap();
                use std::io::Write;
                let mut f = std::fs::OpenOptions::new()
                    .append(true)
                    .create(true)
                    .open(self.journal())
                    .unwrap();
                f.write_all(&line[..usize::from(n).min(line.len() - 1)]).unwrap();
                drop(f);
                self.oracle.restart();
                self.reopen();
            }
            Op::Shutdown => {
                self.disk_heals();
                self.outbox.compact();
                self.oracle.shutdown();
                self.reopen();
            }
            Op::StaleJournal => {
                self.disk_heals();
                let old = std::fs::read(self.journal()).ok();
                self.outbox.compact();
                if let Some(old) = old {
                    std::fs::write(self.journal(), old).unwrap();
                }
                self.oracle.shutdown();
                self.reopen();
            }
            Op::DiskFails => self.disk_fails(),
            Op::DiskHeals => self.disk_heals(),
        }
        self.check();
    }

    /// The real outbox's observable state against the oracle's.
    fn check(&self) {
        let log = || self.log.join("\n");
        let fields = |d: &Delivery| Entry {
            id: d.id.clone(),
            prompt_id: d.prompt_id().to_owned(),
            target: d.target.clone(),
            state: d.state,
            attempts: d.attempts,
        };
        for e in self.oracle.memory() {
            let got = self.outbox.get(&e.id).map(|d| fields(&d));
            assert_eq!(got.as_ref(), Some(e), "memory differs\n{}", log());
        }
        let (listed, waiting) = self.outbox.list(None, usize::MAX);
        let listed: Vec<Entry> = listed.iter().map(fields).collect();
        let want: Vec<Entry> = self.oracle.listed().into_iter().cloned().collect();
        assert_eq!(listed, want, "the listing differs\n{}", log());
        let pending = OutboxOracle::pending(self.oracle.memory()).len();
        assert_eq!(
            (waiting, self.outbox.unsettled()),
            (pending, pending),
            "waiting count\n{}",
            log()
        );
        // What a restart would read now. Not while the journal is a folder: a read sets that aside.
        if self.oracle.disk_ok() {
            let mut on_disk: Vec<Entry> =
                read_saved(&self.path).deliveries.values().map(fields).collect();
            on_disk.sort_by(|a, b| a.id.cmp(&b.id));
            assert_eq!(
                on_disk,
                self.oracle.durable(),
                "the files differ from what was answered\n{}",
                log()
            );
        }
    }
}

fn run(ops: &[Op]) {
    let mut harness = Harness::new();
    for op in ops {
        harness.apply(op);
    }
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: 96,
        failure_persistence: None,
        ..ProptestConfig::default()
    })]

    /// Any sequence of operations: after each, the outbox answers, holds and has on disk what
    /// the in-order list oracle says.
    #[test]
    fn the_outbox_matches_its_oracle_after_every_step(ops in proptest::collection::vec(op(), 1..80)) {
        run(&ops);
    }
}

/// Found by the model: a change whose write failed waits in memory for the next write, and a
/// clean shutdown is one. `compact` skipped when the journal was empty, so with no journal yet
/// (a fresh outbox, or one whose journal could not be started after a snapshot) the shutdown
/// wrote nothing, and the next daemon delivered an acked message again.
#[test]
fn a_shutdown_writes_a_change_whose_write_failed() {
    run(&[Op::Send(0, 0), Op::Shutdown, Op::DiskFails, Op::Ack(0), Op::DiskHeals, Op::Shutdown]);
}

/// Found by the model: an update closure that panicked left its change in memory unmarked, so
/// no write took it and a restart went back to the state before it.
#[test]
fn a_panicking_update_is_saved_like_any_other_change() {
    run(&[Op::Send(0, 0), Op::PanicUpdate(0), Op::Send(1, 0), Op::Restart]);
}

/// The past bugs, each as its shortest sequence.
#[test]
fn past_outbox_bugs_stay_fixed() {
    // #40357: a send whose write failed is refused, and nothing brings it back.
    run(&[Op::DiskFails, Op::Send(0, 0), Op::DiskHeals, Op::Send(1, 0), Op::Restart]);
    // a631eae3bf3: one prompt id to two targets is two messages.
    run(&[Op::Send(0, 0), Op::Send(0, 1), Op::Send(0, 0), Op::Ack(0), Op::Restart]);
    // #40378: a journal left beside a newer snapshot is not replayed over it.
    run(&[Op::Send(0, 0), Op::Ack(0), Op::StaleJournal, Op::Send(1, 0), Op::Restart]);
    // #40378: a torn append never swallows the next change.
    run(&[Op::Send(0, 0), Op::TornRestart(40), Op::Send(1, 0), Op::Ack(1), Op::Restart]);
}
