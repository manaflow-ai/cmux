//! The approval question and its answer (docs/computer-use-approvals.md, "The
//! approval question"): the request object, its canonical JSON and digest, the
//! decision, and the rules that make an answer count.
//!
//! Canonical JSON (the same bytes in Swift and Rust): object keys sorted by
//! their UTF-8 bytes, no whitespace, strings escaped minimally (`\"`, `\\`,
//! `\b`, `\f`, `\n`, `\r`, `\t`, other controls below U+0020 as `\u00xx` with
//! lowercase hex; `/` and non-ASCII are written as they are), integers only (a
//! fraction or exponent is refused), `null` for an absent optional field. The
//! digest is the SHA-256, in 64 lowercase hex digits, of the canonical JSON of
//! the request without its `digest` field.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The request schema version.
pub const VERSION: u64 = 1;
/// How long the agent's call waits for an answer (2 minutes).
pub const WAIT_MS: u64 = 120_000;
/// How long the question stays answerable (10 minutes).
pub const ANSWERABLE_MS: u64 = 600_000;
/// What a deciding device signs (device hub approvals).
pub const SIGNATURE_DOMAIN: &str = "cmux-cu-approval-v1";

/// The canonical JSON text of `value`.
pub fn canonical(value: &Value) -> Result<String, String> {
    let mut out = String::new();
    write_canonical(value, &mut out)?;
    Ok(out)
}

fn write_canonical(value: &Value, out: &mut String) -> Result<(), String> {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Number(number) => {
            if let Some(integer) = number.as_i64() {
                out.push_str(&integer.to_string());
            } else if let Some(integer) = number.as_u64() {
                out.push_str(&integer.to_string());
            } else {
                return Err(format!("{number} is not an integer; canonical JSON has integers only"));
            }
        }
        Value::String(text) => write_string(text, out),
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_canonical(item, out)?;
            }
            out.push(']');
        }
        Value::Object(object) => {
            let mut keys: Vec<&String> = object.keys().collect();
            keys.sort_by(|left, right| left.as_bytes().cmp(right.as_bytes()));
            out.push('{');
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_string(key, out);
                out.push(':');
                write_canonical(&object[key], out)?;
            }
            out.push('}');
        }
    }
    Ok(())
}

fn write_string(text: &str, out: &mut String) {
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if (control as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", control as u32)),
            other => out.push(other),
        }
    }
    out.push('"');
}

/// The digest of a request object: SHA-256 of its canonical JSON without `digest`.
pub fn digest_of(request: &Value) -> Result<String, String> {
    let mut object = request.as_object().ok_or("the request is not an object")?.clone();
    object.remove("digest");
    Ok(crate::wire::sha256_hex(canonical(&Value::Object(object))?.as_bytes()))
}

/// The app an agent wants to use: the real target the worker resolved, never
/// the agent's words. Linux and Windows name it by executable path; macOS by
/// bundle id.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Target {
    pub bundle_id: Option<String>,
    pub executable: Option<String>,
    pub name: String,
}

impl Target {
    /// The key one question per session x app joins on, and saved lists match.
    pub fn key(&self) -> String {
        match (&self.bundle_id, &self.executable) {
            (Some(bundle), _) => format!("bundle:{bundle}"),
            (None, Some(executable)) => format!("exe:{executable}"),
            (None, None) => format!("name:{}", self.name),
        }
    }

    /// The `approved_apps` / manifest entry: `{"bundle_id"|"executable", "name"}`.
    pub fn app_entry(&self) -> Value {
        let mut entry = json!({"name": self.name});
        if let Some(bundle) = &self.bundle_id {
            entry["bundle_id"] = json!(bundle);
        }
        if let Some(executable) = &self.executable {
            entry["executable"] = json!(executable);
        }
        entry
    }

    /// An `approved_apps` / `revoke` entry back to a target.
    pub fn from_app_entry(entry: &Value) -> Option<Self> {
        let bundle_id = entry.get("bundle_id").and_then(Value::as_str).map(str::to_owned);
        let executable = entry.get("executable").and_then(Value::as_str).map(str::to_owned);
        if bundle_id.is_none() && executable.is_none() {
            return None;
        }
        let name = entry.get("name").and_then(Value::as_str).unwrap_or_default().to_owned();
        Some(Self { bundle_id, executable, name })
    }
}

/// One approval question (`request` in `app_approval`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalRequest {
    pub v: u64,
    pub nonce: String,
    pub client: String,
    pub machine: String,
    pub session: String,
    pub agent: String,
    pub workspace: String,
    pub target: Target,
    pub tool: String,
    pub risk: String,
    pub created_ms: u64,
    pub wait_until_ms: u64,
    pub answerable_until_ms: u64,
    pub digest: String,
}

/// The fields a worker fills in for a new question.
pub struct Question {
    pub client: String,
    pub machine: String,
    pub session: String,
    pub agent: String,
    pub workspace: String,
    pub target: Target,
    pub tool: String,
    pub risk: String,
}

impl ApprovalRequest {
    /// A new question at `now_ms` with a fresh nonce and its digest.
    pub fn new(question: Question, now_ms: u64) -> Result<Self, String> {
        let nonce = crate::wire::hex(&crate::wire::make_secret().map_err(|error| error.to_string())?[..16]);
        let mut request = Self {
            v: VERSION,
            nonce,
            client: question.client,
            machine: question.machine,
            session: question.session,
            agent: question.agent,
            workspace: question.workspace,
            target: question.target,
            tool: question.tool,
            risk: question.risk,
            created_ms: now_ms,
            wait_until_ms: now_ms + WAIT_MS,
            answerable_until_ms: now_ms + ANSWERABLE_MS,
            digest: String::new(),
        };
        request.digest = request.compute_digest()?;
        Ok(request)
    }

