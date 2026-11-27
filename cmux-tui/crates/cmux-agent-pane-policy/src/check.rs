//! The full check of one page frame, in the order of CmuxNextAgentPane
//! `AgentPaneTransport.checkOne` (AgentPaneTransport+Check.swift): the
//! allowlist step ([`allowlist_check`]), the session scope, the params rule
//! (P1), the prompt block `_meta` strip, the gesture ticket strip, the facts
//! the host decides on (gesture, path check, attach, scope credit, setting),
//! the click rule (a click-only method that needs a gesture is refused
//! unless the host holds a click, [`Gesture`]; Swift `answerAllowed`),
//! and last the LocalApp token into the first frame. It returns the checked
//! object: the host sends a fresh serialization of it ([`encode`]), never the
//! page's bytes.
//!
//! What it does not do (host state, see the crate docs): validate tickets,
//! record or spend gestures, check paths against the roots, spend scope
//! credit, map request ids.

use crate::data::policy;
use crate::error::Refusal;
use crate::frame::{Refused, allowlist_check, contains, raw_id, with_local_app_token};
use crate::gesture::{Gesture, PermissionOptions, is_click_only, needs_click, needs_gesture};
use crate::params::{
    params_rule_violation, requested_setting, session_refusal, stripping_initialize_opt_ins,
    stripping_prompt_meta, stripping_unknown_params, take_gesture_ticket,
};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};

/// The pane's sessions as the host knows them (`AcpmuxPaneSessions`).
pub trait PaneScope {
    /// Whether the pane started or shows `session`.
    fn contains(&self, session: &str) -> bool;
    /// Whether a fork or handoff names a source inside the scope
    /// (`holdsSource`: `handoffId` the pane owns or whose source it holds,
    /// else `sessionId` in the scope).
    fn holds_source(&self, params: &Map<String, Value>) -> bool;
}

/// What the check reads from the host: small values and handles.
pub struct FrameState<'a> {
    /// The connection's first frame.
    pub is_first: bool,
    /// The LocalApp token read for this connection, if any.
    pub local_app_token: Option<&'a str>,
    /// The daemon's mode field names (P1), when known.
    pub mode_fields: Option<&'a BTreeSet<String>>,
    /// The connection is a chat on another machine (`AgentPaneTransport
    /// .remoteWire`): its `session/new` starts no session on this Mac.
    pub remote_wire: bool,
    /// The person's gesture the host holds for this frame. No default: a
    /// host says which, and [`Gesture::None`] refuses every click-only
    /// frame that needs a gesture.
    pub gesture: Gesture,
    pub scope: &'a dyn PaneScope,
    pub options: &'a PermissionOptions,
}

/// Native input that a host verified while consuming an answer ticket.
/// There is deliberately no conversion from a page value or [`Gesture::Key`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnswerTicketOrigin {
    Click,
    QuestionReturn,
}

/// A ticket redemption request derived from the checked frame, never from
/// a separately supplied page intent.
pub struct AnswerTicketRequest<'a> {
    pub ticket: &'a str,
    pub pick: &'a GesturePick,
    pub session_id: Option<&'a str>,
}

