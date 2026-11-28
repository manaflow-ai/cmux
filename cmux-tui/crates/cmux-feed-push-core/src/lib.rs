//! The feed push rules shared by the cmux Mac app and the phones
//! (plans/cmux-next/feed.md 7.3, cx-aocz), in Rust: one definition the Mac
//! reaches over the app FFI (`include/cmux_feed_push.h`, linked through
//! cmux-app-ffi) and the phones over uniffi (cmux-mobile-ffi `feed_push_json`).
//! It was the Swift package Packages/Shared/CmuxFeedPushCore (RFD 0213,
//! plans/cmux-next/mobile-rust-core.md slice 1).
//!
//! - [`ShownText`]: what the person saw on an agent's permission request,
//!   its canonical bytes and their sha256 (the phone signs it; the Mac that
//!   posted the item recomputes it and refuses a mismatch).
//! - [`ApproveMessage`]: the exact bytes a phone's presence key signs.
//! - [`FeedPushCategory`] and [`FeedPushAction`]: the banner buttons.
//! - [`FeedAnswer`]: what a banner action sends as `feed.answer`.
//! - [`CloudOp`] and [`CloudOpReply`]: `POST /v1/ops` bodies and replies.
//! - [`FeedPushPayload`] and [`FeedPushResponse`]: a push's `userInfo` and
//!   what the app does with one banner response.
//!
//! No I/O, no clock, no keys: the apps sign, send and store. [`ops::call`] is
//! the one JSON entry point both bindings use, so a rule cannot answer one way
//! on the Mac and another on the phone.

#![deny(unsafe_op_in_unsafe_fn)]

pub mod ffi;
pub mod ops;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use unicode_segmentation::UnicodeSegmentation;

/// Lowercase hex of `bytes` (the APNs device-token and sha256 spelling).
pub fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// `true` only for the JSON boolean true.
fn json_true(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Bool(true)))
}

fn json_str(value: Option<&Value>) -> String {
    value.and_then(Value::as_str).unwrap_or_default().to_owned()
}

/// What the person saw on an agent's permission request (cx-aocz): the tool,
/// the summary, the exact command, the input summary of a tool without a
/// command (paths, patterns), and whether the Mac shortened any of it, as the
/// phone renders them from the feed item's `prompt.action`. The phone signs
/// the sha256 of [`ShownText::canonical`]; the Mac that posted the item
/// computes it over the text it posted and refuses a mismatch, so a changed
/// item text cannot turn a seen `ls` into an approved `rm`. A shortened
/// request is never allowed from the phone (the person did not see all of it).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ShownText {
    #[serde(default)]
    pub tool: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub command: String,
    /// A tool input without a command: field name to its shown value.
    #[serde(default)]
    pub input: BTreeMap<String, String>,
    /// The Mac cut the command, an input value, a field name, or dropped fields.
    #[serde(default)]
    pub truncated: bool,
}

impl ShownText {
    /// `prompt.action` of a feed item (`tool`, `summary`, `command`, `input`,
    /// `truncated`). A field of another JSON type reads as empty, an input
    /// value that is not a string is dropped, and `truncated` counts only as
    /// the JSON boolean true.
    pub fn from_action(action: &Value) -> Self {
        let input = action
            .get("input")
            .and_then(Value::as_object)
            .map(|object| {
                object
                    .iter()
                    .filter_map(|(key, value)| Some((key.clone(), value.as_str()?.to_owned())))
                    .collect()
            })
            .unwrap_or_default();
        Self {
            tool: json_str(action.get("tool")),
            summary: json_str(action.get("summary")),
            command: json_str(action.get("command")),
            input,
            truncated: json_true(action.get("truncated")),
        }
    }

