//! Who a `cmux.protocol/2` request comes from (plans/cmux-next/
//! request-origin.md).
//!
//! The daemon derives one origin per request from its connection:
//! - `page` on every request of a connection whose `client-hello` role is
//!   `page_relay` (a page's JS reaches the daemon only through one);
//! - `user` only on a `verified_app` connection (role `main` and a proof;
//!   the proof is P8's install-key hello or the app's code signature,
//!   server/app_trust.rs);
//! - `app` on the in-process app supervisor router (`apps::routing`);
//! - `agent` otherwise, including every connection without a hello.
//!
//! A request's `origin` claim may only narrow that origin. On a page relay
//! the only claims are `{claim: "page"}` and `{claim: "user", confirmation}`,
//! where the confirmation is a single-use token the verified app minted for
//! exactly this operation, these params and this relay connection
//! (`origin.confirmation.issue`). Gate A2: `apps.install`, `apps.uninstall`,
//! `apps.enable`, `workspace.agent_folder.set`, `history.backups.purge`,
//! `history.visit.record`, `history.visit.title`, `history.visit.import`
//! and `history.trail.record` need origin `user`.

use std::time::{Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::resource::{ResourceError, ResourceOperation};

mod page_access;
pub(crate) mod page_router_table;
pub(crate) use page_access::page_forbidden;

/// Advertised by `identify` once client-hello step 1, the envelope `origin`
/// field and `origin.confirmation.issue` exist.
pub(crate) const ORIGIN_CLAIM_CAPABILITY: &str = "origin-claim-v1";
/// The operation that mints a confirmation token.
pub(crate) const ISSUE_OPERATION: &str = "origin.confirmation.issue";
/// How long an issued confirmation token is valid.
pub(crate) const CONFIRMATION_TTL_MS: u64 = 60_000;
/// Gate A2: operations that need origin `user`. The workspace's agent
/// folder decides where agents run, so only the user sets it
/// (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE). A history backup is the undo of
/// a history delete, so only the user deletes one before its retention
/// ends (RECOVERABLE-BY-DEFAULT). Page visits, their titles and the app's
/// older visit logs come from the hosting app, the verified app
/// connection: an agent cannot add a visit the person never made, nor
/// make the daemon read a file by path. The same holds for a step of the
/// location trail.
pub(crate) const USER_ONLY_OPERATIONS: [&str; 9] = [
    "apps.install",
    "apps.uninstall",
    "apps.enable",
    crate::state::agent_folder::OPERATION,
    crate::history_ops::PURGE_OPERATION,
    crate::history_ops::RECORD_OPERATION,
    crate::history_ops::TITLE_OPERATION,
    crate::history_ops::IMPORT_OPERATION,
    crate::history_ops::TRAIL_RECORD_OPERATION,
];
/// Unconsumed tokens one relay connection may hold; the oldest goes first.
const MAX_CONFIRMATIONS_PER_RELAY: usize = 16;
pub(crate) const ORIGIN_FORBIDDEN: &str = "origin.forbidden";
pub(crate) const NEEDS_VERIFIED_APP: &str = "needs a verified cmux app connection";

/// The origin of one request, least to most trusted.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RequestOrigin {
    Page,
    Agent,
    App,
    User,
}

impl RequestOrigin {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Page => "page",
            Self::Agent => "agent",
            Self::App => "app",
            Self::User => "user",
        }
    }
}

/// The role a connection fixes with `client-hello`; `Legacy` without one.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum HelloRole {
    #[default]
    Legacy,
    Main,
    PageRelay,
}

impl HelloRole {
    /// A role a client may declare (`main` or `page_relay`).
    pub(crate) fn declared(value: &str) -> Option<Self> {
        match value {
            "main" => Some(Self::Main),
            "page_relay" => Some(Self::PageRelay),
            _ => None,
        }
    }
}

/// `install_id`: 1 to 128 characters of `[A-Za-z0-9_-]`.
pub(crate) fn valid_install_id(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

/// The envelope's optional `origin` member.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OriginClaim {
    pub claim: RequestOrigin,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confirmation: Option<String>,
}

