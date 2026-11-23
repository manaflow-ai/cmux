//! A window built row by row is exactly the same cut of the whole list, for
//! seeded random lists: pins, equal times (ties by id), fractions of 0-6
//! digits, channels (a later titled conversation with the same one other),
//! deleted Chiefs' directs, and ids the list does not hold.

use super::*;
use crate::{HomeListState, PreviewWords, home_inbox};
use serde_json::json;
use std::collections::BTreeMap;

const ME: &str = "user_local";

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
    // Few distinct seconds, so equal times (ties by id) are common.
    let second = rng.below(20);
    let fraction = match rng.below(4) {
        0 => String::new(),
        1 => format!(".{:03}", rng.below(3)),
        2 => format!(".{}", rng.below(10)),
        _ => format!(".{:06}", rng.below(3) * 1000),
    };
    format!("2026-11-21T10:00:{second:02}{fraction}Z")
}

fn summaries(rng: &mut Rng, n: usize) -> Vec<Summary> {
    (0..n)
        .map(|at| {
            let id = format!("conv_{:04}", rng.below(n as u64 * 4) * 10_000 + at as u64);
            let others: Vec<serde_json::Value> = (0..1 + rng.below(3))
                .map(|_| {
                    let agent = rng.below(5);
                    json!({"id": format!("agent_{agent}"), "kind": "agent",
                           "display_name": format!("Agent {agent}"),
                           "agent_class": if agent == 0 { "mux" } else { "agent" }})
                })
                .collect();
            let mut participants = vec![json!({"id": ME, "kind": "human", "display_name": "Me"})];
            // Some conversations hold another person or an unplain agent id:
            // out of the phone's scope.
            match rng.below(8) {
                0 => participants
                    .push(json!({"id": "user_other", "kind": "human", "display_name": "Other"})),
                1 => participants
                    .push(json!({"id": "agent_x.y", "kind": "agent", "display_name": "Odd"})),
                _ => {}
            }
            for other in others {
                if !participants.contains(&other) {
                    participants.push(other);
                }
            }
            let title = if rng.below(3) == 0 { format!("Title {at}") } else { String::new() };
            let created = time(rng);
            let updated = time(rng);
            let last_seq = rng.below(4);
            let last = (last_seq > 0).then(|| {
                let author = if rng.below(2) == 0 { ME.to_string() } else { "agent_1".to_string() };
                json!({"id": format!("msg_{at}"), "conversation": id, "seq": last_seq,
                       "client_msg_id": format!("k{at}"), "author": author,
                       "parts": [{"type": "text", "text": format!("hello **{at}**")}],
                       "created_at": time(rng)})
            });
            let mut summary = json!({
                "id": id, "owner": "local", "title": title, "last_seq": last_seq, "rev": 1,
                "created_at": created, "updated_at": updated, "participants": participants,
                "read_cursors": {ME: rng.below(3)}
            });
            if let Some(last) = last {
                summary["last_message"] = last;
            }
            serde_json::from_value(summary).unwrap_or_else(|e| panic!("summary: {e}"))
        })
        .collect()
}

fn input<'a>(rng: &mut Rng, summaries: &[Summary]) -> HomeInboxInput<'a> {
    let mut states = HashMap::new();
    for summary in summaries {
        if rng.below(5) == 0 {
            let pinned = rng.below(2) == 0;
            let position = (rng.below(2) == 0).then(|| rng.below(4));
            states.insert(
                summary.id.clone(),
                HomeListState { pinned, pin_position: position, marked_unread: rng.below(2) == 0 },
            );
        }
    }
    let mut deleted_chiefs = BTreeSet::new();
    if rng.below(2) == 0 {
        deleted_chiefs.insert(format!("agent_{}", rng.below(5)));
    }
    HomeInboxInput {
        me: ME,
        states,
        chief_names: BTreeMap::from([("agent_0".to_string(), "Chief Zero".to_string())]),
        typing: HashMap::new(),
        running: HashMap::new(),
        deleted_chiefs,
        preview_words: PreviewWords::default(),
    }
}

#[test]
fn a_window_is_the_same_cut_of_the_whole_list() {
    for seed in 0..300u64 {
        let mut rng = Rng(seed);
        let n = rng.below(60) as usize;
        let list = summaries(&mut rng, n);
        let input = input(&mut rng, &list);
        let whole = home_inbox(&list, &input);
        for _ in 0..8 {
            let offset = rng.below(n as u64 + 3) as usize;
            let limit = 1 + rng.below(20) as usize;
            let (rows, total) =
                home_inbox_window(&list, &input, &HomeWindow::Range { offset, limit });
            assert_eq!(total, whole.len(), "seed {seed}");
            let cut: Vec<(usize, HomeRow)> =
                whole.iter().cloned().enumerate().skip(offset).take(limit).collect();
            assert_eq!(rows, cut, "seed {seed} offset {offset} limit {limit}");
        }
        let mut asked: Vec<String> = (0..1 + rng.below(6))
            .filter_map(|_| list.get(rng.below(n as u64 + 2) as usize).map(|s| s.id.clone()))
            .collect();
        asked.push("conv_not_listed".into());
        let (rows, _) = home_inbox_window(&list, &input, &HomeWindow::Ids(asked.clone()));
        let cut: Vec<(usize, HomeRow)> =
            whole.iter().cloned().enumerate().filter(|(_, row)| asked.contains(&row.id)).collect();
        assert_eq!(rows, cut, "seed {seed} ids");
        let heads: Vec<HomeHead<'_>> = list.iter().map(HomeHead::of).collect();
        let order = HomeOrder::new(&heads, &input);
        assert_eq!(order.digest(), order_digest(whole.iter().map(|row| row.id.as_str())));
        // The phone's scope: the same order with the rows out of scope left out.
        let scoped = HomeOrder::scoped(&heads, &input, HomeScope::OwnerAndAgents);
        let narrowed: Vec<&str> = whole
            .iter()
            .filter(|row| {
                list.iter().any(|summary| summary.id == row.id && owner_and_agents(summary))
            })
            .map(|row| row.id.as_str())
            .collect();
        assert_eq!(
            scoped.ids().iter().map(String::as_str).collect::<Vec<_>>(),
            narrowed,
            "seed {seed}"
        );
    }
}

/// The order reads heads alone: the same heads with no last message and
/// their activity time given beside give the same order.
#[test]
fn the_order_needs_no_last_message() {
    for seed in 0..100u64 {
        let mut rng = Rng(seed + 1000);
        let list = summaries(&mut rng, 40);
        let input = input(&mut rng, &list);
        let full: Vec<HomeHead<'_>> = list.iter().map(HomeHead::of).collect();
        let light: Vec<Summary> =
            list.iter().map(|summary| Summary { last_message: None, ..summary.clone() }).collect();
        let heads: Vec<HomeHead<'_>> = light
            .iter()
            .zip(&full)
            .map(|(summary, whole)| HomeHead { summary, activity_at: whole.activity_at })
            .collect();
        assert_eq!(HomeOrder::new(&heads, &input).ids(), HomeOrder::new(&full, &input).ids());
    }
}
