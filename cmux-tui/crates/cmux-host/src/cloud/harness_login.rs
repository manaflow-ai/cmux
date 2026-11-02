//! One sign-in per person for their Cloud machines (sans I/O): once any of a
//! person's machines has a Claude or Codex login of their own, it is kept for
//! that person server-side, and each new machine of theirs starts signed in.
//! The thread that does the reads, writes and requests is
//! `harness_login_thread`.
//!
//! What a machine does with each harness of [`HARNESSES`]:
//!
//! - boot: one `GET /v1/harness-credentials/machine`, and each saved login is
//!   written when the machine has none (or still has the one it last synced
//!   and the saved one is newer);
//! - detect: a valid login file whose fingerprint differs from the last
//!   synced one is sent once (`PUT .../machine/{harness}` with the last synced
//!   revision as its base);
//! - converge: a newer saved login is written only while the local file is
//!   unchanged since the last sync (a local change wins and is sent instead);
//! - revoked: the person deleted the saved login. The local file stays, the
//!   base does not move, and a `409 harness_credential.revoked` stops sending
//!   that harness until the person signs out here and signs in again.
//!
//! Logins are the person's own. A file holding the CodeRouter placeholder key
//! or a CodeRouter route token, an API-key-only Codex login, or anything that
//! does not parse as the harness's own sign-in is never sent.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::trajectory::{decode_base64, encode_base64};
use crate::json::JsonField;

/// The machine's own saved-login routes on the platform origin.
pub const MACHINE_PATH: &str = "/v1/harness-credentials/machine";
/// The last synced revision and fingerprint per harness (root, 0600). It
/// never holds a login.
pub const STATE_FILE: &str = "/var/lib/cmux/harness-login-sync.json";
pub const CONTENT_MAX_BYTES: usize = 65_536;
/// The 409 code for a saved login the person deleted after this machine's base.
pub const REVOKED_CODE: &str = "harness_credential.revoked";

/// The public placeholder key every CodeRouter guest sends
/// (`web/services/vms/images/devbox/agent-auth.sh`); the machine's edge swaps
/// in the team's credential. A file that holds it is CodeRouter's.
pub const CODEROUTER_PLACEHOLDER: &str = "cmux-vm-edge-placeholder";
/// CodeRouter route tokens (`crt_...`, `agent-config.sh`).
pub const CODEROUTER_TOKEN_PREFIX: &str = "crt_";

/// One harness whose login a machine keeps for its person.
#[derive(Clone, Copy, Debug)]
pub struct Harness {
    pub id: &'static str,
    /// The login file under the work user's home. The CLIs' own default
    /// homes only: the image sets `CLAUDE_CONFIG_DIR` / `CODEX_HOME` for
    /// agents only to point a shared machine's CodeRouter launch at an
    /// isolated home (`~/.config/cmux/claude-team`, `codex-team`), which is
    /// exactly what must never be sent.
    pub file: &'static str,
    validate: fn(&Value) -> Result<(), Refusal>,
}

impl Harness {
    /// Whether `bytes` are a login of this harness that may be sent.
    pub fn check(&self, bytes: &[u8]) -> Result<(), Refusal> {
        if bytes.is_empty() || bytes.len() > CONTENT_MAX_BYTES {
            return Err(Refusal::Size);
        }
        let value: Value = serde_json::from_slice(bytes).map_err(|_| Refusal::NotJson)?;
        if !value.is_object() {
            return Err(Refusal::NotJson);
        }
        if holds_coderouter(&value) {
            return Err(Refusal::CodeRouter);
        }
        (self.validate)(&value)
    }
}

/// The harnesses a machine keeps, keyed by a generic harness id. Others
/// (Gemini, OpenCode) are one row each when their sign-in is built.
pub const HARNESSES: &[Harness] = &[
    Harness { id: "claude", file: ".claude/.credentials.json", validate: claude_login },
    Harness { id: "codex", file: ".codex/auth.json", validate: codex_login },
];

pub fn harness(id: &str) -> Option<&'static Harness> {
    HARNESSES.iter().find(|h| h.id == id)
}

/// Why a local file is not sent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    Size,
    NotJson,
    /// No sign-in of the harness's own (no `claudeAiOauth`, no `tokens`).
    NoLogin,
    /// A Codex API key without a ChatGPT sign-in.
    ApiKeyOnly,
    /// The CodeRouter placeholder or a route token.
    CodeRouter,
}

/// Claude Code's `/login`: `claudeAiOauth` is a non-empty object.
fn claude_login(v: &Value) -> Result<(), Refusal> {
    match v.field("claudeAiOauth").as_object() {
        Some(o) if !o.is_empty() => Ok(()),
        _ => Err(Refusal::NoLogin),
    }
}