/// What the daemon knows about one connection's origin. Lives in the
/// connection's registry record, so it ends with the connection.
#[derive(Default)]
pub(crate) struct ConnectionOrigin {
    pub(crate) role: HelloRole,
    /// `token:<pid>.<pidversion>` of the socket peer, read at accept.
    /// The install-key proof never changes it (request-origin.md).
    pub(crate) peer_key: Option<String>,
    /// Kernel-bound local peer class fixed at accept. It never widens after
    /// the peer exits, changes session, or passes its connected descriptor.
    pub(crate) local_peer: LocalPeer,
    /// The socket peer at accept was this build's own bundled
    /// `cmux-mobile-host` (the executable beside the daemon's): a phone's
    /// spliced lane (`host-size-policy-v1`). Fixed at accept from the
    /// kernel's peer PID, never declared.
    pub(crate) mobile_host: bool,
    /// Role main plus a proof (P8: install-key hello on DEV builds, the
    /// app's code signature on signed builds; server/client_hello.rs).
    pub(crate) verified_app: bool,
    /// The install id the install-key proof (prover B) proved, if any.
    pub(crate) install_id: Option<String>,
    /// The page this connection serves (`page-router-v1`): set once by a
    /// page relay's `client-hello {page}`, or from a WebSocket handshake's
    /// page Origin (`cmux-page://cmux.<page>`). Its allow list decides its
    /// v2 operations (page_access.rs).
    pub(crate) page: Option<String>,
    /// Admitted with a page-bound credential (`page-credential {page}`): its
    /// `subscribe` hears only its page's conversation events.
    pub(crate) scoped_page: bool,
    /// Tokens issued for this connection as a relay (page relays only).
    confirmations: Vec<Confirmation>,
}

struct Confirmation {
    token: String,
    /// The operation's wire name: a catalog operation, or a routed one
    /// (page-router-v1 namespaces).
    operation: String,
    params_sha256: String,
    /// Monotonic deadline ([`OriginClock::monotonic_ms`]).
    deadline_ms: u64,
}

impl ConnectionOrigin {
    pub(crate) fn derive(&self) -> RequestOrigin {
        match self.role {
            HelloRole::PageRelay => RequestOrigin::Page,
            HelloRole::Main if self.verified_app => RequestOrigin::User,
            HelloRole::Main | HelloRole::Legacy => RequestOrigin::Agent,
        }
    }

    /// The connection's base actor (identity.md section 3): the verified app
    /// is `frontend`, any other local connection starts as the local `user`.
    /// The server refines that user to a terminal from kernel peer ancestry.
    pub(crate) fn actor(&self) -> crate::workspace_registry::Actor {
        use crate::workspace_registry::Actor;
        match self.derive() {
            RequestOrigin::User => {
                let install_id =
                    self.install_id.clone().unwrap_or_else(|| "signed_app".to_string());
                Actor::Frontend { install_id }
            }
            RequestOrigin::Agent => match &self.local_peer {
                LocalPeer::Terminal(id) => Actor::Terminal { id: id.clone() },
                LocalPeer::Unknown | LocalPeer::Other => Actor::local_user(),
            },
            RequestOrigin::App | RequestOrigin::Page => Actor::local_user(),
        }
    }

    /// Stores a token minted for this relay connection. `deadline_ms` and
    /// `now_ms` are monotonic readings.
    #[cfg(test)]
    pub(crate) fn store_confirmation(
        &mut self,
        token: String,
        operation: ResourceOperation,
        params_sha256: String,
        deadline_ms: u64,
        now_ms: u64,
    ) {
        let operation = operation.wire_name().to_owned();
        self.store_named_confirmation(token, operation, params_sha256, deadline_ms, now_ms);
    }

    /// [`Self::store_confirmation`] for an operation by wire name (catalog
    /// or routed).
    pub(crate) fn store_named_confirmation(
        &mut self,
        token: String,
        operation: String,
        params_sha256: String,
        deadline_ms: u64,
        now_ms: u64,
    ) {
        self.confirmations.retain(|confirmation| confirmation.deadline_ms > now_ms);
        if self.confirmations.len() >= MAX_CONFIRMATIONS_PER_RELAY {
            self.confirmations.remove(0);
        }
        self.confirmations.push(Confirmation { token, operation, params_sha256, deadline_ms });
    }

    /// Consumes `token` whatever the outcome (single use), and says whether
    /// it was issued for exactly this operation and params and is live.
    fn consume_confirmation(
        &mut self,
        token: &str,
        operation: &str,
        params: &Value,
        now_ms: u64,
    ) -> bool {
        let Some(index) = self
            .confirmations
            .iter()
            .position(|confirmation| cmux_local_auth::tokens_match(token, &confirmation.token))
        else {
            return false;
        };
        let confirmation = self.confirmations.remove(index);
        confirmation.deadline_ms > now_ms
            && confirmation.operation == operation
            && cmux_local_auth::tokens_match(&params_sha256(params), &confirmation.params_sha256)
    }

