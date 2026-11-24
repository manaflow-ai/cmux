//! Per-chat Cloud priority, pinning and slot decisions for hybrid chats.
//!
//! The app supplies the current chat facts and carries out the moves this module chooses. This
//! module has no I/O, and its JSON names match the app's camelCase wire types.

use serde::{Deserialize, Serialize};

/// Whether a chat asks to keep running when this Mac goes away.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Priority {
    #[default]
    Normal,
    High,
}

/// The place a chat is forced to use, or the automatic default.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Pin {
    #[default]
    Auto,
    Cloud,
    Local,
}

/// The place where the chat is currently running.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum At {
    #[default]
    Local,
    Cloud,
}

/// A Cloud plan's included slot and pooled-hour limits.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Plan {
    /// The no-card trial a first turn-on starts.
    Trial,
    /// The first paid month: Plus's limits.
    Intro,
    Plus,
    Pro,
    Agents20,
    Max,
}

/// The number of chats the optional plan can keep in Cloud.
pub fn slots(plan: Option<Plan>) -> u32 {
    match plan {
        None => 0,
        Some(Plan::Trial) => 1,
        Some(Plan::Intro | Plan::Plus) => 3,
        Some(Plan::Pro) => 5,
        Some(Plan::Agents20) => 20,
        Some(Plan::Max) => 50,
    }
}

/// The pooled awake-hour allowance for a plan.
pub fn pool_hours(plan: Option<Plan>) -> Option<u32> {
    match plan {
        None => None,
        Some(Plan::Trial) => Some(10),
        Some(Plan::Intro | Plan::Plus) => Some(100),
        Some(Plan::Pro) => Some(1_000),
        Some(Plan::Agents20) => Some(4_000),
        Some(Plan::Max) => Some(10_000),
    }
}

/// The facts needed to choose a chat's slot and movement order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Chat {
    pub session: String,
    pub title: String,
    pub priority: Priority,
    pub pin: Pin,
    pub at: At,
    /// When the cloud button was lit or the chat was pinned to Cloud.
    pub lit_at_ms: Option<u64>,
    /// The last time this chat was active.
    pub active_at_ms: u64,
    /// A turn is running, or messages are queued for one.
    pub has_work: bool,
}

/// A chat that currently occupies a slot and can be offered as a trade.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Holder {
    pub session: String,
    pub title: String,
}

/// The result of trying to light one chat.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Admit {
    Lit,
    LitAfterReturn { returns: Vec<String> },
    Full { holders: Vec<Holder> },
    NoCloud,
}

/// The local chats to move and pause when this Mac goes away.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Leave {
    pub moves: Vec<String>,
    pub pauses: Vec<String>,
}

/// The cloud button's state and slot count.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    pub priority: Priority,
    pub pin: Pin,
    pub at: At,
    pub lit: bool,
    pub used: u32,
    pub total: u32,
    pub waiting: bool,
}

fn lit_intent(chat: &Chat) -> bool {
    chat.pin != Pin::Local && (chat.priority == Priority::High || chat.pin == Pin::Cloud)
}

fn lit_time(chat: &Chat) -> u64 {
    chat.lit_at_ms.unwrap_or(chat.active_at_ms)
}

fn borrowing(chat: &Chat) -> bool {
    chat.priority == Priority::Normal && chat.pin == Pin::Auto && chat.at == At::Cloud
}

/// The chats in slots, in slot order, each with its index in `chats`.
fn slot_chats(slots: u32, chats: &[Chat]) -> Vec<(usize, &Chat)> {
    let mut lit: Vec<(usize, &Chat)> =
        chats.iter().enumerate().filter(|(_, chat)| lit_intent(chat)).collect();
    lit.sort_by_key(|&(index, chat)| (lit_time(chat), index));

    let mut borrowers: Vec<(usize, &Chat)> =
        chats.iter().enumerate().filter(|(_, chat)| borrowing(chat)).collect();
    borrowers.sort_by_key(|&(index, chat)| (chat.active_at_ms, index));

    lit.extend(borrowers);
    lit.truncate(slots as usize);
    lit
}

