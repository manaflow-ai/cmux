//! A seeded simulation of moving a session to a fresh machine (review of #37284, sixth round):
//! the owner's side is the real code (the copies' store, `Store`, driven op by op on this thread,
//! with its write hook; the outbox and its retention; `open_delivery.rs`'s rules), and the
//! machine is a model of its journal and of `journal_restore`. Each seed interleaves at random:
//! prompts sent and accepted, acceptances lost, links replaced (with a window where the session
//! is not listed), restarts from an older disk, the owner's captures, restore tries that stop
//! short and their retries, purge and recreate, and the clock put 25 h forward.
//!
//! Invariants, after the seed's steps and a quiet end (the link up, restores and redeliveries run
//! to their end, a capture):
//! - every prompt the owner took from its user is in the final machine's journal exactly once,
//!   or its delivery failed with a reason, or the generation that took it was purged (the user's
//!   own purge); none is still waiting;
//! - no copy goes while it holds a record of its generation the machine lacks.
//!
//! `Rules::Before` replays the rules of 2e15539c (a duplicate answer closes a delivery; an
//! attempt reads the session's generation after its answer), which the review found losing
//! prompts: some seeds fail under them. Run (from `cmux-tui/`):
//! `MOVE_SIM_SEEDS=5000 cargo test -p acpmux --lib -- move_sim --nocapture`.

use super::*;
use crate::hub::open_delivery as od;
use crate::hub::outbox::{Delivery, Outbox, Pin, State as DState};
use std::cell::RefCell;

const PEER: &str = "b";
const MUX: &str = "moved";
const DAY_MS: u64 = 24 * 60 * 60 * 1000;

/// The rules the owner follows.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Rules {
    Now,
    Before,
}

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        // splitmix64
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }
    fn chance(&mut self, percent: u64) -> bool {
        self.below(100) < percent
    }
}

/// One journal record of the model machine.
#[derive(Clone, Debug, PartialEq)]
struct Rec {
    seq: u64,
    at: u64,
    kind: &'static str,
    prompt: Option<String>,
}

impl Rec {
    fn json(&self) -> Value {
        let msg = match &self.prompt {
            Some(p) => json!({"promptId": p}),
            None => json!({"text": format!("line {}", self.seq)}),
        };
        json!({"sessionId": MUX, "seq": self.seq, "at": self.at,
               "dir": if self.prompt.is_some() { "mux" } else { "in" },
               "kind": self.kind, "msg": msg})
    }
    fn of(v: &Value) -> Self {
        Rec {
            seq: v["seq"].as_u64().unwrap_or(0),
            at: v["at"].as_u64().unwrap_or(0),
            kind: if v["kind"] == "user_message" { "user_message" } else { "agent_message_chunk" },
            prompt: v.pointer("/msg/promptId").and_then(Value::as_str).map(str::to_owned),
        }
    }
}

/// The machine: one session, its journal on disk, and the disks it could come back on.
struct Machine {
    generation: u64,
    journal: Vec<Rec>,
    /// Older disks of this generation: what a restart from a snapshot comes back with.
    snapshots: Vec<Vec<Rec>>,
    /// Generations purged (the user's purge): what they took is gone by intent.
    purged: Vec<u64>,
    clock: u64,
    /// Every run of a prompt: its id and the generation it ran in.
    ran: Vec<(String, u64)>,
}

