//! A seeded simulation of moving a session to a fresh machine (review of #37284, sixth and
//! seventh rounds): the owner's side is the real code (the copies' store, `Store`, driven op by
//! op on this thread, with its write hook and its bounds; the outbox and its retention;
//! `open_delivery.rs`'s rules; `restore.rs`'s merge of proofs), and the machine is a model of its
//! journal, its queue and `journal_restore`. Each seed interleaves at random: prompts sent and
//! accepted (run at once or queued), acceptances lost, queued prompts run or taken off the queue,
//! turns that write past the copy's bound, links replaced (with a window where the session is not
//! listed), restarts from an older disk, the owner's captures (pages past a gap replace the
//! copy), the queue of captures overflowing (every copy of the peer goes), the disk's eviction,
//! restore tries that stop short and their retries, purge and recreate, and the clock put 25 h
//! forward.
//!
//! Invariants, after the seed's steps and a quiet end (the link up, restores and redeliveries run
//! to their end, the queue run, a capture, and the clock past every open delivery's bound):
//! - every prompt the owner took from its user ran exactly once in the final machine's journal,
//!   or was taken off its queue there, or its delivery failed with a reason, or the generation
//!   that took it was purged (the user's own purge);
//! - no prompt whose end (its result, or its removal from the queue) the owner's copy wrote
//!   ever runs again ("settled work resurrected");
//! - no prompt ran in two generations; no delivery goes while open or unsettled;
//! - no copy goes while it holds a record of its generation the machine lacks, unless the
//!   machine wrote another record at one of its seqs (another history).
//!
//! A prompt whose delivery a later link released (its machine held every record of its proof
//! then) and that a restart from a disk older still loses afterwards is past what the release
//! rule promises (`open_delivery.rs`): it is counted and printed, not failed.
//!
//! `Rules::Before` replays the rules of 0c98c292 (a write's report closes a delivery for good,
//! and a copy replaced past a gap carries its `queued` and `user_message` records alone), which
//! the review found losing prompts and resurrecting settled ones: some seeds fail under them.
//! `Rules::Prior` replays 98b4575a's, and `Rules::Last` 91b1343d's (a removal the copy's bound
//! cut before a write leaves its prompt's proof whole, a queued prompt runs while a restore holds
//! the chat between tries, and a log read for a restore writes its recovery first, on a disk the
//! machine came back on mid-turn): some seeds fail under each.
//! Run (from `cmux-tui/`): `MOVE_SIM_SEEDS=5000 cargo test -p acpmux --lib -- move_sim --nocapture`.

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
    /// 0c98c292's owner (the machine and the link as now).
    Before,
    /// 98b4575a's: the owner as now; a restore and a proof's read on whatever link is up, a
    /// restore refused while a queue waits, and none settled while the log is not read yet.
    Prior,
    /// 91b1343d's (review at 91b1343d, F1, F2 and F4): the bound cuts a record no write reported
    /// and the copy still says it saw every record; a queued prompt runs while a restore holds
    /// the chat between tries; a log read for a restore writes its recovery first.
    Last,
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

/// The record kinds the model writes.
const KINDS: &[&str] =
    &["queued", "user_message", "agent_message_chunk", "turn_result", "queue_removed"];

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
        let kind = v["kind"].as_str().unwrap_or_default();
        Rec {
            seq: v["seq"].as_u64().unwrap_or(0),
            at: v["at"].as_u64().unwrap_or(0),
            kind: KINDS.iter().find(|k| **k == kind).copied().unwrap_or("agent_message_chunk"),
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
    /// Prompts whose end (result or removal) the owner's copy wrote: none may run again by
    /// anything the owner sends (a disk the machine came back on may hold one still queued: its
    /// own queue runs it, before any owner speaks).
    settled_seen: HashSet<String>,
    /// The seqs the owner made on this disk (its prompts, its restores): a prompt that runs from
    /// one of them runs because of the owner.
    by_owner: HashSet<u64>,
    /// Its queue in memory, in the order it runs.
    queue: Vec<String>,
    /// Whether its log is read (a deferred start reads it later): until then its queue is not
    /// rebuilt and nothing of it runs.
    loaded: bool,
    /// The prompts a restore put back in the queue that have not run: no other prompt may run
    /// first.
    restored_first: Vec<String>,
    /// 98b4575a's machine (`Rules::Prior`).
    old: bool,
    /// 91b1343d's machine (`Rules::Last`).
    last: bool,
    /// A restore stopped short holds the chat for the owner's next try (`hold_for_next_try`),
    /// until a try ends it or it lapses.
    holding: bool,
    /// Its log was read for a restore, its recovery still to run (`recover_pending`).
    pending: bool,
    /// Prompts a disk the machine came back on ran again by itself (its own queue, before any
    /// owner spoke): the journal may hold that run and the one its owner gives back.
    ran_by_itself: HashSet<String>,
}

