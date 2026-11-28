//! How fast a shared chat is live and how fast a guest is cut off, held to Leo's bounds: a guest
//! of a shared chat sees a new record within 1 s, and a revoke, kick or uninvite cuts the guest
//! off within 1 s. Each case runs over the fake room (`FakeRoom`) and the fake acpmux with the
//! daemon's own share bridge and guest relays, alone and under duress (16 shares of one chat, an
//! account with 4 guests on each, 48 guest browsers joined, a burst of 300 records while the
//! owner kicks, uninvites and revokes).
//!
//! Measured: from just before acpmux writes a record (or the owner's verb is sent) to the moment
//! the fake room reads the frame (`records` to the guest; `kick`, `end`, the `DELETE`), and to the
//! moment the guest relay's daemon connection is gone (its bound author leaves the connection
//! table, read each millisecond while the room's channel is waited on). Each case prints one
//! `SHARE-LATENCY {json}` line before it asserts, so a slow build still gives its numbers
//! (`cmux-bench share-latency`).
use super::super::super::GUEST_PREFIX;
use super::*;

// Keep the fake-room proof and staging flow on the exact same statistics and bound code.
#[path = "share_latency_report.rs"]
mod share_latency_report;
use std::cell::Cell;
use std::collections::HashMap;
use std::sync::mpsc::RecvTimeoutError;

/// Leo's bound for both: live and cut off.
const BOUND: Duration = Duration::from_millis(share_latency_report::BOUND_MS as u64);
/// How often a wait on the room's channel also reads the daemon's connection table.
const TICK: Duration = Duration::from_millis(1);

fn ms(d: Duration) -> f64 {
    share_latency_report::rounded_ms(d.as_secs_f64() * 1_000.0)
}

/// Prints `case`'s p50, p95 and max, then holds every raw sample to the 1 s bound.
fn report(case: &str, load: &str, samples: Vec<Duration>) {
    let raw: Vec<f64> = samples.iter().map(|sample| sample.as_secs_f64() * 1_000.0).collect();
    let summary = share_latency_report::summarize(&raw).unwrap_or_else(|error| {
        panic!("{case} ({load}): {error}");
    });
    let line = json!({"case": case, "load": load, "n": summary.n, "p50_ms": summary.p50_ms,
        "p95_ms": summary.p95_ms, "max_ms": summary.max_ms, "bound_ms": ms(BOUND),
        "within_1s": summary.within_1s});
    println!("SHARE-LATENCY {line}");
    assert!(
        summary.all_samples_within_1s,
        "{case} ({load}): the slowest took {} ms, over the 1 s bound",
        summary.max_ms
    );
}

/// Reads what the room sees, each with the moment it was read, until `done` holds (`true`) or
/// `limit` passes (`false`). What `on` does not take stays buffered for the room's other helpers.
fn watch(
    room: &FakeRoom,
    limit: Duration,
    mut on: impl FnMut(&Seen, Instant) -> bool,
    mut done: impl FnMut() -> bool,
) -> bool {
    let deadline = Instant::now() + limit;
    {
        let now = Instant::now();
        room.buffer.borrow_mut().retain(|seen| !on(seen, now));
    }
    loop {
        if done() {
            return true;
        }
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return false;
        }
        match room.seen.recv_timeout(left.min(TICK)) {
            Ok(seen) => {
                if !on(&seen, Instant::now()) {
                    room.buffer.borrow_mut().push_back(seen);
                }
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return done(),
        }
    }
}

/// The guest and record seq of a `records` frame the room read.
fn delivered(seen: &Seen) -> Option<(&str, u64)> {
    let Seen::Frame { frame, .. } = seen else { return None };
    if frame["t"] != "records" {
        return None;
    }
    Some((frame["to"][0].as_str()?, frame["records"][0]["seq"].as_u64()?))
}