/// Whether this chat reserves or occupies one slot.
pub fn holds_slot(chat: &Chat) -> bool {
    chat.pin != Pin::Local
        && (chat.pin == Pin::Cloud
            || chat.priority == Priority::High
            || (chat.priority == Priority::Normal && chat.at == At::Cloud))
}

/// Decide whether `session` can become lit now.
pub fn admit(slots: u32, chats: &[Chat], session: &str) -> Admit {
    if slots == 0 {
        return Admit::NoCloud;
    }

    let target = chats.iter().position(|chat| chat.session == session);
    if chats.iter().find(|chat| chat.session == session).is_some_and(lit_intent) {
        return Admit::Lit;
    }

    let selected = slot_chats(slots, chats);
    if selected.len() < slots as usize
        || target.is_some_and(|index| selected.iter().any(|&(picked, _)| picked == index))
    {
        return Admit::Lit;
    }

    let mut borrowers: Vec<(usize, &Chat)> =
        selected.iter().copied().filter(|&(_, chat)| borrowing(chat)).collect();
    borrowers.sort_by_key(|&(index, chat)| (chat.active_at_ms, index));
    if let Some((_, chat)) = borrowers.first() {
        return Admit::LitAfterReturn { returns: vec![chat.session.clone()] };
    }

    let holders = selected
        .iter()
        .filter(|&&(_, chat)| lit_intent(chat))
        .map(|&(_, chat)| Holder { session: chat.session.clone(), title: chat.title.clone() })
        .collect();
    Admit::Full { holders }
}

/// Choose the local chats to move when the computer goes away.
pub fn leave_order(slots: u32, chats: &[Chat]) -> Leave {
    let mut used =
        chats.iter().filter(|chat| chat.at == At::Cloud && holds_slot(chat)).count() as u32;
    used = used.min(slots);

    let mut lit_local: Vec<(usize, &Chat)> = chats
        .iter()
        .enumerate()
        .filter(|(_, chat)| chat.at == At::Local && lit_intent(chat))
        .collect();
    lit_local.sort_by(|&(left, l), &(right, r)| {
        r.has_work
            .cmp(&l.has_work)
            .then_with(|| lit_time(l).cmp(&lit_time(r)))
            .then_with(|| left.cmp(&right))
    });

    let mut moves = Vec::new();
    let mut moved = std::collections::HashSet::new();
    for (index, chat) in lit_local {
        if used >= slots {
            break;
        }
        used = used.saturating_add(1);
        moved.insert(index);
        moves.push(chat.session.clone());
    }

    let mut auto_local: Vec<(usize, &Chat)> = chats
        .iter()
        .enumerate()
        .filter(|(index, chat)| {
            chat.at == At::Local
                && chat.priority == Priority::Normal
                && chat.pin == Pin::Auto
                && chat.has_work
                && !moved.contains(index)
        })
        .collect();
    auto_local.sort_by(|&(left, l), &(right, r)| {
        r.active_at_ms.cmp(&l.active_at_ms).then_with(|| left.cmp(&right))
    });
    for (index, chat) in auto_local {
        if used >= slots {
            break;
        }
        used = used.saturating_add(1);
        moved.insert(index);
        moves.push(chat.session.clone());
    }

    let pauses = chats
        .iter()
        .enumerate()
        .filter_map(|(index, chat)| {
            (chat.at == At::Local && chat.has_work && !moved.contains(&index))
                .then_some(chat.session.clone())
        })
        .collect();
    Leave { moves, pauses }
}

