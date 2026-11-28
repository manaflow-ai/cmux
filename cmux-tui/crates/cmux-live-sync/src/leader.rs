//! The Mac side, which runs every round. It holds three trees: its own folder (the replica's
//! index), its view of the VM's folder (built from the follower's reports) and the synced
//! revision. A round takes only the paths that moved since the last one (the watcher's, the
//! follower's, and those a compare-and-swap refused), decides each with cmux-sync's three-tree
//! rule, fetches what it needs from the VM in one request, applies locally, sends the VM's writes
//! in batches, and moves synced only for the paths whose every write landed. A path whose write
//! found something newer is decided again next round with that newer state, so no save is
//! overwritten. Conflicts keep both copies: text merges three-way against the synced base, else
//! the VM's version stays at the path and the Mac's goes beside it as `NAME.cmux-sync-conflict`.
//!
//! [`Leader::run`] dials again after any drop (a paused VM, a dropped network, a Mac that slept),
//! and every connection starts from both full manifests, so the first round catches up whatever
//! changed while apart.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_sync::three_tree::{self, Conflict, Decision};
use cmux_sync::two_way::{CONFLICT_SUFFIX, Tree};
use crossbeam_channel::{Receiver, Sender, unbounded};

use crate::proto::{self, Item, Msg, WireOp};
use crate::replica::{Hash, Outcome, Replica, first_line, hash_of};
use crate::state::{BASE_MAX, State, is_text};
use crate::watch::{Seen, Watch};
use crate::{DEBOUNCE_MAX, DEBOUNCE_QUIET, IDLE_DROP, PING_EVERY};

/// What the leader reports. A UI shows `Conflict` once per copy, and every `Alert` (a fallback
/// or a skip) with its reason; nothing degrades silently.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// Connected and caught up: `paths` needed work in the catch-up round.
    Online {
        paths: usize,
        took: Duration,
    },
    Offline {
        reason: String,
    },
    /// One round: paths written to the VM, to the Mac, merged, and how long the round took.
    Round {
        to_remote: usize,
        to_local: usize,
        merged: usize,
        took: Duration,
    },
    /// Both changed it and the edits overlap (or it is binary): the Mac's copy is kept at `copy`.
    Conflict {
        path: String,
        copy: String,
    },
    /// An edit won over a delete on the other side.
    KeptEdit {
        path: String,
    },
    Alert {
        reason: String,
    },
}

enum In {
    Frame(Msg, Vec<u8>),
    Closed(String),
}

pub struct Leader {
    replica: Replica,
    state: State,
    synced: Tree,
    remote: Tree,
    events: Sender<Event>,
    watch_rx: Receiver<Seen>,
    _watch: Option<Watch>,
    next_id: u64,
    /// Paths whose write failed outright, held until a watcher names them again.
    failed: BTreeSet<String>,
}

/// Why a session ended.
#[derive(Debug)]
pub enum End {
    Stopped,
    Dropped(String),
}

impl Leader {
    pub fn new(
        root: impl Into<PathBuf>,
        state_dir: impl Into<PathBuf>,
        events: Sender<Event>,
    ) -> anyhow::Result<Self> {
        let replica = Replica::new(root)?;
        let state = State::open(state_dir)?;
        let (_, synced) = state.load()?;
        let (tx, rx) = unbounded();
        let watch = match Watch::start(replica.root(), tx, |s| s) {
            Ok(w) => Some(w),
            Err(e) => {
                let _ = events.send(Event::Alert {
                    reason: format!(
                        "Mac watcher failed; syncing on a 1 s rescan instead: {}",
                        first_line(&e.to_string())
                    ),
                });
                None
            }
        };
        Ok(Self {
            replica,
            state,
            synced,
            remote: Tree::new(),
            events,
            watch_rx: rx,
            _watch: watch,
            next_id: 1,
            failed: BTreeSet::new(),
        })
    }

