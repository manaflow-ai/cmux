//! A machine the index refused past its bound (`acpmux_core::hub::MAX_ORIGINS`) gets its slot
//! back when one frees, whole: its origin record and every one of its rows, with no v1 change on
//! it and no restart (decision 261, `refused.rs`). These run the tee's own task over an index on
//! disk, since a slot frees only when a compaction drops a removed origin's record.
use super::hub_rows_tests::{origin, session, v1_hub, v1_keys, v2_keys};
use super::*;
use acpmux_book::index::SummaryIndex;
use std::time::Duration;

/// The tee's task and the index writer, running as the daemon runs them.
struct Live {
    v1: Arc<Hub>,
    v2: Arc<V2>,
    state: Arc<TeeState>,
    tee: tokio::task::JoinHandle<()>,
    writer: tokio::task::JoinHandle<Result<(), acpmux_core::hub::HubError>>,
    _dir: tempfile::TempDir,
}

impl Live {
    fn start() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let v1 = v1_hub();
        let (hub, writer) = acpmux_core::hub::Hub::open(dir.path(), 101, || 7).unwrap();
        let v2 = Arc::new(V2::new(hub, writer));
        let (handle, task) = start_v2_tee(v1.clone(), v2.clone());
        let state = handle.state.clone();
        handle.remote_ready();
        v1.install_v2_tee(handle);
        let tee = tokio::spawn(task);
        let writer = tokio::spawn(v2.take_writer().unwrap().run());
        Self { v1, v2, state, tee, writer, _dir: dir }
    }

    fn index(&self) -> Arc<SummaryIndex> {
        self.v2.hub.snapshot()
    }

    /// The ids of `host`'s rows in the index.
    fn rows_of(&self, host: &str) -> Vec<String> {
        let keys = v2_keys(&self.index());
        keys.into_iter().filter(|(o, _)| o == host).map(|(_, id)| id).collect()
    }

    fn kept(&self) -> (Vec<String>, bool) {
        self.state.refused.lock().unwrap().kept()
    }

    /// A compaction, reached as a busy daemon reaches one: 1 MiB of log (`maybe_compact`'s
    /// trigger), here local rows written and then removed, none left in either list.
    async fn compact(&self) {
        let done = self.v2.hub.compaction_stats().completed;
        let extra = serde_json::value::to_raw_value(&json!({"pad": "x".repeat(1500)})).unwrap();
        for chunk in 0..10 {
            for n in chunk * 100..(chunk + 1) * 100 {
                let mut row = Summary::new(format!("pad-{n}"));
                row.extra = extra.clone();
                self.v2.hub.submit(row).unwrap();
            }
            let last = format!("pad-{}", chunk * 100 + 99);
            until("the padding rows", || self.index().get(&last).is_some()).await;
        }
        for n in 0..1000 {
            self.v2.hub.remove("local", &format!("pad-{n}")).unwrap();
        }
        until("a compaction", || self.v2.hub.compaction_stats().completed > done).await;
        until("the padding gone", || self.index().get("pad-999").is_none()).await;
    }

    async fn stop(self) {
        self.tee.abort();
        let _ = self.tee.await;
        self.v2.hub.close();
        self.writer.await.unwrap().unwrap();
    }
}