/// Chats to return when pooled hours are spent, in return order.
pub fn return_order(chats: &[Chat]) -> Vec<String> {
    let mut auto: Vec<(usize, &Chat)> = chats
        .iter()
        .enumerate()
        .filter(|(_, chat)| {
            chat.at == At::Cloud && chat.priority == Priority::Normal && chat.pin == Pin::Auto
        })
        .collect();
    auto.sort_by_key(|&(index, chat)| (chat.active_at_ms, index));

    let mut high: Vec<(usize, &Chat)> = chats
        .iter()
        .enumerate()
        .filter(|(_, chat)| {
            chat.at == At::Cloud && chat.priority == Priority::High && chat.pin == Pin::Auto
        })
        .collect();
    high.sort_by(|&(left, l), &(right, r)| {
        lit_time(r).cmp(&lit_time(l)).then_with(|| left.cmp(&right))
    });

    auto.into_iter().chain(high).map(|(_, chat)| chat.session.clone()).collect()
}

/// Chats pinned to Cloud pause in place when pooled hours are spent.
pub fn pauses_in_place(chats: &[Chat]) -> Vec<String> {
    chats
        .iter()
        .filter_map(|chat| {
            (chat.at == At::Cloud && chat.pin == Pin::Cloud).then_some(chat.session.clone())
        })
        .collect()
}