/// The trusted host's one-time answer-ticket redemption boundary. The host
/// must remove the ticket even on failure and verify its connection, age,
/// exact pick/session binding, approval and native input provenance. Return
/// additionally requires the still-current, non-repeating native question
/// witness; posted input and a generic key grant cannot provide it.
///
/// This interface neither issues tickets nor changes the C ABI. It is an
/// integration prerequisite: the host must prove its implementation before
/// adopting [`check_frame_with_answer_tickets`].
pub trait AnswerTicketVerifier {
    fn redeem(&mut self, request: AnswerTicketRequest<'_>) -> Option<AnswerTicketOrigin>;
}

/// The pick a gesture ticket is bound to (`AgentPaneGesturePick`): the method
/// and the scalar params but `sessionId` and `_meta`; `params` is None when a
/// param is an object or a list. A session/prompt picks its promptId, a Cloud
/// start its key, and a permission answer its session, permission and option.
#[derive(Clone, Debug, PartialEq)]
pub struct GesturePick {
    pub method: Option<String>,
    pub params: Option<BTreeMap<String, Value>>,
}

impl GesturePick {
    pub fn new(method: Option<&str>, params: &Map<String, Value>) -> Self {
        let method_name = method.map(str::to_owned);
        // A session/prompt picks only its `_meta.acpmux.promptId` (its blocks
        // are no pick), as the prompt's own id: without a hand-off turn's
        // `handoff-<turn>-` (Swift `AgentPaneHandoffPrompt.ownID`).
        if method == Some("session/prompt") {
            let id =
                params.get("_meta").and_then(|m| m.get("acpmux")).and_then(|a| a.get("promptId"));
            let params = id.and_then(Value::as_str).map(|id| {
                BTreeMap::from([(
                    "promptId".to_owned(),
                    Value::String(own_prompt_id(id).to_owned()),
                )])
            });
            return GesturePick { method: method_name, params };
        }
        // A Cloud start picks only its send's `key` (its task, folder and
        // attachments are no pick); without a string key it picks nothing
        // (Swift `AgentPaneGesturePick`, #34487).
        if method == Some("cloud.startChat") {
            let params = params
                .get("key")
                .and_then(Value::as_str)
                .map(|key| BTreeMap::from([("key".to_owned(), Value::String(key.to_owned()))]));
            return GesturePick { method: method_name, params };
        }
        // A permission answer's pick names its session too (the ticket binds
        // the prompt), and a question's answers and annotations by the sha256
        // of their canonical JSON (Swift `AgentPaneGesturePick`; a null one is
        // no key, one that is not an object or has no digest picks nothing).
        if method == Some("_acpmux/permission_respond") {
            let text = |key: &str| params.get(key).and_then(Value::as_str);
            let (Some(session), Some(permission), Some(option)) =
                (text("sessionId"), text("permissionId"), text("optionId"))
            else {
                return GesturePick { method: method_name, params: None };
            };
            let mut pick = BTreeMap::from([
                ("sessionId".to_owned(), Value::String(session.to_owned())),
                ("permissionId".to_owned(), Value::String(permission.to_owned())),
                ("optionId".to_owned(), Value::String(option.to_owned())),
            ]);
            for key in ["answers", "annotations"] {
                let Some(value) = params.get(key).filter(|v| !v.is_null()) else { continue };
                let digest = value.is_object().then(|| crate::canonical::canonical_digest(value));
                let Some(Some(digest)) = digest else {
                    return GesturePick { method: method_name, params: None };
                };
                pick.insert(key.to_owned(), Value::String(digest));
            }
            return GesturePick { method: method_name, params: Some(pick) };
        }
        let mut scalars = BTreeMap::new();
        for (key, value) in params {
            if key == "sessionId" || key == "_meta" {
                continue;
            }
            if value.is_object() || value.is_array() {
                return GesturePick { method: method_name, params: None };
            }
            scalars.insert(key.clone(), as_double(value));
        }
        GesturePick { method: method_name, params: Some(scalars) }
    }

    /// The pick as JSON, `{"method": m|null, "params": {..}|null}`: the
    /// layout of [`Facts::to_json`]'s `pick` and of `tests/cases/picks.json`.
    pub fn to_json(&self) -> Value {
        serde_json::json!({"method": self.method, "params": self.params})
    }
}

/// A number as Swift's `AgentPaneJSONScalar.number(Double)` holds it, so
/// `1` and `1.0` pick the same; every other scalar as it is.
fn as_double(value: &Value) -> Value {
    match value.as_f64() {
        Some(f) if value.is_number() => {
            serde_json::Number::from_f64(f).map_or(Value::Null, Value::Number)
        }
        _ => value.clone(),
    }
}

/// A prompt's own id: `id` without one hand-off turn's `handoff-<turn>-`
/// (`turn` 1 to 15 ASCII digits, no leading 0, something after it); an id
/// under two labels is its own id as it is (Swift `AgentPaneHandoffPrompt
/// .ownID`), so a ticket for `handoff-2-x` never allows it.
pub fn own_prompt_id(id: &str) -> &str {
    fn stripped(id: &str) -> Option<&str> {
        let (turn, own) = id.strip_prefix("handoff-")?.split_once('-')?;
        let digits = (1..=15).contains(&turn.len())
            && !turn.starts_with('0')
            && turn.bytes().all(|b| b.is_ascii_digit());
        (digits && !own.is_empty()).then_some(own)
    }
    match stripped(id) {
        Some(own) if stripped(own).is_none() => own,
        _ => id,
    }
}

/// What the confirmation sheet would ask (`AgentPaneModeConfirmation`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SettingAsk {
    Mode(String),
    Option { id: String, value: String },
}