async fn until(what: &str, mut done: impl FnMut() -> bool) {
    // timeout: Test-only deadline detects a state the tee never reaches; no user request is cancelled.
    tokio::time::timeout(Duration::from_secs(60), async {
        while !done() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for {what}"));
}

/// Machines and their chats with each chat's state, as the mesh hub's book lists them.
type Book = Vec<(String, Vec<(String, &'static str)>)>;

/// The book read after a heartbeat: each machine with its chats, `running` unless named.
fn book(v1: &Hub, machines: &Book) {
    let hosts = machines.iter().map(|(host, _)| (host.clone(), 5)).collect();
    let sessions = machines
        .iter()
        .flat_map(|(host, chats)| chats.iter().map(move |(id, st)| session(host, id, st)))
        .collect();
    v1.set_mesh_book(hosts, sessions);
}

/// `count` machines named `prefix-NNN` from `from`, each with `chats` running chats.
fn machines(prefix: &str, from: usize, count: usize, chats: usize) -> Book {
    (from..from + count)
        .map(|n| {
            let host = format!("{prefix}-{n:03}");
            let rows = (1..=chats).map(|c| (format!("{host}-{c}"), "running")).collect();
            (host, rows)
        })
        .collect()
}

const LAST: &str = "machine-256";

/// 256 machines admitted, the 257th (`LAST`, three chats) refused, then `machine-000` leaves
/// the book. Its removed record still holds the slot (the bound counts records), so `LAST` is out.
async fn refused_last_with_a_removal_pending(live: &Live) -> Book {
    let mut listed = machines("machine", 0, 256, 1);
    book(&live.v1, &listed);
    until("256 origins", || live.index().origins().count() == 256).await;
    listed.extend(machines("machine", 256, 1, 3));
    book(&live.v1, &listed);
    until("the 257th kept refused", || live.kept().0 == [LAST]).await;
    assert!(origin(&live.index(), LAST).is_none());
    assert!(live.rows_of(LAST).is_empty());

    listed.remove(0);
    book(&live.v1, &listed);
    until("machine-000 removed", || {
        origin(&live.index(), "machine-000") == Some(OriginState::Removed)
            && live.rows_of("machine-000").is_empty()
    })
    .await;
    assert!(origin(&live.index(), LAST).is_none(), "a removed record still holds its slot");
    listed
}

/// Decision 261, (c): a slot frees at a compaction and the refused machine comes back with its
/// record and all three chats, with no v1 change on it. Its next change takes it off the kept set.
#[tokio::test]
async fn a_refused_machine_returns_whole_when_a_compaction_frees_a_slot() {
    let live = Live::start();
    let mut listed = refused_last_with_a_removal_pending(&live).await;
    let freed = live.v2.hub.origin_slots_freed();

    live.compact().await;
    assert!(live.v2.hub.origin_slots_freed() > freed, "the compaction dropped machine-000");
    assert!(origin(&live.index(), "machine-000").is_none());
    until("the 257th whole", || live.rows_of(LAST).len() == 3).await;
    until("its record", || origin(&live.index(), LAST) == Some(OriginState::Connected)).await;
    assert_eq!(live.index().origins().count(), 256);
    assert_eq!(v2_keys(&live.index()), v1_keys(&live.v1));

    // A change on one chat is one submit, and the machine leaves the kept set.
    listed.last_mut().unwrap().1[0].1 = "waiting";
    book(&live.v1, &listed);
    until("the change", || {
        live.index()
            .get_row(&RowKey::new(LAST, "machine-256-1"))
            .is_some_and(|r| r.state == "waiting")
    })
    .await;
    assert_eq!(live.kept(), (Vec::new(), false));
    assert!(!live.state.refused_any.load(Ordering::Acquire));
    live.stop().await;
}

/// Without the release, a v1 change on one chat of a refused machine after a slot frees gets
/// that chat in alone: the writer admits the origin on that row, and its record and other chats
/// stay out. With it, one change on one chat ends with the record and every chat in.
#[tokio::test]
async fn one_change_on_a_refused_machine_after_a_slot_frees_brings_every_chat() {
    let live = Live::start();
    let mut listed = refused_last_with_a_removal_pending(&live).await;

    live.compact().await;
    listed.last_mut().unwrap().1[1].1 = "waiting";
    book(&live.v1, &listed);
    until("the 257th whole", || live.rows_of(LAST).len() == 3).await;
    until("its record", || origin(&live.index(), LAST) == Some(OriginState::Connected)).await;
    let changed = live.index().get_row(&RowKey::new(LAST, "machine-256-2")).unwrap();
    assert_eq!(changed.state, "waiting");
    assert_eq!(v2_keys(&live.index()), v1_keys(&live.v1));
    live.stop().await;
}

/// 257 machines refused at once: the kept set holds 256 and the overflow flag the rest. When the
/// slots free, the remote reconcile runs whole once: 256 machines are in, each with its record and
/// both chats (the bound holds 256, so one stays out with none of its chats), and the flag is off.
#[tokio::test]
async fn an_overflow_of_refused_machines_is_answered_by_one_whole_reconcile() {
    let live = Live::start();
    book(&live.v1, &machines("machine", 0, 256, 1));
    until("256 origins", || live.index().origins().count() == 256).await;

    // The old machines leave as the new arrive: their removed records hold every slot.
    let arrived = machines("new", 0, 257, 2);
    book(&live.v1, &arrived);
    until("257 refused", || {
        let (ids, overflow) = live.kept();
        ids.len() == acpmux_core::hub::MAX_ORIGINS && overflow
    })
    .await;
    // The writer applies the old machines' removals after the tee told the refusals.
    until("the old machines removed", || {
        let index = live.index();
        index.origins().count() == 256 && index.origins().all(|o| o.state == OriginState::Removed)
    })
    .await;
    assert!(v2_keys(&live.index()).is_empty(), "no new machine got in before a slot freed");

    live.compact().await;
    until("256 new machines in", || {
        live.index().origins().filter(|o| o.state == OriginState::Connected).count() == 256
    })
    .await;
    until("their chats", || v2_keys(&live.index()).len() == 512).await;
    let index = live.index();
    let mut out = Vec::new();
    for (host, _) in &arrived {
        match origin(&index, host) {
            Some(OriginState::Connected) => assert_eq!(live.rows_of(host).len(), 2, "{host}"),
            other => {
                assert_eq!(other, None, "{host}");
                assert!(live.rows_of(host).is_empty(), "{host} is out whole");
                out.push(host.clone());
            }
        }
    }
    assert_eq!(out.len(), 1, "{out:?}");
    // The reconcile cleared the flag and the one left out was refused again: it is kept, or the
    // flag is set again, so the next freed slot brings it.
    until("the one left out kept", || {
        let (ids, overflow) = live.kept();
        overflow || ids.contains(&out[0])
    })
    .await;
    assert!(live.state.refused_any.load(Ordering::Acquire));
    live.stop().await;
}

/// A refusal the tee could not tell: its read of the index had a slot that the writer's fill took
/// (`stale_read` stands for that read), so it notes nothing and keeps no origin. The hub's
/// refusal count moves, the tee sets the overflow flag, and the next freed slot brings the 257th
/// machine back whole, its record and three chats, with no v1 change on it.
#[tokio::test]
async fn a_refusal_the_tee_could_not_tell_is_released_whole_on_the_next_freed_slot() {
    let live = Live::start();
    let mut listed = machines("machine", 0, 256, 1);
    book(&live.v1, &listed);
    until("256 origins", || live.index().origins().count() == 256).await;

    live.state.refused.lock().unwrap().stale_read = true;
    let refusals = live.v2.hub.origins_refused();
    listed.extend(machines("machine", 256, 1, 3));
    book(&live.v1, &listed);
    until("the writer's refusal", || live.v2.hub.origins_refused() > refusals).await;
    until("the flag, with no origin kept", || live.kept() == (Vec::new(), true)).await;
    live.state.refused.lock().unwrap().stale_read = false;
    assert!(origin(&live.index(), LAST).is_none());
    assert!(live.rows_of(LAST).is_empty());

    listed.remove(0);
    book(&live.v1, &listed);
    until("machine-000 removed", || {
        origin(&live.index(), "machine-000") == Some(OriginState::Removed)
            && live.rows_of("machine-000").is_empty()
    })
    .await;
    live.compact().await;
    until("the 257th whole", || live.rows_of(LAST).len() == 3).await;
    until("its record", || origin(&live.index(), LAST) == Some(OriginState::Connected)).await;
    assert_eq!(v2_keys(&live.index()), v1_keys(&live.v1));
    live.stop().await;
}