impl Machine {
    fn end(&self) -> u64 {
        self.journal.last().map_or(0, |r| r.seq)
    }
    fn tick(&mut self) -> u64 {
        self.clock += 1;
        self.clock
    }
    fn holds(&self, prompt: &str) -> usize {
        self.journal.iter().filter(|r| r.prompt.as_deref() == Some(prompt)).count()
    }
    /// A prompt arrives naming `generation` (None: names none).
    fn prompt(&mut self, prompt: &str, generation: Option<u64>) -> Result<bool, &'static str> {
        if generation.is_some_and(|g| g != self.generation) {
            return Err("stale_generation");
        }
        if self.holds(prompt) > 0 {
            return Ok(true);
        }
        let (seq, at) = (self.end() + 1, self.tick());
        self.journal.push(Rec { seq, at, kind: "user_message", prompt: Some(prompt.into()) });
        self.ran.push((prompt.to_owned(), self.generation));
        // Its turn writes a line too.
        let (seq, at) = (self.end() + 1, self.tick());
        self.journal.push(Rec { seq, at, kind: "agent_message_chunk", prompt: None });
        Ok(false)
    }
    /// `journal_restore`, as `hub/journal_restore.rs` takes it; `stop_after`: the disk fails
    /// after that many records (a try that stops short).
    fn restore(
        &mut self,
        generation: u64,
        after: u64,
        records: &[Rec],
        stop_after: Option<usize>,
    ) -> Result<u64, &'static str> {
        if generation != self.generation {
            return Err("generation");
        }
        let at = self.end();
        if at < after {
            return Err("diverged");
        }
        for r in records.iter().filter(|r| r.seq <= at) {
            if let Some(held) = self.journal.iter().find(|h| h.seq == r.seq)
                && (held.at, held.kind) != (r.at, r.kind)
            {
                return Err("diverged");
            }
        }
        for (n, r) in records.iter().filter(|r| r.seq > at).enumerate() {
            if stop_after.is_some_and(|k| n >= k) {
                return Err("append_failed");
            }
            self.journal.push(r.clone());
        }
        Ok(self.end())
    }
}

/// An attempt in flight: what it was pinned to when it started.
struct InFlight {
    id: String,
    prompt: String,
    pin: Option<Pin>,
    answer: Option<Result<bool, &'static str>>,
    lost: bool,
    /// Its pin was read for it (none was kept from an attempt before).
    fresh: bool,
}

/// One restore try in flight, of a link.
struct RestoreTask {
    link: u64,
    rows: (u64, u64),
    ahead: Option<Option<(u64, Vec<Value>)>>,
    tries: u32,
    done: bool,
}

struct World {
    rng: Rng,
    rules: Rules,
    machine: Machine,
    store: Store,
    _dir: cmux_unix_socket::TestDir,
    outbox: Outbox,
    link: u64,
    up: bool,
    listed: bool,
    decided: bool,
    task: Option<RestoreTask>,
    flights: Vec<InFlight>,
    sent: Vec<String>,
    /// The generation each prompt was taken into, when known to the model.
    taken_in: HashMap<String, u64>,
    trace: Vec<String>,
    /// The quiet end: no try stops short.
    calm: bool,
    /// Each delivery as last seen: the outbox's retention may drop a settled one.
    seen: HashMap<String, Delivery>,
}

fn key() -> Key {
    (PEER.to_owned(), MUX.to_owned())
}

impl World {
    fn new(seed: u64, rules: Rules) -> Self {
        let dir = cmux_unix_socket::short_test_dir("acpmux-msim");
        // The store's hook is `Send + Sync`; this thread is the only one, so the hook records
        // into a thread-local the world drains after each op.
        let hook: Written = Arc::new(|key, generation, prompts| {
            WRITTEN.with(|w| w.borrow_mut().push((key.clone(), generation, prompts)));
        });
        let mut store =
            Store::new(disk::root(dir.path()), Arc::default(), Arc::new(StdMutex::new(Some(hook))));
        store.scan();
        crate::store::CLOCK_AHEAD_MS.with(|c| c.set(0));
        let mut world = World {
            rng: Rng(seed),
            rules,
            machine: Machine {
                generation: 100,
                journal: vec![],
                snapshots: vec![],
                purged: vec![],
                clock: 1,
                ran: vec![],
            },
            store,
            _dir: dir,
            outbox: Outbox::default(),
            link: 0,
            up: false,
            listed: false,
            decided: false,
            task: None,
            flights: vec![],
            sent: vec![],
            taken_in: HashMap::new(),
            trace: vec![],
            calm: false,
            seen: HashMap::new(),
        };
        world.connect();
        world
    }

