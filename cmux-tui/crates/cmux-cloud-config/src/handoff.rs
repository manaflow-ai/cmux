//! The consent session handoff (`auth.session.request` on cmux NIGHTLY's control socket): a local cmux
//! build that starts signed out asks the running NIGHTLY of the same macOS user for a session, NIGHTLY
//! asks the person once, and on "Sign In" mints a NEW session for the same account (the web route
//! `POST /api/auth/session-handoff`, 7 days) and answers with it. NIGHTLY's own session never leaves it.
//!
//! Pure: the app reads the facts (the peer's uid and code signature from the socket's audit token, its
//! own sign-in, the alert's answer, the route's HTTP answer), asks here, and acts. Swift keeps the
//! sockets, the Security calls, the alert and the HTTP call. Served over the app FFI's JSON channel as
//! `cloud_handoff_*` (cmux-layout-reducer-ffi `cloud_handoff`).
//!
//! Who may ask: a process of this user (uid) whose code is validly signed, ad hoc included, with a cmux
//! main app identifier ([`is_cmux_app`]) equal to the bundle id it asks for, on NIGHTLY's own Stack
//! project. A same-user process can make an ad hoc app of any name, so nothing here is proof of who
//! asks: the person's answer to the alert is, and the alert names the app's path and its signer.
//!
//! - [`client_asks`]: whether a launching build asks NIGHTLY at all.
//! - [`request_answer`]: NIGHTLY's answer to one request before the person is asked: a refusal, or the
//!   alert to show.
//! - [`mint_request`], [`mint_answer`]: the web route's request and what its HTTP answer means.

use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::config::NIGHTLY_BUNDLE_ID;

/// The control socket method.
pub const METHOD: &str = "auth.session.request";
/// No answer to the consent alert in this long is "Don't Allow".
pub const CONSENT_TIMEOUT: Duration = Duration::from_secs(120);
/// The client's read bound: the consent wait plus the mint call.
pub const CLIENT_TIMEOUT: Duration = Duration::from_secs(150);
/// cmux's Apple Developer team.
pub const CMUX_TEAM_ID: &str = "7WLXT3NR37";
/// The web route that mints the recipient's session, under the build's sign-in web origin (cmux.com).
pub const MINT_PATH: &str = "/api/auth/session-handoff";
/// The longest tag a request may carry.
pub const MAX_TAG_LEN: usize = 64;
/// Longest label (a path, an origin, an email) shown in the alert or a refusal; longer ones are cut.
const MAX_LABEL_LEN: usize = 200;

/// Main cmux app bundle ids: the release channels, and DEV and staging builds with or without a tag of
/// `[a-z0-9]` segments. Never a helper (Computer Use, the bundled `cmux` CLI), so a script cannot run a
/// cmux tool to ask for a session. The same list `SessionHandoffPolicy.isCmuxApp` keeps in Swift for
/// `auth.session.handoff`.
pub fn is_cmux_app(identifier: &str) -> bool {
    const EXACT: [&str; 7] = [
        "com.cmuxterm.app",
        "com.cmuxterm.app.nightly",
        "com.cmuxterm.app.nightly.cmux-next",
        "com.cmuxterm.app.nightly.cmux-next-stable",
        "com.cmuxterm.app.rc",
        "com.cmuxterm.app.debug",
        "com.cmuxterm.app.staging",
    ];
    if EXACT.contains(&identifier) {
        return true;
    }
    for prefix in ["com.cmuxterm.app.debug.", "com.cmuxterm.app.staging."] {
        if let Some(rest) = identifier.strip_prefix(prefix) {
            return rest.split('.').all(|segment| {
                !segment.is_empty()
                    && segment.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
                    && segment != "cua"
                    && segment != "helper"
            });
        }
    }
    false
}

/// What a launching build knows when it decides whether to ask NIGHTLY.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ClientFacts {
    /// This build's bundle id.
    pub bundle_id: Option<String>,
    /// Whether this build signs in to the production account (only NIGHTLY's account is asked).
    pub is_production_auth: bool,
    /// Whether this build's own token store holds a session.
    pub signed_in: bool,
    /// Whether reading this build's own store failed (a locked Keychain): unknown, not signed out.
    pub store_read_failed: bool,
    /// A launch whose session lives in memory only (an explicit credentials file).
    pub memory_only: bool,
    /// A launch that signs in from credentials it was given (agents, CI).
    pub auto_login: bool,
    /// A capture fixture build, which must not inherit this machine's auth.
    pub capture_fixture: bool,
    /// Signed NEXT DEV, which adopts NIGHTLY's own session through `auth.session.handoff` instead.
    pub adopts_nightly_session: bool,
}

