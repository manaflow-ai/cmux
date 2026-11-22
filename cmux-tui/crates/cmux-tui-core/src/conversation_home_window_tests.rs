//! The owner's window read is the same cut of the whole Home list, and a
//! Home open costs the window, not the list.
//!
//! `home_open_cost_by_list_length` (ignored; run it by name) prints the cost
//! of the first screen (30 rows) at 100, 1k, 10k and 100k conversations, as
//! NETCOND lines: before (the whole list, then the cut) and after (the
//! window), cold (first open) and warm (an open after no change).

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::time::Instant;

use cmux_conversation::{
    HomeInboxInput, HomeListState, HomeRow, HomeScope, HomeWindow, PreviewWords,
};
use rusqlite::params;
use serde_json::json;

use super::super::{ConversationStore, LOCAL_USER};

/// The phone's first screen.
const FIRST_SCREEN: usize = 30;

/// A small deterministic generator (SplitMix64).
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }
}

fn time(rng: &mut Rng) -> String {
    let minute = rng.below(60);
    let second = rng.below(60);
    match rng.below(3) {
        0 => format!("2026-11-21T10:{minute:02}:{second:02}Z"),
        1 => format!("2026-11-21T10:{minute:02}:{second:02}.{:03}Z", rng.below(1000)),
        _ => format!("2026-11-21T10:{minute:02}:{second:02}.{:06}Z", rng.below(1_000_000)),
    }
}

/// `n` conversations of the local person with one of 8 agents (some
/// titled, some with no message), written in one transaction.
fn seeded_store(n: usize, seed: u64) -> ConversationStore {
    let mut rng = Rng(seed);
    let mut store = ConversationStore::open(None).unwrap();
    let transaction = store.connection.transaction().unwrap();
    for at in 0..n {
        let id = format!("conv_{at:06}");
        let agent = rng.below(8);
        let participants = json!([
            {"id": LOCAL_USER, "kind": "human", "display_name": "Me"},
            {"id": format!("agent_{agent}"), "kind": "agent", "display_name": format!("Agent {agent}")}
        ]);
        let title = if rng.below(3) == 0 { format!("Title {at}") } else { String::new() };
        let created = time(&mut rng);
        let updated = time(&mut rng);
        let last_seq: i64 = if rng.below(10) == 0 { 0 } else { 1 };
        transaction
            .execute(
                "INSERT INTO conversation(id, title, participants_json, last_seq, rev,
                                          created_at, updated_at)
                 VALUES(?1, ?2, ?3, ?4, 1, ?5, ?6)",
                params![id, title, participants.to_string(), last_seq, created, updated],
            )
            .unwrap();
        if last_seq == 1 {
            let author =
                if rng.below(2) == 0 { LOCAL_USER.to_string() } else { format!("agent_{agent}") };
            let message = json!({
                "id": format!("msg_{at:06}"), "conversation": id, "seq": 1,
                "client_msg_id": format!("k{at}"), "author": author,
                "parts": [{"type": "text", "text": format!("hello **{at}**, the quick brown fox")}],
                "created_at": time(&mut rng),
            });
            transaction
                .execute(
                    "INSERT INTO message(conversation, seq, id, message_json) VALUES(?1, 1, ?2, ?3)",
                    params![id, format!("msg_{at:06}"), message.to_string()],
                )
                .unwrap();
        }
    }
    transaction.commit().unwrap();
    store
}

/// A caller's input with its pins and marks, which are written to `store`
/// too (the window reads them there).
fn input(rng: &mut Rng, n: usize, store: &mut ConversationStore) -> HomeInboxInput<'static> {
    let mut states = HashMap::new();
    for _ in 0..(n / 50).max(3) {
        let id = format!("conv_{:06}", rng.below(n as u64));
        let pinned = rng.below(2) == 0;
        // The store keeps a pin as its position.
        let position = pinned.then(|| rng.below(4));
        states.insert(
            id,
            HomeListState { pinned, pin_position: position, marked_unread: rng.below(2) == 0 },
        );
    }
    for (id, state) in &states {
        store
            .connection
            .execute(
                "INSERT OR REPLACE INTO inbox_state(participant, conversation, pin_position,
                                                     marked_unread) VALUES(?1, ?2, ?3, ?4)",
                params![
                    LOCAL_USER,
                    id,
                    state.pin_position.map(|p| p as i64),
                    i64::from(state.marked_unread)
                ],
            )
            .unwrap();
    }
    HomeInboxInput { me: LOCAL_USER, states, ..ask(&HomeInboxInput::default()) }
}