    fn note(&mut self, line: String) {
        self.trace.push(line);
    }

    fn take(&mut self, op: Op) {
        self.store.take(op);
        let told: Vec<_> = WRITTEN.with(|w| std::mem::take(&mut *w.borrow_mut()));
        for (key, generation, prompts) in told {
            // The hook's work (`Hub::close_captured`).
            let _ = od::close_captured(&self.outbox, (&key.0, &key.1, generation), &prompts);
        }
    }

    fn list(&mut self) {
        let rows = vec![(MUX.to_owned(), Some(self.machine.generation))];
        self.take(Op::Listed { peer: PEER.into(), rows, full: true });
        self.listed = true;
    }

    /// A new link: listed after a while (`listed` false meanwhile), its restore task reads the
    /// rows as listed now.
    fn connect(&mut self) {
        self.link += 1;
        self.up = true;
        self.listed = false;
        self.decided = false;
        self.task = None;
        self.note(format!("link {} up", self.link));
    }

    fn drop_link(&mut self) {
        self.up = false;
        self.listed = false;
        self.decided = false;
        self.note(format!("link {} down", self.link));
    }

    fn pin_now(&self) -> Option<Pin> {
        (self.up && self.listed).then(|| Pin {
            peer: PEER.into(),
            session: MUX.into(),
            generation: self.machine.generation,
            link: (1, self.link),
        })
    }

    fn send(&mut self) {
        let n = self.sent.len();
        let prompt = format!("p{n}");
        let at = crate::store::now_ms();
        let d: Delivery = serde_json::from_value(json!({
            "id": format!("d{n}"), "target": format!("{PEER}/{MUX}"),
            "request": {"sessionId": format!("{PEER}/{MUX}"), "_meta": {"acpmux": {"promptId": prompt}}},
            "state": "queued", "createdAt": at, "updatedAt": at,
        }))
        .unwrap();
        self.outbox.add(d);
        self.sent.push(prompt.clone());
        self.note(format!("send {prompt}"));
    }

    /// An attempt of a queued delivery starts (`server/outbox.rs` `deliver`).
    fn start_attempt(&mut self) {
        let queued: Vec<Delivery> = self
            .outbox
            .list(None, usize::MAX)
            .0
            .into_iter()
            .filter(|d| d.state == DState::Queued)
            .filter(|d| !self.flights.iter().any(|f| f.id == d.id))
            .collect();
        if queued.is_empty() {
            return;
        }
        let d = queued[self.rng.below(queued.len() as u64) as usize].clone();
        let now = crate::store::now_ms();
        if now >= d.created_at + crate::hub::outbox::RETRY_FOR_MS {
            self.outbox.update(&d.id, |d| {
                d.state = DState::Failed;
                d.error = Some("not delivered within a day of being sent".into());
            });
            self.note(format!("{} expired unsent", d.id));
            return;
        }
        // Prompts to the peer wait for its link's restore decision (`restore.rs` `Gate`).
        if !(self.up && self.listed && self.decided) {
            return;
        }
        // Now: pinned at the first attempt, kept for every later one (`deliver`).
        let fresh = d.pin.is_none();
        let pin = match self.rules {
            Rules::Now => d.pin.clone().or_else(|| self.pin_now()),
            Rules::Before => None,
        };
        if self.rules == Rules::Now && fresh && pin.is_some() {
            self.outbox.update(&d.id, |d| d.pin.clone_from(&pin));
        }
        let prompt = d.prompt_id().to_owned();
        let named = pin.as_ref().map(|p| p.generation);
        let answer = Some(self.machine.prompt(&prompt, named));
        if let Some(Ok(_)) = answer {
            self.taken_in.insert(prompt.clone(), self.machine.generation);
        }
        let lost = self.rng.chance(20);
        self.note(format!(
            "attempt {} {prompt}: {answer:?}{}",
            d.id,
            if lost { " (answer lost)" } else { "" }
        ));
        self.flights.push(InFlight { id: d.id, prompt, pin, answer, lost, fresh });
    }