/// A mode or config option the frame sets (R2, P2).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Setting {
    pub session_id: Option<String>,
    pub config_id: String,
    pub value: Option<String>,
    pub asked: SettingAsk,
}

/// What the host learns about a checked frame (`AgentPaneTransport.Facts`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Facts {
    pub is_first: bool,
    /// The params the frame carried that this host's lists do not name,
    /// dropped before it was sent (`limit`, `_meta.acpmux.peerRowBatches`):
    /// the host logs them, once each, so a page newer than the host shows.
    pub dropped: Vec<String>,
    pub method: Option<String>,
    /// The page's JSON-RPC id as raw JSON.
    pub page_id: Option<String>,
    /// The gesture ticket the frame carried (stripped from it), and whether
    /// its `_meta` held anything else (R1). The host redeems it, but a
    /// frame that needs no gesture (a Send) is granted even when its ticket
    /// does not redeem (Swift `granted = !facts.needsGesture || (redeemed &&
    /// ...)`; Leo, 2026-11-17, on "Not sent: it needs your own key press or
    /// click": "go remove this").
    pub ticket: Option<String>,
    pub other_meta: bool,
    /// Sorted names accompanying a ticket; metadata values never enter diagnostics.
    pub other_meta_keys: Vec<String>,
    /// A trusted host already redeemed this ticket and consumed its input
    /// credit. Do not redeem or spend another click/grant for this frame.
    /// All other facts (path, scope and setting approval) still apply.
    pub redeemed_answer: Option<AnswerTicketOrigin>,
    pub pick: Option<GesturePick>,
    pub session_id: Option<String>,
    pub needs_gesture: bool,
    /// The frame requires native answer input (`policy.json` `click_only`).
    /// With no `redeemed_answer`, the host must spend the click it named
    /// in [`FrameState::gesture`] and its grant once, redeeming any ticket
    /// that holds that grant. With `redeemed_answer`, the verifier already
    /// consumed the ticket/input credit: do not spend a second click.
    /// A raw ticket or generic key never satisfies this requirement.
    /// Implies `needs_gesture`.
    pub needs_click: bool,
    pub needs_path_check: bool,
    pub setting: Option<Setting>,
    /// An attach of a session that is not the pane's yet.
    pub attach_session: Option<String>,
    /// A fork or handoff from outside the scope (it uses the click's scope
    /// credit), and the handoff it names.
    pub foreign_source: bool,
    pub handoff_id: Option<String>,
    /// `_acpmux/harness_enable`: the host's native sheet decides it, and the
    /// host adds the confirmed `sha256` (AgentPaneTransport `harnessEnable`,
    /// `confirmHarnessEnable`); refused with [`Refusal::HarnessNotConfirmed`]
    /// when the user does not enable it.
    pub harness_enable: bool,
    /// A `session/new` on this Mac (not a remote wire's): a send's gesture
    /// goes on to its first prompt (Swift `startCredit`).
    pub starts_local_session: bool,
}

impl Facts {
    /// No host state decides this frame: it is sent as checked. A
    /// `session/prompt` never is, though it needs no gesture (Leo,
    /// 2026-11-17, on "Not sent: it needs your own key press or click": "go
    /// remove this"): it goes on disk first (the prompt journal) and ends
    /// its tickets and credits (Swift `Facts.free`).
    pub fn free(&self) -> bool {
        self.method.as_deref() != Some("session/prompt")
            && self.ticket.is_none()
            && !self.needs_gesture
            && !self.needs_path_check
            && self.setting.is_none()
            && self.attach_session.is_none()
            && !self.foreign_source
            && !self.harness_enable
            && !self.starts_local_session
    }