    /// Unambiguous: a version line, then each field as
    /// `<name>:<UTF-8 byte count>:<value>` on its own line (a value may hold
    /// newlines), the input fields by name (bytewise UTF-8 order), then
    /// `truncated:0|1`.
    pub fn canonical(&self) -> String {
        let mut text = String::from("cmux-feed-shown-v2\n");
        for (name, value) in [("tool", &self.tool), ("summary", &self.summary), ("command", &self.command)] {
            text.push_str(&format!("{name}:{}:{value}\n", value.len()));
        }
        for (key, value) in &self.input {
            text.push_str(&format!("input:{}:{key}:{}:{value}\n", key.len(), value.len()));
        }
        text.push_str(if self.truncated { "truncated:1\n" } else { "truncated:0\n" });
        text
    }

    /// Lowercase hex sha256 of [`ShownText::canonical`].
    pub fn sha256(&self) -> String {
        hex(&Sha256::digest(self.canonical().as_bytes()))
    }
}

/// The bytes a phone's presence key signs to answer an approve request it
/// cannot otherwise prove it answered (cx-aocz, chief-approved design):
/// `cmux-feed-approve-v1\n<environment>\n<user>\n<phone install>\n<Mac install>
/// \n<item id>\n<shown-text sha256>\n<decision>\n<scope>\n<ts ms>`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApproveMessage {
    pub environment: String,
    pub user: String,
    pub phone_install: String,
    pub mac_install: String,
    pub item: String,
    pub shown_sha256: String,
    /// `allow` or `deny`.
    pub decision: String,
    /// `once` or `session`.
    pub scope: String,
    pub timestamp_ms: i64,
}

impl ApproveMessage {
    pub fn text(&self) -> String {
        [
            "cmux-feed-approve-v1",
            &self.environment,
            &self.user,
            &self.phone_install,
            &self.mac_install,
            &self.item,
            &self.shown_sha256,
            &self.decision,
            &self.scope,
            &self.timestamp_ms.to_string(),
        ]
        .join("\n")
    }
}

/// The proof an approve answer carries (`answer.proof`): the signing install,
/// the time it signed and the base64url raw P-256 signature.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApproveProof {
    pub install: String,
    #[serde(rename = "ts")]
    pub timestamp_ms: i64,
    #[serde(rename = "sig")]
    pub signature: String,
}

impl ApproveProof {
    pub fn value(&self) -> Value {
        json!({"install": self.install, "ts": self.timestamp_ms, "sig": self.signature})
    }
}

/// The notification category the feed owner sets in `aps.category`
/// (`FEED_<KIND>` for requests, `FEED_NOTICE` for notices).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FeedPushCategory {
    Approve,
    Confirm,
    Choice,
    Question,
    SignIn,
    Passkey,
    Handoff,
    Notice,
}

impl FeedPushCategory {
    pub const ALL: [Self; 8] = [
        Self::Approve,
        Self::Confirm,
        Self::Choice,
        Self::Question,
        Self::SignIn,
        Self::Passkey,
        Self::Handoff,
        Self::Notice,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Self::Approve => "FEED_APPROVE",
            Self::Confirm => "FEED_CONFIRM",
            Self::Choice => "FEED_CHOICE",
            Self::Question => "FEED_QUESTION",
            Self::SignIn => "FEED_SIGN_IN",
            Self::Passkey => "FEED_PASSKEY",
            Self::Handoff => "FEED_HANDOFF",
            Self::Notice => "FEED_NOTICE",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|category| category.id() == id)
    }

    /// The buttons the banner offers, in order. An empty list means the
    /// default action only (a tap opens the item).
    pub fn actions(self) -> &'static [FeedPushAction] {
        match self {
            // "Allow for Session" is offered only in the app: the push does not say
            // whether the prompt offers the session scope, and the owner refuses it otherwise.
            Self::Approve => &[FeedPushAction::Allow, FeedPushAction::Deny],
            Self::Confirm => &[FeedPushAction::Confirm, FeedPushAction::Cancel],
            Self::Question => &[FeedPushAction::Reply],
            // Sign-in, passkey and handoff need the Mac; the owner refuses phone answers.
            Self::SignIn | Self::Passkey | Self::Handoff => &[FeedPushAction::OpenOnMac],
            Self::Choice | Self::Notice => &[],
        }
    }
}