    pub fn synced(&self) -> &Tree {
        &self.synced
    }

    /// Sessions until `stop` fires: dial, sync, and on a drop dial again with backoff (100 ms
    /// doubling to 5 s; a wake or resume reconnects within that).
    pub fn run<R, W>(
        &mut self,
        mut dial: impl FnMut() -> std::io::Result<(R, W)>,
        stop: &Receiver<()>,
    ) where
        R: Read + Send + 'static,
        W: Write,
    {
        let mut backoff = Duration::from_millis(100);
        loop {
            if stop.try_recv().is_ok() {
                return;
            }
            match dial() {
                Ok((r, w)) => match self.session(r, w, stop) {
                    End::Stopped => return,
                    End::Dropped(reason) => {
                        let _ = self.events.send(Event::Offline { reason });
                        backoff = Duration::from_millis(100);
                    }
                },
                Err(e) => {
                    let _ = self.events.send(Event::Offline {
                        reason: format!("dial: {}", first_line(&e.to_string())),
                    });
                }
            }
            if stop.recv_timeout(backoff).is_ok() {
                return;
            }
            backoff = (backoff * 2).min(Duration::from_secs(5));
        }
    }

    /// One connection, until it drops or `stop` fires.
    pub fn session<R: Read + Send + 'static, W: Write>(
        &mut self,
        reader: R,
        writer: W,
        stop: &Receiver<()>,
    ) -> End {
        match self.session_inner(reader, writer, stop) {
            Ok(()) => End::Stopped,
            Err(e) => End::Dropped(first_line(&format!("{e:#}"))),
        }
    }

    fn session_inner<R: Read + Send + 'static, W: Write>(
        &mut self,
        reader: R,
        writer: W,
        stop: &Receiver<()>,
    ) -> anyhow::Result<()> {
        let started = Instant::now();
        let mut w = BufWriter::new(writer);
        let (tx, rx) = unbounded::<In>();
        std::thread::spawn(move || {
            let mut r = BufReader::new(reader);
            loop {
                match proto::read_frame(&mut r) {
                    Ok((m, b)) => {
                        if tx.send(In::Frame(m, b)).is_err() {
                            return;
                        }
                    }
                    Err(e) => {
                        let _ = tx.send(In::Closed(e.to_string()));
                        return;
                    }
                }
            }
        });
        let (synced_id, _) = self.state.load()?;
        proto::write_frame(
            &mut w,
            &Msg::Hello { protocol: proto::PROTOCOL, synced: synced_id.clone() },
            &[],
        )?;

        // The follower's Hello, its synced copy (if any), then its whole manifest.
        let mut follower_synced: Option<Tree> = None;
        let deadline = Instant::now() + IDLE_DROP * 3;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match rx.recv_timeout(left) {
                Ok(In::Frame(Msg::Hello { protocol, .. }, _)) if protocol != proto::PROTOCOL => {
                    anyhow::bail!(
                        "follower speaks protocol {protocol}, this Mac {}",
                        proto::PROTOCOL
                    )
                }
                Ok(In::Frame(Msg::Hello { .. }, _)) => {}
                Ok(In::Frame(Msg::SyncedTree { tree, .. }, _)) => {
                    follower_synced = Some(tree.into_iter().collect());
                }
                Ok(In::Frame(Msg::State { full: true, entries, alerts }, _)) => {
                    self.remote = entries.into_iter().filter_map(|(p, h)| Some((p, h?))).collect();
                    self.alert_all(alerts);
                    break;
                }
                Ok(In::Frame(..)) => {}
                Ok(In::Closed(why)) => anyhow::bail!("link closed before the manifest: {why}"),
                Err(_) => {
                    anyhow::bail!("no manifest from the VM in {} s", (IDLE_DROP * 3).as_secs())
                }
            }
        }
        // A Mac that lost its store starts from the VM's copy rather than from empty (empty
        // would read every differing file as a conflict; still safe, never a loss).
        if synced_id.is_none()
            && let Some(t) = follower_synced
        {
            self.synced = t;
            self.state.commit(&self.synced);
        }
        while self.watch_rx.try_recv().is_ok() {}
        self.replica.full_scan();
        self.failed.clear();
        let local = self.replica.tree();
        let mut dirty: BTreeSet<String> = BTreeSet::new();
        for p in self.synced.keys().chain(local.keys()).chain(self.remote.keys()) {
            if local.get(p) != self.synced.get(p) || self.remote.get(p) != self.synced.get(p) {
                dirty.insert(p.clone());
            }
        }
        let caught = dirty.len();
        let mut conn = Conn { w, rx, last_heard: Instant::now(), last_sent: Instant::now() };
        while !dirty.is_empty() {
            self.round(&mut conn, &mut dirty)?;
        }
        let _ = self.events.send(Event::Online { paths: caught, took: started.elapsed() });

        // Steady state.
        let mut named: BTreeSet<String> = BTreeSet::new();
        let mut first: Option<Instant> = None;
        let mut last = Instant::now();
        let poll_rescan = self._watch.is_none();
        let mut last_poll = Instant::now();
        loop {
            let wait = match first {
                Some(f) => DEBOUNCE_QUIET
                    .saturating_sub(last.elapsed())
                    .min(DEBOUNCE_MAX.saturating_sub(f.elapsed())),
                None => PING_EVERY
                    .saturating_sub(conn.last_sent.elapsed())
                    .max(Duration::from_millis(5)),
            };
            crossbeam_channel::select! {
                recv(stop) -> _ => return Ok(()),
                recv(conn.rx) -> m => match m {
                    Ok(In::Frame(msg, _)) => { conn.last_heard = Instant::now(); self.note(msg, &mut dirty); }
                    Ok(In::Closed(why)) => anyhow::bail!("link closed: {why}"),
                    Err(_) => anyhow::bail!("reader gone"),
                },
                recv(self.watch_rx) -> m => match m {
                    Ok(Seen::Paths(paths)) => {
                        for p in paths {
                            if let Some(rel) = self.replica.relative(&p) {
                                self.failed.remove(&rel);
                                named.insert(rel);
                            }
                        }
                        first.get_or_insert_with(Instant::now);
                        last = Instant::now();
                    }
                    Ok(Seen::Rescan(why)) => {
                        self.alert(why);
                        dirty.extend(self.replica.full_scan());
                    }
                    Err(_) => {}
                },
                default(wait) => {}
            }
            if poll_rescan && last_poll.elapsed() >= Duration::from_secs(1) {
                last_poll = Instant::now();
                dirty.extend(self.replica.full_scan());
            }
            if first
                .is_some_and(|f| last.elapsed() >= DEBOUNCE_QUIET || f.elapsed() >= DEBOUNCE_MAX)
            {
                first = None;
                dirty.extend(self.replica.rescan_paths(std::mem::take(&mut named)));
            }
            self.alert_all(vec![]);
            dirty.retain(|p| !self.failed.contains(p));
            while !dirty.is_empty() {
                self.round(&mut conn, &mut dirty)?;
                dirty.retain(|p| !self.failed.contains(p));
            }
            if conn.last_sent.elapsed() >= PING_EVERY {
                conn.send(&Msg::Ping, &[])?;
            }
            if conn.last_heard.elapsed() > IDLE_DROP {
                anyhow::bail!("VM silent for {} s", IDLE_DROP.as_secs());
            }
        }
    }

    /// A frame that is not an answer: the follower's state reports go into the remote view.
    fn note(&mut self, msg: Msg, dirty: &mut BTreeSet<String>) {
        if let Msg::State { full, entries, alerts } = msg {
            if full {
                let now: Tree =
                    entries.iter().filter_map(|(p, h)| Some((p.clone(), h.clone()?))).collect();
                for p in self.remote.keys().chain(now.keys()) {
                    dirty.insert(p.clone());
                }
                self.remote = now;
            } else {
                for (p, h) in entries {
                    self.failed.remove(&p);
                    match h {
                        Some(h) => self.remote.insert(p.clone(), h),
                        None => self.remote.remove(&p),
                    };
                    dirty.insert(p);
                }
            }
            self.alert_all(alerts);
        }
    }

    fn alert(&self, reason: String) {
        let _ = self.events.send(Event::Alert { reason });
    }

    fn alert_all(&mut self, alerts: Vec<String>) {
        for a in alerts {
            self.alert(a);
        }
        for a in std::mem::take(&mut self.replica.alerts) {
            self.alert(a);
        }
    }

    fn id(&mut self) -> u64 {
        self.next_id += 1;
        self.next_id
    }

    /// One round over `dirty` (drained); paths that need another round are put back.
    fn round<W: Write>(
        &mut self,
        conn: &mut Conn<W>,
        dirty: &mut BTreeSet<String>,
    ) -> anyhow::Result<()> {
        let started = Instant::now();
        let paths = std::mem::take(dirty);
        let mut decisions: BTreeMap<String, Decision<Hash>> = BTreeMap::new();
        for p in paths {
            let d =
                three_tree::decide(self.synced.get(&p), self.replica.get(&p), self.remote.get(&p));
            if d != Decision::Nothing {
                decisions.insert(p, d);
            }
        }
        if decisions.is_empty() {
            return Ok(());
        }

        // One fetch for every remote byte the round needs.
        let want: Vec<String> = decisions
            .iter()
            .filter(|(_, d)| {
                matches!(
                    d,
                    Decision::Apply(Some(_))
                        | Decision::Conflict(
                            Conflict::Content { .. } | Conflict::LocalDeleted { .. }
                        )
                )
            })
            .map(|(p, _)| p.clone())
            .collect();
        let mut fetched: BTreeMap<String, Vec<u8>> = BTreeMap::new();
        if !want.is_empty() {
            let id = self.id();
            let (msg, body) =
                conn.request(&Msg::Fetch { id, paths: want }, &[], id, |m| self.note(m, dirty))?;
            let Msg::Blobs { items, .. } = msg else {
                anyhow::bail!("fetch answered with {msg:?}")
            };
            let lens: Vec<u64> = items.iter().map(|i| i.len).collect();
            for (Item { path, hash, .. }, bytes) in
                items.into_iter().zip(proto::split_body(&body, lens)?)
            {
                if hash.as_ref() == self.remote.get(&path) {
                    fetched.insert(path, bytes.to_vec());
                } else {
                    // The VM moved on since its report: decide again with what it holds now.
                    match hash {
                        Some(h) => self.remote.insert(path.clone(), h),
                        None => self.remote.remove(&path),
                    };
                    dirty.insert(path.clone());
                    decisions.remove(&path);
                }
            }
        }

        let mut plan = Plan::default();
        let mut to_local = 0usize;
        let mut merged = 0usize;
        for (p, d) in &decisions {
            let l = self.replica.get(p).cloned();
            let r = self.remote.get(p).cloned();
            match d {
                Decision::Nothing => {}
                Decision::RecordSynced(h) => plan.synced(p, h.clone(), &[]),
                Decision::Push(Some(h)) => {
                    let Some(bytes) = self.local_bytes(p, h, dirty) else { continue };
                    let op = plan.remote(
                        WireOp::Write {
                            path: p.clone(),
                            expect: r,
                            hash: h.clone(),
                            len: bytes.len() as u64,
                        },
                        bytes.clone(),
                    );
                    plan.synced(p, Some(h.clone()), &[op]);
                    plan.base(h, bytes);
                }
                Decision::Push(None) => {
                    let Some(r) = r else { continue };
                    let op = plan.remote(WireOp::Delete { path: p.clone(), expect: r }, vec![]);
                    plan.synced(p, None, &[op]);
                }
                Decision::Apply(Some(h)) => {
                    let Some(bytes) = fetched.remove(p) else { continue };
                    if !self.local_write(p, l.as_deref(), h, &bytes, dirty) {
                        continue;
                    }
                    to_local += 1;
                    plan.synced(p, Some(h.clone()), &[]);
                    plan.base(h, bytes);
                }
                Decision::Apply(None) => {
                    let Some(l) = l else { continue };
                    match self.replica.delete(p, &l) {
                        Outcome::Done => {
                            to_local += 1;
                            plan.synced(p, None, &[]);
                        }
                        other => self.refused(p, other, dirty),
                    }
                }
                Decision::Conflict(Conflict::RemoteDeleted { local }) => {
                    // An edit beats a delete: the Mac's edit goes back to the VM.
                    let Some(bytes) = self.local_bytes(p, local, dirty) else { continue };
                    let op = plan.remote(
                        WireOp::Write {
                            path: p.clone(),
                            expect: None,
                            hash: local.clone(),
                            len: bytes.len() as u64,
                        },
                        bytes.clone(),
                    );
                    plan.synced(p, Some(local.clone()), &[op]);
                    plan.base(local, bytes);
                    plan.kept.push(p.clone());
                }
                Decision::Conflict(Conflict::LocalDeleted { remote }) => {
                    let Some(bytes) = fetched.remove(p) else { continue };
                    if !self.local_write(p, None, remote, &bytes, dirty) {
                        continue;
                    }
                    to_local += 1;
                    plan.synced(p, Some(remote.clone()), &[]);
                    plan.base(remote, bytes);
                    plan.kept.push(p.clone());
                }
                Decision::Conflict(Conflict::Content { local, remote }) => {
                    let Some(rbytes) = fetched.remove(p) else { continue };
                    let Some(lbytes) = self.local_bytes(p, local, dirty) else { continue };
                    if let Some(m) = self.merge(p, &lbytes, &rbytes, local) {
                        let mh = hash_of(&m, false, local.ends_with("+x"));
                        if !self.local_write(p, Some(local), &mh, &m, dirty) {
                            continue;
                        }
                        to_local += 1;
                        merged += 1;
                        let op = plan.remote(
                            WireOp::Write {
                                path: p.clone(),
                                expect: Some(remote.clone()),
                                hash: mh.clone(),
                                len: m.len() as u64,
                            },
                            m.clone(),
                        );
                        plan.synced(p, Some(mh.clone()), &[op]);
                        plan.base(&mh, m);
                        continue;
                    }
                    // Keep both: the Mac's copy goes aside first (so a crash never loses it), then
                    // the VM's version takes the path on the Mac.
                    let copy = self.conflict_name(p, &decisions, &plan);
                    if !self.local_write(&copy, None, local, &lbytes, dirty) {
                        continue;
                    }
                    let aside = plan.remote(
                        WireOp::Write {
                            path: copy.clone(),
                            expect: None,
                            hash: local.clone(),
                            len: lbytes.len() as u64,
                        },
                        lbytes.clone(),
                    );
                    plan.synced(&copy, Some(local.clone()), &[aside]);
                    if self.local_write(p, Some(local), remote, &rbytes, dirty) {
                        to_local += 2;
                        plan.synced(p, Some(remote.clone()), &[]);
                        plan.base(remote, rbytes);
                    }
                    plan.conflicts.push((p.clone(), copy));
                }
            }
        }

        // The VM's writes, in batches under the frame size.
        let mut outcomes: Vec<Outcome> = Vec::with_capacity(plan.ops.len());
        let mut at = 0;
        while at < plan.ops.len() {
            let mut end = at;
            let mut bytes = 0usize;
            while end < plan.ops.len()
                && (end == at || bytes + plan.bodies[end].len() <= proto::BATCH_BYTES)
            {
                bytes += plan.bodies[end].len();
                end += 1;
            }
            let id = self.id();
            let body: Vec<u8> = plan.bodies[at..end].concat();
            let (msg, _) = conn.request(
                &Msg::Apply { id, ops: plan.ops[at..end].to_vec() },
                &body,
                id,
                |m| self.note(m, dirty),
            )?;
            let Msg::Applied { outcomes: got, .. } = msg else {
                anyhow::bail!("apply answered with {msg:?}")
            };
            if got.len() != end - at {
                anyhow::bail!("apply answered {} outcomes for {} ops", got.len(), end - at);
            }
            outcomes.extend(got);
            at = end;
        }
        let mut to_remote = 0usize;
        let mut ok = vec![true; plan.ops.len()];
        for (i, (op, outcome)) in plan.ops.iter().zip(&outcomes).enumerate() {
            let path = match op {
                WireOp::Write { path, .. } | WireOp::Delete { path, .. } => path.clone(),
            };
            match outcome {
                Outcome::Done => {
                    to_remote += 1;
                    match op {
                        WireOp::Write { hash, .. } => self.remote.insert(path, hash.clone()),
                        WireOp::Delete { .. } => self.remote.remove(&path),
                    };
                }
                Outcome::Changed(now) => {
                    ok[i] = false;
                    match now {
                        Some(h) => self.remote.insert(path.clone(), h.clone()),
                        None => self.remote.remove(&path),
                    };
                    dirty.insert(path);
                }
                Outcome::Failed(why) => {
                    ok[i] = false;
                    self.alert(format!("VM write failed for {path}: {why}"));
                    self.failed.insert(path);
                }
            }
        }

        // Synced moves only where every write for the path landed.
        let mut changes: Vec<(String, Option<Hash>)> = vec![];
        for (p, h, needs) in plan.moves {
            if needs.iter().all(|&i| ok[i]) {
                match &h {
                    Some(h) => self.synced.insert(p.clone(), h.clone()),
                    None => self.synced.remove(&p),
                };
                changes.push((p, h));
            } else {
                dirty.insert(p);
            }
        }
        for (h, bytes) in plan.bases {
            if self.synced.values().any(|v| *v == h) {
                self.state.put_base(&h, &bytes);
            }
        }
        if !changes.is_empty() {
            let id = self.state.commit(&self.synced);
            conn.send(&Msg::Synced { id, changes }, &[])?;
        }
        for (path, copy) in plan.conflicts {
            let _ = self.events.send(Event::Conflict { path, copy });
        }
        for path in plan.kept {
            let _ = self.events.send(Event::KeptEdit { path });
        }
        let _ =
            self.events.send(Event::Round { to_remote, to_local, merged, took: started.elapsed() });
        Ok(())
    }

    /// The Mac's bytes at `p` if it still holds `h`; else the path goes back to dirty.
    fn local_bytes(&mut self, p: &str, h: &str, dirty: &mut BTreeSet<String>) -> Option<Vec<u8>> {
        match self.replica.read(p) {
            Ok(Some((now, bytes))) if now == h => Some(bytes),
            Ok(_) => {
                dirty.insert(p.to_owned());
                None
            }
            Err(e) => {
                self.alert(format!("Mac read failed for {p}: {}", first_line(&e.to_string())));
                self.failed.insert(p.to_owned());
                None
            }
        }
    }

    fn local_write(
        &mut self,
        p: &str,
        expect: Option<&str>,
        h: &str,
        bytes: &[u8],
        dirty: &mut BTreeSet<String>,
    ) -> bool {
        match self.replica.write(p, expect, h, bytes) {
            Outcome::Done => true,
            other => {
                self.refused(p, other, dirty);
                false
            }
        }
    }

    fn refused(&mut self, p: &str, outcome: Outcome, dirty: &mut BTreeSet<String>) {
        match outcome {
            Outcome::Done => {}
            Outcome::Changed(_) => {
                dirty.insert(p.to_owned());
            }
            Outcome::Failed(why) => {
                self.alert(format!("Mac write failed for {p}: {why}"));
                self.failed.insert(p.to_owned());
            }
        }
    }

    /// A clean three-way line merge against the synced base, or `None` (overlap, binary, no base).
    fn merge(&self, p: &str, l: &[u8], r: &[u8], _lh: &str) -> Option<Vec<u8>> {
        if l.len() > BASE_MAX || r.len() > BASE_MAX || !is_text(l) || !is_text(r) {
            return None;
        }
        let base = match self.synced.get(p) {
            Some(h) => self.state.base(h)?,
            None => vec![],
        };
        let (b, l, r) = (
            std::str::from_utf8(&base).ok()?,
            std::str::from_utf8(l).ok()?,
            std::str::from_utf8(r).ok()?,
        );
        diffy::merge(b, l, r).ok().map(String::into_bytes)
    }

    fn conflict_name(
        &self,
        p: &str,
        decisions: &BTreeMap<String, Decision<Hash>>,
        plan: &Plan,
    ) -> String {
        let taken = |n: &str| {
            self.replica.get(n).is_some()
                || self.remote.contains_key(n)
                || self.synced.contains_key(n)
                || decisions.contains_key(n)
                || plan.moves.iter().any(|(m, ..)| m == n)
        };
        let first = format!("{p}{CONFLICT_SUFFIX}");
        if !taken(&first) {
            return first;
        }
        (2u64..).map(|n| format!("{first}-{n}")).find(|n| !taken(n)).unwrap_or(first)
    }
}