    /// The facts as JSON, in the layout of `tests/cases/check.json`'s
    /// `expect.facts` (the app reads this through [`crate::ffi`]).
    pub fn to_json(&self) -> Value {
        let setting = self.setting.as_ref().map(|s| {
            let asked = match &s.asked {
                SettingAsk::Mode(v) => serde_json::json!({"mode": v}),
                SettingAsk::Option { id, value } => {
                    serde_json::json!({"option": {"id": id, "value": value}})
                }
            };
            serde_json::json!({
                "session_id": s.session_id, "config_id": s.config_id, "value": s.value, "asked": asked,
            })
        });
        let pick = self.pick.as_ref().map(GesturePick::to_json);
        let mut value = serde_json::json!({
            "is_first": self.is_first, "method": self.method, "page_id": self.page_id,
            "ticket": self.ticket, "other_meta": self.other_meta, "pick": pick,
            "other_meta_keys": self.other_meta_keys,
            "session_id": self.session_id, "needs_gesture": self.needs_gesture,
            "needs_click": self.needs_click,
            "needs_path_check": self.needs_path_check, "setting": setting,
            "attach_session": self.attach_session, "foreign_source": self.foreign_source,
            "handoff_id": self.handoff_id, "harness_enable": self.harness_enable,
            "starts_local_session": self.starts_local_session, "free": self.free(),
        });
        if let Some(origin) = self.redeemed_answer {
            value["redeemed_answer"] = Value::String(
                match origin {
                    AnswerTicketOrigin::Click => "click",
                    AnswerTicketOrigin::QuestionReturn => "question_return",
                }
                .into(),
            );
        }
        value
    }
}

/// The result of [`check_frame`].
#[derive(Clone, PartialEq)]
pub enum Checked {
    /// Refused; `spend` is a gesture ticket the frame carried, which the host
    /// spends so it cannot be used again.
    Refuse { refused: Refused, spend: Option<String> },
    /// The checked object (the first frame with the LocalApp token) and its
    /// facts.
    Frame { frame: Map<String, Value>, facts: Box<Facts> },
}

impl std::fmt::Debug for Checked {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Checked::Refuse { refused, spend } => f
                .debug_struct("Refuse")
                .field("refused", refused)
                .field("spend", &spend.as_ref().map(|_| "<ticket>"))
                .finish(),
            Checked::Frame { frame, facts } => f
                .debug_struct("Frame")
                .field("frame", &redacted(frame))
                .field("facts", &RedactedFacts(facts))
                .finish(),
        }
    }
}

struct RedactedFacts<'a>(&'a Facts);

impl std::fmt::Debug for RedactedFacts<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut facts = self.0.clone();
        if facts.ticket.is_some() {
            facts.ticket = Some("<ticket>".into());
        }
        facts.fmt(f)
    }
}

/// `frame` for logs: the LocalApp token and a gesture ticket replaced.
pub fn redacted(frame: &Map<String, Value>) -> Value {
    let mut copy = Value::Object(frame.clone());
    for pointer in ["/params/_meta/acpmux/localAppToken", "/params/_meta/cmuxGesture"] {
        if let Some(v) = copy.pointer_mut(pointer) {
            *v = Value::String("<redacted>".into());
        }
    }
    copy
}

/// The full check of `text` (see the module docs).
pub fn check_frame(text: &str, state: &FrameState<'_>) -> Checked {
    check_frame_inner(text, state, None)
}

/// Check with a host-owned ticket verifier. The legacy API and C ABI never
/// enter this path. A failed redemption still returns `spend` (idempotently
/// discard the ticket); a successful one is explicit in `redeemed_answer`.
pub fn check_frame_with_answer_tickets(
    text: &str,
    state: &FrameState<'_>,
    verifier: &mut dyn AnswerTicketVerifier,
) -> Checked {
    check_frame_inner(text, state, Some(verifier))
}

