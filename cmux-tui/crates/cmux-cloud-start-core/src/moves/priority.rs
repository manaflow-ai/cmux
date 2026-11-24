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

fn slot_indices(slots: u32, chats: &[Chat]) -> Vec<usize> {
    let mut lit: Vec<usize> = chats
        .iter()
        .enumerate()
        .filter_map(|(index, chat)| lit_intent(chat).then_some(index))
        .collect();
    lit.sort_by_key(|&index| (lit_time(&chats[index]), index));

    let mut borrowers: Vec<usize> = chats
        .iter()
        .enumerate()
        .filter_map(|(index, chat)| borrowing(chat).then_some(index))
        .collect();
    borrowers.sort_by_key(|&index| (chats[index].active_at_ms, index));

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
    if target.is_some_and(|index| lit_intent(&chats[index])) {
        return Admit::Lit;
    }

    let selected = slot_indices(slots, chats);
    if selected.len() < slots as usize || target.is_some_and(|index| selected.contains(&index)) {
        return Admit::Lit;
    }

    let mut borrowers: Vec<usize> =
        selected.iter().copied().filter(|&index| borrowing(&chats[index])).collect();
    borrowers.sort_by_key(|&index| (chats[index].active_at_ms, index));
    if let Some(index) = borrowers.first() {
        return Admit::LitAfterReturn { returns: vec![chats[*index].session.clone()] };
    }

    let holders = selected
        .iter()
        .copied()
        .filter(|&index| lit_intent(&chats[index]))
        .map(|index| Holder {
            session: chats[index].session.clone(),
            title: chats[index].title.clone(),
        })
        .collect();
    Admit::Full { holders }
}

/// Choose the local chats to move when the computer goes away.
pub fn leave_order(slots: u32, chats: &[Chat]) -> Leave {
    let mut used =
        chats.iter().filter(|chat| chat.at == At::Cloud && holds_slot(chat)).count() as u32;
    used = used.min(slots);

    let mut lit_local: Vec<usize> = chats
        .iter()
        .enumerate()
        .filter_map(|(index, chat)| (chat.at == At::Local && lit_intent(chat)).then_some(index))
        .collect();
    lit_local.sort_by(|&left, &right| {
        chats[right]
            .has_work
            .cmp(&chats[left].has_work)
            .then_with(|| lit_time(&chats[left]).cmp(&lit_time(&chats[right])))
            .then_with(|| left.cmp(&right))
    });

    let mut moves = Vec::new();
    let mut moved = vec![false; chats.len()];
    for index in lit_local {
        if used >= slots {
            break;
        }
        used += 1;
        moved[index] = true;
        moves.push(chats[index].session.clone());
    }

    let mut auto_local: Vec<usize> = chats
        .iter()
        .enumerate()
        .filter_map(|(index, chat)| {
            (chat.at == At::Local
                && chat.priority == Priority::Normal
                && chat.pin == Pin::Auto
                && chat.has_work
                && !moved[index])
                .then_some(index)
        })
        .collect();
    auto_local.sort_by(|&left, &right| {
        chats[right].active_at_ms.cmp(&chats[left].active_at_ms).then_with(|| left.cmp(&right))
    });
    for index in auto_local {
        if used >= slots {
            break;
        }
        used += 1;
        moved[index] = true;
        moves.push(chats[index].session.clone());
    }

    let pauses = chats
        .iter()
        .enumerate()
        .filter_map(|(index, chat)| {
            (chat.at == At::Local && chat.has_work && !moved[index]).then_some(chat.session.clone())
        })
        .collect();
    Leave { moves, pauses }
}

/// Chats to return when pooled hours are spent, in return order.
pub fn return_order(chats: &[Chat]) -> Vec<String> {
    let mut auto: Vec<usize> = chats
        .iter()
        .enumerate()
        .filter_map(|(index, chat)| {
            (chat.at == At::Cloud && chat.priority == Priority::Normal && chat.pin == Pin::Auto)
                .then_some(index)
        })
        .collect();
    auto.sort_by_key(|&index| (chats[index].active_at_ms, index));

    let mut high: Vec<usize> = chats
        .iter()
        .enumerate()
        .filter_map(|(index, chat)| {
            (chat.at == At::Cloud && chat.priority == Priority::High && chat.pin == Pin::Auto)
                .then_some(index)
        })
        .collect();
    high.sort_by(|&left, &right| {
        lit_time(&chats[right]).cmp(&lit_time(&chats[left])).then_with(|| left.cmp(&right))
    });

    auto.into_iter().chain(high).map(|index| chats[index].session.clone()).collect()
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
    let index = chats.iter().position(|chat| chat.session == session)?;
    let selected = slot_indices(slots, chats);
    let chat = &chats[index];
    let selected_here = selected.contains(&index);
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
#[path = "priority/tests.rs"]
mod tests;
