//! Harness magic §8 (cmuxterm-hq RFD 0158 row 18): plan first, with a reply point. A person's
//! first prompt to a chat that is a real task (at least [`MIN_WORDS`] words, and no "just do
//! it") gets one hidden context block asking the agent for a short plan and a stop. That turn's
//! end arms the reply point: a person's reply within the window steers before any work is done;
//! no reply in [`reply_window`] sends "go" as acpmux's own prompt, so the lane never waits on a
//! person who is away.
//!
//! Why: in steering-lenses only 10% of Leo's steers reach a plan, the rest land on work already
//! done, and agents do worse when requirements arrive mid-task. Cost: one short turn a task and at
//! most the window's wait.
//!
//! Only a person's own prompt (`prompt_sender::person_turn`): never another agent's brief, an
//! inbox notice, a trigger, a resumed or cut turn, or a slash command. The go prompt runs only
//! while the chat still ends on the planning turn (`PromptOptions::after_turn`) and queues
//! nothing (`no_queue`), so any reply, prompt or Stop that came since cancels it.
//!
//! Measured per turn on `turn_result` as `harnessMagic.planFirst.*`: `asked` (the planning turn)
//! and `armed` (its reply point was set); the go turn's own prompt says `plan_first_go`.
//!
//! Off by default (a steering change for every chat): `agents.harnessMagic.planFirst.enabled:
//! true` turns it on; `ACPMUX_HM_PLANFIRST=0` in the daemon's environment turns it off. The
//! window is `agents.harnessMagic.planFirst.replySeconds` (default 120, 15 to 1800).

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

pub(crate) const FEATURE: &str = "planFirst";
pub(crate) const SETTING_ENABLED: &str = "agents.harnessMagic.planFirst.enabled";
pub(crate) const SETTING_REPLY: &str = "agents.harnessMagic.planFirst.replySeconds";
pub(crate) const ENV_KILL: &str = "ACPMUX_HM_PLANFIRST";
/// The provenance kind of the go prompt.
pub(crate) const GO_KIND: &str = "plan_first_go";
/// The fewest words a first prompt has to be a task worth a plan: a question or a one-line ask
/// goes straight to work.
pub(crate) const MIN_WORDS: usize = 60;
const REPLY_DEFAULT_SECS: u64 = 120;
const REPLY_RANGE: (u64, u64) = (15, 1800);

/// Words that say the sender wants no plan.
const OPT_OUTS: &[&str] = &[
    "no plan",
    "don't plan",
    "do not plan",
    "skip the plan",
    "just do it",
    "without asking",
    "don't ask",
    "do not ask",
];

/// The planning turn of each chat, by session id: its turn id, until that turn's end.
static ASKED: LazyLock<Mutex<HashMap<String, String>>> = LazyLock::new(Default::default);

/// Whether the feature is on, given the settings file and the kill switch: off unless the
/// setting is `true`.
pub(crate) fn enabled_by(doc: Option<&Value>, env: Option<&str>) -> bool {
    if env.is_some_and(|v| {
        matches!(v.trim().to_ascii_lowercase().as_str(), "0" | "false" | "off" | "no")
    }) {
        return false;
    }
    doc.and_then(|d| crate::user_settings::value(d, SETTING_ENABLED))
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
}

fn settings_doc() -> Option<Value> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    }
}

/// Whether the feature is on now.
pub(crate) fn enabled() -> bool {
    enabled_by(settings_doc().as_ref(), std::env::var(ENV_KILL).ok().as_deref())
}

/// The reply window the settings name, else the default.
pub(crate) fn reply_window_in(doc: Option<&Value>) -> Duration {
    let secs = doc
        .and_then(|d| crate::user_settings::value(d, SETTING_REPLY))
        .and_then(|v| v.as_u64())
        .map_or(REPLY_DEFAULT_SECS, |s| s.clamp(REPLY_RANGE.0, REPLY_RANGE.1));
    Duration::from_secs(secs)
}

fn reply_window() -> Duration {
    reply_window_in(settings_doc().as_ref())
}

/// Whether `text`, a person's first prompt, is a task that gets a plan first.
pub(crate) fn wants_plan(text: &str) -> bool {
    if text.split_whitespace().count() < MIN_WORDS {
        return false;
    }
    let lower = text.to_lowercase().replace('\u{2019}', "'");
    !OPT_OUTS.iter().any(|o| lower.contains(o))
}

/// The hidden block that asks for the plan.
pub(crate) fn instruction(window: Duration) -> String {
    format!(
        "Plan first: this is a new task. Before changing anything, reply with a short plan (at \
         most 8 lines: the approach, the files or areas it touches, and anything you would ask \
         the person), then end your turn. The person has {}s to reply; if no reply comes, acpmux \
         tells you to go ahead and you start on the plan.",
        window.as_secs()
    )
}

/// The go prompt's words.
pub(crate) fn go_text(window: Duration) -> String {
    format!("No reply to your plan in {}s: go ahead with it.", window.as_secs())
}

/// Whether a prompt's provenance is the go prompt.
pub(crate) fn is_go(provenance: Option<&Value>) -> bool {
    provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) == Some(GO_KIND)
}