    /// An attempt's answer comes back (or its loss is found: tried again).
    fn end_attempt(&mut self) {
        if self.flights.is_empty() {
            return;
        }
        let i = self.rng.below(self.flights.len() as u64) as usize;
        let f = self.flights.remove(i);
        let answer = if f.lost { None } else { f.answer };
        match answer {
            Some(Ok(duplicate)) => {
                let answer = json!({"duplicate": duplicate});
                match self.rules {
                    Rules::Now => self.outbox.update(&f.id, |d| od::accepted(d, f.pin, answer)),
                    Rules::Before => {
                        // 2e15539c: the generation read now, from the row as it is now; a
                        // duplicate, or no row, is not kept open.
                        let pin = self.pin_now().filter(|_| !duplicate);
                        self.outbox.update(&f.id, |d| {
                            d.state = DState::Delivered;
                            d.open_on_peer = pin.is_some();
                            d.pin = pin;
                            d.accepted = Some(answer);
                        });
                    }
                }
                self.note(format!("{} accepted (duplicate {duplicate})", f.id));
            }
            Some(Err("stale_generation")) => {
                // A pin read for this attempt is read again; one kept from an attempt before,
                // which that session may have taken, fails (`deliver`).
                self.outbox.update(&f.id, |d| {
                    d.attempts += 1;
                    if f.fresh {
                        d.pin = None;
                    } else {
                        d.state = DState::Failed;
                        d.error = Some("stale_generation".into());
                    }
                });
            }
            Some(Err(e)) => self.outbox.update(&f.id, |d| {
                d.state = DState::Failed;
                d.error = Some(e.into());
            }),
            None => self.outbox.update(&f.id, |d| d.attempts += 1),
        }
        let _ = f.prompt;
    }

    /// The owner reads a page of the machine's journal on the current link and writes it.
    fn capture(&mut self) {
        if !(self.up && self.listed) {
            return;
        }
        let n = self.machine.journal.len();
        let from = n - self.rng.below(n as u64 + 1) as usize;
        let records: Vec<Value> = self.machine.journal[from..].iter().map(Rec::json).collect();
        let page = Page {
            link: (1, self.link),
            asked: Some(self.machine.generation),
            generation: Some(self.machine.generation),
            has_more: from > 0,
            host_last_seq: Some(self.machine.end()),
            records,
            ..Page::default()
        };
        self.take(Op::Page { key: key(), page });
        self.take(Op::Flush { peer: Some(PEER.into()), done: None });
        self.note(format!("capture from {from} of {n}"));
    }

    fn copy_seqs(&mut self) -> Vec<Rec> {
        if !self.store.load(&key()) {
            return vec![];
        }
        let generation = self.store.copies[&key()].head.generation;
        if generation != Some(self.machine.generation) {
            return vec![];
        }
        self.store.copies[&key()]
            .records
            .as_ref()
            .map_or(vec![], |r| r.values().map(Rec::of).collect())
    }