/// What a window read is given: the caller and the registry, no pins (the
/// store reads its own).
fn ask(_: &HomeInboxInput<'_>) -> HomeInboxInput<'static> {
    HomeInboxInput {
        me: LOCAL_USER,
        states: HashMap::new(),
        chief_names: BTreeMap::from([("agent_0".to_string(), "Chief Zero".to_string())]),
        typing: HashMap::new(),
        running: HashMap::new(),
        deleted_chiefs: BTreeSet::from(["agent_7".to_string()]),
        preview_words: PreviewWords::default(),
    }
}

/// Before: the whole list (every head, cursor, guard and last message read,
/// every row built), then the cut.
fn whole_then_cut(
    store: &mut ConversationStore,
    input: &HomeInboxInput<'_>,
    window: &HomeWindow,
) -> (Vec<(usize, HomeRow)>, usize, usize) {
    let list = store.list().unwrap();
    let whole = cmux_conversation::home_inbox(&list, input);
    let built = whole.len();
    let total = whole.len();
    let cut = match window {
        HomeWindow::Range { offset, limit } => {
            whole.into_iter().enumerate().skip(*offset).take(*limit).collect()
        }
        HomeWindow::Ids(ids) => {
            whole.into_iter().enumerate().filter(|(_, row)| ids.contains(&row.id)).collect()
        }
    };
    (cut, total, built)
}

#[test]
fn the_owner_window_is_the_same_cut_of_the_whole_list() {
    for seed in 0..12u64 {
        let mut rng = Rng(seed);
        let n = 1 + rng.below(400) as usize;
        let mut store = seeded_store(n, seed);
        let input = input(&mut rng, n, &mut store);
        for _ in 0..6 {
            let window = if rng.below(3) == 0 {
                HomeWindow::Ids(
                    (0..1 + rng.below(8))
                        .map(|_| format!("conv_{:06}", rng.below(n as u64 + 3)))
                        .collect(),
                )
            } else {
                HomeWindow::Range {
                    offset: rng.below(n as u64 + 2) as usize,
                    limit: 1 + rng.below(60) as usize,
                }
            };
            let (cut, total, _) = whole_then_cut(&mut store, &input, &window);
            let read = store.home_window(&mut ask(&input), &window, HomeScope::All).unwrap();
            assert_eq!(read.rows, cut, "seed {seed} {window:?}");
            assert_eq!(read.order.total(), total, "seed {seed}");
        }
    }
}

#[test]
fn a_store_change_orders_again() {
    let mut store = seeded_store(50, 3);
    let input = input(&mut Rng(3), 50, &mut store);
    let first = HomeWindow::Range { offset: 0, limit: 5 };
    let before = store.home_window(&mut ask(&input), &first, HomeScope::All).unwrap();
    assert!(before.ordered_now);
    assert!(
        !store.home_window(&mut ask(&input), &first, HomeScope::All).unwrap().ordered_now,
        "no change: the kept order"
    );
    let people: Vec<cmux_conversation::Participant> = serde_json::from_value(json!([
        {"id": LOCAL_USER, "kind": "human", "display_name": "Me"},
        {"id": "agent_new", "kind": "agent", "display_name": "New"}
    ]))
    .unwrap();
    let made = store.create("home-window-new", LOCAL_USER, "New", &people).unwrap().summary.id;
    let read = store
        .home_window(&mut ask(&input), &HomeWindow::Ids(vec![made.clone()]), HomeScope::All)
        .unwrap();
    assert!(read.ordered_now, "a new conversation orders again");
    assert_eq!(read.rows.len(), 1);
    // Not every seeded conversation is in this caller's list; the new one is.
    assert_eq!(read.order.total(), before.order.total() + 1);
    let (cut, _, _) = whole_then_cut(&mut store, &input, &first);
    assert_eq!(store.home_window(&mut ask(&input), &first, HomeScope::All).unwrap().rows, cut);
}

fn netcond(when: &str, phase: &str, scale: &str, metric: &str, value: f64) {
    let line = json!({
        "surface": "list", "profile": "store-in-memory@1", "phase": phase, "scale": scale,
        "metric": metric, "value": value, "run": 0, "seed": 7,
    });
    println!("{when} NETCOND {line}");
}

fn ms(start: Instant) -> f64 {
    (start.elapsed().as_secs_f64() * 1000.0 * 1000.0).round() / 1000.0
}

/// Best of `runs` (milliseconds) and the rows built by the last run.
fn best<T>(runs: usize, mut run: impl FnMut() -> (T, usize)) -> (f64, usize) {
    let mut fastest = f64::MAX;
    let mut built = 0;
    for _ in 0..runs {
        let start = Instant::now();
        let (_, rows) = run();
        fastest = fastest.min(ms(start));
        built = rows;
    }
    (fastest, built)
}

#[test]
#[ignore = "measurement: run by name (cargo test -p cmux-tui-core home_open_cost -- --ignored --nocapture)"]
fn home_open_cost_by_list_length() {
    let window = HomeWindow::Range { offset: 0, limit: FIRST_SCREEN };
    let mut warm_after = Vec::new();
    for (n, scale) in [(100, "1x"), (1_000, "10x"), (10_000, "100x"), (100_000, "1000x")] {
        let mut store = seeded_store(n, 7);
        let input = input(&mut Rng(7), n, &mut store);
        let (before_ms, before_rows) = best(3, || {
            let (cut, _, built) = whole_then_cut(&mut store, &input, &window);
            (cut, built)
        });
        for phase in ["cold", "warm"] {
            netcond("before", phase, scale, "home_open_ms", before_ms);
            netcond("before", phase, scale, "rows_built", before_rows as f64);
        }
        // Cold: the order is read from the store (as after any change).
        let (cold_ms, cold_rows) = best(3, || {
            store.home_order_cache = Default::default();
            let read = store.home_window(&mut ask(&input), &window, HomeScope::All).unwrap();
            assert!(read.ordered_now);
            let built = read.rows.len();
            (read, built)
        });
        netcond("after", "cold", scale, "home_open_ms", cold_ms);
        netcond("after", "cold", scale, "rows_built", cold_rows as f64);
        let (warm_ms, warm_rows) = best(5, || {
            let read = store.home_window(&mut ask(&input), &window, HomeScope::All).unwrap();
            assert!(!read.ordered_now);
            let built = read.rows.len();
            (read, built)
        });
        netcond("after", "warm", scale, "home_open_ms", warm_ms);
        netcond("after", "warm", scale, "rows_built", warm_rows as f64);
        assert_eq!(cold_rows, FIRST_SCREEN.min(before_rows));
        assert_eq!(warm_rows, FIRST_SCREEN.min(before_rows));
        warm_after.push(warm_ms);
    }
    let (Some(&first), Some(&last)) = (warm_after.first(), warm_after.last()) else {
        panic!("no warm open was measured");
    };
    println!("warm home open 1x {first} ms, 1000x {last} ms, ratio {:.3}", last / first.max(1e-9));
}

#[test]
#[ignore = "profile: run by name"]
fn home_open_profile_split() {
    for n in [100, 100_000] {
        let mut store = seeded_store(n, 7);
        let input = input(&mut Rng(7), n, &mut store);
        let window = HomeWindow::Range { offset: 0, limit: FIRST_SCREEN };
        let (heads_ms, _) = best(3, || {
            let heads = store.home_heads().unwrap();
            let len = heads.len();
            (heads, len)
        });
        let heads = store.home_heads().unwrap();
        let refs: Vec<cmux_conversation::HomeHead<'_>> = heads
            .iter()
            .map(|(summary, activity_at)| cmux_conversation::HomeHead { summary, activity_at })
            .collect();
        let (order_ms, _) = best(3, || {
            let order = cmux_conversation::HomeOrder::scoped(&refs, &input, HomeScope::All);
            (order, 0)
        });
        store.home_window(&mut ask(&input), &window, HomeScope::All).unwrap();
        let (key_ms, _) =
            best(5, || (store.home_order(&mut ask(&input), HomeScope::All).unwrap(), 0));
        let (warm_ms, _) =
            best(5, || (store.home_window(&mut ask(&input), &window, HomeScope::All).unwrap(), 0));
        println!(
            "profile n={n} heads_query={heads_ms} order_build={order_ms} warm_key={key_ms} warm_total={warm_ms}"
        );
    }
}
