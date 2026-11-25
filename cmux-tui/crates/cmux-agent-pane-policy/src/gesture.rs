//! The frames that grant something and so need a fresh user gesture
//! (CmuxNextAgentPane AcpmuxPaneMethods.swift `gestureRules`, `needsGesture`),
//! the answer frames that need a click (`answerAllowed`)
//! and the permission options that tell a deny from an allow
//! (AgentPaneUserGestures.swift `AcpmuxPermissionOptions`).

use crate::data::{GestureRule, policy};
use crate::frame::contains;
use serde_json::{Map, Value};
use std::collections::{BTreeSet, HashMap};
use std::sync::Mutex;

/// Whether `object` (a page frame the allowlist passed) grants and needs a
/// gesture. `is_deny(permission, option)` is true only for a known deny.
pub fn needs_gesture(object: &Map<String, Value>, is_deny: impl Fn(&str, &str) -> bool) -> bool {
    let p = policy();
    let Some(method) = object.get("method").and_then(Value::as_str) else { return false };
    let Some(rule) = p.gesture_rules.get(method) else { return false };
    let empty = Map::new();
    let params = object.get("params").and_then(Value::as_object).unwrap_or(&empty);
    let text = |k: &str| params.get(k).and_then(Value::as_str);
    match rule {
        GestureRule::Always => true,
        GestureRule::WhenTrusting => {
            params.contains_key("peer")
                || !text("level").is_some_and(|l| contains(&p.non_trusting_levels, l))
        }
        GestureRule::WhenOptionAllows => match (text("permissionId"), text("optionId")) {
            (Some(permission), Some(option)) => !is_deny(permission, option),
            _ => true,
        },
        GestureRule::WhenDecisionAllows => text("decision") != Some("deny"),
        GestureRule::WhenPrompting => params.contains_key("prompt"),
    }
}

/// The person's gesture the host holds when it checks a page frame: what
/// the host itself recorded from the person's input, never what the page
/// says.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Gesture {
    /// No gesture, or the host did not say: nothing click-only passes.
    #[default]
    None,
    /// Every gesture that is not a [`Gesture::Click`]: a key press, and a
    /// click older than `policy.json` `click_window_ms`.
    Key,
    /// A host may say `Click` for two inputs only, each the person's own and
    /// not older than `click_window_ms`: a pointer click on the answer
    /// control in the pane, or the host's own answer shortcut on the focused
    /// answer card (a native shortcut the page does not get as a key).
    ///
    /// A host that can not see which control of the page got the click says
    /// `Click` for the person's pointer click inside the pane's page or the
    /// person's own answer shortcut, and for no other input. The Swift host
    /// does so (`AgentPaneView` records each mouse press of the person in
    /// the web view, and its permission shortcut without a look at the
    /// card's focus).
    ///
    /// A host must never say `Click` for: a key that the web page gets (the
    /// person types while another process posts a click on Allow; this is
    /// also the Return key that answers a question), an event that a process
    /// made (posted input), or a gesture ticket. A ticket is no click: see
    /// [`crate::check::check_frame`].
    Click,
}

impl Gesture {
    /// The gesture for its number in the C ABI (0 none, 1 key, 2 click);
    /// None for any other number, which the host's frame is refused for.
    pub fn from_abi(value: u8) -> Option<Gesture> {
        match value {
            0 => Some(Gesture::None),
            1 => Some(Gesture::Key),
            2 => Some(Gesture::Click),
            _ => None,
        }
    }
}

/// Whether `method` is one of `policy.json` `click_only` (an answer to a
/// permission prompt, a plan build, a preset approval): when a frame of it
/// needs a gesture ([`needs_gesture`]), only a click gives it. A deny needs
/// no gesture, so no click.
pub fn is_click_only(method: &str) -> bool {
    contains(&policy().click_only, method)
}

/// Whether a frame goes on the person's click only. `click_only`: its method
/// is one of `policy.json` `click_only`; `ruled`: the method has a gesture
/// rule; `needs_gesture`: what that rule says for this frame.
///
/// A click-only method with no gesture rule is a fault in `policy.json`
/// (tests/click_only.rs refuses the file). It fails closed here: each frame
/// of such a method needs a click, also the one that would be a deny.
pub fn needs_click(click_only: bool, ruled: bool, needs_gesture: bool) -> bool {
    click_only && (needs_gesture || !ruled)
}

/// The permission options the daemon sent, read only from their fixed places
/// (never by walking the frame): `_acpmux/permission_pending` params, a
/// `permission_request` event the daemon recorded (`dir` "mux") in an
/// `_acpmux/event`, or in `result.events` of a reply to a history request.
/// An option seen with two kinds counts as allow.
///
/// A request whose `request.toolCall._meta.acpmux.question` (the daemon's
/// normalized question) is an object is a question; its items' ids and
/// prompts are the keys its `answers` may use ([`Self::question_keys`]). A
/// permission seen once without a question is no question.
#[derive(Default)]
pub struct PermissionOptions {
    denies: Mutex<HashMap<String, HashMap<String, bool>>>,
    /// permissionId -> the item ids and prompts of its question; None once a
    /// request without a question was seen for it.
    questions: Mutex<HashMap<String, Option<BTreeSet<String>>>>,
}

impl PermissionOptions {
    pub fn new() -> Self {
        Self::default()
    }