    /// One step of the current link's restore task (`restore.rs` `restore_peer_journals`).
    fn restore_step(&mut self) {
        if !(self.up && self.listed) || self.decided {
            return;
        }
        let link = self.link;
        // A task of a link before goes with it (`restore.rs`: it stops where it is).
        if self.task.as_ref().is_some_and(|t| t.link != link) {
            self.task = None;
        }
        let task = self.task.get_or_insert(RestoreTask {
            link,
            rows: (self.machine.generation, self.machine.end()),
            ahead: None,
            tries: 0,
            done: false,
        });
        if task.ahead.is_none() {
            let (generation, last) = task.rows;
            let ahead = self.store.ahead(PEER, vec![(MUX.into(), generation, last)]);
            let ahead = ahead.into_iter().next().map(|(_, _, after, records)| (after, records));
            self.task.as_mut().unwrap().ahead = Some(ahead);
            return;
        }
        let task = self.task.as_mut().unwrap();
        let Some(Some((after, records))) = task.ahead.clone() else {
            task.done = true;
            self.decided = true;
            self.note(format!("link {link}: nothing ahead; decided"));
            self.redeliver();
            return;
        };
        let generation = task.rows.0;
        task.tries += 1;
        let tries = task.tries;
        let recs: Vec<Rec> = records.iter().map(Rec::of).collect();
        let stop =
            (!self.calm && self.rng.chance(25)).then(|| self.rng.below(recs.len() as u64) as usize);
        let before = self.copy_seqs();
        let answer = self.machine.restore(generation, after, &recs, stop);
        self.note(format!(
            "link {link}: restore after {after} ({} records): {answer:?}",
            recs.len()
        ));
        match answer {
            Ok(last) => {
                self.take(Op::Restored {
                    key: key(),
                    link: (1, link),
                    generation,
                    last: Some(last),
                });
            }
            Err("generation" | "diverged") => {
                self.take(Op::Restored { key: key(), link: (1, link), generation, last: None });
                self.check_copy_kept(&before);
            }
            Err(_) if tries < 4 => return,
            Err(_) => {
                // Held: prompts fail visibly until a later link decides again.
                self.note(format!("link {link}: held"));
                return;
            }
        }
        self.decided = true;
        self.redeliver();
    }

    /// A copy went: every record of it of the machine's generation must be on the machine.
    fn check_copy_kept(&mut self, before: &[Rec]) {
        if !self.copy_seqs().is_empty() {
            return;
        }
        for r in before {
            if !self.machine.journal.iter().any(|h| h.seq == r.seq && h.prompt == r.prompt) {
                LOST.with(|l| {
                    l.borrow_mut()
                        .push(format!("copy went holding seq {} the machine lacks", r.seq))
                });
            }
        }
    }

    /// The link's redelivery (`server/outbox.rs` `redeliver_open`).
    fn redeliver(&mut self) {
        let now = crate::store::now_ms();
        let open: Vec<Delivery> = self.outbox.open_on_peers();
        for d in open {
            let Some(pin) = d.pin.clone() else { continue };
            if d.open_lapsed(now) {
                let lapsed = crate::hub::outbox::OPEN_LAPSED.to_owned();
                self.outbox.update(&d.id, |d| d.fail_open(lapsed));
                continue;
            }
            if self.rules == Rules::Now && self.store.holds(&key(), pin.generation, d.prompt_id()) {
                self.outbox.update(&d.id, |d| {
                    od::close_if_held(d, true);
                });
                continue;
            }
            let answer = self.machine.prompt(d.prompt_id(), Some(pin.generation));
            if answer.is_ok() {
                self.taken_in.insert(d.prompt_id().to_owned(), self.machine.generation);
            }
            self.note(format!("again {}: {answer:?}", d.id));
            match self.rules {
                Rules::Now => {
                    let again = match answer {
                        Ok(dup) => od::Again::Taken(json!({"duplicate": dup})),
                        Err(e) => od::Again::Refused(e.into()),
                    };
                    self.outbox.update(&d.id, |d| {
                        od::after_again(d, again);
                    });
                }
                Rules::Before => self.outbox.update(&d.id, |d| match answer {
                    Ok(_) => d.open_on_peer = false,
                    Err(e) => d.fail_open(e.into()),
                }),
            }
        }
    }