/// Whether a launching build asks NIGHTLY for a session: any cmux app that is not NIGHTLY, on the
/// production account, signed out (a store that could not be read is not signed out), and launched
/// neither with credentials, memory only, as a capture fixture, nor as signed NEXT DEV (whose
/// `auth.session.handoff` adoption stays as it is).
pub fn client_asks(facts: &ClientFacts) -> bool {
    let Some(bundle_id) = facts.bundle_id.as_deref() else { return false };
    is_cmux_app(bundle_id)
        && bundle_id != NIGHTLY_BUNDLE_ID
        && facts.is_production_auth
        && !facts.signed_in
        && !facts.store_read_failed
        && !facts.memory_only
        && !facts.auto_login
        && !facts.capture_fixture
        && !facts.adopts_nightly_session
}

/// The requesting process's code signature, read by NIGHTLY from the connection's audit token.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Signer {
    /// The signing identifier the code's valid signature carries (ad hoc included).
    pub identifier: String,
    /// The team, when the signature chains to an Apple certificate of one.
    pub team_id: Option<String>,
    /// The code's path on disk.
    pub path: Option<String>,
}

/// The request's `params`, as the client sent them.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RequestParams {
    pub bundle_id: Option<String>,
    pub tag: Option<String>,
    pub stack_project_id: Option<String>,
    pub api_origin: Option<String>,
}

/// NIGHTLY's own side.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct NightlyFacts {
    pub stack_project_id: String,
    pub api_origin: String,
    /// Whether NIGHTLY holds a session to mint from.
    pub signed_in: bool,
    /// The signed-in account's email, for the alert.
    pub account_email: Option<String>,
}

/// What NIGHTLY knows when one request arrives.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RequestFacts {
    /// Whether the peer's uid (`LOCAL_PEERCRED`) is NIGHTLY's own.
    pub peer_uid_matches: bool,
    /// The peer's signature, nil when the code has no valid one or the process is gone.
    pub signer: Option<Signer>,
    pub params: RequestParams,
    pub nightly: NightlyFacts,
    /// Whether another request's alert is up now (one at a time).
    pub consent_pending: bool,
}

/// A refusal answered on the socket: `{code, message}`. Never carries a token.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Refusal {
    pub code: String,
    pub message: String,
}

impl Refusal {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Refusal { code: code.to_owned(), message: message.into() }
    }
}

/// NIGHTLY's answer to a request before the person is asked.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Answer {
    /// Answer this refusal and close.
    Refuse { code: String, message: String },
    /// Show this alert; no answer in `timeout_seconds` is `deny`, answered with `declined`.
    AskConsent {
        title: String,
        message: String,
        allow: String,
        deny: String,
        timeout_seconds: u64,
        declined: Refusal,
        /// What NIGHTLY sends the web route on "Sign In" (`{"recipient":{"bundleId","tag"}}`).
        recipient: Recipient,
    },
}

impl From<Refusal> for Answer {
    fn from(refusal: Refusal) -> Self {
        Answer::Refuse { code: refusal.code, message: refusal.message }
    }
}

/// The recipient labels the web route records.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Recipient {
    pub bundle_id: String,
    pub tag: Option<String>,
}

/// The refusal of a person's "Don't Allow" or a timeout.
pub fn declined() -> Refusal {
    Refusal::new("forbidden", "declined")
}

/// NIGHTLY's answer to one `auth.session.request`, in this order: the peer's user, a readable
/// signature, a cmux main app, not NIGHTLY itself, the signature's identifier equal to the asked bundle
/// id, a well-formed tag, the same Stack project (else `backend_mismatch` naming both), NIGHTLY signed
/// in (else `not_found`), no other alert up (else `busy`); then the alert.
pub fn request_answer(facts: &RequestFacts) -> Answer {
    match check(facts) {
        Err(refusal) => refusal.into(),
        Ok((signer, tag)) => ask(facts, signer, tag),
    }
}