/// Whether `guest`'s relay still holds a daemon connection bound as that guest.
fn bound(mux: &Mux, share: &str, guest: &str) -> bool {
    let id = format!("{GUEST_PREFIX}{share}.{guest}");
    let authors =
        mux.control_clients.agent_sessions.proxy_authors.lock().unwrap_or_else(|e| e.into_inner());
    authors.values().any(|author| author["id"] == id.as_str())
}

/// A new share of the chat, its host socket past `guests`: (share id, conn).
fn open(room: &FakeRoom, owner: &mut Client, surface: u64) -> (String, u64) {
    let reply = owner.request(json!({"cmd":"agent-session-share-create", "surface":surface,
        "owner_token":OWNER_TOKEN, "uses":2}));
    assert_eq!(reply["ok"], true, "{reply}");
    let (conn, _) = room.host();
    assert_eq!(room.next(conn, "guests")["active"], json!([]));
    (reply["data"]["share_id"].as_str().unwrap().to_owned(), conn)
}

/// `account`, invited to `share` with `talk`, joined as `count` guests (its browsers).
fn guests_of(owner: &mut Client, share: &str, account: &str, count: usize) -> Vec<String> {
    let invite = owner.request(json!({"cmd":"agent-session-share-invite", "share_id":share,
        "account":account, "role":"talk"}));
    assert_eq!(invite["ok"], true, "{invite}");
    // An attempt is one account's: each join gets its own id, across accounts too.
    static ATTEMPT: AtomicU64 = AtomicU64::new(0);
    (0..count)
        .map(|_| {
            let n = ATTEMPT.fetch_add(1, Ordering::Relaxed);
            let reply = owner.request(json!({"cmd":"agent-session-share-redeem",
                "share_id":share, "account":account, "name":"Ann",
                "attempt_id":format!("attempt-{n}")}));
            assert_eq!(reply["ok"], true, "{reply}");
            reply["data"]["guest_id"].as_str().unwrap().to_owned()
        })
        .collect()
}

/// Each guest's browser joins the newest host socket (`conn`). The snapshot is not the relay's
/// attach barrier because the relay asks acpmux to mark the session visible immediately after it
/// emits the snapshot. Wait for the fake's view response before pushing a live record.
fn join(room: &FakeRoom, fake: &FakeAcpmux, conn: u64, guests: &[String]) {
    for guest in guests {
        room.send(json!({"v": 1, "t": "guest_joined", "guest_id": guest}));
    }
    let mut waiting: HashSet<&str> = guests.iter().map(String::as_str).collect();
    while !waiting.is_empty() {
        let snapshot = room.next(conn, "snapshot");
        waiting.remove(snapshot["to"].as_str().unwrap());
    }
    for _ in guests {
        fake.wait_for_attachment();
    }
}

/// A live transcript record.
fn record(seq: u64) -> Value {
    sized(seq, 64)
}

/// Sends record `seq` and waits until every guest of `to` has it at the room; each one's time.
/// A record that reaches a guest of `never` is a failure.
fn live(
    room: &FakeRoom,
    fake: &mut FakeAcpmux,
    seq: u64,
    to: &[String],
    never: &[String],
) -> Vec<Duration> {
    let sent = Instant::now();
    fake.notify_all("_acpmux/event", record(seq));
    let mut got: HashMap<String, Duration> = HashMap::new();
    let leaked = Cell::new(false);
    let arrived = RefCell::new(&mut got);
    let all = watch(
        room,
        WAIT,
        |seen, at| match delivered(seen) {
            Some((guest, s)) if s == seq && never.iter().any(|g| g == guest) => {
                leaked.set(true);
                true
            }
            Some((guest, s)) if s == seq && to.iter().any(|g| g == guest) => {
                arrived.borrow_mut().insert(guest.to_owned(), at - sent);
                true
            }
            _ => false,
        },
        || arrived.borrow().len() == to.len(),
    );
    assert!(!leaked.get(), "record {seq} reached a guest that was cut off");
    assert!(all, "record {seq} reached {} of {} guests", arrived.borrow().len(), to.len());
    got.into_values().collect()
}