fn check_frame_inner(
    text: &str,
    state: &FrameState<'_>,
    verifier: Option<&mut dyn AnswerTicketVerifier>,
) -> Checked {
    let p = policy();
    let mut object = match allowlist_check(text, state.is_first) {
        Err(refused) => return Checked::Refuse { refused, spend: None },
        Ok(object) => object,
    };
    // The handshake fails safe: an initialize's unknown `_meta.acpmux` opt-ins
    // are removed before every rule, so they never reach the daemon and never
    // fail the connect (cmux#46563; Swift `strippingInitializeOptIns`).
    // Its keys are dropped keys like P0's, so the facts name them too.
    let mut opt_ins = Vec::new();
    if let Some((stripped, keys)) = stripping_initialize_opt_ins(&object, state.mode_fields) {
        object = stripped;
        opt_ins = keys.into_iter().map(|k| format!("_meta.acpmux.{k}")).collect();
    }
    // P0: any other key this host's lists do not name is dropped, not refused
    // ([`stripping_unknown_params`]): a newer page never loses its chat to it.
    let (object, mut dropped) = match stripping_unknown_params(&object, state.mode_fields) {
        Some((stripped, dropped)) => (stripped, dropped),
        None => (object, Vec::new()),
    };
    if !opt_ins.is_empty() {
        dropped.extend(opt_ins);
        dropped.sort();
    }
    let method = object.get("method").and_then(Value::as_str).map(str::to_owned);
    let page_id = object.get("id").and_then(raw_id);
    let empty = Map::new();
    let params = object.get("params").and_then(Value::as_object).unwrap_or(&empty);
    let carried = params
        .get("_meta")
        .and_then(Value::as_object)
        .and_then(|m| m.get(&p.gesture_ticket_key))
        .and_then(Value::as_str)
        .map(str::to_owned);
    if !state.is_first
        && let Some(refused) = session_refusal(&object, |s| state.scope.contains(s))
    {
        return Checked::Refuse { refused, spend: carried };
    }
    if let Some(cause) = params_rule_violation(&object, state.mode_fields) {
        let refused = Refused {
            refusal: Refusal::IntentInvalid,
            method,
            request_id: page_id,
            cause: Some(cause),
        };
        return Checked::Refuse { refused, spend: carried };
    }
    // One permission generation supplies answer validation and the gesture
    // decision. Copy only this permission, not the pane's growing history.
    let options = state.options.snapshot_for(params.get("permissionId").and_then(Value::as_str));
    // Answers go only to a pending question, keyed by its items and bounded.
    if let Some(cause) = crate::answers::answers_rule_violation(&object, &options) {
        let refused = Refused {
            refusal: Refusal::IntentInvalid,
            method,
            request_id: page_id,
            cause: Some(cause),
        };
        return Checked::Refuse { refused, spend: carried };
    }
    let mut frame = stripping_prompt_meta(&object).unwrap_or_else(|| object.clone());
    let mut facts = Facts {
        is_first: state.is_first,
        method: method.clone(),
        page_id,
        dropped,
        ..Facts::default()
    };
    if !state.is_first {
        let taken = take_gesture_ticket(&frame);
        frame = taken.object;
        facts.other_meta = taken.other_meta;
        facts.other_meta_keys = taken.other_meta_keys;
        if taken.ticket.is_some() {
            facts.pick = Some(GesturePick::new(method.as_deref(), params));
            facts.session_id = params.get("sessionId").and_then(Value::as_str).map(str::to_owned);
        }
        facts.ticket = taken.ticket;
        facts.needs_gesture = needs_gesture(&frame, |p, o| options.is_deny(p, o));
        // The click rule. An answer goes on the person's click only: a
        // gesture that typing left does not answer. A click-only method
        // with no gesture rule (a fault in policy.json) needs a click on
        // each frame, so it is never free.
        let click_only = method.as_deref().is_some_and(is_click_only);
        let ruled = method.as_deref().is_some_and(|m| p.gesture_rules.contains_key(m));
        facts.needs_click = needs_click(click_only, ruled, facts.needs_gesture);
        facts.needs_gesture |= facts.needs_click;
        // A raw ticket or key is never proof. Only the opt-in host verifier
        // may supply already-consumed native click/Return provenance.
        if facts.needs_click
            && state.gesture != Gesture::Click
            && !facts.other_meta
            && let (Some(verifier), Some(ticket), Some(pick)) =
                (verifier, facts.ticket.as_deref().filter(|t| !t.is_empty()), facts.pick.as_ref())
        {
            let origin = verifier.redeem(AnswerTicketRequest {
                ticket,
                pick,
                session_id: facts.session_id.as_deref(),
            });
            let question_allow = method.as_deref() == Some("_acpmux/permission_respond")
                && params.get("answers").is_some_and(Value::is_object)
                && params.get("permissionId").and_then(Value::as_str).is_some_and(|permission| {
                    options.question_keys(permission).is_some()
                        && params
                            .get("optionId")
                            .and_then(Value::as_str)
                            .is_some_and(|option| options.is_known_allow(permission, option))
                });
            facts.redeemed_answer =
                origin.filter(|origin| *origin == AnswerTicketOrigin::Click || question_allow);
        }
        if facts.needs_click && state.gesture != Gesture::Click && facts.redeemed_answer.is_none() {
            let refused = Refused {
                refusal: Refusal::GestureRequired,
                method,
                request_id: facts.page_id,
                cause: None,
            };
            return Checked::Refuse { refused, spend: carried };
        }
        facts.needs_path_check = needs_path_check(&frame);
        if method.as_deref() == Some("_acpmux/attach")
            && let Some(session) = params.get("sessionId").and_then(Value::as_str)
            && !state.scope.contains(session)
        {
            facts.attach_session = Some(session.to_owned());
        }
        if let Some(m) = method.as_deref()
            && contains(&p.source_scoped, m)
            && !state.scope.holds_source(params)
        {
            facts.foreign_source = true;
            facts.handoff_id = params.get("handoffId").and_then(Value::as_str).map(str::to_owned);
        }
        facts.harness_enable = method.as_deref() == Some("_acpmux/harness_enable");
        facts.starts_local_session = method.as_deref() == Some("session/new") && !state.remote_wire;
    }
    if let Some(requested) = requested_setting(&frame) {
        let value = requested.value.clone().unwrap_or_else(|| config_value_text(&frame));
        let asked = if requested.config_id == "mode" {
            SettingAsk::Mode(value)
        } else {
            SettingAsk::Option { id: requested.config_id.clone(), value }
        };
        facts.setting = Some(Setting {
            session_id: requested.session_id,
            config_id: requested.config_id,
            value: requested.value,
            asked,
        });
    }
    if state.is_first
        && let Some(token) = state.local_app_token
    {
        frame = with_local_app_token(frame, token);
    }
    Checked::Frame { frame, facts: Box::new(facts) }
}