/// `codex login` with ChatGPT: a non-empty `tokens` object, and not an
/// `apikey` login.
fn codex_login(v: &Value) -> Result<(), Refusal> {
    let tokens = v.field("tokens").as_object().filter(|o| !o.is_empty());
    let api_key = v.field("OPENAI_API_KEY").as_str().is_some_and(|k| !k.is_empty());
    if *v.field("auth_mode") == "apikey" {
        return Err(Refusal::ApiKeyOnly);
    }
    match (tokens, api_key) {
        (Some(_), _) => Ok(()),
        (None, true) => Err(Refusal::ApiKeyOnly),
        (None, false) => Err(Refusal::NoLogin),
    }
}

/// Whether any string in `v` (a value or a key) holds the CodeRouter
/// placeholder or a route token anywhere in it (`"Bearer crt_..."`,
/// `"url=crt_..."`). It fails closed: an OAuth token that happens to contain
/// `crt_` is not sent either, and is sent once it rotates.
fn holds_coderouter(v: &Value) -> bool {
    let marked =
        |s: &str| s.contains(CODEROUTER_PLACEHOLDER) || s.contains(CODEROUTER_TOKEN_PREFIX);
    match v {
        Value::String(s) => marked(s),
        Value::Array(items) => items.iter().any(holds_coderouter),
        Value::Object(map) => map.iter().any(|(k, v)| marked(k) || holds_coderouter(v)),
        _ => false,
    }
}

/// `^[a-z][a-z0-9-]{0,31}$`.
pub fn harness_id_ok(id: &str) -> bool {
    let mut bytes = id.bytes();
    bytes.next().is_some_and(|b| b.is_ascii_lowercase())
        && id.len() <= 32
        && bytes.all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// sha256 hex of the file's bytes.
pub fn fingerprint(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

fn fingerprint_ok(fp: &str) -> bool {
    fp.len() == 64 && fp.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// What the machine sees of one harness's login file.
#[derive(Clone, PartialEq, Eq)]
pub enum Local {
    Absent,
    /// A login that may be sent.
    Login {
        bytes: Vec<u8>,
        fingerprint: String,
    },
    /// A file that is never sent (and never replaced by a saved login).
    Refused(Refusal),
    /// A read that failed other than "not found": nothing is decided.
    Unreadable,
}

impl std::fmt::Debug for Local {
    /// Never the login, never its fingerprint.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Local::Absent => write!(f, "Absent"),
            Local::Login { bytes, .. } => write!(f, "Login({} bytes)", bytes.len()),
            Local::Refused(why) => write!(f, "Refused({why:?})"),
            Local::Unreadable => write!(f, "Unreadable"),
        }
    }
}

impl Local {
    /// The local file's state from its bytes (`None`: not found).
    pub fn from_bytes(harness: &Harness, bytes: Option<Vec<u8>>) -> Local {
        let Some(bytes) = bytes else { return Local::Absent };
        match harness.check(&bytes) {
            Ok(()) => Local::Login { fingerprint: fingerprint(&bytes), bytes },
            Err(why) => Local::Refused(why),
        }
    }
}

/// One saved login as the server lists it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Saved {
    pub harness: String,
    pub revision: u64,
    pub active: Option<Active>,
}

#[derive(Clone, PartialEq, Eq)]
pub struct Active {
    pub fingerprint: String,
    pub content: Vec<u8>,
}

impl std::fmt::Debug for Active {
    /// Never the login, never its fingerprint.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Active({} bytes)", self.content.len())
    }
}

/// The answer of `GET /v1/harness-credentials/machine`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Listed {
    Saved(Vec<Saved>),
    /// 404: the deployment keeps no logins; ask again much later.
    Off,
    /// A network error, 429 or 5xx: retry with backoff.
    Retry(String),
    /// Any other answer: logged, retried later.
    Refused(String),
}