/// After every cut, nothing more reaches the guests of `never` (a last record, waited on a moment).
fn none_reach(room: &FakeRoom, fake: &mut FakeAcpmux, seq: u64, never: &[String]) {
    fake.notify_all("_acpmux/event", record(seq));
    room.none("a record for a guest that was cut off", |seen| {
        delivered(seen).is_some_and(|(guest, s)| s == seq && never.iter().any(|g| g == guest))
    });
}

/// What the room and the daemon show of one cut: when the room read each frame `frames` names
/// (the kick of a guest, the share's `end`, its `DELETE`), and when each guest's relay connection
/// was gone, from `start`.
struct Cut<'a> {
    mux: &'a Mux,
    share: &'a str,
    start: Instant,
    kicks: HashMap<String, Option<Duration>>,
    end: Option<(u64, Option<Duration>)>,
    delete: Option<Option<Duration>>,
    closed: HashMap<String, Option<Duration>>,
}

impl<'a> Cut<'a> {
    fn new(mux: &'a Mux, share: &'a str, start: Instant) -> Self {
        Self {
            mux,
            share,
            start,
            kicks: HashMap::new(),
            end: None,
            delete: None,
            closed: HashMap::new(),
        }
    }

    fn kicks(mut self, guests: &[String]) -> Self {
        self.kicks.extend(guests.iter().map(|g| (g.clone(), None)));
        self
    }

    fn closes(mut self, guests: &[String]) -> Self {
        self.closed.extend(guests.iter().map(|g| (g.clone(), None)));
        self
    }

    fn revoked(mut self, conn: u64) -> Self {
        self.end = Some((conn, None));
        self.delete = Some(None);
        self
    }

    /// Takes `seen` if it is one of this cut's frames.
    fn take(&mut self, seen: &Seen, at: Instant) -> bool {
        let after = at - self.start;
        match seen {
            Seen::Frame { frame, .. } if frame["t"] == "kick" => {
                let Some(slot) = frame["guest_id"].as_str().and_then(|g| self.kicks.get_mut(g))
                else {
                    return false;
                };
                slot.get_or_insert(after);
                true
            }
            Seen::Frame { conn, frame } if frame["t"] == "end" => match &mut self.end {
                Some((c, slot)) if c == conn => {
                    slot.get_or_insert(after);
                    true
                }
                _ => false,
            },
            Seen::Request { method, path, .. }
                if method == "DELETE" && path.ends_with(&format!("/{}", self.share)) =>
            {
                match &mut self.delete {
                    Some(slot) => {
                        slot.get_or_insert(after);
                        true
                    }
                    None => false,
                }
            }
            _ => false,
        }
    }

    /// Notes the relays gone by now; whether every frame and close is in.
    fn done(&mut self) -> bool {
        let now = self.start.elapsed();
        for (guest, slot) in &mut self.closed {
            if slot.is_none() && !bound(self.mux, self.share, guest) {
                *slot = Some(now);
            }
        }
        self.kicks.values().all(Option::is_some)
            && self.closed.values().all(Option::is_some)
            && self.end.as_ref().is_none_or(|(_, slot)| slot.is_some())
            && self.delete.as_ref().is_none_or(Option::is_some)
    }

    fn missing(&self) -> String {
        format!(
            "kicks {:?}, closed {:?}, end {:?}, delete {:?}",
            self.kicks, self.closed, self.end, self.delete
        )
    }

    /// Waits on the room until the whole cut is in (at most [`WAIT`]).
    fn wait(mut self, room: &FakeRoom) -> Self {
        let cut = RefCell::new(&mut self);
        let all =
            watch(room, WAIT, |s, at| cut.borrow_mut().take(s, at), || cut.borrow_mut().done());
        assert!(all, "the cut never finished: {}", self.missing());
        self
    }

    fn kick_times(&self) -> impl Iterator<Item = Duration> + '_ {
        self.kicks.values().flatten().copied()
    }

    fn close_times(&self) -> impl Iterator<Item = Duration> + '_ {
        self.closed.values().flatten().copied()
    }
}

