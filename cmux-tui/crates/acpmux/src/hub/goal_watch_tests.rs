use super::*;
use crate::goal::{GoalProvider, GoalState, GoalStatus};

fn meta(family: &str, condition: Option<&str>, status: Option<GoalStatus>) -> SessionMeta {
    let mut m: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "c1", "name": "lane", "harness": family,
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    }))
    .unwrap();
    m.family = Some(family.to_owned());
    m.stop_condition = condition.map(str::to_owned);
    m.goal = status.map(|status| GoalState {
        objective: "ship it".to_owned(),
        status,
        provider: GoalProvider::Codex,
        token_budget: None,
        tokens_used: None,
        elapsed_seconds: None,
        created_at: None,
        updated_at: None,
        steps: None,
        extra: Default::default(),
    });
    m
}

/// A Codex chat left idle on an open goal is nudged three times, 3, 10 and 30 minutes after
/// each turn, then its owner is told once (acp-chief-issues 2026-11-27 04:30: two Codex chats
/// sat `ready` for two hours). Only a prompt that is not acpmux's own starts the count again: an
/// inbox notice's turn does not, so the nudges stay bounded in a chat that gets messages.
#[test]
fn an_open_goal_left_idle_is_nudged_three_times_then_its_owner_is_told_once() {
    let m = meta("codex", Some("ship it"), Some(GoalStatus::Running));
    let mut watch = GoalWatch::default();
    assert_eq!(step(&m, false, true, &mut watch), Step::Wait(NUDGE_WAITS_MS[0]));
    for n in 1..=3 {
        watch.nudges = n;
        let want = match NUDGE_WAITS_MS.get(n) {
            Some(ms) => Step::Wait(*ms),
            None => Step::Tell("it stopped with its goal open after 3 nudges"),
        };
        assert_eq!(step(&m, true, true, &mut watch), want, "after nudge {n}");
    }
    assert_eq!(step(&m, true, true, &mut watch), Step::Nothing, "a notice's turn: told once");
    assert_eq!(watch.nudges, 3, "a notice's turn starts no new count");
    // The owner's next prompt starts it again.
    assert_eq!(step(&m, false, true, &mut watch), Step::Wait(NUDGE_WAITS_MS[0]));
    assert_eq!(watch.nudges, 0);
}

/// A turn that does not complete (the person's Stop, a failure `auto_resume.rs` continues) arms
/// nothing and ends the wait the last one armed, so no nudge follows a Stop.
#[test]
fn a_turn_that_does_not_complete_ends_the_wait_and_arms_nothing() {
    let m = meta("codex", Some("ship it"), Some(GoalStatus::Running));
    let mut watch = GoalWatch::default();
    assert_eq!(step(&m, false, true, &mut watch), Step::Wait(NUDGE_WAITS_MS[0]));
    let armed = watch.generation;
    assert_eq!(step(&m, false, false, &mut watch), Step::Nothing);
    assert_ne!(watch.generation, armed, "the armed wait finds its generation moved");
}

/// Codex's `blocked` goal tells the owner once until it is unblocked: a prompt that leaves it
/// blocked tells nobody again, so a Chief that answers the notice is not told in a loop. A done
/// goal, a chat with no stop condition, and a Claude Code chat (its Stop hook keeps it going)
/// arm nothing.
#[test]
fn a_blocked_goal_tells_the_owner_once_and_others_arm_nothing() {
    let mut watch = GoalWatch::default();
    let blocked = meta("codex", Some("ship it"), Some(GoalStatus::Stalled));
    let running = meta("codex", Some("ship it"), Some(GoalStatus::Running));
    assert_eq!(step(&blocked, false, true, &mut watch), Step::Tell("its goal is blocked"));
    assert_eq!(step(&blocked, false, true, &mut watch), Step::Nothing, "still blocked");
    assert_eq!(step(&running, false, true, &mut watch), Step::Wait(NUDGE_WAITS_MS[0]));
    assert_eq!(step(&blocked, false, true, &mut watch), Step::Tell("its goal is blocked"));
    let mut watch = GoalWatch::default();
    for m in [
        meta("codex", Some("ship it"), Some(GoalStatus::Done)),
        meta("codex", None, Some(GoalStatus::Running)),
        meta("claude", Some("ship it"), None),
    ] {
        assert_eq!(step(&m, false, true, &mut watch), Step::Nothing, "{m:?}");
    }
    // A goal Codex has not reported yet is open.
    let unreported = meta("codex", Some("ship it"), None);
    assert_eq!(step(&unreported, false, true, &mut watch), Step::Wait(NUDGE_WAITS_MS[0]));
}

/// The notice goes to the stable session of the Chief that made the chat. A lane with no Chief
/// hears of retries that ran out from `lane_stranded` only, not a second time from here.
#[test]
fn the_owner_is_the_chiefs_stable_session_and_a_lane_parent_hears_once() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let tag = |v: &str| crate::store::Tag { value: v.to_owned(), expires_at: None };
    let named = |id: &str, mut m: SessionMeta| {
        (m.id, m.name) = (id.to_owned(), id.to_owned());
        m
    };
    let mut chat = named("made", meta("codex", Some("ship it"), None));
    chat.tags.insert(CHIEF_OWNER_TAG.into(), tag("agent_mux"));
    let mut inbox = named("inbox", meta("claude", None, None));
    inbox.tags.insert(CHIEF_INBOX_TAG.into(), tag("agent_mux"));
    let mut lane = named("lane", meta("codex", Some("ship it"), None));
    lane.tags.insert(super::super::lane_reports::TAG.into(), tag("inbox"));
    for m in [&chat, &inbox, &lane] {
        store.save(m).unwrap();
    }
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    let (_inbox, chat, lane) =
        (hub.resolve("inbox").unwrap(), hub.resolve("made").unwrap(), hub.resolve("lane").unwrap());
    let owner = |s: &Session, parent_too| hub.goal_owner(s, parent_too).map(|o| o.id.clone());
    assert_eq!(owner(&chat, false).as_deref(), Some("inbox"));
    assert_eq!(owner(&lane, false), None, "a lane's parent hears from lane_stranded");
}

/// A chat a Chief's turn made keeps that Chief: the turn's own tag, else the owner stamped on a
/// chat that made it in turn. An expired tag names none.
#[test]
fn a_chats_chief_is_its_turns_participant_or_its_stamped_owner() {
    let tag = |v: &str, expires_at| crate::store::Tag { value: v.to_owned(), expires_at };
    let mut turn = meta("chief", None, None);
    turn.tags
        .insert(crate::prompt_provenance::CHIEF_PARTICIPANT_TAG.into(), tag("agent_mux", None));
    assert_eq!(chief_of(&turn).as_deref(), Some("agent_mux"));
    let mut lane = meta("codex", None, None);
    lane.tags.insert(CHIEF_OWNER_TAG.into(), tag("agent_codex", None));
    assert_eq!(chief_of(&lane).as_deref(), Some("agent_codex"));
    let mut gone = meta("codex", None, None);
    gone.tags.insert(CHIEF_OWNER_TAG.into(), tag("agent_codex", Some(1)));
    assert_eq!(chief_of(&gone), None);
}