/// One banner action. Identifiers are stable: they travel in
/// `UNNotificationResponse.actionIdentifier`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FeedPushAction {
    Allow,
    AllowForSession,
    Deny,
    Confirm,
    Cancel,
    Reply,
    OpenOnMac,
}

/// How an action behaves on the banner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FeedPushActionStyle {
    /// Answers from the banner, without opening the app.
    Answer { destructive: bool, requires_unlock: bool },
    /// A text field; the typed text is the answer.
    TextInput,
    /// Opens the app (nothing is answered from the phone).
    OpenApp,
}

impl FeedPushAction {
    pub const ALL: [Self; 7] =
        [Self::Allow, Self::AllowForSession, Self::Deny, Self::Confirm, Self::Cancel, Self::Reply, Self::OpenOnMac];

    pub fn id(self) -> &'static str {
        match self {
            Self::Allow => "FEED_ALLOW",
            Self::AllowForSession => "FEED_ALLOW_SESSION",
            Self::Deny => "FEED_DENY",
            Self::Confirm => "FEED_CONFIRM_YES",
            Self::Cancel => "FEED_CONFIRM_NO",
            Self::Reply => "FEED_REPLY",
            Self::OpenOnMac => "FEED_OPEN_ON_MAC",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|action| action.id() == id)
    }

    pub fn style(self) -> FeedPushActionStyle {
        match self {
            // Approving work an agent asked for needs an unlocked phone.
            Self::Allow | Self::AllowForSession | Self::Confirm => {
                FeedPushActionStyle::Answer { destructive: false, requires_unlock: true }
            }
            Self::Deny | Self::Cancel => FeedPushActionStyle::Answer { destructive: true, requires_unlock: false },
            Self::Reply => FeedPushActionStyle::TextInput,
            Self::OpenOnMac => FeedPushActionStyle::OpenApp,
        }
    }
}

/// What a banner action sends as `feed.answer {item, answer}`.
///
/// As JSON (the ops' spelling): `{"kind": "decision", "allow", "scope"?}`,
/// `{"kind": "signed_decision", "allow", "scope"?, "proof": {install, ts, sig}}`,
/// `{"kind": "confirmed", "value": bool}` or `{"kind": "text", "value": string}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FeedAnswer {
    Decision {
        allow: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        scope: Option<String>,
    },
    /// An approve answer with the phone's presence-key proof (cx-aocz). The
    /// Mac that posted an agent's permission request answers an allow only
    /// with a valid proof.
    SignedDecision {
        allow: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        scope: Option<String>,
        proof: ApproveProof,
    },
    Confirmed {
        value: bool,
    },
    Text {
        value: String,
    },
}

impl FeedAnswer {
    /// The answer for one banner action, or none when the action only opens
    /// the app (or carries no usable text).
    pub fn for_action(action: FeedPushAction, text: Option<&str>) -> Option<Self> {
        Some(match action {
            FeedPushAction::Allow => Self::Decision { allow: true, scope: None },
            FeedPushAction::AllowForSession => Self::Decision { allow: true, scope: Some("session".into()) },
            FeedPushAction::Deny => Self::Decision { allow: false, scope: None },
            FeedPushAction::Confirm => Self::Confirmed { value: true },
            FeedPushAction::Cancel => Self::Confirmed { value: false },
            FeedPushAction::Reply => {
                let trimmed = text.unwrap_or_default().trim();
                if trimmed.is_empty() {
                    return None;
                }
                Self::Text { value: trimmed.to_owned() }
            }
            FeedPushAction::OpenOnMac => return None,
        })
    }

    /// The wire `answer` object.
    pub fn value(&self) -> Value {
        fn decision(allow: bool, scope: &Option<String>) -> Map<String, Value> {
            let mut object = Map::new();
            object.insert("decision".into(), Value::from(if allow { "allow" } else { "deny" }));
            if let Some(scope) = scope {
                object.insert("scope".into(), Value::from(scope.as_str()));
            }
            object
        }
        match self {
            Self::Decision { allow, scope } => Value::Object(decision(*allow, scope)),
            Self::SignedDecision { allow, scope, proof } => {
                let mut object = decision(*allow, scope);
                object.insert("proof".into(), proof.value());
                Value::Object(object)
            }
            Self::Confirmed { value } => json!({"confirmed": value}),
            Self::Text { value } => json!({"text": value}),
        }
    }
}