// MARK: Alone

/// (a) A record acpmux sends reaches a joined guest at the room within 1 s.
#[test]
fn a_new_record_reaches_a_joined_guest_within_a_second() {
    let room = FakeRoom::start(&[]);
    let (mut fake, _mux, surface, mut owner) = bridged("latency-live", &room);
    let (share, conn) = open(&room, &mut owner, surface);
    let ann = guests_of(&mut owner, &share, "ann@example.com", 1);
    join(&room, &fake, conn, &ann);
    let samples = (100..140).flat_map(|seq| live(&room, &mut fake, seq, &ann, &[])).collect();
    report("live", "alone", samples);
}

/// (b) A revoke: the room hears `end` and the `DELETE`, and the guest's relay connection is gone,
/// each within 1 s; nothing more reaches the guest.
#[test]
fn a_revoke_cuts_the_guest_off_within_a_second() {
    let room = FakeRoom::start(&[]);
    let (mut fake, mux, surface, mut owner) = bridged("latency-revoke", &room);
    let (mut ends, mut deletes, mut closes, mut gone) = (vec![], vec![], vec![], vec![]);
    for round in 0..5 {
        let (share, conn) = open(&room, &mut owner, surface);
        let guests = guests_of(&mut owner, &share, &format!("r{round}@example.com"), 1);
        join(&room, &fake, conn, &guests);
        let start = Instant::now();
        let revoke = owner.request(json!({"cmd":"agent-session-share-revoke", "share_id":share}));
        assert_eq!(revoke["ok"], true, "{revoke}");
        let cut = Cut::new(&mux, &share, start).revoked(conn).closes(&guests).wait(&room);
        ends.push(cut.end.unwrap().1.unwrap());
        deletes.push(cut.delete.unwrap().unwrap());
        closes.extend(cut.close_times());
        gone.extend(guests);
    }
    none_reach(&room, &mut fake, 500, &gone);
    report("revoke.room_end", "alone", ends);
    report("revoke.room_delete", "alone", deletes);
    report("revoke.guest_closed", "alone", closes);
}

/// (c) A kick of one of two guests: the room hears the kick and the kicked guest's relay is gone
/// within 1 s, while the other guest still gets the next record within 1 s.
#[test]
fn a_kick_cuts_one_guest_off_within_a_second_and_the_other_stays_live() {
    let room = FakeRoom::start(&[]);
    let (mut fake, mux, surface, mut owner) = bridged("latency-kick", &room);
    let (share, conn) = open(&room, &mut owner, surface);
    let bob = guests_of(&mut owner, &share, "bob@example.com", 1);
    join(&room, &fake, conn, &bob);
    let (mut kicks, mut closes, mut next, mut gone) = (vec![], vec![], vec![], vec![]);
    for round in 0..5_u64 {
        let ann = guests_of(&mut owner, &share, &format!("k{round}@example.com"), 1);
        join(&room, &fake, conn, &ann);
        // Both are live first.
        let both = [ann[0].clone(), bob[0].clone()];
        live(&room, &mut fake, 200 + round * 2, &both, &[]);
        let start = Instant::now();
        let kick = owner.request(json!({"cmd":"agent-session-share-kick", "share_id":share,
            "guest_id":ann[0]}));
        assert_eq!(kick["ok"], true, "{kick}");
        let cut = Cut::new(&mux, &share, start).kicks(&ann).closes(&ann).wait(&room);
        kicks.extend(cut.kick_times());
        closes.extend(cut.close_times());
        gone.extend(ann);
        next.extend(live(&room, &mut fake, 201 + round * 2, &bob, &gone));
    }
    none_reach(&room, &mut fake, 500, &gone);
    report("kick.room_kick", "alone", kicks);
    report("kick.guest_closed", "alone", closes);
    report("kick.other_guest_next_record", "alone", next);
}