    /// The origin of one request on this connection: the derived origin,
    /// narrowed by `claim`, then checked against the operation's needs.
    /// `operation`, `params` and `claim` come from the one typed parse of
    /// the request (`resource_router::parse_resource_line`).
    pub(crate) fn request_origin(
        &mut self,
        operation: ResourceOperation,
        params: &Value,
        claim: Option<&OriginClaim>,
        now_ms: u64,
    ) -> Result<RequestOrigin, ResourceError> {
        let origin = self.narrow(operation.wire_name(), params, claim, now_ms)?;
        if self.role == HelloRole::PageRelay
            && operation == ResourceOperation::OriginConfirmationIssue
        {
            return Err(forbidden(
                "a page relay connection cannot issue confirmations",
                json!({"derived": RequestOrigin::Page.wire_name()}),
            ));
        }
        // Default deny for pages (page_access.rs), whatever a page relay
        // claims: a confirmed-user result still reaches page JS. A page
        // connection gets its own page's allow list, whatever its role.
        let refusal = match self.page.as_deref() {
            Some(page) => page_access::page_refusal(page, operation, params, origin),
            None if self.role == HelloRole::PageRelay || origin == RequestOrigin::Page => {
                page_access::refusal(operation, params)
            }
            None => None,
        };
        if let Some(refusal) = refusal {
            return Err(refusal);
        }
        // The token makes a later page call the user's, so the request
        // that mints one must itself be the user's after narrowing: a claim
        // the verified app adds (agent, app) is obeyed here.
        if operation == ResourceOperation::OriginConfirmationIssue && origin != RequestOrigin::User
        {
            return Err(needs_user(origin));
        }
        require_origin(operation.wire_name(), origin)?;
        Ok(origin)
    }

    /// The derived origin narrowed by `claim` (a page relay's confirmed
    /// `user` claim consumes its token for `operation`, by wire name).
    fn narrow(
        &mut self,
        operation: &str,
        params: &Value,
        claim: Option<&OriginClaim>,
        now_ms: u64,
    ) -> Result<RequestOrigin, ResourceError> {
        let derived = self.derive();
        let origin = match (self.role, claim) {
            (_, None) => derived,
            (
                HelloRole::PageRelay,
                Some(OriginClaim { claim: RequestOrigin::Page, confirmation: None }),
            ) => RequestOrigin::Page,
            (
                HelloRole::PageRelay,
                Some(OriginClaim { claim: RequestOrigin::User, confirmation: Some(token) }),
            ) => {
                if !self.consume_confirmation(token, operation, params, now_ms) {
                    return Err(forbidden(
                        "the confirmation is not valid for this request",
                        json!({"derived": derived.wire_name(), "claim": "user", "reason": "confirmation_invalid"}),
                    ));
                }
                RequestOrigin::User
            }
            (
                HelloRole::Main | HelloRole::Legacy,
                Some(OriginClaim { claim, confirmation: None }),
            ) if *claim <= derived => *claim,
            (_, Some(claim)) => {
                return Err(forbidden(
                    "the origin claim may only narrow the connection's origin",
                    json!({"derived": derived.wire_name(), "claim": claim.claim.wire_name()}),
                ));
            }
        };
        Ok(origin)
    }

    /// The origin of one routed v2 request (a page-router-v1 namespace
    /// operation, not a catalog one): the claim rules of
    /// [`Self::request_origin`], then the page's allow list for a page
    /// connection, default deny for a page relay without a page, and origin
    /// `user` for a mutation (Gate A2).
    pub(crate) fn routed_origin(
        &mut self,
        operation: &str,
        mutation: bool,
        params: &Value,
        claim: Option<&OriginClaim>,
        now_ms: u64,
    ) -> Result<RequestOrigin, ResourceError> {
        use page_router_table::PageGrant;
        let origin = self.narrow(operation, params, claim, now_ms)?;
        if let Some(page) = self.page.as_deref() {
            let grant = page_router_table::grant(page, operation);
            let confirmed = matches!(grant, PageGrant::Gesture | PageGrant::Confirm)
                && origin == RequestOrigin::User;
            if let Some(reason) = page_router_table::missing_confirmation_reason(grant)
                && !confirmed
            {
                return Err(page_forbidden(page, operation, reason, origin));
            }
        } else if self.role == HelloRole::PageRelay || origin == RequestOrigin::Page {
            return Err(forbidden(
                "a page may call only allow-listed operations",
                json!({"required": RequestOrigin::Agent.wire_name(), "derived": origin.wire_name()}),
            ));
        }
        if mutation && origin != RequestOrigin::User {
            return Err(needs_user(origin));
        }
        Ok(origin)
    }
}

/// The local socket peer identity captured once while the accepted process is live.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) enum LocalPeer {
    /// No stable peer PID/session/executable evidence. Owner-only ops fail closed.
    #[default]
    Unknown,
    /// A process in one live cmux terminal session.
    Terminal(String),
    /// A resolved same-user process outside cmux terminals.
    Other,
}

