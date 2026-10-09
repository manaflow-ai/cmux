//! The rules as data (`policy.json`), read once. One file so a second host
//! (the Swift app) can read the same lists; the Swift parity test compares
//! them with AcpmuxPaneMethods.swift.

use serde::Deserialize;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;

/// The policy file's text.
pub const POLICY_JSON: &str = include_str!("../policy.json");

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GestureRule {
    /// Every frame of the method (the user pressed send, picked a mode or an option).
    Always,
    /// `acp.trust.set` that trusts (`level` not one of `non_trusting_levels`).
    WhenTrusting,
    /// `_acpmux/permission_respond` whose option is not a known deny.
    WhenOptionAllows,
    /// `_acpmux/permission_group_respond` whose `decision` is not `deny`.
    WhenDecisionAllows,
}

#[derive(Clone, Debug, Deserialize)]
pub struct KnownParams {
    pub params: BTreeSet<String>,
    pub acpmux: BTreeSet<String>,
}

/// The bounds on a question's answers (crate rule, stricter than the Swift
/// host today): `method`'s `param` is accepted only for a pending question,
/// and only as an object of at most `maximum_items` item ids, each mapped to a
/// string or a list of strings of at most `maximum_value_bytes` UTF-8 bytes
/// (a list: its strings together). The default (a policy that did not parse)
/// accepts no answers.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct QuestionAnswers {
    pub method: String,
    pub param: String,
    pub maximum_items: usize,
    pub maximum_value_bytes: usize,
}

/// The shape of a reply the host filters itself.
#[derive(Clone, Debug, PartialEq)]
pub enum ReplyShape {
    String,
    Object(BTreeMap<String, ReplyShape>),
    List(Box<ReplyShape>),
}

impl ReplyShape {
    fn from_json(v: &Value) -> Option<ReplyShape> {
        if v.as_str() == Some("string") {
            return Some(ReplyShape::String);
        }
        let o = v.as_object()?;
        if let Some(fields) = o.get("object").and_then(Value::as_object) {
            let fields = fields
                .iter()
                .map(|(k, f)| Some((k.clone(), ReplyShape::from_json(f)?)))
                .collect::<Option<_>>()?;
            return Some(ReplyShape::Object(fields));
        }
        o.get("list").and_then(ReplyShape::from_json).map(|item| ReplyShape::List(Box::new(item)))
    }
}

#[derive(Debug, Default, Deserialize)]
struct Raw {
    pane_origin: String,
    initialize: String,
    requests: BTreeSet<String>,
    notifications: BTreeSet<String>,
    maximum_frame_bytes: usize,
    servers_key: String,
    gesture_ticket_key: String,
    session_scoped: BTreeSet<String>,
    optionally_session_scoped: BTreeSet<String>,
    source_scoped: BTreeSet<String>,
    gesture_rules: BTreeMap<String, GestureRule>,
    non_trusting_levels: BTreeSet<String>,
    setting_methods: BTreeSet<String>,
    known_params: BTreeMap<String, KnownParams>,
    reply_shapes: BTreeMap<String, Value>,
    history_replies: BTreeSet<String>,
    path_keys: BTreeSet<String>,
    question_answers: QuestionAnswers,
}

/// The rules.
#[derive(Debug)]
pub struct Policy {
    /// The origin acpmux accepts for the bundled pane (acpmux `server/local_app.rs`).
    pub pane_origin: String,
    /// The first frame of every connection, and only the first.
    pub initialize: String,
    /// Requests (`id` present) the page may send.
    pub requests: BTreeSet<String>,
    /// Notifications (no `id`).
    pub notifications: BTreeSet<String>,
    /// Longest frame the page may send.
    pub maximum_frame_bytes: usize,
    /// The key whose entries a harness spawns (C1).
    pub servers_key: String,
    /// Where a frame carries a gesture ticket (`params._meta.<key>`).
    pub gesture_ticket_key: String,
    /// Methods allowed only for a session the pane started or shows.
    pub session_scoped: BTreeSet<String>,
    /// Methods that may name a session (`sessionId`, the trust question's
    /// chat): a named one must be the pane's, none is fine
    /// (`optionallySessionScoped`).
    pub optionally_session_scoped: BTreeSet<String>,
    /// Methods that copy a session into a new one the pane controls.
    pub source_scoped: BTreeSet<String>,
    pub gesture_rules: BTreeMap<String, GestureRule>,
    /// `acp.trust.set` levels that do not trust (no gesture).
    pub non_trusting_levels: BTreeSet<String>,
    /// The methods that set a mode or an option (P1).
    pub setting_methods: BTreeSet<String>,
    pub known_params: BTreeMap<String, KnownParams>,
    pub reply_shapes: BTreeMap<String, ReplyShape>,
    /// The replies whose `result.events` hold the daemon's history.
    pub history_replies: BTreeSet<String>,
    /// The params a page frame may name a folder in, at any depth
    /// (`AcpmuxPathPolicy.keys`): such a frame waits for the host's path check.
    pub path_keys: BTreeSet<String>,
    pub question_answers: QuestionAnswers,
}

pub fn policy() -> &'static Policy {
    static POLICY: OnceLock<Policy> = OnceLock::new();
    POLICY.get_or_init(|| {
        // policy.json is built in; tests/parity.rs fails on a file that does
        // not parse. Should it not, the policy denies everything (no method,
        // every frame too large) instead of ending the host.
        let raw: Raw = serde_json::from_str(POLICY_JSON).unwrap_or_default();
        let reply_shapes = raw
            .reply_shapes
            .iter()
            .filter_map(|(k, v)| ReplyShape::from_json(v).map(|shape| (k.clone(), shape)))
            .collect();
        Policy {
            pane_origin: raw.pane_origin,
            initialize: raw.initialize,
            requests: raw.requests,
            notifications: raw.notifications,
            maximum_frame_bytes: raw.maximum_frame_bytes,
            servers_key: raw.servers_key,
            gesture_ticket_key: raw.gesture_ticket_key,
            session_scoped: raw.session_scoped,
            optionally_session_scoped: raw.optionally_session_scoped,
            source_scoped: raw.source_scoped,
            gesture_rules: raw.gesture_rules,
            non_trusting_levels: raw.non_trusting_levels,
            setting_methods: raw.setting_methods,
            known_params: raw.known_params,
            reply_shapes,
            history_replies: raw.history_replies,
            path_keys: raw.path_keys,
            question_answers: raw.question_answers,
        }
    })
}