    /// The machine goes and comes back on an older disk of this generation, on a new link.
    fn restart_older(&mut self) {
        if self.machine.snapshots.is_empty() {
            return;
        }
        let i = self.rng.below(self.machine.snapshots.len() as u64) as usize;
        self.machine.journal = self.machine.snapshots[i].clone();
        // A disk at most as new as the one it came back on.
        self.machine.snapshots.truncate(i + 1);
        // Answers in flight were the old machine's: lost with it.
        for f in &mut self.flights {
            f.lost = true;
        }
        self.note(format!("restart from snapshot {i} (ends {})", self.machine.end()));
        self.drop_link();
        self.connect();
    }

    fn purge_recreate(&mut self) {
        self.machine.purged.push(self.machine.generation);
        self.machine.generation += 1;
        self.machine.journal.clear();
        self.machine.snapshots.clear();
        let gone = Some(self.machine.generation - 1);
        self.take(Op::Gone { key: key(), generation: gone });
        self.note(format!("purged; generation {} made", self.machine.generation));
        if self.up {
            self.list();
        }
    }

    fn look(&mut self) {
        for d in self.outbox.list(None, usize::MAX).0 {
            self.seen.insert(d.id.clone(), d);
        }
    }

    fn step(&mut self) {
        self.look();
        match self.rng.below(100) {
            0..=14 if self.sent.len() < 8 => self.send(),
            0..=29 => self.start_attempt(),
            30..=44 => self.end_attempt(),
            45..=54 => self.capture(),
            55..=59 => {
                let journal = self.machine.journal.clone();
                self.note(format!(
                    "snapshot {} (ends {})",
                    self.machine.snapshots.len(),
                    self.machine.end()
                ));
                self.machine.snapshots.push(journal);
            }
            60..=64 => self.restart_older(),
            65..=69 => {
                self.drop_link();
                self.connect();
            }
            70..=79 if self.up && !self.listed => self.list(),
            70..=89 => self.restore_step(),
            90 => self.purge_recreate(),
            91..=92 => {
                crate::store::CLOCK_AHEAD_MS.with(|c| c.set(c.get() + DAY_MS + 60 * 60 * 1000));
                // Any change runs the retention.
                self.outbox.update("none", |_| {});
                let anything = self.outbox.list(None, 1).0.first().map(|d| d.id.clone());
                if let Some(id) = anything {
                    self.outbox.update(&id, |_| {});
                }
                self.note("clock +25 h".into());
            }
            _ => {}
        }
    }

    /// The quiet end: the link up and listed, its restore run, every attempt answered, the
    /// queue delivered, a capture, and one more link's redelivery.
    fn settle(&mut self) {
        for f in &mut self.flights {
            f.lost = true;
        }
        self.calm = true;
        for _ in 0..3 {
            self.drop_link();
            self.connect();
            self.list();
            for _ in 0..12 {
                self.restore_step();
            }
            for _ in 0..40 {
                self.start_attempt();
                self.end_attempt();
            }
            while !self.flights.is_empty() {
                self.end_attempt();
            }
            let n = self.machine.journal.len();
            if n > 0 {
                let records = self.machine.journal.iter().map(Rec::json).collect();
                let page = Page {
                    link: (1, self.link),
                    asked: Some(self.machine.generation),
                    generation: Some(self.machine.generation),
                    host_last_seq: Some(self.machine.end()),
                    records,
                    ..Page::default()
                };
                self.take(Op::Page { key: key(), page });
                self.take(Op::Flush { peer: Some(PEER.into()), done: None });
            }
            self.redeliver();
        }
    }