#[derive(Default)]
struct Plan {
    ops: Vec<WireOp>,
    bodies: Vec<Vec<u8>>,
    /// (path, new synced state, the remote ops that must all land first).
    moves: Vec<(String, Option<Hash>, Vec<usize>)>,
    bases: Vec<(Hash, Vec<u8>)>,
    conflicts: Vec<(String, String)>,
    kept: Vec<String>,
}

impl Plan {
    fn remote(&mut self, op: WireOp, body: Vec<u8>) -> usize {
        self.ops.push(op);
        self.bodies.push(body);
        self.ops.len() - 1
    }
    fn synced(&mut self, p: &str, h: Option<Hash>, needs: &[usize]) {
        self.moves.push((p.to_owned(), h, needs.to_vec()));
    }
    fn base(&mut self, h: &str, bytes: Vec<u8>) {
        if bytes.len() <= BASE_MAX {
            self.bases.push((h.to_owned(), bytes));
        }
    }
}

struct Conn<W: Write> {
    w: BufWriter<W>,
    rx: Receiver<In>,
    last_heard: Instant,
    last_sent: Instant,
}

impl<W: Write> Conn<W> {
    fn send(&mut self, msg: &Msg, body: &[u8]) -> anyhow::Result<()> {
        proto::write_frame(&mut self.w, msg, body)?;
        self.last_sent = Instant::now();
        Ok(())
    }

    /// Sends and waits for the answer with `id`; other frames go to `other` meanwhile.
    fn request(
        &mut self,
        msg: &Msg,
        body: &[u8],
        id: u64,
        mut other: impl FnMut(Msg),
    ) -> anyhow::Result<(Msg, Vec<u8>)> {
        self.send(msg, body)?;
        loop {
            match self.rx.recv_timeout(IDLE_DROP) {
                Ok(In::Frame(m, b)) => {
                    self.last_heard = Instant::now();
                    match &m {
                        Msg::Blobs { id: got, .. } | Msg::Applied { id: got, .. } if *got == id => {
                            return Ok((m, b));
                        }
                        _ => other(m),
                    }
                }
                Ok(In::Closed(why)) => anyhow::bail!("link closed mid-round: {why}"),
                Err(_) => anyhow::bail!("VM silent for {} s mid-round", IDLE_DROP.as_secs()),
            }
        }
    }
}