/// (d) An uninvite: every guest the account joined as (its 4 browsers) is kicked at the room and
/// its relay gone within 1 s; another account's guest stays live.
#[test]
fn an_uninvite_cuts_off_every_guest_of_the_account_within_a_second() {
    let room = FakeRoom::start(&[]);
    let (mut fake, mux, surface, mut owner) = bridged("latency-uninvite", &room);
    let (share, conn) = open(&room, &mut owner, surface);
    let bob = guests_of(&mut owner, &share, "bob@example.com", 1);
    join(&room, &fake, conn, &bob);
    let (mut kicks, mut closes, mut next, mut gone) = (vec![], vec![], vec![], vec![]);
    for round in 0..3_u64 {
        let account = format!("u{round}@example.com");
        let vera = guests_of(&mut owner, &share, &account, 4);
        join(&room, &fake, conn, &vera);
        let start = Instant::now();
        let uninvite = owner.request(json!({"cmd":"agent-session-share-uninvite",
            "share_id":share, "account":account}));
        assert_eq!(uninvite["ok"], true, "{uninvite}");
        let cut = Cut::new(&mux, &share, start).kicks(&vera).closes(&vera).wait(&room);
        kicks.extend(cut.kick_times());
        closes.extend(cut.close_times());
        gone.extend(vera);
        next.extend(live(&room, &mut fake, 300 + round, &bob, &gone));
    }
    none_reach(&room, &mut fake, 500, &gone);
    report("uninvite.room_kick", "alone", kicks);
    report("uninvite.guest_closed", "alone", closes);
    report("uninvite.other_guest_next_record", "alone", next);
}

// MARK: Under duress

const SHARES: usize = 16;
const GUESTS_PER_ACCOUNT: usize = 4;
/// Browsers joined per share: 48 relays in all, under the daemon's 64 connections with the owner's.
const JOINED: usize = 3;
const BURST: u64 = 300;
const FIRST: u64 = 1000;

