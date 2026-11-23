//! Which chats keep running when the Mac sleeps or closes (hq RFD 0076, "Keep running").
//! Prototype: pure decision logic, no I/O, no clock (times come in), not wired to the app.
//!
//! Policy: chats the person turned On are kept in the order they were turned on, up to the plan's
//! slots. A chat set Off is never kept. With `auto` on, slots left over go to Unset chats that are
//! in a turn, most recently active first. With no awake minutes left nothing is kept. Ties break
//! by id, so the answer does not depend on input order. Turning one on never silently drops a
//! chat the person turned On ([`preview_turn_on`] says Full); it may take an auto-kept slot.

use std::cmp::Reverse;

/// A chat's id.
pub type ChatId = String;

/// The plan's side of the switch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Plan {
    /// How many chats the plan keeps running at once.
    pub kept_slots: u32,
    /// Awake minutes the plan has left.
    pub awake_minutes_left: u32,
}

/// What the person chose for a chat's switch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeepChoice {
    On { turned_on_at_ms: u64 },
    Off,
    Unset,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chat {
    pub id: ChatId,
    pub keep: KeepChoice,
    pub in_turn: bool,
    pub last_active_ms: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reason {
    /// The switch is off, or on Unset and Auto did not pick it.
    SwitchOff,
    /// Turned on, but the plan's slots are taken (Auto: an in-turn chat that found no slot).
    OverPlan,
    NoHoursLeft,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    Kept,
    NotKept(Reason),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Preview {
    /// Turning it on fits in a free slot (or it is already kept).
    Fits,
    /// Turning it on takes the slot of this auto-kept chat.
    TakesAutoSlot {
        from: ChatId,
    },
    /// Every slot holds a chat the person turned on.
    Full {
        kept: u32,
        of: u32,
    },
    NoHoursLeft,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Summary {
    pub kept: u32,
    pub of: u32,
}

/// One decision per chat, sorted by id.
pub fn decide(plan: Plan, chats: &[Chat], auto: bool) -> Vec<(ChatId, Decision)> {
    let slots = plan.kept_slots as usize;
    let no_hours = plan.awake_minutes_left == 0;

    let mut on: Vec<(u64, &Chat)> = chats
        .iter()
        .filter_map(|c| match c.keep {
            KeepChoice::On { turned_on_at_ms } => Some((turned_on_at_ms, c)),
            _ => None,
        })
        .collect();
    on.sort_by(|a, b| (a.0, &a.1.id).cmp(&(b.0, &b.1.id)));

    let mut auto_pool: Vec<&Chat> = if auto {
        chats.iter().filter(|c| c.keep == KeepChoice::Unset && c.in_turn).collect()
    } else {
        Vec::new()
    };
    auto_pool.sort_by(|a, b| {
        (Reverse(a.last_active_ms), &a.id).cmp(&(Reverse(b.last_active_ms), &b.id))
    });

    let mut out: Vec<(ChatId, Decision)> = Vec::with_capacity(chats.len());
    let mut used = 0usize;
    for (_, c) in &on {
        let d = if no_hours {
            Decision::NotKept(Reason::NoHoursLeft)
        } else if used < slots {
            used += 1;
            Decision::Kept
        } else {
            Decision::NotKept(Reason::OverPlan)
        };
        out.push((c.id.clone(), d));
    }
    for c in &auto_pool {
        let d = if !no_hours && used < slots {
            used += 1;
            Decision::Kept
        } else if no_hours {
            Decision::NotKept(Reason::SwitchOff)
        } else {
            Decision::NotKept(Reason::OverPlan)
        };
        out.push((c.id.clone(), d));
    }
    for c in chats {
        if matches!(c.keep, KeepChoice::Off)
            || (c.keep == KeepChoice::Unset && !(auto && c.in_turn))
        {
            out.push((c.id.clone(), Decision::NotKept(Reason::SwitchOff)));
        }
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

/// What turning `chat_id` on would do, without doing it.
pub fn preview_turn_on(plan: Plan, chats: &[Chat], auto: bool, chat_id: &str) -> Preview {
    let now = decide(plan, chats, auto);
    if now.iter().any(|(id, d)| id == chat_id && *d == Decision::Kept) {
        return Preview::Fits;
    }
    if plan.awake_minutes_left == 0 {
        return Preview::NoHoursLeft;
    }
    let on_others =
        chats.iter().filter(|c| c.id != chat_id && matches!(c.keep, KeepChoice::On { .. })).count()
            as u32;
    if on_others >= plan.kept_slots {
        return Preview::Full { kept: on_others.min(plan.kept_slots), of: plan.kept_slots };
    }
    let kept = now.iter().filter(|(_, d)| *d == Decision::Kept).count() as u32;
    if kept < plan.kept_slots {
        return Preview::Fits;
    }
    // Every slot is held and fewer than all by explicit choice: an auto-kept chat gives one up,
    // the one Auto would drop first (least recently active, then highest id).
    let from = now
        .iter()
        .filter(|(_, d)| *d == Decision::Kept)
        .filter_map(|(id, _)| chats.iter().find(|c| &c.id == id))
        .filter(|c| c.keep == KeepChoice::Unset)
        .min_by(|a, b| (a.last_active_ms, Reverse(&a.id)).cmp(&(b.last_active_ms, Reverse(&b.id))))
        .map(|c| c.id.clone());
    match from {
        Some(from) => Preview::TakesAutoSlot { from },
        None => Preview::Full { kept, of: plan.kept_slots },
    }
}

pub fn summary(plan: Plan, decisions: &[(ChatId, Decision)]) -> Summary {
    let kept = decisions.iter().filter(|(_, d)| *d == Decision::Kept).count() as u32;
    Summary { kept, of: plan.kept_slots }
}

/// "N of M kept running".
pub fn summary_line(s: &Summary) -> String {
    format!("{} of {} kept running", s.kept, s.of)
}

#[cfg(test)]
mod tests;