fn check(facts: &RequestFacts) -> Result<(&Signer, Option<String>), Refusal> {
    const REFUSED: &str = "session request refused";
    if !facts.peer_uid_matches {
        return Err(Refusal::new(
            "forbidden",
            format!("{REFUSED}: the asking process runs as another user"),
        ));
    }
    let Some(signer) = facts.signer.as_ref().filter(|s| !s.identifier.is_empty()) else {
        return Err(Refusal::new(
            "forbidden",
            format!("{REFUSED}: the asking process has no valid code signature"),
        ));
    };
    let identifier = label(&signer.identifier);
    if !is_cmux_app(&signer.identifier) {
        return Err(Refusal::new(
            "forbidden",
            format!("{REFUSED}: {identifier} is not a cmux app"),
        ));
    }
    if signer.identifier == NIGHTLY_BUNDLE_ID {
        return Err(Refusal::new(
            "forbidden",
            format!("{REFUSED}: cmux NIGHTLY does not ask itself"),
        ));
    }
    let asked = facts.params.bundle_id.as_deref().unwrap_or_default();
    if asked != signer.identifier {
        return Err(Refusal::new(
            "forbidden",
            format!("{REFUSED}: the asking app is signed as {identifier}, not {}", label(asked)),
        ));
    }
    let tag = match facts.params.tag.as_deref().map(str::trim).filter(|t| !t.is_empty()) {
        None => None,
        Some(tag) if valid_tag(tag) => Some(tag.to_owned()),
        Some(_) => {
            return Err(Refusal::new(
                "invalid_params",
                format!(
                    "{REFUSED}: the tag must be 1 to {MAX_TAG_LEN} letters, digits, '.', '_' or '-'"
                ),
            ));
        }
    };
    let asked_project = facts.params.stack_project_id.as_deref().unwrap_or_default();
    if asked_project.is_empty() || asked_project != facts.nightly.stack_project_id {
        return Err(Refusal::new(
            "backend_mismatch",
            format!(
                "{REFUSED}: cmux NIGHTLY signs in to {} (Stack project {}), and {identifier} to {} (Stack project {})",
                backend_label(&facts.nightly.api_origin),
                label(&facts.nightly.stack_project_id),
                backend_label(facts.params.api_origin.as_deref().unwrap_or_default()),
                if asked_project.is_empty() { "none".to_owned() } else { label(asked_project) },
            ),
        ));
    }
    if !facts.nightly.signed_in {
        return Err(Refusal::new("not_found", "cmux NIGHTLY is not signed in"));
    }
    if facts.consent_pending {
        return Err(Refusal::new(
            "busy",
            "another sign-in request is waiting for an answer in cmux NIGHTLY",
        ));
    }
    Ok((signer, tag))
}

fn ask(facts: &RequestFacts, signer: &Signer, tag: Option<String>) -> Answer {
    let name = app_name(&signer.identifier, tag.as_deref());
    let signed = match signer.team_id.as_deref() {
        Some(CMUX_TEAM_ID) => format!("Team cmux ({CMUX_TEAM_ID})"),
        Some(team) if !team.is_empty() => format!("Team {}", label(team)),
        _ => "ad hoc (any app on this Mac can be signed this way: check that the path is a build you made)"
            .to_owned(),
    };
    let path = signer
        .path
        .as_deref()
        .filter(|p| !p.is_empty())
        .map_or_else(|| "an unknown path".to_owned(), label);
    let account = facts
        .nightly
        .account_email
        .as_deref()
        .filter(|e| !e.is_empty())
        .map_or_else(|| "your cmux account".to_owned(), label);
    let message = format!(
        "{name} asks to sign in as {account}.\n\n\
         App: {path}\n\
         Bundle ID: {}\n\
         Signed: {signed}\n\
         Backend: {}\n\n\
         It gets its own new session for this account, valid for 7 days. Your session in cmux NIGHTLY is not shared. \
         No answer in {} seconds is Don't Allow.",
        label(&signer.identifier),
        backend_label(&facts.nightly.api_origin),
        CONSENT_TIMEOUT.as_secs(),
    );
    Answer::AskConsent {
        title: format!("Sign in {name}?"),
        message,
        allow: "Sign In".to_owned(),
        deny: "Don't Allow".to_owned(),
        timeout_seconds: CONSENT_TIMEOUT.as_secs(),
        declined: declined(),
        recipient: Recipient { bundle_id: signer.identifier.clone(), tag },
    }
}