/// Whether the frame waits for the host's folder check (`AcpmuxPathPolicy
/// .needsCheck`): a `session/new`, or params that name a folder key at any
/// depth.
pub fn needs_path_check(object: &Map<String, Value>) -> bool {
    fn names_folder(value: &Value) -> bool {
        match value {
            Value::Object(o) => {
                o.iter().any(|(k, v)| contains(&policy().path_keys, k) || names_folder(v))
            }
            Value::Array(a) => a.iter().any(names_folder),
            _ => false,
        }
    }
    object.get("method").and_then(Value::as_str) == Some("session/new")
        || object.get("params").is_some_and(names_folder)
}

/// A config option's value as text for the sheet (`configValueText`): the
/// JSON of `params.value`, slashes escaped as Foundation writes them; empty
/// when absent.
pub fn config_value_text(object: &Map<String, Value>) -> String {
    match object.get("params").and_then(|p| p.get("value")) {
        None => String::new(),
        Some(value) => serde_json::to_string(value).unwrap_or_default().replace('/', "\\/"),
    }
}

/// The text the host sends to acpmux for a checked frame: its fresh
/// serialization, with the relay's own id when given (`FrameBox.encoded`).
/// None when it does not encode: the host refuses the frame
/// ([`Refusal::InvalidFrame`], as Swift's `sendNow`), never sends an empty one.
pub fn encode(frame: &Map<String, Value>, relay_id: Option<i64>) -> Option<String> {
    let mut copy = frame.clone();
    if let Some(id) = relay_id {
        copy.insert("id".into(), Value::from(id));
    }
    serde_json::to_string(&copy).ok()
}

/// The close a refusal ends the connection with: the first frame that is not
/// `initialize` closes it with 1008 "first frame" (`AgentPaneTransport
/// .refuse`); every other refusal is answered (a request) or dropped.
pub fn closes_connection(refusal: Refusal) -> Option<(u16, &'static str)> {
    (refusal == Refusal::FirstFrameNotInitialize).then_some((1008, "first frame"))
}