/// Reads a list answer. Entries for harnesses this machine does not keep, and
/// malformed entries, are skipped; an active entry counts only when its
/// content is 1..64 KiB and hashes to its fingerprint.
pub fn parse_list(status: u16, body: &Value) -> Listed {
    match status {
        200 => {}
        404 => return Listed::Off,
        429 | 500..=599 => return Listed::Retry(format!("HTTP {status}")),
        _ => return Listed::Refused(error_code(status, body)),
    }
    let Some(items) = body.field("credentials").as_array() else {
        return Listed::Refused("no credentials list".to_owned());
    };
    let mut out = Vec::new();
    for item in items {
        let id = item.field("harness").as_str().unwrap_or("");
        let Some(revision) = item.field("revision").as_u64() else { continue };
        if !harness_id_ok(id) || harness(id).is_none() {
            continue;
        }
        let active = match item.field("state").as_str() {
            Some("revoked") => None,
            Some("active") => {
                let fp = item.field("fingerprint").as_str().unwrap_or("");
                let Some(content) = item.field("contentBase64").as_str().and_then(decode_base64)
                else {
                    continue;
                };
                if !fingerprint_ok(fp)
                    || content.is_empty()
                    || content.len() > CONTENT_MAX_BYTES
                    || fingerprint(&content) != fp
                {
                    continue;
                }
                Some(Active { fingerprint: fp.to_owned(), content })
            }
            _ => continue,
        };
        out.push(Saved { harness: id.to_owned(), revision, active });
    }
    Listed::Saved(out)
}

fn error_code(status: u16, body: &Value) -> String {
    let code = body.field("error").field("code").as_str().or_else(|| body.field("code").as_str());
    code.map_or_else(|| format!("http.{status}"), str::to_owned)
}

/// The path of one harness's `PUT`.
pub fn put_path(harness: &str) -> String {
    format!("{MACHINE_PATH}/{harness}")
}

/// One login to send.
#[derive(Clone, PartialEq, Eq)]
pub struct Report {
    pub harness: String,
    pub fingerprint: String,
    pub base_revision: u64,
    pub content: Vec<u8>,
}

impl std::fmt::Debug for Report {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Report({} base={})", self.harness, self.base_revision)
    }
}

impl Report {
    pub fn body(&self) -> Value {
        json!({
            "contentBase64": encode_base64(&self.content),
            "fingerprint": self.fingerprint,
            "baseRevision": self.base_revision,
        })
    }
}

/// The answer of one `PUT`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Put {
    Saved {
        revision: u64,
        fingerprint: String,
    },
    /// 409 `harness_credential.revoked`.
    Revoked,
    /// 404: the deployment keeps no logins.
    Off,
    Retry(String),
    /// Any other final answer: this fingerprint is not sent again.
    Refused(String),
}

pub fn parse_put(status: u16, body: &Value) -> Put {
    match status {
        200 => {
            let revision = body.field("revision").as_u64();
            let fp = body.field("fingerprint").as_str().filter(|fp| fingerprint_ok(fp));
            match (revision, fp) {
                (Some(revision), Some(fp)) => Put::Saved { revision, fingerprint: fp.to_owned() },
                _ => Put::Refused("malformed answer".to_owned()),
            }
        }
        404 => Put::Off,
        409 if error_code(status, body) == REVOKED_CODE => Put::Revoked,
        429 | 500..=599 => Put::Retry(format!("HTTP {status}")),
        _ => Put::Refused(error_code(status, body)),
    }
}

/// What the machine remembers of one harness: no login, only hashes and
/// revisions.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HarnessSync {
    /// The base: the saved revision the local file last matched.
    #[serde(default)]
    pub revision: u64,
    /// The local file's fingerprint at the last sync; `None` is "no file".
    #[serde(default)]
    pub fingerprint: Option<String>,
    /// The newest saved revision seen, active or revoked.
    #[serde(default)]
    pub newest_seen: u64,
    /// The saved login was deleted at this revision (the local one stays).
    #[serde(default)]
    pub revoked_at: Option<u64>,
    /// A 409 said the saved login was deleted after the base: nothing is sent
    /// until the person signs out here and signs in again.
    #[serde(default)]
    pub stopped: bool,
    /// The last fingerprint sent with a final answer, so none is sent twice.
    #[serde(default)]
    pub sent: Option<String>,
}

/// All harnesses' sync state ([`STATE_FILE`]).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncState {
    #[serde(default)]
    pub harnesses: BTreeMap<String, HarnessSync>,
}

impl SyncState {
    /// The saved state, or a fresh one when there is none or it does not parse.
    pub fn parse(text: Option<&str>) -> SyncState {
        text.and_then(|t| serde_json::from_str(t).ok()).unwrap_or_default()
    }

    pub fn to_text(&self) -> String {
        format!("{}\n", serde_json::to_string(self).unwrap_or_else(|_| "{}".to_owned()))
    }

    pub fn of(&self, harness: &str) -> HarnessSync {
        self.harnesses.get(harness).cloned().unwrap_or_default()
    }

    fn entry(&mut self, harness: &str) -> &mut HarnessSync {
        self.harnesses.entry(harness.to_owned()).or_default()
    }