/// (e) The four under load: 16 shares of the chat, each with an account of 4 guests (3 of them
/// joined), a burst of 300 records written to every relay, and mid-burst a kick (share 0), an
/// uninvite (share 1) and a revoke (share 2). Every record reaches every guest still live within
/// 1 s, each cut lands within 1 s, and after it nothing reaches a guest cut off.
#[test]
fn under_duress_records_stay_live_and_cuts_land_within_a_second() {
    let room = FakeRoom::start(&[]);
    let (mut fake, mux, surface, mut owner) = bridged("latency-duress", &room);
    let mut shares = Vec::new();
    for k in 0..SHARES {
        let (share, conn) = open(&room, &mut owner, surface);
        let account = format!("d{k}@example.com");
        let guests = guests_of(&mut owner, &share, &account, GUESTS_PER_ACCOUNT);
        join(&room, &fake, conn, &guests[..JOINED]);
        shares.push((share, conn, account, guests));
    }
    // The burst, on its own thread: every record to every connection, as acpmux fans one out.
    let streams = fake.streams();
    let (halfway_tx, halfway) = channel();
    let writer = std::thread::spawn(move || {
        let mut streams = streams;
        let mut sent = Vec::with_capacity(BURST as usize);
        for n in 0..BURST {
            let line = json!({"jsonrpc":"2.0","method":"_acpmux/event",
                "params":record(FIRST + n)});
            let line = format!("{line}\n");
            sent.push(Instant::now());
            for stream in &mut streams {
                let _ = stream.write_all(line.as_bytes());
            }
            if n == BURST / 3 {
                let _ = halfway_tx.send(());
            }
        }
        sent
    });
    halfway.recv_timeout(WAIT).expect("the burst is under way");
    // The cuts, mid-burst.
    let (kicked_share, _, _, kicked_guests) = &shares[0];
    let kicked = vec![kicked_guests[0].clone()];
    let kick_start = Instant::now();
    let reply = owner.request(json!({"cmd":"agent-session-share-kick",
        "share_id":kicked_share, "guest_id":kicked[0]}));
    assert_eq!(reply["ok"], true, "{reply}");
    let (uninvited_share, _, account, uninvited) = &shares[1];
    let uninvite_start = Instant::now();
    let reply = owner.request(json!({"cmd":"agent-session-share-uninvite",
        "share_id":uninvited_share, "account":account}));
    assert_eq!(reply["ok"], true, "{reply}");
    let (revoked_share, revoked_conn, _, revoked) = &shares[2];
    let revoke_start = Instant::now();
    let reply =
        owner.request(json!({"cmd":"agent-session-share-revoke", "share_id":revoked_share}));
    assert_eq!(reply["ok"], true, "{reply}");
    let mut kick = Cut::new(&mux, kicked_share, kick_start).kicks(&kicked).closes(&kicked);
    let mut uninvite = Cut::new(&mux, uninvited_share, uninvite_start)
        .kicks(&uninvited[..JOINED])
        .closes(&uninvited[..JOINED]);
    let mut revoke = Cut::new(&mux, revoked_share, revoke_start)
        .revoked(*revoked_conn)
        .closes(&revoked[..JOINED]);
    // The guests still live: every one of shares 3.., and share 0's other two.
    let mut stay: Vec<String> = kicked_guests[1..JOINED].to_vec();
    for (_, _, _, guests) in &shares[3..] {
        stay.extend(guests[..JOINED].iter().cloned());
    }
    let mut gone: Vec<String> = kicked.clone();
    gone.extend(uninvited.iter().cloned());
    gone.extend(revoked.iter().cloned());
    // Every frame the room reads in the burst: the records' arrivals and the cuts.
    let mut arrivals: HashMap<(String, u64), Instant> = HashMap::new();
    let wanted = stay.len() * BURST as usize;
    let state = RefCell::new((&mut kick, &mut uninvite, &mut revoke, &mut arrivals));
    let all = watch(
        &room,
        Duration::from_secs(60),
        |seen, at| {
            let (kick, uninvite, revoke, arrivals) = &mut *state.borrow_mut();
            if let Some((guest, seq)) = delivered(seen)
                && (FIRST..FIRST + BURST).contains(&seq)
            {
                if stay.iter().any(|g| g == guest) {
                    arrivals.entry((guest.to_owned(), seq)).or_insert(at);
                }
                return true;
            }
            kick.take(seen, at) || uninvite.take(seen, at) || revoke.take(seen, at)
        },
        || {
            let (kick, uninvite, revoke, arrivals) = &mut *state.borrow_mut();
            // Each is asked every time, so each notes its relays gone as soon as they are.
            let cuts = [kick.done(), uninvite.done(), revoke.done()];
            cuts.iter().all(|done| *done) && arrivals.len() == wanted
        },
    );
    let sent = writer.join().unwrap();
    assert!(
        all,
        "under duress: {} of {wanted} records arrived; kick {}; uninvite {}; revoke {}",
        arrivals.len(),
        kick.missing(),
        uninvite.missing(),
        revoke.missing()
    );
    let records =
        arrivals.iter().map(|((_, seq), at)| *at - sent[(seq - FIRST) as usize]).collect();
    // After the burst: one more record reaches every guest still live, and none cut off.
    let next = live(&room, &mut fake, FIRST + BURST + 1, &stay, &gone);
    none_reach(&room, &mut fake, FIRST + BURST + 2, &gone);
    let load = "duress";
    report("live", load, records);
    report("live.after_cuts", load, next);
    report("kick.room_kick", load, kick.kick_times().collect());
    report("kick.guest_closed", load, kick.close_times().collect());
    report("uninvite.room_kick", load, uninvite.kick_times().collect());
    report("uninvite.guest_closed", load, uninvite.close_times().collect());
    report("revoke.room_end", load, revoke.end.and_then(|(_, at)| at).into_iter().collect());
    report("revoke.room_delete", load, revoke.delete.flatten().into_iter().collect());
    report("revoke.guest_closed", load, revoke.close_times().collect());
}