/// The name the alert gives a cmux app: its channel, and its tag (the request's, else the bundle id's
/// suffix) for DEV and staging builds.
pub fn app_name(identifier: &str, tag: Option<&str>) -> String {
    let (channel, suffix) = match identifier {
        "com.cmuxterm.app" => ("cmux", None),
        "com.cmuxterm.app.rc" => ("cmux RC", None),
        "com.cmuxterm.app.nightly" => ("cmux NIGHTLY", None),
        "com.cmuxterm.app.nightly.cmux-next" => ("cmux NEXT NIGHTLY", None),
        "com.cmuxterm.app.nightly.cmux-next-stable" => ("cmux NEXT", None),
        "com.cmuxterm.app.debug" => ("cmux DEV", None),
        "com.cmuxterm.app.staging" => ("cmux STAGING", None),
        other => {
            if let Some(rest) = other.strip_prefix("com.cmuxterm.app.debug.") {
                ("cmux DEV", Some(rest))
            } else if let Some(rest) = other.strip_prefix("com.cmuxterm.app.staging.") {
                ("cmux STAGING", Some(rest))
            } else {
                ("cmux", None)
            }
        }
    };
    match tag.or(suffix) {
        Some(tag) if channel == "cmux DEV" || channel == "cmux STAGING" => {
            format!("{channel} {}", label(tag))
        }
        _ => channel.to_owned(),
    }
}

/// A tag the alert may show: 1 to [`MAX_TAG_LEN`] of `[A-Za-z0-9._-]`.
pub fn valid_tag(tag: &str) -> bool {
    !tag.is_empty()
        && tag.len() <= MAX_TAG_LEN
        && tag.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// A backend named by its origin's host (`cloud-api.cmux.dev`), or the text itself when it is no URL.
fn backend_label(origin: &str) -> String {
    let trimmed = origin.trim();
    if trimmed.is_empty() {
        return "an unnamed backend".to_owned();
    }
    let host = trimmed
        .split_once("://")
        .map_or(trimmed, |(_, rest)| rest)
        .split(['/', '?', '#'])
        .next()
        .unwrap_or_default();
    label(if host.is_empty() { trimmed } else { host })
}

/// `text` as one line the alert or a refusal can show: control characters dropped, at most
/// [`MAX_LABEL_LEN`] characters.
fn label(text: &str) -> String {
    let clean: String = text.chars().filter(|c| !c.is_control()).collect();
    if clean.chars().count() <= MAX_LABEL_LEN {
        return clean;
    }
    let mut cut: String = clean.chars().take(MAX_LABEL_LEN - 1).collect();
    cut.push('…');
    cut
}

/// The web route call NIGHTLY makes on "Sign In", with its own tokens in the native headers
/// (`Authorization: Bearer <access>`, `X-Stack-Refresh-Token: <refresh>`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MintRequest {
    pub url: String,
    pub method: String,
    /// The JSON body: `{"recipient":{"bundleId","tag"}}`.
    pub body: serde_json::Value,
}

/// The route call for `recipient` under `auth_web_origin` (the build's sign-in web origin).
pub fn mint_request(auth_web_origin: &str, recipient: &Recipient) -> MintRequest {
    MintRequest {
        url: format!("{}{MINT_PATH}", auth_web_origin.trim_end_matches('/')),
        method: "POST".to_owned(),
        body: serde_json::json!({ "recipient": recipient }),
    }
}

/// What the route's answer means: the socket's success result
/// (`{"access_token","refresh_token","expires_at"}`) or a refusal. The body is never echoed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MintAnswer {
    Result(serde_json::Value),
    Refusal(Refusal),
}

/// The route's 200 body.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Minted {
    access_token: String,
    refresh_token: String,
    expires_at: String,
}

/// The meaning of the route's `status` and `body`.
pub fn mint_answer(status: u16, body: &[u8]) -> MintAnswer {
    match status {
        200 => match serde_json::from_slice::<Minted>(body) {
            Ok(minted)
                if !minted.access_token.is_empty()
                    && !minted.refresh_token.is_empty()
                    && !minted.expires_at.is_empty() =>
            {
                MintAnswer::Result(serde_json::json!({
                    "access_token": minted.access_token,
                    "refresh_token": minted.refresh_token,
                    "expires_at": minted.expires_at,
                }))
            }
            _ => MintAnswer::Refusal(Refusal::new(
                "mint_failed",
                "the sign-in service's answer had no session in it",
            )),
        },
        401 | 403 => MintAnswer::Refusal(Refusal::new(
            "unauthorized",
            "the sign-in service did not accept cmux NIGHTLY's session: sign in again in cmux NIGHTLY",
        )),
        0 => MintAnswer::Refusal(Refusal::new("mint_failed", "the sign-in service did not answer")),
        status => MintAnswer::Refusal(Refusal::new(
            "mint_failed",
            format!("the sign-in service answered HTTP {status}"),
        )),
    }
}

#[cfg(test)]
#[path = "handoff_tests.rs"]
mod tests;