/// The button state for one chat, or none when the session is not present.
pub fn view(slots: u32, chats: &[Chat], session: &str) -> Option<View> {
    let (index, chat) = chats.iter().enumerate().find(|(_, chat)| chat.session == session)?;
    let selected = slot_chats(slots, chats);
    let selected_here = selected.iter().any(|&(picked, _)| picked == index);
    Some(View {
        priority: chat.priority,
        pin: chat.pin,
        at: chat.at,
        lit: selected_here && lit_intent(chat),
        used: selected.len() as u32,
        total: slots,
        waiting: chat.priority == Priority::High
            && chat.pin != Pin::Local
            && lit_intent(chat)
            && !selected_here,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chat(session: &str) -> Chat {
        Chat { session: session.into(), title: format!("{session} title"), ..Chat::default() }
    }

    #[test]
    fn plans_have_the_rfd_slot_and_pool_limits() {
        let cases = [
            (None, 0, None),
            (Some(Plan::Trial), 1, Some(10)),
            (Some(Plan::Intro), 3, Some(100)),
            (Some(Plan::Plus), 3, Some(100)),
            (Some(Plan::Pro), 5, Some(1_000)),
            (Some(Plan::Agents20), 20, Some(4_000)),
            (Some(Plan::Max), 50, Some(10_000)),
        ];
        for (plan, expected_slots, expected_hours) in cases {
            assert_eq!(slots(plan), expected_slots);
            assert_eq!(pool_hours(plan), expected_hours);
        }
    }

    #[test]
    fn every_priority_pin_and_place_combination_has_the_right_slot_rule() {
        for priority in [Priority::Normal, Priority::High] {
            for pin in [Pin::Auto, Pin::Cloud, Pin::Local] {
                for at in [At::Local, At::Cloud] {
                    let actual = holds_slot(&Chat { priority, pin, at, ..Chat::default() });
                    let expected = pin != Pin::Local
                        && (pin == Pin::Cloud
                            || priority == Priority::High
                            || (priority == Priority::Normal && at == At::Cloud));
                    assert_eq!(actual, expected, "{priority:?} {pin:?} {at:?}");
                }
            }
        }
    }

    #[test]
    fn admission_uses_a_free_slot_then_returns_the_oldest_borrower() {
        let free = vec![chat("one")];
        assert_eq!(admit(2, &free, "one"), Admit::Lit);

        let chats = vec![
            Chat { session: "old".into(), at: At::Cloud, active_at_ms: 10, ..chat("old") },
            Chat { session: "new".into(), at: At::Cloud, active_at_ms: 20, ..chat("new") },
            Chat { session: "wanted".into(), ..chat("wanted") },
        ];
        assert_eq!(
            admit(2, &chats, "wanted"),
            Admit::LitAfterReturn { returns: vec!["old".into()] }
        );
    }

    #[test]
    fn admission_reports_lit_holders_oldest_first_and_handles_no_cloud() {
        let chats = vec![
            Chat {
                session: "new".into(),
                priority: Priority::High,
                lit_at_ms: Some(20),
                ..chat("new")
            },
            Chat {
                session: "old".into(),
                priority: Priority::High,
                lit_at_ms: Some(10),
                title: "Older".into(),
                ..chat("old")
            },
            chat("wanted"),
        ];
        assert_eq!(
            admit(2, &chats, "wanted"),
            Admit::Full {
                holders: vec![
                    Holder { session: "old".into(), title: "Older".into() },
                    Holder { session: "new".into(), title: "new title".into() },
                ]
            }
        );
        assert_eq!(admit(0, &chats, "wanted"), Admit::NoCloud);
        assert_eq!(admit(2, &chats, "old"), Admit::Lit);
    }

    #[test]
    fn leave_order_caps_moves_and_keeps_the_priority_and_work_order() {
        let chats = vec![
            Chat { session: "borrowed".into(), at: At::Cloud, ..chat("borrowed") },
            Chat {
                session: "high-idle".into(),
                priority: Priority::High,
                lit_at_ms: Some(1),
                ..chat("high-idle")
            },
            Chat {
                session: "high-work".into(),
                priority: Priority::High,
                lit_at_ms: Some(20),
                has_work: true,
                ..chat("high-work")
            },
            Chat {
                session: "auto-new".into(),
                active_at_ms: 50,
                has_work: true,
                ..chat("auto-new")
            },
            Chat {
                session: "auto-old".into(),
                active_at_ms: 10,
                has_work: true,
                ..chat("auto-old")
            },
            Chat {
                session: "local-pinned".into(),
                pin: Pin::Local,
                has_work: true,
                ..chat("local-pinned")
            },
            Chat {
                session: "waiting".into(),
                priority: Priority::High,
                lit_at_ms: Some(30),
                has_work: true,
                ..chat("waiting")
            },
        ];
        let leave = leave_order(3, &chats);
        assert_eq!(leave.moves, ["high-work", "waiting"]);
        assert_eq!(leave.pauses, ["auto-new", "auto-old", "local-pinned"]);
    }

    #[test]
    fn returns_put_auto_before_newest_high_and_expose_cloud_pins() {
        let chats = vec![
            Chat {
                session: "high-old".into(),
                priority: Priority::High,
                at: At::Cloud,
                lit_at_ms: Some(10),
                ..chat("high-old")
            },
            Chat {
                session: "auto-new".into(),
                at: At::Cloud,
                active_at_ms: 20,
                ..chat("auto-new")
            },
            Chat {
                session: "high-new".into(),
                priority: Priority::High,
                at: At::Cloud,
                lit_at_ms: Some(30),
                ..chat("high-new")
            },
            Chat { session: "pinned".into(), pin: Pin::Cloud, at: At::Cloud, ..chat("pinned") },
        ];
        assert_eq!(return_order(&chats), ["auto-new", "high-new", "high-old"]);
        assert_eq!(pauses_in_place(&chats), ["pinned"]);
    }

    #[test]
    fn view_never_marks_a_waiting_chat_lit_and_caps_generated_usage() {
        let mut seed = 0x5eed_u64;
        for round in 0..200 {
            let count = (seed as usize % 9) + 1;
            let total = (seed.rotate_left(7) % 6) as u32;
            let mut chats = Vec::with_capacity(count);
            for index in 0..count {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
                let priority = if seed & 1 == 0 { Priority::Normal } else { Priority::High };
                let pin = match (seed >> 1) % 3 {
                    0 => Pin::Auto,
                    1 => Pin::Cloud,
                    _ => Pin::Local,
                };
                let at = if seed & 8 == 0 { At::Local } else { At::Cloud };
                chats.push(Chat {
                    session: format!("{round}-{index}"),
                    priority,
                    pin,
                    at,
                    lit_at_ms: Some(seed % 100),
                    active_at_ms: seed % 100,
                    has_work: seed & 16 != 0,
                    ..Chat::default()
                });
            }
            for chat in &chats {
                let shown = view(total, &chats, &chat.session).expect("generated session exists");
                assert!(shown.used <= shown.total);
                assert!(!(shown.lit && shown.waiting));
            }
        }
    }
}
