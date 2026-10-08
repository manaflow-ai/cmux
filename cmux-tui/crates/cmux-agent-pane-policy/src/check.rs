//! The full check of one page frame, in the order of CmuxNextAgentPane
//! `AgentPaneTransport.checkOne` (AgentPaneTransport+Check.swift): the
//! allowlist step ([`allowlist_check`]), the session scope, the params rule
//! (P1) and the question answers rule (crate only so far), the prompt block
//! `_meta` strip, the gesture ticket strip, the facts the host decides on
//! (gesture, path check, attach, scope credit, setting), and last the
//! LocalApp token into the first frame. It returns the checked
//! object: the host sends a fresh serialization of it ([`encode`]), never the
//! page's bytes.
//!
//! What it does not do (host state, see the crate docs): redeem tickets, ask
//! for gestures, check paths against the roots, spend scope credit, map
//! request ids.

use crate::data::policy;
use crate::error::Refusal;
use crate::frame::{Refused, allowlist_check, contains, raw_id, with_local_app_token};
use crate::gesture::{PermissionOptions, needs_gesture};
use crate::params::{
    breaks_answers_rule, breaks_params_rule, requested_setting, session_refusal,
    stripping_prompt_meta, take_gesture_ticket,
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
    pub scope: &'a dyn PaneScope,
    pub options: &'a PermissionOptions,
}

/// The pick a gesture ticket is bound to (`AgentPaneGesturePick`): the method
/// and the scalar params but `sessionId` and `_meta`; `params` is None when a
/// param is an object or a list.
#[derive(Clone, Debug, PartialEq)]
pub struct GesturePick {
    pub method: Option<String>,
    pub params: Option<BTreeMap<String, Value>>,
}

impl GesturePick {
    pub fn new(method: Option<&str>, params: &Map<String, Value>) -> Self {
        // A session/prompt picks only its `_meta.acpmux.promptId` (its blocks
        // are no pick).
        if method == Some("session/prompt") {
            let id =
                params.get("_meta").and_then(|m| m.get("acpmux")).and_then(|a| a.get("promptId"));
            let params = id
                .and_then(Value::as_str)
                .map(|id| BTreeMap::from([("promptId".to_owned(), Value::String(id.to_owned()))]));
            return GesturePick { method: method.map(str::to_owned), params };
        }
        let mut scalars = BTreeMap::new();
        for (key, value) in params {
            if key == "sessionId" || key == "_meta" {
                continue;
            }
            if value.is_object() || value.is_array() {
                return GesturePick { method: method.map(str::to_owned), params: None };
            }
            scalars.insert(key.clone(), value.clone());
        }
        GesturePick { method: method.map(str::to_owned), params: Some(scalars) }
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
    pub method: Option<String>,
    /// The page's JSON-RPC id as raw JSON.
    pub page_id: Option<String>,
    /// The gesture ticket the frame carried (stripped from it), and whether
    /// its `_meta` held anything else (R1).
    pub ticket: Option<String>,
    pub other_meta: bool,
    pub pick: Option<GesturePick>,
    pub session_id: Option<String>,
    pub needs_gesture: bool,
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
}

impl Facts {
    /// No host state decides this frame: it is sent as checked.
    pub fn free(&self) -> bool {
        self.ticket.is_none()
            && !self.needs_gesture
            && !self.needs_path_check
            && self.setting.is_none()
            && self.attach_session.is_none()
            && !self.foreign_source
            && !self.harness_enable
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
    let p = policy();
    let object = match allowlist_check(text, state.is_first) {
        Err(refused) => return Checked::Refuse { refused, spend: None },
        Ok(object) => object,
    };
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
    if breaks_params_rule(&object, state.mode_fields)
        || breaks_answers_rule(&object, |p| state.options.is_question(p))
    {
        let refused = Refused { refusal: Refusal::IntentInvalid, method, request_id: page_id };
        return Checked::Refuse { refused, spend: carried };
    }
    let mut frame = stripping_prompt_meta(&object).unwrap_or_else(|| object.clone());
    let mut facts =
        Facts { is_first: state.is_first, method: method.clone(), page_id, ..Facts::default() };
    if !state.is_first {
        let taken = take_gesture_ticket(&frame);
        frame = taken.object;
        facts.other_meta = taken.other_meta;
        if taken.ticket.is_some() {
            facts.pick = Some(GesturePick::new(method.as_deref(), params));
            facts.session_id = params.get("sessionId").and_then(Value::as_str).map(str::to_owned);
        }
        facts.ticket = taken.ticket;
        facts.needs_gesture = needs_gesture(&frame, |p, o| state.options.is_deny(p, o));
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