/// Gate A2 for one operation and origin.
pub(crate) fn require_origin(operation: &str, origin: RequestOrigin) -> Result<(), ResourceError> {
    if USER_ONLY_OPERATIONS.contains(&operation) && origin != RequestOrigin::User {
        return Err(needs_user(origin));
    }
    Ok(())
}

/// The A2 refusal: `{required: "user", derived}`.
pub(crate) fn needs_user(derived: RequestOrigin) -> ResourceError {
    forbidden(NEEDS_VERIFIED_APP, json!({"required": "user", "derived": derived.wire_name()}))
}

pub(crate) fn forbidden(message: &str, details: Value) -> ResourceError {
    ResourceError::new(ORIGIN_FORBIDDEN, message, details, false)
}

/// A fresh confirmation token: 32 random bytes, base64url without padding.
pub(crate) fn mint_token() -> Result<String, ResourceError> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|error| {
        ResourceError::operation_failed(
            ISSUE_OPERATION,
            "could not mint a confirmation token",
            json!({"error": error.to_string()}),
        )
    })?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}

/// 64 lowercase hex digits.
pub(crate) fn valid_sha256_hex(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// SHA-256 (lowercase hex) of `params` in canonical JSON.
pub(crate) fn params_sha256(params: &Value) -> String {
    let mut canonical = String::new();
    write_canonical_json(params, &mut canonical);
    Sha256::digest(canonical.as_bytes()).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Canonical JSON: object keys sorted by code point, no whitespace, strings
/// and numbers as serde_json writes them (no `/` escape, UTF-8 kept).
pub(crate) fn write_canonical_json(value: &Value, out: &mut String) {
    match value {
        Value::Object(map) => {
            let mut keys = map.keys().collect::<Vec<_>>();
            keys.sort();
            out.push('{');
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(key.clone()).to_string());
                out.push(':');
                if let Some(member) = map.get(key) {
                    write_canonical_json(member, out);
                }
            }
            out.push('}');
        }
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_canonical_json(item, out);
            }
            out.push(']');
        }
        scalar => out.push_str(&scalar.to_string()),
    }
}

/// Time for confirmation tokens. Validity uses only the monotonic reading
/// (milliseconds since the clock started, built on `Instant`), so a wall
/// clock step neither extends nor cuts the TTL; the wall reading only
/// labels `expires_at` for display. Tests freeze it and move each reading.
pub(crate) struct OriginClock {
    base: Instant,
    #[cfg(test)]
    manual: std::sync::Mutex<Option<ManualTime>>,
}

#[cfg(test)]
#[derive(Clone, Copy)]
struct ManualTime {
    monotonic_ms: u64,
    wall_ms: u64,
}

impl Default for OriginClock {
    fn default() -> Self {
        Self {
            base: Instant::now(),
            #[cfg(test)]
            manual: std::sync::Mutex::new(None),
        }
    }
}

impl OriginClock {
    /// Monotonic milliseconds since this clock started.
    pub(crate) fn monotonic_ms(&self) -> u64 {
        #[cfg(test)]
        if let Some(time) = self.manual_time() {
            return time.monotonic_ms;
        }
        self.real_monotonic_ms()
    }

    /// Wall-clock milliseconds since the Unix epoch (display only).
    pub(crate) fn wall_ms(&self) -> u64 {
        #[cfg(test)]
        if let Some(time) = self.manual_time() {
            return time.wall_ms;
        }
        real_wall_ms()
    }

    fn real_monotonic_ms(&self) -> u64 {
        u64::try_from(self.base.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    #[cfg(test)]
    fn manual_time(&self) -> Option<ManualTime> {
        *self.manual.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Freezes the clock at its current readings (first call), then
    /// applies `change`.
    #[cfg(test)]
    fn change_manual(&self, change: impl FnOnce(&mut ManualTime)) {
        let mut manual = self.manual.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut time = manual.unwrap_or(ManualTime {
            monotonic_ms: self.real_monotonic_ms(),
            wall_ms: real_wall_ms(),
        });
        change(&mut time);
        *manual = Some(time);
    }

    /// Moves both readings forward by `ms` (time passes).
    #[cfg(test)]
    pub(crate) fn advance(&self, ms: u64) {
        self.change_manual(|time| {
            time.monotonic_ms = time.monotonic_ms.saturating_add(ms);
            time.wall_ms = time.wall_ms.saturating_add(ms);
        });
    }

    /// Moves only the wall reading (an NTP step or a user change).
    #[cfg(test)]
    pub(crate) fn jump_wall(&self, delta_ms: i64) {
        self.change_manual(|time| time.wall_ms = time.wall_ms.saturating_add_signed(delta_ms));
    }
}

fn real_wall_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
}

#[cfg(test)]
#[path = "request_origin_tests.rs"]
mod tests;