/// APNs environment of a push target.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ApnsEnvironment {
    Development,
    Production,
}

impl ApnsEnvironment {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Development => "development",
            Self::Production => "production",
        }
    }
}

/// One `POST /v1/ops` body for the API Worker: a typed op with a
/// client-chosen idempotency key (a retry reuses the key; a new user action
/// makes a new key).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloudOp {
    pub op: String,
    pub params: Map<String, Value>,
    pub idempotency_key: String,
    pub origin: String,
}

impl CloudOp {
    /// Registers this install's APNs token on the user's account (one per install).
    pub fn register_push_target(
        token: &[u8],
        topic: &str,
        environment: ApnsEnvironment,
        device_name: &str,
        idempotency_key: &str,
    ) -> Self {
        let mut params = Map::new();
        params.insert("token".into(), Value::from(hex(token)));
        params.insert("topic".into(), Value::from(topic));
        params.insert("environment".into(), Value::from(environment.as_str()));
        params.insert("device_name".into(), Value::from(limited_utf16(device_name, 80)));
        Self { op: "push.target.register".into(), params, idempotency_key: idempotency_key.into(), origin: "cli".into() }
    }

    /// Removes the token (sign-out, notifications turned off).
    pub fn remove_push_target(token: &[u8], idempotency_key: &str) -> Self {
        let mut params = Map::new();
        params.insert("token".into(), Value::from(hex(token)));
        Self { op: "push.target.remove".into(), params, idempotency_key: idempotency_key.into(), origin: "cli".into() }
    }

    /// Answers a feed item from a banner action. The user acted: origin `user`.
    pub fn answer(item: &str, answer: &FeedAnswer, idempotency_key: &str) -> Self {
        let mut params = Map::new();
        params.insert("item".into(), Value::from(item));
        params.insert("answer".into(), answer.value());
        Self { op: "feed.answer".into(), params, idempotency_key: idempotency_key.into(), origin: "user".into() }
    }

    /// The request body object.
    pub fn body_value(&self) -> Value {
        json!({
            "op": self.op,
            "params": Value::Object(self.params.clone()),
            "idempotency_key": self.idempotency_key,
            "origin": self.origin,
        })
    }

    /// The JSON request body (keys sorted at every level).
    pub fn body(&self) -> String {
        self.body_value().to_string()
    }
}

/// Cuts `value` to at most `limit` UTF-16 code units on a character
/// (extended grapheme cluster) boundary.
pub fn limited_utf16(value: &str, limit: usize) -> String {
    let mut used = 0;
    let mut out = String::new();
    for grapheme in value.graphemes(true) {
        let units = grapheme.encode_utf16().count();
        if used + units > limit {
            break;
        }
        used += units;
        out.push_str(grapheme);
    }
    out
}

/// The API Worker's answer to `POST /v1/ops`. A domain refusal is HTTP 200
/// with `ok: false`, so the status code alone never means success.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CloudOpReply {
    Committed { replayed: bool },
    Rejected { code: String, retryable: bool },
}

impl CloudOpReply {
    /// Decodes the body; an unreadable body is a refusal (fail closed).
    pub fn decode(body: &[u8]) -> Self {
        let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(body) else {
            return Self::invalid();
        };
        match object.get("ok") {
            Some(Value::Bool(true)) => Self::Committed { replayed: json_true(object.get("replayed")) },
            Some(Value::Bool(false)) => {
                let error = object.get("error").and_then(Value::as_object);
                Self::Rejected {
                    code: error
                        .and_then(|error| error.get("code"))
                        .and_then(Value::as_str)
                        .unwrap_or("unknown")
                        .to_owned(),
                    retryable: json_true(error.and_then(|error| error.get("retryable"))),
                }
            }
            _ => Self::invalid(),
        }
    }