    fn check(&mut self) -> Result<(), String> {
        let lost = LOST.with(|l| std::mem::take(&mut *l.borrow_mut()));
        if let Some(first) = lost.first() {
            return Err(first.clone());
        }
        for (n, prompt) in self.sent.clone().iter().enumerate() {
            let mut generations: Vec<u64> =
                self.machine.ran.iter().filter(|(p, _)| p == prompt).map(|(_, g)| *g).collect();
            generations.dedup();
            if generations.len() > 1 {
                return Err(format!("{prompt} ran in generations {generations:?}"));
            }
            self.look();
            let id = format!("d{n}");
            let d = self.outbox.get(&id).or_else(|| self.seen.get(&id).cloned());
            let d = d.ok_or(format!("{prompt}'s delivery was never seen"))?;
            if self.outbox.get(&id).is_none() && (!d.settled() || d.open_on_peer) {
                let open = d.open_on_peer;
                return Err(format!("{prompt}'s delivery went while {:?} (open {open})", d.state));
            }
            let ran = self.machine.holds(prompt);
            let purged = self.taken_in.get(prompt).is_some_and(|g| self.machine.purged.contains(g));
            match (d.state, ran) {
                (_, n) if n > 1 => return Err(format!("{prompt} ran {n} times")),
                (DState::Failed, _) if d.error.is_some() => {}
                (DState::Delivered, 1) => {}
                (DState::Delivered, 0) if purged => {}
                (state, ran) => {
                    return Err(format!(
                        "{prompt}: delivery {state:?} (open {}), {ran} times on the machine",
                        d.open_on_peer
                    ));
                }
            }
        }
        Ok(())
    }
}

thread_local! {
    static WRITTEN: RefCell<Vec<(Key, u64, Vec<String>)>> = const { RefCell::new(Vec::new()) };
    static LOST: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
}

fn run(seed: u64, rules: Rules) -> (Result<(), String>, Vec<String>) {
    LOST.with(|l| l.borrow_mut().clear());
    let mut world = World::new(seed, rules);
    world.list();
    let steps = 60 + world.rng.below(140);
    for _ in 0..steps {
        world.step();
    }
    world.settle();
    let verdict = world.check();
    crate::store::CLOCK_AHEAD_MS.with(|c| c.set(0));
    (verdict, world.trace)
}

fn seeds() -> std::ops::Range<u64> {
    let n = std::env::var("MOVE_SIM_SEEDS").ok().and_then(|v| v.parse().ok()).unwrap_or(500);
    let base = std::env::var("MOVE_SIM_SEED_BASE").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
    base..base + n
}

/// Every seed holds the invariants under the rules of now.
#[test]
fn move_sim_seeds_hold_the_move_invariants() {
    if let Some(seed) = std::env::var("MOVE_SIM_SEED").ok().and_then(|v| v.parse().ok()) {
        let (verdict, trace) = run(seed, Rules::Now);
        eprintln!("{}", trace.join("\n"));
        assert!(verdict.is_ok(), "seed {seed}: {verdict:?}");
        return;
    }
    let range = seeds();
    let n = range.end - range.start;
    let failed: Vec<String> = range
        .filter_map(|seed| run(seed, Rules::Now).0.err().map(|e| format!("seed {seed}: {e}")))
        .collect();
    eprintln!("move sim: {n} seeds, {} failed", failed.len());
    assert!(
        failed.is_empty(),
        "{} of {n} seeds failed (replay: MOVE_SIM_SEED=N cargo test -p acpmux --lib -- move_sim --nocapture):\n{}",
        failed.len(),
        failed.join("\n")
    );
}

/// Under the rules of 2e15539c some seeds lose a prompt: the simulation finds what the review
/// found. Prints which seeds, and how.
#[test]
fn move_sim_finds_the_losses_of_the_rules_before() {
    let range = seeds();
    let n = range.end - range.start;
    let failed: Vec<String> = range
        .filter_map(|seed| run(seed, Rules::Before).0.err().map(|e| format!("seed {seed}: {e}")))
        .collect();
    eprintln!("move sim, the rules of 2e15539c: {n} seeds, {} failed", failed.len());
    for f in failed.iter().take(20) {
        eprintln!("  {f}");
    }
    assert!(!failed.is_empty(), "no seed found the losses the review found");
}