    /// Records the options in a parsed daemon frame; `reply_to` is the
    /// request a reply answers.
    pub fn observe(&self, object: &Map<String, Value>, reply_to: Option<&str>) {
        type Asked = Vec<(String, Option<BTreeSet<String>>)>;
        let mut found: Vec<(String, String, bool)> = Vec::new();
        let mut asked: Asked = Vec::new();
        fn request(
            record: Option<&Map<String, Value>>,
            found: &mut Vec<(String, String, bool)>,
            asked: &mut Asked,
        ) {
            let Some(record) = record else { return };
            let Some(permission) = record.get("permissionId").and_then(Value::as_str) else {
                return;
            };
            let request = record.get("request").and_then(Value::as_object);
            asked.push((permission.to_owned(), request.and_then(question_keys)));
            let Some(options) = request.and_then(|r| r.get("options")).and_then(Value::as_array)
            else {
                return;
            };
            for option in options.iter().filter_map(Value::as_object) {
                let (Some(id), Some(kind)) = (
                    option.get("optionId").and_then(Value::as_str),
                    option.get("kind").and_then(Value::as_str),
                ) else {
                    continue;
                };
                found.push((permission.to_owned(), id.to_owned(), kind.starts_with("reject")));
            }
        }
        fn event(
            value: Option<&Value>,
            found: &mut Vec<(String, String, bool)>,
            asked: &mut Asked,
        ) {
            let Some(event) = value.and_then(Value::as_object) else { return };
            if event.get("kind").and_then(Value::as_str) != Some("permission_request")
                || event.get("dir").and_then(Value::as_str) != Some("mux")
            {
                return;
            }
            request(event.get("msg").and_then(Value::as_object), found, asked);
        }
        match object.get("method").and_then(Value::as_str) {
            Some("_acpmux/permission_pending") => {
                request(object.get("params").and_then(Value::as_object), &mut found, &mut asked);
            }
            Some("_acpmux/event") => event(object.get("params"), &mut found, &mut asked),
            None => {
                let Some(method) = reply_to else { return };
                if !contains(&policy().history_replies, method) {
                    return;
                }
                let Some(events) = object
                    .get("result")
                    .and_then(Value::as_object)
                    .and_then(|r| r.get("events"))
                    .and_then(Value::as_array)
                else {
                    return;
                };
                for e in events {
                    event(Some(e), &mut found, &mut asked);
                }
            }
            Some(_) => return,
        }
        if !asked.is_empty() {
            let mut questions =
                self.questions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            for (permission, keys) in asked {
                let before = questions.get(&permission).cloned().unwrap_or(Some(BTreeSet::new()));
                let merged = before.and_then(|old| keys.map(|new| &old | &new));
                questions.insert(permission, merged);
            }
        }
        if found.is_empty() {
            return;
        }
        let mut denies = self.denies.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        for (permission, option, deny) in found {
            let options = denies.entry(permission).or_default();
            let before = options.get(&option).copied().unwrap_or(true);
            options.insert(option, before && deny);
        }
    }

    /// The keys `answers` may use for `permission`: its question's item ids
    /// and prompts; None when the pane never saw it as a question (a tool
    /// permission, or an unknown one).
    pub fn question_keys(&self, permission: &str) -> Option<BTreeSet<String>> {
        let questions = self.questions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        questions.get(permission).cloned().flatten()
    }

    /// True only when the pane saw `permission` offer `option` and not every
    /// kind seen for it denies (Swift `isKnownAllow`): the host reserves a
    /// permission answer's ticket only for such an option. An option the pane
    /// never saw is no known allow (and no known deny).
    pub fn is_known_allow(&self, permission: &str, option: &str) -> bool {
        let denies = self.denies.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        denies.get(permission).and_then(|o| o.get(option)).copied() == Some(false)
    }

    /// True only when `option` is a known deny of `permission`.
    pub fn is_deny(&self, permission: &str, option: &str) -> bool {
        let denies = self.denies.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        denies.get(permission).and_then(|o| o.get(option)).copied() == Some(true)
    }
}

/// The keys a question request's `answers` may use (AgentPaneUserGestures
/// .swift `questionKeys`): the item ids and prompts of
/// `request.toolCall._meta.acpmux.question` when it is an object, else, for
/// Claude Code's own AskUserQuestion (`toolCall._meta.claude.tool`, a shape
/// older than the normalized envelope), the text of each
/// `toolCall.rawInput.questions[].question`. None when the request is no
/// question.
fn question_keys(request: &Map<String, Value>) -> Option<BTreeSet<String>> {
    let tool = request.get("toolCall").and_then(Value::as_object);
    let meta = tool.and_then(|t| t.get("_meta")).and_then(Value::as_object);
    let normalized = meta
        .and_then(|m| m.get("acpmux"))
        .and_then(Value::as_object)
        .and_then(|a| a.get("question"))
        .and_then(Value::as_object);
    if let Some(question) = normalized {
        let mut keys = BTreeSet::new();
        for item in question.get("items").and_then(Value::as_array).into_iter().flatten() {
            for key in ["id", "prompt"] {
                if let Some(value) = item.get(key).and_then(Value::as_str) {
                    keys.insert(value.to_owned());
                }
            }
        }
        return Some(keys);
    }
    let claude_tool = meta.and_then(|m| m.get("claude")).and_then(|c| c.get("tool"));
    if claude_tool.and_then(Value::as_str) != Some("AskUserQuestion") {
        return None;
    }
    let questions = tool?.get("rawInput")?.get("questions")?.as_array()?;
    Some(
        questions
            .iter()
            .filter_map(|q| q.get("question").and_then(Value::as_str).map(str::to_owned))
            .collect(),
    )
}
