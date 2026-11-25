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
}

/// The control's state for `facts.session`: signed out blocks every pick (a click signs in); a
/// known plan with no slot blocks a chat on this Mac; a known plan whose slots are all held by
/// other chats' choices names them (`Admit::Full`). Anything unknown shows nothing extra.
pub fn control(facts: &ControlFacts) -> Control {
    if !facts.signed_in {
        if facts.restoring {
            return Control::default();
        }
        return Control { blocked: Some(Blocked { why: BlockedWhy::SignedOut }), holders: None };
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
    match admit(slots(plan), &facts.chats, &facts.session) {
        // A chat already in Cloud is never blocked: Only on This Mac must still bring it back.
        Admit::NoCloud if !in_cloud => {
            Control { blocked: Some(Blocked { why: BlockedWhy::NoPlan }), holders: None }
        }
        Admit::Full { holders } if !holders.is_empty() => {
            Control { blocked: None, holders: Some(holders) }
        }
        _ => Control::default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_blocks_signed_out_but_not_while_restoring() {
        let facts =
            ControlFacts { session: "s".into(), chats: vec![chat("s")], ..ControlFacts::default() };
        assert_eq!(
            serde_json::to_value(control(&facts)).unwrap(),
            serde_json::json!({ "blocked": { "why": "signed-out" } })
        );
        let restoring = ControlFacts { restoring: true, ..facts.clone() };
        assert_eq!(serde_json::to_value(control(&restoring)).unwrap(), serde_json::json!({}));
        let signed_in = ControlFacts { signed_in: true, ..facts };
        assert_eq!(control(&signed_in), Control::default());
    }

    #[test]
    fn control_names_no_plan_only_for_a_chat_on_this_mac() {
        let facts = ControlFacts {
            session: "s".into(),
            signed_in: true,
            plan_known: true,
            plan: None,
            chats: vec![chat("s")],
            ..ControlFacts::default()
        };
        assert_eq!(
            serde_json::to_value(control(&facts)).unwrap(),
            serde_json::json!({ "blocked": { "why": "no-plan" } })
        );
        let in_cloud = ControlFacts { chats: vec![Chat { at: At::Cloud, ..chat("s") }], ..facts };
        assert_eq!(control(&in_cloud), Control::default());
    }

    #[test]
    fn control_lists_holders_when_every_slot_is_pinned_elsewhere() {
        let pinned = |session: &str, at: u64| Chat {
            pin: Pin::Cloud,
            at: At::Cloud,
            lit_at_ms: Some(at),
            ..chat(session)
        };
        let facts = ControlFacts {
            session: "s".into(),
            signed_in: true,
            plan_known: true,
            plan: Some(Plan::Trial),
            chats: vec![pinned("held", 5), chat("s")],
            ..ControlFacts::default()
        };
        assert_eq!(
            serde_json::to_value(control(&facts)).unwrap(),
            serde_json::json!({ "holders": [{ "session": "held", "title": "held title" }] })
        );
        // The holder itself, and a plan with a free slot, show nothing extra.
        let holder = ControlFacts { session: "held".into(), ..facts.clone() };
        assert_eq!(control(&holder), Control::default());
        let roomy = ControlFacts { plan: Some(Plan::Pro), ..facts };
        assert_eq!(control(&roomy), Control::default());
    }

    #[test]
    fn control_facts_read_the_apps_camel_case() {
        let facts: ControlFacts = serde_json::from_value(serde_json::json!({
            "session": "s",
            "signedIn": true,
            "planKnown": true,
            "plan": "plus",
            "chats": [{ "session": "s", "pin": "auto", "at": "local" }]
        }))
        .unwrap();
        assert_eq!(facts.plan, Some(Plan::Plus));
        assert_eq!(facts.chats[0].pin, Pin::Auto);
    }

    #[test]
    fn control_reads_the_servers_plan_id_and_ignores_an_unknown_one() {
        let pinned = Chat { pin: Pin::Cloud, at: At::Cloud, ..chat("held") };
        let facts = ControlFacts {
            session: "s".into(),
            signed_in: true,
            plan_known: true,
            plan_id: Some("next_plus".into()),
            chats: vec![pinned.clone(), chat("s")],
            ..ControlFacts::default()
        };
        assert_eq!(control(&facts), Control::default());
        let unknown = ControlFacts { plan_id: Some("enterprise_x".into()), ..facts.clone() };
        assert_eq!(control(&unknown), Control::default());
        assert_eq!(plan_of_id("next_max"), Some(Plan::Max));
        assert_eq!(plan_of_id("pro"), Some(Plan::Pro));
    }

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
