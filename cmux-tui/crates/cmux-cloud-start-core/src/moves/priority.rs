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

fn slot_indices(slots: u32, chats: &[Chat]) -> Vec<(usize, &Chat)> {
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

    let target = chats.iter().enumerate().find(|(_, chat)| chat.session == session);
    if target.is_some_and(|(_, chat)| lit_intent(chat)) {
        return Admit::Lit;
    }

    let selected = slot_indices(slots, chats);
    if selected.len() < slots as usize
        || target.is_some_and(|(index, _)| selected.iter().any(|&(held, _)| held == index))
    {
        return Admit::Lit;
    }

    let mut borrowers: Vec<(usize, &Chat)> =
        selected.iter().copied().filter(|(_, chat)| borrowing(chat)).collect();
    borrowers.sort_by_key(|&(index, chat)| (chat.active_at_ms, index));
    if let Some((_, chat)) = borrowers.first() {
        return Admit::LitAfterReturn { returns: vec![chat.session.clone()] };
    }

    let holders = selected
        .iter()
        .filter(|(_, chat)| lit_intent(chat))
        .map(|(_, chat)| Holder { session: chat.session.clone(), title: chat.title.clone() })
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
    lit_local.sort_by(|&(left, left_chat), &(right, right_chat)| {
        right_chat
            .has_work
            .cmp(&left_chat.has_work)
            .then_with(|| lit_time(left_chat).cmp(&lit_time(right_chat)))
            .then_with(|| left.cmp(&right))
    });

    let mut moves = Vec::new();
    let mut moved = std::collections::BTreeSet::new();
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
    auto_local.sort_by(|&(left, left_chat), &(right, right_chat)| {
        right_chat.active_at_ms.cmp(&left_chat.active_at_ms).then_with(|| left.cmp(&right))
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
    high.sort_by(|&(left, left_chat), &(right, right_chat)| {
        lit_time(right_chat).cmp(&lit_time(left_chat)).then_with(|| left.cmp(&right))
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
    let selected = slot_indices(slots, chats);
    let selected_here = selected.iter().any(|&(held, _)| held == index);
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

/// Why one chat's cloud control cannot change its place now. The JSON names are the control's
/// (`webviews hybridModel.ts` `HybridBlockedWhy`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum BlockedWhy {
    /// No Cloud account is signed in: a click signs in.
    SignedOut,
    /// Signed in, and the account's plan keeps no chat in Cloud (`Admit::NoCloud`).
    NoPlan,
}

/// The blocked state as the control reads it: `{"why": "signed-out"}`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Blocked {
    pub why: BlockedWhy,
}

/// What the app knows when it draws one chat's cloud control. The app only carries facts; which
/// state the control shows is decided here.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ControlFacts {
    /// The chat the control is for.
    pub session: String,
    /// A Cloud account is signed in now.
    pub signed_in: bool,
    /// The app is still restoring a saved sign-in: it may yet be signed in, so nothing is blocked.
    pub restoring: bool,
    /// Whether the app has read the account's plan. Unread, no slot rule applies.
    pub plan_known: bool,
    /// The account's plan when `plan_known`; none is no plan.
    pub plan: Option<Plan>,
    /// The server's plan id (`cloud.plan.get` `plan_id`, e.g. `next_pro`) when `plan` is not set.
    /// An id this table does not know leaves the plan unknown.
    pub plan_id: Option<String>,
    /// The chats that count toward the plan's slots, this one included.
    pub chats: Vec<Chat>,
}

/// The plan a server plan id names (`cloud.plan.get` `plan_id`), or none for an id not listed.
pub fn plan_of_id(id: &str) -> Option<Plan> {
    match id {
        "trial" | "next_trial" => Some(Plan::Trial),
        "intro" | "next_intro" => Some(Plan::Intro),
        "plus" | "next_plus" => Some(Plan::Plus),
        "pro" | "next_pro" => Some(Plan::Pro),
        "agents20" | "next_agents20" | "next_agents_20" => Some(Plan::Agents20),
        "max" | "next_max" => Some(Plan::Max),
        _ => None,
    }
}

/// The control's extra state for one chat: blocked, or every slot held by the chats named.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Control {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blocked: Option<Blocked>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub holders: Option<Vec<Holder>>,
    /// Keep Running (high priority) for this chat under a known plan: whether it holds a slot,
    /// the slots used and the plan's total, and whether it waits for one (`view`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keep: Option<View>,
}

/// The control's state for `facts.session`: signed out blocks every pick (a click signs in); a
/// known plan with no slot blocks a chat on this Mac; a known plan whose slots are all held by
/// other chats' choices names them (`Admit::Full`). Anything unknown shows nothing extra.
pub fn control(facts: &ControlFacts) -> Control {
    if !facts.signed_in {
        if facts.restoring {
            return Control::default();
        }
        return Control {
            blocked: Some(Blocked { why: BlockedWhy::SignedOut }),
            ..Control::default()
        };
    }
    if !facts.plan_known {
        return Control::default();
    }
    let plan = match (facts.plan, facts.plan_id.as_deref()) {
        (Some(plan), _) => Some(plan),
        (None, Some(id)) => match plan_of_id(id) {
            Some(plan) => Some(plan),
            None => return Control::default(),
        },
        (None, None) => None,
    };
    let chat = facts.chats.iter().find(|chat| chat.session == facts.session);
    let in_cloud = chat.is_some_and(|chat| chat.at == At::Cloud);
    let keep = view(slots(plan), &facts.chats, &facts.session);
    let mut control = match admit(slots(plan), &facts.chats, &facts.session) {
        // A chat already in Cloud is never blocked: Only on This Mac must still bring it back.
        Admit::NoCloud if !in_cloud => {
            Control { blocked: Some(Blocked { why: BlockedWhy::NoPlan }), ..Control::default() }
        }
        Admit::Full { holders } if !holders.is_empty() => {
            Control { holders: Some(holders), ..Control::default() }
        }
        _ => Control::default(),
    };
    control.keep = keep;
    control
}

#[cfg(test)]
#[path = "priority_tests.rs"]
mod tests;