/// At a turn's start (`turns.rs`): the block to add to a person's first prompt when the feature
/// is on and the prompt is a task, remembering the turn as this chat's planning turn.
pub(crate) fn start(session_id: &str, turn_id: &str, text: &str) -> Option<Value> {
    if !wants_plan(text) || !enabled() {
        return None;
    }
    ASKED.lock().unwrap_or_else(|e| e.into_inner()).insert(session_id.into(), turn_id.into());
    Some(json!({
        "type": "text",
        "text": instruction(reply_window()),
        "_meta": {"acpmux": {"context": true}},
    }))
}

/// At a turn's end: whether `turn_id` was `session_id`'s planning turn (forgotten either way).
fn take(session_id: &str, turn_id: &str) -> bool {
    let mut asked = ASKED.lock().unwrap_or_else(|e| e.into_inner());
    if asked.get(session_id).is_some_and(|t| t == turn_id) {
        asked.remove(session_id);
        return true;
    }
    false
}

impl super::Hub {
    /// `turn_git.rs` `write_turn_result`: counts the planning turn and, when it completed, arms
    /// its reply point.
    pub(super) fn plan_first_end(&self, session: &super::Session, msg: &mut Value) {
        let Some(turn) = msg.get("turnId").and_then(Value::as_str).map(str::to_owned) else {
            return;
        };
        if !take(&session.id, &turn) {
            return;
        }
        super::harness_magic::add_counter(msg, FEATURE, "asked", 1);
        if msg.get("status").and_then(Value::as_str) != Some("completed") {
            return;
        }
        let Some(hub) = self.hub_ref.get().and_then(std::sync::Weak::upgrade) else { return };
        super::harness_magic::add_counter(msg, FEATURE, "armed", 1);
        let (window, id) = (reply_window(), session.id.clone());
        // Owned by the hub's scope: its close ends a wait still running (check-spawn-owner).
        self.scope.spawn_named("plan-first-go", async move {
            tokio::time::sleep(window).await;
            let Some(s) = hub.session_by_id(&id) else { return };
            // A reply, a Stop or any other turn since: the chat no longer ends on the plan, and
            // `after_turn` refuses this unrecorded.
            let opts = super::PromptOptions {
                prompt_id: Some(format!("plan-first-go-{}", uuid::Uuid::now_v7())),
                provenance: Some(json!({"kind": GO_KIND})),
                no_queue: true,
                after_turn: Some(turn),
                ..super::PromptOptions::default()
            };
            let blocks = vec![json!({"type": "text", "text": go_text(window)})];
            if let Err(e) = hub.prompt_with(&s, blocks, "acpmux", false, opts).await {
                tracing::info!(session = %s.id, error = ?e, "plan first: go not sent");
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(n: usize) -> String {
        vec!["word"; n].join(" ")
    }

    #[test]
    fn plan_first_is_off_unless_turned_on_and_the_kill_switch_wins() {
        assert!(!enabled_by(None, None));
        let on = json!({"agents": {"harnessMagic": {"planFirst": {"enabled": true}}}});
        assert!(enabled_by(Some(&on), None));
        assert!(!enabled_by(Some(&on), Some("0")));
        let off = json!({"agents": {"harnessMagic": {"planFirst": {"enabled": false}}}});
        assert!(!enabled_by(Some(&off), None));
    }

    #[test]
    fn its_switches_are_the_shared_harness_magic_names() {
        use crate::hub::harness_magic::{FEATURES, env_key, setting_key};
        assert!(FEATURES.iter().any(|f| f.name == FEATURE));
        assert_eq!(setting_key(FEATURE), SETTING_ENABLED);
        assert_eq!(env_key(FEATURE), ENV_KILL);
    }

    #[test]
    fn a_short_ask_or_a_just_do_it_task_goes_straight_to_work() {
        assert!(!wants_plan("fix the typo in the README"));
        assert!(!wants_plan(&words(MIN_WORDS - 1)));
        assert!(wants_plan(&words(MIN_WORDS)));
        assert!(!wants_plan(&format!("{} just do it", words(MIN_WORDS))));
        assert!(!wants_plan(&format!("{} Don\u{2019}t ask, decide.", words(MIN_WORDS))));
    }

    #[test]
    fn the_reply_window_defaults_and_is_clamped() {
        assert_eq!(reply_window_in(None), Duration::from_secs(120));
        let short = json!({"agents": {"harnessMagic": {"planFirst": {"replySeconds": 1}}}});
        assert_eq!(reply_window_in(Some(&short)), Duration::from_secs(15));
        let long = json!({"agents": {"harnessMagic": {"planFirst": {"replySeconds": 99999}}}});
        assert_eq!(reply_window_in(Some(&long)), Duration::from_secs(1800));
    }

    #[test]
    fn only_the_planning_turn_arms_once() {
        ASKED.lock().unwrap().insert("s-plan".into(), "t1".into());
        assert!(!take("s-plan", "t0"));
        assert!(take("s-plan", "t1"));
        assert!(!take("s-plan", "t1"), "a turn arms its reply point once");
    }

    #[test]
    fn the_go_prompt_is_known_by_its_provenance_and_names_the_window() {
        assert!(is_go(Some(&json!({"kind": GO_KIND}))));
        assert!(!is_go(Some(&json!({"kind": "auto_resume"}))));
        assert!(!is_go(None));
        assert!(go_text(Duration::from_secs(120)).contains("120s"));
        assert!(instruction(Duration::from_secs(90)).contains("90s"));
    }
}