    /// The local file as seen now. A file that is gone after a sync (or after
    /// the saved login was deleted) is a sign-out: the base moves to the newest
    /// saved revision seen, so a fresh sign-in afterwards is sent and accepted.
    /// A login that differs from the last synced one comes back as a report,
    /// once per fingerprint. `true` in the second place: the state changed.
    pub fn observe(&mut self, harness: &str, local: &Local) -> (Option<Report>, bool) {
        let s = self.entry(harness);
        match local {
            Local::Absent => {
                if s.fingerprint.is_some() || s.stopped || s.revoked_at.is_some() {
                    s.revision = s.revision.max(s.newest_seen);
                    s.fingerprint = None;
                    s.stopped = false;
                    s.revoked_at = None;
                    s.sent = None;
                    return (None, true);
                }
                (None, false)
            }
            Local::Login { bytes, fingerprint } => {
                if s.stopped
                    || s.fingerprint.as_deref() == Some(fingerprint.as_str())
                    || s.sent.as_deref() == Some(fingerprint.as_str())
                {
                    return (None, false);
                }
                let report = Report {
                    harness: harness.to_owned(),
                    fingerprint: fingerprint.clone(),
                    base_revision: s.revision,
                    content: bytes.clone(),
                };
                (Some(report), false)
            }
            Local::Refused(_) | Local::Unreadable => (None, false),
        }
    }

    /// One saved login from a list. Returns the bytes to write when the local
    /// file is still what was last synced (no file counts when none was) and
    /// the saved one is newer. `true` in the second place: the state changed.
    pub fn saved(&mut self, local: &Local, saved: &Saved) -> (Option<Vec<u8>>, bool) {
        let s = self.entry(&saved.harness);
        let before = s.clone();
        s.newest_seen = s.newest_seen.max(saved.revision);
        let Some(active) = &saved.active else {
            if saved.revision > s.revision {
                s.revoked_at = Some(saved.revision);
            }
            let changed = *s != before;
            // A machine with no login when the saved one is deleted: its next
            // sign-in is fresh.
            let (_, gone) = if local == &Local::Absent {
                self.observe(&saved.harness, local)
            } else {
                (None, false)
            };
            return (None, changed || gone);
        };
        if saved.revision <= s.revision {
            return (None, *s != before);
        }
        match local {
            // Already the saved one (an answer that was lost): adopt it.
            Local::Login { fingerprint, .. } if *fingerprint == active.fingerprint => {
                adopt(s, saved.revision, &active.fingerprint);
                (None, true)
            }
            Local::Login { fingerprint, .. }
                if s.fingerprint.as_deref() == Some(fingerprint.as_str()) =>
            {
                (Some(active.content.clone()), *s != before)
            }
            Local::Absent if s.fingerprint.is_none() => {
                (Some(active.content.clone()), *s != before)
            }
            // A local change wins and is sent; a refused or unreadable file
            // is left as it is.
            _ => (None, *s != before),
        }
    }

    /// `content` of `saved` was written to the login file.
    pub fn written(&mut self, saved: &Saved) {
        if let Some(active) = &saved.active {
            adopt(self.entry(&saved.harness), saved.revision, &active.fingerprint);
        }
    }

    /// The answer to `report`.
    pub fn answered(&mut self, report: &Report, put: &Put) {
        let s = self.entry(&report.harness);
        match put {
            Put::Saved { revision, fingerprint } => {
                s.newest_seen = s.newest_seen.max(*revision);
                adopt(s, *revision, fingerprint);
                s.sent = Some(report.fingerprint.clone());
            }
            Put::Revoked => {
                s.stopped = true;
                s.sent = Some(report.fingerprint.clone());
            }
            Put::Refused(_) => s.sent = Some(report.fingerprint.clone()),
            Put::Off | Put::Retry(_) => {}
        }
    }
}

fn adopt(s: &mut HarnessSync, revision: u64, fingerprint: &str) {
    s.revision = revision;
    s.fingerprint = Some(fingerprint.to_owned());
    s.revoked_at = None;
    s.stopped = false;
}

/// Whether this machine is one person's own: `/etc/cmux/vm-kind` reads
/// `owner` and the machine was not enrolled as a team machine. Missing or
/// unreadable is shared (fail closed), as the image's
/// `cmux_agent_own_login_allowed` and acpmux's sign-in decide: on a team
/// machine every member's terminal runs as the same Unix user.
pub fn personal_machine(vm_kind: Option<&str>, team_enrolled: bool) -> bool {
    !team_enrolled && vm_kind.is_some_and(|k| k.trim() == "owner")
}