    fn invalid() -> Self {
        Self::Rejected { code: "invalid_reply".into(), retryable: true }
    }
}

/// The parts of a feed push the app reads: `cmux.feed_item`, `kind`, `type`
/// and `aps.category`. Mail pushes carry no content (only the item id).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FeedPushPayload {
    pub item: String,
    pub kind: Option<String>,
    pub r#type: Option<String>,
    pub category: Option<FeedPushCategory>,
}

impl FeedPushPayload {
    /// Owner item ids: a lowercase ASCII prefix, "_", then ASCII letters and
    /// digits (at most 80 bytes).
    pub fn is_item_id(value: &str) -> bool {
        if value.len() > 80 {
            return false;
        }
        let Some((prefix, rest)) = value.split_once('_') else { return false };
        !prefix.is_empty()
            && prefix.bytes().all(|byte| byte.is_ascii_lowercase())
            && !rest.is_empty()
            && rest.bytes().all(|byte| byte.is_ascii_alphanumeric())
    }

    /// Parses a notification's `userInfo`. None when it is not a feed push.
    pub fn from_user_info(user_info: &Value) -> Option<Self> {
        let cmux = user_info.get("cmux")?.as_object()?;
        let item = cmux.get("feed_item")?.as_str()?;
        if !Self::is_item_id(item) {
            return None;
        }
        let string = |value: Option<&Value>| value.and_then(Value::as_str).map(str::to_owned);
        Some(Self {
            item: item.to_owned(),
            kind: string(cmux.get("kind")),
            r#type: string(cmux.get("type")),
            category: user_info
                .get("aps")
                .and_then(|aps| aps.get("category"))
                .and_then(Value::as_str)
                .and_then(FeedPushCategory::from_id),
        })
    }
}

/// What the app does with one banner response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FeedPushResponse {
    /// Send this op (an answer from the banner), with an idempotency key
    /// stable per (item, action, answer), so a repeated delivery of the same
    /// tap is applied once by the owner.
    Send { item: String, answer: FeedAnswer, idempotency_key: String },
    /// Open the item in the app (a tap, Open on Mac, a choice, or an empty reply).
    Open { item: String },
    /// Not a feed push.
    Ignore,
}

impl FeedPushResponse {
    /// FNV-1a 64-bit of the UTF-8 bytes, hex without leading zeros: short
    /// and stable across launches.
    pub fn digest(text: &str) -> String {
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in text.bytes() {
            hash = (hash ^ u64::from(byte)).wrapping_mul(0x0000_0100_0000_01b3);
        }
        format!("{hash:x}")
    }

    pub fn new(action_identifier: &str, user_text: Option<&str>, user_info: &Value) -> Self {
        let Some(payload) = FeedPushPayload::from_user_info(user_info) else { return Self::Ignore };
        // Only an action the item's own category offers can answer it.
        let answer = FeedPushAction::from_id(action_identifier).and_then(|action| {
            let category = payload.category?;
            if !category.actions().contains(&action) {
                return None;
            }
            Some((action, FeedAnswer::for_action(action, user_text)?))
        });
        let Some((action, answer)) = answer else { return Self::Open { item: payload.item } };
        // Stable per (item, action, answer): a repeated delivery of one tap is
        // applied once; a different reply text is a different answer.
        let mut key = format!("feed-answer-{}-{}", payload.item, action.id());
        if let FeedAnswer::Text { value } = &answer {
            key.push('-');
            key.push_str(&Self::digest(value));
        }
        Self::Send { item: payload.item, answer, idempotency_key: key }
    }

    /// The op to send, for [`FeedPushResponse::Send`].
    pub fn op(&self) -> Option<CloudOp> {
        match self {
            Self::Send { item, answer, idempotency_key } => Some(CloudOp::answer(item, answer, idempotency_key)),
            _ => None,
        }
    }
}