impl Machine {
    fn end(&self) -> u64 {
        self.journal.last().map_or(0, |r| r.seq)
    }
    fn push(&mut self, kind: &'static str, prompt: Option<&str>) {
        let (seq, at) = (self.end() + 1, self.tick());
        self.by_owner.insert(seq);
        self.journal.push(Rec { seq, at, kind, prompt: prompt.map(str::to_owned) });
    }
    fn tick(&mut self) -> u64 {
        self.clock += 1;
        self.clock
    }
    fn holds(&self, prompt: &str) -> usize {
        self.journal.iter().filter(|r| r.prompt.as_deref() == Some(prompt)).count()
    }
    fn count(&self, prompt: &str, kind: &str) -> usize {
        self.journal
            .iter()
            .filter(|r| r.prompt.as_deref() == Some(prompt) && r.kind == kind)
            .count()
    }
    /// The prompts waiting in the queue, as `restore_queue` reads the journal: queued, with no
    /// record of them after.
    fn pending(&self) -> Vec<String> {
        self.waiting().into_iter().map(|(p, _)| p).collect()
    }
    /// `pending`, with the seq of each one's `queued` record.
    fn waiting(&self) -> Vec<(String, u64)> {
        let mut waiting: Vec<(String, u64)> = Vec::new();
        for r in &self.journal {
            let Some(p) = &r.prompt else { continue };
            if r.kind == "queued" {
                if !waiting.iter().any(|(w, _)| w == p) {
                    waiting.push((p.clone(), r.seq));
                }
            } else {
                waiting.retain(|(w, _)| w != p);
            }
        }
        waiting
    }
    /// Runs `prompt`: its turn, its output and its result; `by_owner`: because of the owner.
    fn run(&mut self, prompt: &str, by_owner: bool) {
        if !self.restored_first.is_empty() && !self.restored_first.iter().any(|p| p == prompt) {
            LOST.with(|l| {
                l.borrow_mut().push(format!("ahead: {prompt} ran before the restored queue"))
            });
        }
        self.restored_first.retain(|p| p != prompt);
        self.queue.retain(|p| p != prompt);
        if !by_owner {
            self.ran_by_itself.insert(prompt.to_owned());
        }
        if by_owner && self.settled_seen.contains(prompt) {
            if std::env::var_os("MOVE_SIM_SEED").is_some() {
                let lives: Vec<String> = self
                    .journal
                    .iter()
                    .filter(|r| r.prompt.is_some())
                    .map(|r| format!("{}:{}:{}", r.seq, r.kind, r.prompt.as_deref().unwrap_or("")))
                    .collect();
                eprintln!("RESURRECTED {prompt}; journal {lives:?}");
            }
            LOST.with(|l| {
                l.borrow_mut()
                    .push(format!("resurrected: {prompt} ran again after its end was captured"))
            });
        }
        self.push("user_message", Some(prompt));
        self.ran.push((prompt.to_owned(), self.generation));
        self.push("agent_message_chunk", None);
        self.push("turn_result", Some(prompt));
    }
    /// A prompt arrives naming `generation` (None: names none); `queue`: a turn runs, so it
    /// waits.
    fn prompt(
        &mut self,
        prompt: &str,
        generation: Option<u64>,
        queue: bool,
    ) -> Result<bool, &'static str> {
        if generation.is_some_and(|g| g != self.generation) {
            return Err("stale_generation");
        }
        if self.holds(prompt) > 0 {
            return Ok(true);
        }
        // Behind what waits, too.
        if queue || !self.queue.is_empty() {
            self.push("queued", Some(prompt));
            self.queue.push(prompt.to_owned());
        } else {
            self.run(prompt, true);
        }
        Ok(false)
    }
    /// The queue's first prompt runs, once the log is read.
    fn work(&mut self) {
        if !self.loaded {
            return;
        }
        if self.holding {
            if !self.last {
                return;
            }
            // 91b1343d: a task that waited before the restore takes the turn lock between tries.
            if !self.queue.is_empty() {
                LOST.with(|l| {
                    l.borrow_mut()
                        .push("held: a queued prompt ran while a restore held the chat".into())
                });
            }
        }
        let waiting = self.waiting();
        while !self.queue.is_empty() {
            let p = self.queue.remove(0);
            if let Some((_, seq)) = waiting.iter().find(|(w, _)| *w == p) {
                let by_owner = self.by_owner.contains(seq);
                self.run(&p, by_owner);
                return;
            }
        }
    }
    /// A waiting prompt is taken off the queue.
    fn cancel(&mut self, pick: u64) {
        if !self.queue.is_empty() {
            let p = self.queue.remove((pick % self.queue.len() as u64) as usize);
            self.push("queue_removed", Some(&p));
            self.restored_first.retain(|r| *r != p);
        }
    }
    /// The log is read (a deferred start's lazy load): a turn the restart cut gets its unknown
    /// outcome, and what waits in it joins the queue, after what is there (`restore_queue`).
    fn load(&mut self) {
        if self.loaded {
            return;
        }
        self.loaded = true;
        self.recover();
    }
    /// The recovery a read log writes (`recover_log`): a turn with no result gets its unknown
    /// outcome (`mark_unknown_outcome`); what waits joins the queue. Answers whether it wrote.
    fn recover(&mut self) -> bool {
        let open = self
            .journal
            .iter()
            .rev()
            .take_while(|r| r.kind != "turn_result")
            .find(|r| r.kind == "user_message")
            .and_then(|r| r.prompt.clone());
        if let Some(p) = &open {
            let (seq, at) = (self.end() + 1, self.tick());
            self.journal.push(Rec { seq, at, kind: "turn_result", prompt: Some(p.clone()) });
        }
        for p in self.pending() {
            if !self.queue.contains(&p) {
                self.queue.push(p);
            }
        }
        open.is_some()
    }
    /// The hold a restore that stopped short left lapses: the recovery it owes runs.
    fn lapse(&mut self) {
        if !std::mem::take(&mut self.holding) {
            return;
        }
        if std::mem::take(&mut self.pending) {
            self.recover();
        }
    }
    /// The machine starts on `journal`, its log read now or later.
    fn start(&mut self, journal: Vec<Rec>, loaded: bool) {
        self.journal = journal;
        self.by_owner.clear();
        self.queue.clear();
        self.restored_first.clear();
        self.loaded = false;
        self.holding = false;
        self.pending = false;
        if loaded {
            self.load();
        }
    }
    /// `journal_restore`, as `hub/journal_restore.rs` takes it; `stop_after`: the disk fails
    /// after that many records (a try that stops short). What it gives back waiting in the queue
    /// waits there again (`pending`).
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
        if self.old && !self.queue.is_empty() {
            // 98b4575a: refused while a prompt waits, with no turn running.
            LOST.with(|l| {
                l.borrow_mut()
                    .push("stalled: a restore was refused while only a queue waited".into())
            });
            return Err("busy");
        }
        // Its log is read first (`journal_restore.rs`, F3), its recovery after the records
        // (F4); 91b1343d's wrote the recovery first.
        let mut recovered = false;
        if !self.old && !self.loaded {
            if self.last {
                self.loaded = true;
                recovered = self.recover();
            } else {
                self.loaded = true;
                self.pending = true;
            }
        }
        let answer = self.write_restored(after, records, stop_after);
        if answer == Err("diverged") && recovered {
            LOST.with(|l| {
                l.borrow_mut().push(
                    "diverged: a log read for a restore wrote its recovery in the restore's seqs"
                        .into(),
                )
            });
        }
        match answer {
            Err(e @ "append_failed") => {
                self.holding = true;
                return Err(e);
            }
            Err(e) => {
                self.holding = false;
                if std::mem::take(&mut self.pending) {
                    self.recover();
                }
                return Err(e);
            }
            Ok(_) => self.holding = false,
        }
        if std::mem::take(&mut self.pending) {
            self.recover();
        }
        let from_copy: Vec<String> = records
            .iter()
            .filter(|r| r.seq > after && r.kind == "queued")
            .filter_map(|r| r.prompt.clone())
            .collect();
        let pending = self.pending();
        if self.old {
            // 98b4575a: merged into the queue, and only when the log is read.
            if self.loaded {
                for p in &pending {
                    if !self.queue.contains(p) {
                        self.queue.push(p.clone());
                    }
                }
            }
        } else {
            // Rebuilt whole: the copy's prompts first, then the machine's own, in their order.
            let rank = |p: &String| {
                let own = self.queue.iter().position(|q| q == p).unwrap_or(usize::MAX);
                (!from_copy.contains(p), own)
            };
            let mut queue = pending.clone();
            queue.sort_by_key(rank);
            self.queue = queue;
        }
        self.restored_first = from_copy.into_iter().filter(|p| pending.contains(p)).collect();
        Ok(self.end())
    }
    /// The restore's check and write (`write_restored`).
    fn write_restored(
        &mut self,
        after: u64,
        records: &[Rec],
        stop_after: Option<usize>,
    ) -> Result<(), &'static str> {
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
            self.by_owner.insert(r.seq);
        }
        Ok(())
    }
}

