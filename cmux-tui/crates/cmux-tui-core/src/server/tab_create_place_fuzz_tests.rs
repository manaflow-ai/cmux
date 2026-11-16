//! New Tab and Close Tab keys in a fixed list for each of 8 seeds, against
//! the daemon's strip (`place`, `tab-create-place-v1`). A New Tab key asks
//! for a tab after the active tab: a terminal tab for 2 keys of 4, a tab
//! with a page for the others. New Tab keys that follow each other go out as
//! one burst: each tab after the first names the creation before it. A page
//! commits when its request arrives; the terminal launches of the burst end
//! later, in an order that the seed gives. A Close Tab key closes the active
//! tab. After each burst and each close, the pane's tabs and its active tab
//! are those of a list that the test keeps with no code of the daemon.

use super::super::*;
use super::tab_create_place_chain_tests::HeldConnection;
use super::tab_create_place_tests::{Kind, strip, tabs, with};

const KEYS: usize = 24;

/// The most New Tab keys of one burst. The launch of each terminal of a
/// burst holds one of the 8 workers of the terminal work pool until the test
/// lets it end, so a burst stays smaller than the pool.
const BURST: usize = 4;

/// A fixed sequence of numbers for one seed (a linear congruential generator).
struct Numbers(u64);

impl Numbers {
    fn below(&mut self, below: usize) -> usize {
        self.0 =
            self.0.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        usize::try_from((self.0 >> 33) % below as u64).unwrap()
    }
}

/// The strip as the keys make it: its tabs and the index of the active one.
struct Model {
    tabs: Vec<SurfaceId>,
    active: usize,
}

/// The keys of one seed, as bursts: the count of New Tab keys in a row
/// (0 to [`BURST`]), each followed by one Close Tab key, but for the last.
fn bursts(numbers: &mut Numbers) -> Vec<usize> {
    let mut bursts = vec![0];
    for _ in 0..KEYS {
        // 2 of 3 keys are New Tab; a full burst ends with a Close Tab key.
        if numbers.below(3) < 2 && bursts.last() != Some(&BURST) {
            *bursts.last_mut().unwrap() += 1;
        } else {
            bursts.push(0);
        }
    }
    bursts
}

#[test]
fn held_new_tab_keys_with_close_keys_give_the_strip_of_the_list_for_8_seeds() {
    for seed in 1..=8u64 {
        let mut numbers = Numbers(seed);
        let bursts = bursts(&mut numbers);
        // Each terminal launch is held: the launches are not more than the keys.
        let (mux, pane, [a, b, c]) = strip(&format!("fuzz-{seed}"));
        let connection = HeldConnection::new(&mux, KEYS);
        let mut model = Model { tabs: vec![a, b, c], active: 0 };
        let (mut next_id, mut next_seq) = (1u64, 0usize);
        for (round, burst) in bursts.iter().copied().enumerate() {
            if round > 0 && model.tabs.len() > 1 {
                // Close Tab: the active tab closes; the test then selects the
                // tab on its left, or the new first tab. With one tab left the
                // key does nothing.
                let closed = model.tabs.remove(model.active);
                mux.close_surface(closed).unwrap();
                model.active = model.active.saturating_sub(1);
                mux.select_tab(Some(pane), Some(model.active), None);
            }
            if burst > 0 {
                let ids = (next_id..).take(burst).collect::<Vec<_>>();
                let mut waiting = Vec::new();
                for (n, id) in ids.iter().enumerate() {
                    let kind = match numbers.below(4) {
                        0 => Kind::Conversation,
                        1 => Kind::Browser,
                        _ => Kind::Terminal,
                    };
                    let place = match n {
                        0 => json!({"after": model.tabs[model.active]}),
                        _ => json!({"after_creation": format!("t{}", id - 1)}),
                    };
                    let named = [("transaction", json!(format!("t{id}"))), ("place", place)];
                    connection.send(*id, with(kind.request(pane), named));
                    if kind == Kind::Terminal {
                        waiting.push(next_seq);
                        next_seq += 1;
                    }
                }
                // The launches of the burst end in an order of the seed.
                while !waiting.is_empty() {
                    connection.release(waiting.remove(numbers.below(waiting.len())));
                }
                for id in &ids {
                    model.active += 1;
                    model.tabs.insert(model.active, connection.surface(*id));
                }
                next_id += burst as u64;
            }
            let active = mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.active_tab));
            assert_eq!(tabs(&mux, pane), model.tabs, "seed {seed}, round {round}: the order");
            assert_eq!(active, Some(model.active), "seed {seed}, round {round}: the active tab");
        }
        connection.finish::<0>([]);
        mux.shutdown();
    }
}