    pub fn to_value(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }

    pub fn compute_digest(&self) -> Result<String, String> {
        digest_of(&self.to_value())
    }

    /// A request read from the wire whose digest is its own and whose fields
    /// are well formed.
    pub fn parse_verified(value: &Value) -> Result<Self, String> {
        let request: Self = serde_json::from_value(value.clone()).map_err(|error| format!("bad request: {error}"))?;
        if request.v != VERSION {
            return Err(format!("unknown request version {}", request.v));
        }
        if request.nonce.len() != 32 || crate::wire::unhex(&request.nonce).is_none() {
            return Err("the nonce must be 32 hex digits".into());
        }
        if request.wait_until_ms < request.created_ms || request.answerable_until_ms < request.wait_until_ms {
            return Err("the request's deadlines are out of order".into());
        }
        if digest_of(value)? != request.digest {
            return Err("the request's digest is not its own".into());
        }
        Ok(request)
    }
}

/// The person's answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Decision {
    /// This call only.
    Once,
    /// The app joins this session's manifest.
    Session,
    /// The app joins the client's saved list and this session.
    Always,
    /// This call is refused with `approval_denied`.
    Deny,
}

impl Decision {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Once => "once",
            Self::Session => "session",
            Self::Always => "always",
            Self::Deny => "deny",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "once" => Some(Self::Once),
            "session" => Some(Self::Session),
            "always" => Some(Self::Always),
            "deny" => Some(Self::Deny),
            _ => None,
        }
    }

    /// Whether this decision lets the agent use the app.
    pub fn allows(self) -> bool {
        !matches!(self, Self::Deny)
    }
}

/// What a deciding device signs: `"cmux-cu-approval-v1\n<digest>\n<decision>"`.
pub fn signing_payload(digest: &str, decision: Decision) -> String {
    format!("{SIGNATURE_DOMAIN}\n{digest}\n{}", decision.as_str())
}

/// Why an answer does not count.
#[derive(Debug, PartialEq, Eq)]
pub enum AnswerRefusal {
    WrongDigest,
    AlreadyAnswered,
    Expired,
}

/// The state of one question on the asking side: an answer counts once, with
/// the request's own digest, until `answerable_until_ms`.
#[derive(Debug)]
pub struct Pending {
    pub request: ApprovalRequest,
    answered: Option<Decision>,
}

impl Pending {
    pub fn new(request: ApprovalRequest) -> Self {
        Self { request, answered: None }
    }

    pub fn answered(&self) -> Option<Decision> {
        self.answered
    }

    /// Takes an answer, or says why it does not count.
    pub fn accept(&mut self, decision: Decision, digest: &str, now_ms: u64) -> Result<Decision, AnswerRefusal> {
        if !crate::wire::same_secret(digest.as_bytes(), self.request.digest.as_bytes()) {
            return Err(AnswerRefusal::WrongDigest);
        }
        if self.answered.is_some() {
            return Err(AnswerRefusal::AlreadyAnswered);
        }
        if now_ms > self.request.answerable_until_ms {
            return Err(AnswerRefusal::Expired);
        }
        self.answered = Some(decision);
        Ok(decision)
    }
}

/// Milliseconds since the Unix epoch.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn question() -> Question {
        Question {
            client: "com.cmuxterm.app.debug.cu1".into(),
            machine: "box-1".into(),
            session: "s1".into(),
            agent: "Claude".into(),
            workspace: "api-server".into(),
            target: Target { bundle_id: None, executable: Some("/usr/bin/firefox".into()), name: "Firefox".into() },
            tool: "click".into(),
            risk: "R1".into(),
        }
    }

    #[test]
    fn canonical_sorts_keys_and_escapes_minimally() {
        let value = json!({"b": 1, "a": {"z": null, "y": [true, "x/\"\n\u{1}é"]}, "A": -2});
        assert_eq!(canonical(&value).unwrap(), r#"{"A":-2,"a":{"y":[true,"x/\"\n\u0001é"],"z":null},"b":1}"#);
        assert!(canonical(&json!({"f": 1.5})).is_err());
    }

    #[test]
    fn a_new_request_verifies_and_a_changed_field_does_not() {
        let request = ApprovalRequest::new(question(), 1_793_400_000_000).unwrap();
        assert_eq!(request.wait_until_ms, 1_793_400_120_000);
        assert_eq!(request.answerable_until_ms, 1_793_400_600_000);
        let value = request.to_value();
        assert_eq!(ApprovalRequest::parse_verified(&value).unwrap(), request);
        let mut changed = value.clone();
        changed["target"]["executable"] = json!("/usr/bin/xterm");
        assert!(ApprovalRequest::parse_verified(&changed).is_err());
    }

    #[test]
    fn an_answer_counts_once_with_its_digest_until_the_deadline() {
        let request = ApprovalRequest::new(question(), 1_000).unwrap();
        let digest = request.digest.clone();
        let mut pending = Pending::new(request.clone());
        assert_eq!(pending.accept(Decision::Session, "0".repeat(64).as_str(), 2_000), Err(AnswerRefusal::WrongDigest));
        assert_eq!(pending.accept(Decision::Session, &digest, 2_000), Ok(Decision::Session));
        assert_eq!(pending.accept(Decision::Deny, &digest, 2_000), Err(AnswerRefusal::AlreadyAnswered));
        let mut late = Pending::new(request);
        assert_eq!(late.accept(Decision::Once, &digest, 1_000 + ANSWERABLE_MS + 1), Err(AnswerRefusal::Expired));
    }

    #[test]
    fn the_signing_payload_names_digest_and_decision() {
        assert_eq!(signing_payload("ab", Decision::Always), "cmux-cu-approval-v1\nab\nalways");
    }
}