/// An attempt in flight: what it was pinned to when it started.
struct InFlight {
    id: String,
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
    /// Where the journal ends once this link's restore ran (`redeliver_open`).
    ends: HashMap<String, (u64, u64)>,
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
    /// The prompts whose deliveries a link released: their machine held every record of their
    /// proofs then (`od::Step::Release`).
    released: HashSet<String>,
}

fn key() -> Key {
    (PEER.to_owned(), MUX.to_owned())
}

impl World {
    fn new(seed: u64, rules: Rules) -> Self {
        let dir = cmux_unix_socket::short_test_dir("acpmux-msim");
        // The store's hook is `Send + Sync`; this thread is the only one, so the hook records
        // into a thread-local the world drains after each op.
        let hook: Written = Arc::new(|key, generation, link, records| {
            WRITTEN.with(|w| w.borrow_mut().push((key.clone(), generation, link, records)));
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
                settled_seen: HashSet::new(),
                by_owner: HashSet::new(),
                queue: vec![],
                loaded: true,
                restored_first: vec![],
                old: rules == Rules::Prior,
                last: rules == Rules::Last,
                holding: false,
                pending: false,
                ran_by_itself: HashSet::new(),
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
            released: HashSet::new(),
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
        for (key, generation, link, records) in told {
            for r in &records {
                if matches!(r["kind"].as_str(), Some("turn_result" | "queue_removed"))
                    && let Some(p) = od::prompt_of(r)
                {
                    self.machine.settled_seen.insert(p.to_owned());
                }
            }
            let pinned = (key.0.as_str(), key.1.as_str(), generation);
            match self.rules {
                // The hook's work (`Hub::proof_written`).
                Rules::Now | Rules::Last => {
                    let _ = od::take_written(&self.outbox, pinned, &records, link);
                }
                // 98b4575a: the peer's link when the write's hook runs.
                Rules::Prior => {
                    let _ = od::take_written(&self.outbox, pinned, &records, (1, self.link));
                }
                // 0c98c292: each open delivery whose prompt's record the write held closes.
                Rules::Before => {
                    for d in self.outbox.open_on_peers() {
                        let same = d.pin.as_ref().is_some_and(|p| {
                            (p.peer.as_str(), p.session.as_str(), p.generation) == pinned
                        });
                        if same && records.iter().any(|r| od::names_prompt(r, d.prompt_id())) {
                            self.outbox.update(&d.id, |d| d.open_on_peer = false);
                        }
                    }
                }
            }
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
        // Now: proven, it is taken, and never sent again (`deliver`).
        if self.rules != Rules::Before && d.proof.is_some() && d.pin.is_some() {
            self.outbox.update(&d.id, |d| {
                let pin = d.pin.clone();
                od::accepted(d, pin, json!({"proven": true}));
            });
            self.note(format!("{} proven: taken", d.id));
            return;
        }
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
        // Pinned at the first attempt, kept for every later one (`deliver`).
        let fresh = d.pin.is_none();
        let pin = d.pin.clone().or_else(|| self.pin_now());
        if fresh && pin.is_some() {
            self.outbox.update(&d.id, |d| d.pin.clone_from(&pin));
        }
        let prompt = d.prompt_id().to_owned();
        let named = pin.as_ref().map(|p| p.generation);
        let queue = self.rng.chance(50);
        let answer = Some(self.machine.prompt(&prompt, named, queue));
        if let Some(Ok(_)) = answer {
            self.taken_in.insert(prompt.clone(), self.machine.generation);
        }
        let lost = self.rng.chance(20);
        self.note(format!(
            "attempt {} {prompt}: {answer:?}{}",
            d.id,
            if lost { " (answer lost)" } else { "" }
        ));
        self.flights.push(InFlight { id: d.id, pin, answer, lost, fresh });
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
                self.outbox.update(&f.id, |d| od::accepted(d, f.pin, answer));
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
    }

    /// What the copy holds of the machine's generation, and from which seq it saw every record.
    fn copy(&mut self) -> Option<(u64, BTreeMap<u64, Value>)> {
        if !self.store.load(&key()) {
            return None;
        }
        let c = &self.store.copies[&key()];
        (c.head.generation == Some(self.machine.generation))
            .then(|| (c.head.since, c.records.clone().unwrap_or_default()))
    }

    /// The owner reads a page of the machine's journal on the current link and writes it.
    fn capture(&mut self) {
        if !(self.up && self.listed) {
            return;
        }
        let n = self.machine.journal.len();
        let from = n - self.rng.below(n as u64 + 1) as usize;
        let records: Vec<Value> = self.machine.journal[from..].iter().map(Rec::json).collect();
        self.page(records, from > 0);
        self.note(format!("capture from {from} of {n}"));
    }

    fn page(&mut self, records: Vec<Value>, has_more: bool) {
        let before = if self.rules == Rules::Before { self.copy() } else { None };
        let page = Page {
            link: (1, self.link),
            asked: Some(self.machine.generation),
            generation: Some(self.machine.generation),
            has_more,
            host_last_seq: Some(self.machine.end()),
            records,
            ..Page::default()
        };
        let ends: Vec<(u64, String)> = page
            .records
            .iter()
            .filter(|r| matches!(r["kind"].as_str(), Some("turn_result" | "queue_removed")))
            .filter_map(|r| Some((r["seq"].as_u64()?, od::prompt_of(r)?.to_owned())))
            .collect();
        self.take(Op::Page { key: key(), page });
        // An end the copy took, of a prompt whose delivery holds a proof, settles it as a write
        // that reported it would, though the bound cut it before any write did (review at
        // 91b1343d, F1): nothing the owner gives back may run it again.
        if let Some(c) = self.store.copies.get(&key())
            && c.head.generation == Some(self.machine.generation)
        {
            let last = c.head.last_seq;
            for (seq, prompt) in ends {
                let proven = self
                    .outbox
                    .open_on_peers()
                    .iter()
                    .any(|d| d.prompt_id() == prompt && d.proof.is_some());
                if seq <= last && proven {
                    self.machine.settled_seen.insert(prompt);
                }
            }
        }
        // 0c98c292: a copy of this generation replaced past a gap carries its records of
        // `queued` and `user_message` from before the gap, and nothing else of their lives.
        if let Some((since, held)) = before
            && let Some((now_since, _)) = self.copy()
            && now_since != since
        {
            let names = |r: &&Value| od::prompt_of(r).is_some_and(|p| od::names_prompt(r, p));
            let carried: Vec<Value> =
                held.range(..now_since).map(|(_, r)| r).filter(names).cloned().collect();
            if !carried.is_empty() {
                self.store.add(&key(), carried);
            }
        }
        self.take(Op::Flush { peer: Some(PEER.into()), done: None });
    }

    fn copy_seqs(&mut self) -> Vec<Rec> {
        self.copy().map_or(vec![], |(_, r)| r.values().map(Rec::of).collect())
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
        let rows = (self.machine.generation, self.machine.end());
        let task = self.task.get_or_insert(RestoreTask {
            link,
            rows,
            ahead: None,
            tries: 0,
            ends: HashMap::from([(MUX.to_owned(), rows)]),
        });
        if task.ahead.is_none() {
            let (generation, last) = task.rows;
            let rows = vec![(MUX.to_owned(), generation, last)];
            let (ahead, since) = self.store.ahead(PEER, rows.clone());
            let ahead = match self.rules {
                Rules::Now | Rules::Prior | Rules::Last => {
                    let proofs = od::proofs_past(&self.outbox, PEER, &rows, &since);
                    restore::with_proofs(ahead, proofs, &rows).0
                }
                Rules::Before => ahead,
            };
            let ahead = ahead.into_iter().next().map(|(_, _, after, records)| (after, records));
            self.task.as_mut().unwrap().ahead = Some(ahead);
            return;
        }
        let task = self.task.as_mut().unwrap();
        let Some(Some((after, records))) = task.ahead.clone() else {
            let ends = task.ends.clone();
            self.decided = true;
            self.note(format!("link {link}: nothing ahead; decided"));
            self.redeliver(&ends);
            return;
        };
        let generation = task.rows.0;
        task.tries += 1;
        let tries = task.tries;
        let recs: Vec<Rec> = records.iter().map(Rec::of).collect();
        let stop =
            (!self.calm && self.rng.chance(25)).then(|| self.rng.below(recs.len() as u64) as usize);
        // The link may flip between the check and the send (review at 98b4575a, F1): the request
        // is pinned to this link's epoch, so it fails and nothing is written.
        if !self.calm && self.rng.chance(6) {
            self.note(format!("link {link} flips before its restore goes"));
            self.flip();
            if self.rules == Rules::Prior && self.up {
                // 98b4575a: `Peer::request` goes on whatever link is up now.
                let end = self.machine.end();
                let _ = self.machine.restore(generation, after, &recs, None);
                if self.machine.end() > end {
                    LOST.with(|l| {
                        l.borrow_mut().push(format!(
                            "stale: link {link}'s restore wrote on link {}",
                            self.link
                        ))
                    });
                }
            }
            return;
        }
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
                if let Some(t) = self.task.as_mut() {
                    t.ends.insert(MUX.to_owned(), (generation, last));
                }
            }
            Err("generation" | "diverged") => {
                self.take(Op::Restored { key: key(), link: (1, link), generation, last: None });
                self.check_copy_kept(&before);
            }
            Err("append_failed") if tries < 4 => {
                // A prompt that waited before the restore began tries for its turn between the
                // tries (review at 91b1343d, F2).
                if self.rng.chance(50) {
                    self.machine.work();
                    self.note(format!("work while held (ends {})", self.machine.end()));
                }
                return;
            }
            Err(_) if tries < 4 => return,
            Err(_) => {
                // Held: prompts fail visibly until a later link decides again.
                self.note(format!("link {link}: held"));
                return;
            }
        }
        self.decided = true;
        let ends = self.task.as_ref().map(|t| t.ends.clone()).unwrap_or_default();
        self.redeliver(&ends);
    }

    /// A copy went on a refusal: every record of it of the machine's generation must be on the
    /// machine, unless the machine holds another record at one of its seqs (it wrote its own
    /// there first: another history, which the copy cannot go back into).
    fn check_copy_kept(&mut self, before: &[Rec]) {
        let other = before.iter().any(|r| {
            self.machine.journal.iter().any(|h| h.seq == r.seq && (h.at, h.kind) != (r.at, r.kind))
        });
        if other || !self.copy_seqs().is_empty() {
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
    fn redeliver(&mut self, ends: &HashMap<String, (u64, u64)>) {
        let now = crate::store::now_ms();
        let link = (1, self.link);
        for d in self.outbox.open_on_peers() {
            let Some(pin) = d.pin.clone() else { continue };
            let step = match self.rules {
                Rules::Now | Rules::Prior | Rules::Last => match od::step(&d, now, link, ends) {
                    // The machine's journal read on this link (`Hub::proof_held`); the link may
                    // flip first.
                    od::Step::Check if !self.calm && self.rng.chance(8) => {
                        self.flip();
                        if self.rules == Rules::Prior && self.up {
                            // 98b4575a: read on whatever link is up now.
                            LOST.with(|l| {
                                l.borrow_mut().push(format!(
                                    "stale: {}'s proof was read on link {}, not link {}",
                                    d.id, self.link, link.1
                                ))
                            });
                        }
                        // The redelivery's link is gone: it stops (`redeliver_all`).
                        return;
                    }
                    od::Step::Check => {
                        let records = d.proof.as_ref().map_or(&[][..], |p| &p.records[..]);
                        od::checked(Some(records.iter().all(|r| {
                            let at = r["seq"].as_u64();
                            let found = self.machine.journal.iter().find(|h| Some(h.seq) == at);
                            od::same_record(r, found.map(Rec::json).as_ref())
                        })))
                    }
                    step => step,
                },
                // 0c98c292: lapse, or closed on the copy, else again.
                Rules::Before if d.open_lapsed(now) => od::Step::Lapse,
                Rules::Before => {
                    let held = self.store.copies.get(&key()).is_some_and(|c| {
                        c.head.generation == Some(pin.generation) && c.due.is_none() && c.disk > 0
                    }) && self.copy().is_some_and(|(_, r)| {
                        r.values().any(|r| od::names_prompt(r, d.prompt_id()))
                    });
                    if held { od::Step::Release } else { od::Step::Again }
                }
            };
            match step {
                od::Step::Lapse => {
                    let lapsed = crate::hub::outbox::OPEN_LAPSED.to_owned();
                    self.outbox.update(&d.id, |d| d.fail_open(lapsed));
                }
                od::Step::Stale => {
                    self.outbox.update(&d.id, |d| d.fail_open(od::STALE.to_owned()));
                }
                od::Step::Release => {
                    self.note(format!("{} released", d.id));
                    if self.rules != Rules::Before {
                        self.released.insert(d.prompt_id().to_owned());
                    }
                    self.outbox.update(&d.id, od::release);
                }
                od::Step::Lost => {
                    self.note(format!("{} lost: another history", d.id));
                    self.outbox.update(&d.id, |d| d.fail_open(od::LOST.to_owned()));
                }
                od::Step::Wait | od::Step::Check => {
                    self.note(format!("{} proven, waits", d.id));
                }
                od::Step::Again => {
                    let queue = self.rng.chance(50);
                    let answer = self.machine.prompt(d.prompt_id(), Some(pin.generation), queue);
                    if answer.is_ok() {
                        self.taken_in.insert(d.prompt_id().to_owned(), self.machine.generation);
                    }
                    self.note(format!("again {}: {answer:?}", d.id));
                    let again = match answer {
                        Ok(dup) => od::Again::Taken(json!({"duplicate": dup})),
                        Err(e) => od::Again::Refused(e.into()),
                    };
                    self.outbox.update(&d.id, |d| {
                        od::after_again(d, again);
                    });
                }
            }
        }
    }

    /// The link is replaced: by the same machine, or by one on an older disk.
    fn flip(&mut self) {
        if self.machine.snapshots.is_empty() || self.rng.chance(50) {
            self.drop_link();
            self.connect();
        } else {
            self.restart_older();
        }
    }

    /// The machine goes and comes back on an older disk of this generation, on a new link.
    fn restart_older(&mut self) {
        if self.machine.snapshots.is_empty() {
            return;
        }
        let i = self.rng.below(self.machine.snapshots.len() as u64) as usize;
        // What this disk holds is its own now; a deferred start reads its log later.
        let loaded = self.rng.chance(50);
        self.machine.start(self.machine.snapshots[i].clone(), loaded);
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
        self.machine.start(vec![], true);
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
            0..=11 if self.sent.len() < 8 => self.send(),
            0..=23 => self.start_attempt(),
            24..=35 => self.end_attempt(),
            36..=45 => self.capture(),
            46..=50 => {
                let mut journal = self.machine.journal.clone();
                // Taken during a turn: its `user_message` is on the disk, its result not yet
                // (review at 91b1343d, F4).
                if self.rng.chance(30)
                    && let Some(i) = journal.iter().rposition(|r| r.kind == "user_message")
                {
                    journal.truncate(i + 1);
                }
                self.note(format!(
                    "snapshot {} (ends {})",
                    self.machine.snapshots.len(),
                    self.machine.end()
                ));
                self.machine.snapshots.push(journal);
            }
            51..=54 => self.restart_older(),
            55..=58 => {
                self.drop_link();
                self.connect();
            }
            59..=66 if self.up && !self.listed => self.list(),
            59..=72 => self.restore_step(),
            73..=78 => {
                self.machine.work();
                self.note(format!("work (ends {})", self.machine.end()));
            }
            79..=81 => {
                let pick = self.rng.next();
                self.machine.cancel(pick);
                self.note(format!("cancel (ends {})", self.machine.end()));
            }
            82..=85 => {
                // A turn that writes past the copy's bound (`SESSION_EVENTS`).
                let n = 5 + self.rng.below(30);
                for _ in 0..n {
                    self.machine.push("agent_message_chunk", None);
                }
                self.note(format!("{n} lines (ends {})", self.machine.end()));
            }
            86 => self.purge_recreate(),
            87..=88 => {
                self.clock_ahead(DAY_MS + 60 * 60 * 1000);
                self.note("clock +25 h".into());
            }
            89..=90 => {
                // The captures' queue overflowed: every copy of the peer goes.
                self.take(Op::LostPeer(PEER.into()));
                self.note("captures lost".into());
            }
            93..=95 => {
                // A deferred start's lazy load of the log.
                self.machine.load();
                self.note("log read".into());
            }
            91..=92 => {
                // The disk's bound: written copies are evicted.
                self.store.evict_disk(None, TOTAL_BYTES);
                self.note("disk evicted".into());
            }
            _ => {}
        }
    }

    fn clock_ahead(&mut self, ms: u64) {
        // As last seen before the retention runs at the new time.
        self.look();
        crate::store::CLOCK_AHEAD_MS.with(|c| c.set(c.get() + ms));
        // A restore's hold lapses long before.
        self.machine.lapse();
        // Any change runs the retention.
        let anything = self.outbox.list(None, 1).0.first().map(|d| d.id.clone());
        if let Some(id) = anything {
            self.outbox.update(&id, |_| {});
        }
    }

    /// One quiet round: a new link, listed, its restore run, every attempt answered, the queue
    /// run, a capture, and the link's redelivery once more.
    fn quiet_round(&mut self) {
        self.drop_link();
        self.connect();
        self.list();
        for _ in 0..12 {
            self.restore_step();
        }
        for _ in 0..40 {
            self.start_attempt();
            self.end_attempt();
            self.look();
        }
        while !self.flights.is_empty() {
            self.end_attempt();
        }
        // A deferred start's lazy load comes; a restore's hold lapses.
        self.machine.load();
        self.machine.lapse();
        while !self.machine.queue.is_empty() {
            self.machine.work();
        }
        if !self.machine.journal.is_empty() {
            let records = self.machine.journal.iter().map(Rec::json).collect();
            self.page(records, false);
        }
        let ends = HashMap::from([(MUX.to_owned(), (self.machine.generation, self.machine.end()))]);
        self.redeliver(&ends);
        self.look();
    }

    /// The quiet end: three quiet rounds, then the clock past every open delivery's bound.
    fn settle(&mut self) {
        for f in &mut self.flights {
            f.lost = true;
        }
        self.calm = true;
        for _ in 0..3 {
            self.quiet_round();
        }
        self.clock_ahead(crate::hub::outbox::OPEN_ON_PEER_FOR_MS);
        self.quiet_round();
    }

    fn check(&mut self) -> Result<(), String> {
        let lost = LOST.with(|l| std::mem::take(&mut *l.borrow_mut()));
        if !lost.is_empty() {
            let mut lost = lost;
            lost.dedup_by(|a, b| a.split(": ").next() == b.split(": ").next());
            return Err(lost.join(" | "));
        }
        for (n, prompt) in self.sent.clone().iter().enumerate() {
            let mut generations: Vec<u64> =
                self.machine.ran.iter().filter(|(p, _)| p == prompt).map(|(_, g)| *g).collect();
            generations.dedup();
            if generations.len() > 1 {
                return Err(format!("twice: {prompt} ran in generations {generations:?}"));
            }
            self.look();
            let id = format!("d{n}");
            let d = self.outbox.get(&id).or_else(|| self.seen.get(&id).cloned());
            let d = d.ok_or(format!("{prompt}'s delivery was never seen"))?;
            if self.outbox.get(&id).is_none() && (!d.settled() || d.open_on_peer) {
                let open = d.open_on_peer;
                return Err(format!(
                    "lost: {prompt}'s delivery went while {:?} (open {open})",
                    d.state
                ));
            }
            let ran = self.machine.count(prompt, "user_message");
            let removed = self.machine.count(prompt, "queue_removed") > 0;
            let purged = self.taken_in.get(prompt).is_some_and(|g| self.machine.purged.contains(g));
            match (d.state, ran) {
                (_, n) if n > 1 && !self.machine.ran_by_itself.contains(prompt) => {
                    return Err(format!("twice: {prompt} ran {n} times"));
                }
                (_, n) if n > 1 => {}
                (DState::Failed, _) if d.error.is_some() => {}
                (DState::Delivered, 1) => {}
                (DState::Delivered, 0) if removed || purged => {}
                // Released (its machine held it on a later link), then lost to a disk older
                // still: past what the rule promises (`open_delivery.rs`); counted, not failed.
                (DState::Delivered, 0) if self.released.contains(prompt) => {
                    PAST_RELEASE.with(|n| n.set(n.get() + 1));
                }
                (state, ran) => {
                    return Err(format!(
                        "lost: {prompt}: delivery {state:?} (open {}), {ran} times on the machine",
                        d.open_on_peer
                    ));
                }
            }
        }
        Ok(())
    }
}

thread_local! {
    static WRITTEN: RefCell<Vec<(Key, u64, Link, Vec<Value>)>> = const { RefCell::new(Vec::new()) };
    static LOST: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
    /// Prompts lost after their release (`World::check`), over the seeds run.
    static PAST_RELEASE: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

fn run(seed: u64, rules: Rules) -> (Result<(), String>, Vec<String>) {
    LOST.with(|l| l.borrow_mut().clear());
    crate::hub::journal_restore::RULES_OF_91B.with(|r| r.set(rules == Rules::Last));
    let mut world = World::new(seed, rules);
    world.list();
    let steps = 60 + world.rng.below(140);
    for _ in 0..steps {
        world.step();
    }
    world.settle();
    let verdict = world.check();
    crate::store::CLOCK_AHEAD_MS.with(|c| c.set(0));
    crate::hub::journal_restore::RULES_OF_91B.with(|r| r.set(false));
    (verdict, world.trace)
}

fn seeds() -> std::ops::Range<u64> {
    let n = std::env::var("MOVE_SIM_SEEDS").ok().and_then(|v| v.parse().ok()).unwrap_or(500);
    let base = std::env::var("MOVE_SIM_SEED_BASE").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
    base..base + n
}

/// The seeds that fail under `rules`, and how many seeds failed of each kind (`lost`,
/// `resurrected`, `twice`, `stale`, `stalled`, `ahead`, other).
fn failures(rules: Rules) -> (u64, Vec<String>, BTreeMap<String, usize>) {
    failures_in(rules, seeds())
}

fn failures_in(
    rules: Rules,
    range: std::ops::Range<u64>,
) -> (u64, Vec<String>, BTreeMap<String, usize>) {
    let n = range.end - range.start;
    let mut kinds = BTreeMap::new();
    let mut failed = Vec::new();
    for seed in range {
        let Err(e) = run(seed, rules).0 else { continue };
        let mut seen = HashSet::new();
        for part in e.split(" | ") {
            let kind = part.split(": ").next().unwrap_or("other");
            let known =
                ["lost", "resurrected", "twice", "stale", "stalled", "ahead", "held", "diverged"];
            let kind = if known.contains(&kind) { kind } else { "other" };
            if seen.insert(kind) {
                *kinds.entry(kind.to_owned()).or_insert(0) += 1;
            }
        }
        failed.push(format!("seed {seed}: {e}"));
    }
    (n, failed, kinds)
}

/// Every seed holds the invariants under the rules of now.
#[test]
fn move_sim_seeds_hold_the_move_invariants() {
    if let Some(seed) = std::env::var("MOVE_SIM_SEED").ok().and_then(|v| v.parse().ok()) {
        let rules = match std::env::var("MOVE_SIM_RULES").as_deref() {
            Ok("before") => Rules::Before,
            Ok("prior") => Rules::Prior,
            Ok("last") => Rules::Last,
            _ => Rules::Now,
        };
        let (verdict, trace) = run(seed, rules);
        eprintln!("{}", trace.join("\n"));
        assert!(verdict.is_ok(), "seed {seed}: {verdict:?}");
        return;
    }
    PAST_RELEASE.with(|n| n.set(0));
    let (n, failed, kinds) = failures(Rules::Now);
    let past = PAST_RELEASE.with(std::cell::Cell::get);
    eprintln!(
        "move sim: {n} seeds, {} failed {kinds:?}; {past} prompts lost after their release",
        failed.len()
    );
    assert!(
        failed.is_empty(),
        "{} of {n} seeds failed (replay: MOVE_SIM_SEED=N cargo test -p acpmux --lib -- move_sim --nocapture):\n{}",
        failed.len(),
        failed.join("\n")
    );
}

/// Under the rules of 0c98c292 some seeds lose a prompt (a delivery closed on a record a bound or
/// an eviction later dropped) and some run settled work again (a `queued` record carried past a
/// gap without its removal): the simulation finds what the review found. Prints which seeds.
#[test]
fn move_sim_finds_the_losses_of_the_rules_before() {
    let (n, failed, kinds) = failures(Rules::Before);
    eprintln!("move sim, the rules of 0c98c292: {n} seeds, {} failed {kinds:?}", failed.len());
    for f in failed.iter().take(20) {
        eprintln!("  {f}");
    }
    assert!(kinds.contains_key("lost"), "no seed found a prompt lost");
    assert!(kinds.contains_key("resurrected"), "no seed found settled work run again");
}

/// Under the rules of 98b4575a (review at 98b4575a, F1 to F3) some seeds send a restore or read
/// a proof on a link that replaced the one they checked (`stale`), refuse a restore while only a
/// queue waits (`stalled`), or run a prompt ahead of the queue a restore put back, which a log
/// not read yet never rebuilt (`ahead`). Prints which seeds.
#[test]
fn move_sim_finds_the_losses_of_the_rules_of_98b4575a() {
    let (n, failed, kinds) = failures(Rules::Prior);
    eprintln!("move sim, the rules of 98b4575a: {n} seeds, {} failed {kinds:?}", failed.len());
    for f in failed.iter().take(10) {
        eprintln!("  {f}");
    }
    for kind in ["stale", "stalled", "ahead"] {
        assert!(kinds.contains_key(kind), "no seed found {kind}");
    }
}

/// Under the rules of 91b1343d (review at 91b1343d, F2 and F4) some seeds run a queued prompt
/// while a restore held the chat between tries (`held`), or read a log for a restore and write
/// its recovery in the seqs the restore needed (`diverged`); a few run a prompt whose removal the
/// bound cut before any write reported it (`resurrected`, F1: its proof still went back whole;
/// rare here, so `a_removal_the_bound_cut_before_its_write_keeps_its_prompt_from_going_back`
/// holds it). At least 2000 seeds: a restore into a log not read yet is rare. Prints which seeds.
#[test]
fn move_sim_finds_the_losses_of_the_rules_of_91b1343d() {
    let range = seeds();
    let range = range.start..range.end.max(range.start + 2000);
    let (n, failed, kinds) = failures_in(Rules::Last, range);
    eprintln!("move sim, the rules of 91b1343d: {n} seeds, {} failed {kinds:?}", failed.len());
    for f in failed.iter().take(10) {
        eprintln!("  {f}");
    }
    for kind in ["held", "diverged"] {
        assert!(kinds.contains_key(kind), "no seed found {kind}");
    }
}
