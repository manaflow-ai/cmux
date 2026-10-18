//! Only the person-facing app may allow (cx-1l61).
//!
//! An agent runs as the user, so it can run the acpmux CLI or open the unix
//! socket itself. Without this rule it could allow its own permission prompt
//! or turn its own session to approve-all. The daemon cannot see who sits at
//! a client, so the app proves it with a per-launch person key:
//!
//! - The app makes 32 random bytes at each launch and keeps them in memory
//!   only: never in an environment variable, argv, a file, a log, or a child
//!   process.
//! - The daemon learns the key from the app only, on one of two paths that
//!   an agent cannot take:
//!   - a Team-signed daemon (Release): `_acpmux/person_enroll` on the unix
//!     socket, from a peer whose audit token is the signed app that contains
//!     this binary (`cmux_link::app_caller`, prover A of
//!     plans/cmux-next/identity.md). A new app launch enrolls its new key.
//!   - an unsigned daemon (DEV, tests): `--person-key-fd` at spawn only. The
//!     daemon reads the key, closes the descriptor and never takes another
//!     key while it runs. A signed daemon ignores the descriptor (a same-uid
//!     process could restart the daemon with its own key).
//! - The key never crosses a socket after enrollment (cx-fcaq): whatever
//!   listens on the socket path could be a squatter. Each unix socket or
//!   proven LocalApp connection gets a random nonce. Its FIRST request must
//!   be `initialize`, whose result carries `_meta.acpmux.personChallenge`
//!   `{nonce, connection}`. Its SECOND request may be
//!   `_acpmux/person_prove {proof}` with `proof` = lowercase hex
//!   HMAC-SHA256(key, "acpmux-person-v1" 0 transport 0 nonce 0 connection
//!   id), where transport is `unix` or `app` as the client knows it
//!   ([`person_proof`]), compared in constant time. A match makes the
//!   connection the person for its whole life. The proof is bound to the
//!   nonce and the connection id, so a proof captured anywhere else (a
//!   squatter that relayed the challenge, another connection) proves
//!   nothing. A `personKey` field is stripped and never read. Web and Peer
//!   connections are never the person.
//! - The app checks the server peer before it enrolls or proves (the code
//!   signature of the bundled acpmux, or in DEV its executable path), and
//!   makes a new key for each daemon it starts or enrolls, so a key from a
//!   daemon that went away proves nothing to the next one.
//!
//! - A relayed allow (cx-0q7o, #13742 D16): a prompt can be answered from
//!   another machine's app through a connection that is never the person (a
//!   peer daemon, the remote cmux-tui server). Each pending prompt has a new
//!   random `decisionNonce` and each daemon run a random `personInstance`;
//!   both are in `_acpmux/permission_pending`. `permission_respond` with an
//!   allow then counts only with `_meta.acpmux.decisionNonce` and
//!   `personDecision` = lowercase hex HMAC-SHA256(key,
//!   "acpmux-person-decision-v1" 0 instance 0 session 0 permission 0 option
//!   0 nonce) ([`decision_proof`]), for the prompt that is pending with that
//!   nonce. A nonce counts once: the answer that counts spends it under
//!   the prompt's lock, together with taking the prompt (so a refused answer
//!   spends nothing, and of two racing answers one counts), and a bounded
//!   store of spent nonces ([`SPENT_LIMIT`] entries, [`SPENT_TTL`]) refuses
//!   it again. A prompt the next daemon adopts gets a new nonce under the
//!   new run (`permission_reissued`, also a `permission_pending`). A restarted daemon has a new instance, so an old proof proves
//!   nothing. A proof never covers question answers, a group's allow, a
//!   policy, a rule or a mode: those widen and stay the person's own.
//!   A keyed daemon is not dumpable (`daemon.rs`), so an agent it starts
//!   cannot read the key from its memory.
//! - Through a peer (slice 2a, 2b): a daemon that only mirrors a peer's
//!   session cannot check a proof made with the peer's key, so it forwards
//!   every answer for that session (allow, deny, cancel) and the peer
//!   decides; a forwarded answer counts hops (`server/peer_forward.rs`). `answeredBy` from a
//!   connection that is not the person counts only together with a proof
//!   that counts. `initialize` and `_acpmux/status` name the run
//!   (`personInstance`); status says whether it holds a key (`personKey`).
//!   `_acpmux/person_holds {nonce}` (slice 2c, unix socket only, 8 per
//!   connection) answers HMAC(key, "acpmux-person-holds-v1" 0 instance 0
//!   nonce), so the app can check that a daemon it started holds ITS key: a
//!   `person_prove` reply alone proves nothing (whatever answers on the
//!   socket path can say `person: true`).
//!   The key reaches a daemon that `acpmux daemon start --person-key-fd 0`
//!   launches over a socket pair, only after the daemon said it is not
//!   dumpable (`daemon.rs`).
//!
//! [`Hub::person_check`] is the one check, run for every request before it
//! is handled or forwarded. Without the person, a client may read prompts and
//! deny or cancel them, and may narrow (ask, deny-all, deny rules, asking
//! modes). It may never allow (a permission answer, a question's answer, a
//! group's allow) and never widen what runs without asking (a policy other
//! than ask or deny-all for a session, the daemon default, a family default
//! or a preset; a rule that could auto-approve; a mode the reviewed asking
//! table does not list; a spawn env). Such a request gets
//! [`REASON`] and changes nothing: a prompt stays pending.
//!
//! (c) A pending prompt reaches every app that sees the session: a peer's
//! `_acpmux/permission_pending` reaches the watchers of this daemon that
//! did not attach the session (`hub/peers.rs`), with the peer's
//! `decisionNonce` and `personInstance`; an answer still goes to the peer,
//! which counts an allow only with its own person's proof (above). The
//! proof covers the prompt's ids, not the text the app shows, so a peer
//! that re-sends a real prompt with other text could get the person's
//! allow of that text counted for the real one. A peer's prompt is
//! therefore relayed only for a session that peer listed as its own and
//! that is not this daemon's, in the run the peer named at its handshake,
//! which is neither this daemon's run nor one another peer named; and only
//! to unix socket and app watchers, never to a Web client or on to
//! another peer daemon. The app holds the key of the daemons it enrolled,
//! so this daemon's prompts (whose proofs it can make) never arrive with
//! a peer's text. Binding the proof to the prompt's text would need the
//! app to hash what it shows; not done.
//! Residual: the run a peer names at its handshake is a claim. A peer can
//! name a third daemon's run (one the app enrolled directly, say over
//! ssh) and re-send that daemon's prompt with other text; this daemon
//! cannot tell. The app has to refuse to prove a `via: "peer"` prompt whose
//! `personInstance` is a daemon it enrolled directly (an app follow-up).
//!
//! Also without the person: no rules change under a session policy that
//! does not ask (a rule is then what keeps a tool asking), no removal of a
//! stored family-default or preset policy, no write of the `handoffKey`
//! tag (a handoff adopts the session it names, and never wider: see
//! `handoff/ops.rs`), and no session method acpmux does not handle itself
//! (the harness catch-all, [`harness_forward_check`]).
//!
//! Residual risks (not covered here):
//! - Remote approvals (cx-0q7o) stop agents and scripts that cannot write the
//!   remote user's home folder or cmux-tui binary. An agent that runs as the
//!   same user and can write those files can capture the key on the next
//!   restart. Such an agent already has that user's power on that host, and
//!   the key is valid only for that one daemon run.
//! - Cloud machines (cx-0q7o slice 2d): the key reaches the daemon through
//!   the cmux backend and the VM provider (trusted: they already run any
//!   command as root there), only as the stdin of `daemon start
//!   --person-key-fd 0`. Agents on a Cloud machine have passwordless sudo,
//!   so an agent that gets one allowed shell command can read the key from
//!   this daemon's memory at any time (not dumpable does not stop root). The
//!   key then counts only for that one daemon run on that one machine.
//!   See docs/security/threat-model.md "Remote approvals (acpmux person key)".
//! - Same-uid file writes: an agent that edits config.json, a profile file
//!   or the store directly. That needs an OS boundary between the agent and
//!   the user's files.
//! - `_acpmux/harness/add` (a new harness profile), `_acpmux/defaults`
//!   `prefer` and a preset's `harness` (which profile, and so which profile
//!   default policy, a new session gets), a preset's `args`,
//!   `acp.trust.set`, `_acpmux/harness_enable` and `_acpmux/import` stay
//!   open to the unix socket.
//! - DEV only: a same-uid process that starts the unsigned daemon before the
//!   app does gives it its own spawn key; the app then hands that daemon off
//!   (when its agents run under agent hosts), but the process held the
//!   person until then.

use super::*;

/// The old place of the key in `initialize` (`_meta.acpmux`): stripped, never read.
pub const KEY_FIELD: &str = "personKey";
/// The challenge in a local connection's `initialize` result (`_meta.acpmux`).
pub const CHALLENGE_FIELD: &str = "personChallenge";
/// `error.data.reason` of a `_acpmux/person_prove` that proves nothing.
pub const PROOF_REFUSED: &str = "person.proof_refused";
/// `error.data.reason` of a refused allow or grant.
pub const REASON: &str = "permission.person_required";
/// `error.data.reason` of `_acpmux/person_enroll` on a daemon that cannot
/// verify the app's signature and has another key (an unsigned build that
/// this app launch did not start).
pub const ENROLL_UNAVAILABLE: &str = "person.enroll_unavailable";
/// `error.data.reason` of `_acpmux/person_enroll` from a client that is not
/// the signed app.
pub const ENROLL_REFUSED: &str = "person.enroll_refused";

/// Where `_acpmux/permission_respond` carries who answered for the person
/// (`_meta.acpmux.answeredBy`), and the outcome slot that carries it to the
/// `permission_decision` record (removed before the agent gets the outcome).
pub const ANSWERED_BY_FIELD: &str = "answeredBy";
pub(crate) const ANSWERED_BY_SLOT: &str = "_acpmuxAnsweredBy";

/// `answeredBy` (cx-aocz): the person's own app answering on behalf of a
/// device the person answered on, `{device, feedItem}`. Only the person's
/// connection may say so (an audit record, never a grant). Each field: 1 to
/// 128 characters of `[A-Za-z0-9_.:-]`; no other field.
pub fn answered_by(params: &Value) -> Result<Option<Value>, RpcError> {
    let Some(v) =
        params.pointer(&format!("/_meta/acpmux/{ANSWERED_BY_FIELD}")).filter(|v| !v.is_null())
    else {
        return Ok(None);
    };
    let bad = || {
        RpcError::invalid_params(
            "answeredBy must be {device, feedItem}: 1 to 128 of [A-Za-z0-9_.:-] each",
        )
    };
    let o = v.as_object().ok_or_else(bad)?;
    let ok = |s: &str| {
        (1..=128).contains(&s.len())
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
    };
    if o.len() != 2 {
        return Err(bad());
    }
    for key in ["device", "feedItem"] {
        if !o.get(key).and_then(Value::as_str).is_some_and(ok) {
            return Err(bad());
        }
    }
    Ok(Some(v.clone()))
}

/// The only policies a client without the person may set: every tool call
/// asks, or nothing is approved. The exact names; aliases and unknown values
/// are refused. Shared with the remote guard's Web rule.
pub(crate) const ASKING_POLICIES: &[&str] = &["ask", "deny-all"];

/// `_meta.acpmux` field of a relayed allow: the prompt's decision nonce.
pub const DECISION_NONCE_FIELD: &str = "decisionNonce";
/// `_meta.acpmux` field of a relayed allow: the person's decision proof.
pub const DECISION_FIELD: &str = "personDecision";
/// `error.data.reason` of `_acpmux/person_holds` on a daemon without a key.
pub const NO_KEY: &str = "person.no_key";
/// `error.data.reason` of `_acpmux/person_holds` past its per-connection limit.
pub const HOLDS_LIMIT: &str = "person.holds_limit";
/// `_acpmux/person_holds` answers per connection. Not a security bound: the
/// answers count only in their own HMAC domain.
pub const HOLDS_PER_CONNECTION: u32 = 8;

/// At most this many spent decision nonces are kept.
pub const SPENT_LIMIT: usize = 4096;
/// A spent decision nonce is kept this long.
pub const SPENT_TTL: std::time::Duration = std::time::Duration::from_secs(24 * 60 * 60);

/// Who answers a prompt, for the authoritative check in
/// `Hub::respond_permission`: whether the connection is the person, and the
/// decision proof (`decisionNonce`, `personDecision`) the answer carries.
#[derive(Clone, Copy, Debug, Default)]
pub struct Answerer<'a> {
    pub person: bool,
    pub decision: Option<(&'a str, &'a str)>,
}

impl<'a> Answerer<'a> {
    /// The answerer of a `permission_respond` with `params`.
    pub fn of(person: bool, params: &'a Value) -> Self {
        let meta = params.pointer("/_meta/acpmux");
        let field = |f: &str| meta.and_then(|m| m.get(f)).and_then(Value::as_str);
        let decision = match (field(DECISION_NONCE_FIELD), field(DECISION_FIELD)) {
            (Some(nonce), Some(proof)) => Some((nonce, proof)),
            _ => None,
        };
        Self { person, decision }
    }
}

/// What the request check decided for a request that may go on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PersonVerdict {
    /// Handle it as usual.
    Handle,
    /// An answer for a peer's prompt: forward it to the peer, which decides;
    /// never handle it here (`server/requests.rs`).
    PeerOnly,
}

/// This launch's person key, once the app gave it.
#[derive(Default)]
pub struct PersonGate {
    key: StdMutex<Option<String>>,
    /// Set by `--person-key-fd`: a running unsigned daemon takes no other.
    from_spawn: AtomicBool,
    /// This daemon run's id, which a decision proof binds.
    instance: std::sync::OnceLock<String>,
    /// Decision nonces that counted once, with when.
    spent: StdMutex<std::collections::VecDeque<(String, std::time::Instant)>>,
}

impl PersonGate {
    /// `_acpmux/person_holds`: proof that this run holds the key the app
    /// gave it, over the app's fresh `nonce`: lowercase hex HMAC-SHA256(key,
    /// "acpmux-person-holds-v1" 0 instance 0 nonce). None without a key. An
    /// HMAC oracle over caller-chosen nonces in its own domain only: never
    /// a decision proof or a connection proof (their messages start with
    /// another prefix).
    pub fn holds(&self, nonce: &str) -> Option<String> {
        let key = self.key.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()?;
        let key = cmux_local_auth::frontend_proof::unhex::<32>(&key)?;
        let mut message = b"acpmux-person-holds-v1".to_vec();
        for part in [self.instance(), nonce] {
            message.push(0);
            message.extend_from_slice(part.as_bytes());
        }
        Some(cmux_local_auth::frontend_proof::hex(&cmux_local_auth::frontend_proof::hmac_sha256(
            &key, &message,
        )))
    }

    /// Whether this daemon run holds a person key (never the key itself).
    pub fn has_key(&self) -> bool {
        self.key.lock().unwrap_or_else(std::sync::PoisonError::into_inner).is_some()
    }

    /// This daemon run's id (16 random bytes, lowercase hex).
    pub fn instance(&self) -> &str {
        self.instance.get_or_init(|| new_nonce()[..32].to_owned())
    }

    /// Whether `proof` is the person's decision for this exact prompt,
    /// option and nonce on this daemon run (constant time), with a nonce that
    /// has not counted yet. It spends nothing: the answer spends the nonce
    /// when it counts ([`Self::spend_decision`]).
    pub fn decision_proves(
        &self,
        session: &str,
        permission: &str,
        option: &str,
        nonce: &str,
        proof: &str,
    ) -> bool {
        let key = self.key.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
        let instance = self.instance();
        let Some(expected) =
            key.and_then(|k| decision_proof(&k, instance, session, permission, option, nonce))
        else {
            return false;
        };
        cmux_local_auth::tokens_match(proof, &expected) && !self.spent(nonce)
    }

    fn spent(&self, nonce: &str) -> bool {
        self.spent
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .any(|(n, _)| n == nonce)
    }

    /// Spends a decision nonce; false when it was spent already. Called
    /// under the prompt's lock by the answer that counts.
    pub fn spend_decision(&self, nonce: &str) -> bool {
        let mut spent = self.spent.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let now = std::time::Instant::now();
        while spent.front().is_some_and(|(_, at)| now.duration_since(*at) > SPENT_TTL) {
            spent.pop_front();
        }
        if spent.iter().any(|(n, _)| n == nonce) {
            return false;
        }
        if spent.len() >= SPENT_LIMIT {
            spent.pop_front();
        }
        spent.push_back((nonce.to_owned(), now));
        true
    }

    /// The key the app passed on `--person-key-fd` (unsigned daemon only).
    pub fn install_spawn_key(&self, key: &str) -> Result<(), String> {
        if !valid_key(key) {
            return Err("the person key must be 64 lowercase hex characters".into());
        }
        let mut slot = self.key.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if slot.is_some() {
            return Err("this daemon already has a person key".into());
        }
        *slot = Some(key.to_owned());
        self.from_spawn.store(true, Ordering::SeqCst);
        Ok(())
    }

    /// Whether `proof` answers the challenge (`nonce`, `connection`) with
    /// the current key (constant time).
    pub fn proves(&self, transport: &str, nonce: &str, connection: &str, proof: &str) -> bool {
        let key = self.key.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
        key.and_then(|k| person_proof(&k, transport, nonce, connection))
            .is_some_and(|expected| cmux_local_auth::tokens_match(proof, &expected))
    }

    /// Whether `presented` is this launch's key (constant time).
    pub fn matches(&self, presented: &str) -> bool {
        self.key
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_deref()
            .is_some_and(|k| valid_key(presented) && cmux_local_auth::tokens_match(presented, k))
    }

    /// `_acpmux/person_enroll` from a peer the caller already proved to be
    /// the signed app (`app_verified`), or, on an unsigned daemon, a check
    /// that `key` is the spawn key.
    pub fn enroll(&self, key: &str, app_verified: bool) -> Result<Value, RpcError> {
        if !valid_key(key) {
            return Err(RpcError::invalid_params("key must be 64 lowercase hex characters"));
        }
        if app_verified {
            *self.key.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                Some(key.to_owned());
            return Ok(json!({"enrolled": true, "via": "signature"}));
        }
        if self.from_spawn.load(Ordering::SeqCst) && self.matches(key) {
            return Ok(json!({"enrolled": true, "via": "spawn"}));
        }
        Err(RpcError::new(
            -32000,
            "this daemon cannot verify the app and has another person key: start a new daemon with this key",
        )
        .with_data(json!({"reason": ENROLL_UNAVAILABLE})))
    }
}

/// The transport a unix socket connection proves on (`transport` of [`person_proof`]).
pub const TRANSPORT_UNIX: &str = "unix";
/// The transport a proven LocalApp WebSocket connection proves on.
pub const TRANSPORT_APP: &str = "app";

/// The bytes a person proof covers.
fn proof_message(transport: &str, nonce: &str, connection: &str) -> Vec<u8> {
    let mut message = b"acpmux-person-v1\0".to_vec();
    for part in [transport, nonce, connection] {
        message.extend_from_slice(part.as_bytes());
        message.push(0);
    }
    message.pop();
    message
}

/// The proof for one connection's challenge, as lowercase hex; None when
/// `key` is not a person key. `transport` is the one the CLIENT knows it
/// uses ([`TRANSPORT_UNIX`] or [`TRANSPORT_APP`]), never a value from the
/// challenge: a relay that hands a unix connection's challenge to the app's
/// WebSocket gets a proof for the other transport.
pub fn person_proof(key: &str, transport: &str, nonce: &str, connection: &str) -> Option<String> {
    let key = cmux_local_auth::frontend_proof::unhex::<32>(key).filter(|_| valid_key(key))?;
    Some(cmux_local_auth::frontend_proof::hex(&cmux_local_auth::frontend_proof::hmac_sha256(
        &key,
        &proof_message(transport, nonce, connection),
    )))
}

/// The bytes a decision proof covers.
fn decision_message(parts: [&str; 5]) -> Vec<u8> {
    let mut message = b"acpmux-person-decision-v1".to_vec();
    for part in parts {
        message.push(0);
        message.extend_from_slice(part.as_bytes());
    }
    message
}

/// The person's proof that they chose `option` for `permission` of
/// `session`, with the prompt's `nonce`, on daemon run `instance`, as
/// lowercase hex; None when `key` is not a person key.
pub fn decision_proof(
    key: &str,
    instance: &str,
    session: &str,
    permission: &str,
    option: &str,
    nonce: &str,
) -> Option<String> {
    let key = cmux_local_auth::frontend_proof::unhex::<32>(key).filter(|_| valid_key(key))?;
    Some(cmux_local_auth::frontend_proof::hex(&cmux_local_auth::frontend_proof::hmac_sha256(
        &key,
        &decision_message([instance, session, permission, option, nonce]),
    )))
}

/// A connection's nonce: 32 random bytes as lowercase hex.
pub fn new_nonce() -> String {
    let mut bytes = [0u8; 32];
    // No randomness means no safe challenge: the daemon cannot serve.
    getrandom::fill(&mut bytes).expect("the OS random generator for a connection nonce"); // crash-allow: no randomness, no safe challenge
    cmux_local_auth::frontend_proof::hex(&bytes)
}

/// 32 bytes as lowercase hex.
pub fn valid_key(key: &str) -> bool {
    key.len() == 64 && key.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The declared refusal.
pub fn person_required(what: &str) -> RpcError {
    RpcError::new(
        -32000,
        format!(
            "approve this on the Mac app: {what} is accepted only from the cmux app, never from the CLI, a script or an agent"
        ),
    )
    .with_data(json!({"reason": REASON}))
}

/// Remove the key from a first `initialize`'s params and return it.
pub fn take_key(params: &mut Value) -> Option<String> {
    params
        .pointer_mut("/_meta/acpmux")
        .and_then(Value::as_object_mut)
        .and_then(|m| m.remove(KEY_FIELD))
        .and_then(|v| v.as_str().map(str::to_owned))
}

/// Rules that cannot auto-approve: none (a clear), or only `autoDeny` and
/// `ask` lists with a `default` of `ask` or `deny`. No `autoApprove` entry,
/// no `default: "approve"`, and no field this check does not know.
pub(crate) fn rules_cannot_auto_approve(rules: Option<&Value>) -> bool {
    let Some(rules) = rules.filter(|r| !r.is_null()) else { return true };
    let Some(obj) = rules.as_object() else { return false };
    obj.iter().all(|(k, v)| match k.as_str() {
        "autoApprove" => match v {
            Value::Null => true,
            Value::Array(a) => a.is_empty(),
            Value::Object(o) => o.is_empty(),
            _ => false,
        },
        "autoDeny" | "ask" => v.is_null() || v.is_array(),
        "default" => v.is_null() || matches!(v.as_str(), Some("ask" | "deny")),
        _ => false,
    })
}

/// Whether `policy` asks before anything runs (ask, deny-all).
pub(crate) fn asks(policy: PermissionPolicy) -> bool {
    matches!(policy, PermissionPolicy::Ask | PermissionPolicy::DenyAll)
}

/// How much a policy runs without asking: deny-all 0, ask 1, approve-reads 2,
/// approve-edits 3, approve-all 4. A higher number is wider.
pub(crate) fn breadth(policy: PermissionPolicy) -> u8 {
    match policy {
        PermissionPolicy::DenyAll => 0,
        PermissionPolicy::Ask => 1,
        PermissionPolicy::ApproveReads => 2,
        PermissionPolicy::ApproveEdits => 3,
        PermissionPolicy::ApproveAll => 4,
    }
}

/// The catch-all that passes a session method acpmux does not handle to the
/// harness (`server/requests.rs`): a harness extension method may change
/// what the harness runs without asking, so only the person reaches it.
pub fn harness_forward_check(person: bool, m: &str) -> Result<(), RpcError> {
    if person {
        Ok(())
    } else {
        Err(person_required(&format!("{m}, a harness method acpmux does not handle,")))
    }
}

/// Absent or null: nothing is set. Present: one of the asking policies.
pub(crate) fn asking_policy_value(v: Option<&Value>) -> bool {
    match v {
        None | Some(Value::Null) => true,
        Some(Value::String(p)) => ASKING_POLICIES.contains(&p.as_str()),
        Some(_) => false,
    }
}

impl Hub {
    /// The one person check (module docs). `person`: the connection
    /// presented this launch's key. `remote_authenticated`: a connection
    /// held to the Web's rules (a Web connection, or a peer forwarding for its
    /// Web client) that proved a credential (`server/conn_auth.rs`),
    /// which may set any mode of the Codex bridge (Lawrence, 2026-10-13:
    /// "remote connection must be authed, and should be able to pretty much
    /// use yolo mode"; `Hub::any_mode_for_web`). The unix socket (the
    /// CLI, scripts, agents) still needs the person for a mode that does not ask.
    pub async fn person_check(
        &self,
        person: bool,
        remote_authenticated: bool,
        m: &str,
        params: &Value,
    ) -> Result<PersonVerdict, RpcError> {
        if person {
            return Ok(PersonVerdict::Handle);
        }
        if m == method::MUX_PERMISSION_RESPOND && self.is_peer_session(params) {
            // A peer's prompt: the peer is the only one that decides its
            // prompts (with its own key and rules); it gets the whole
            // request, an allow, a deny or a cancel (slice 2b). The request
            // handler forwards it and never handles it here.
            return Ok(PersonVerdict::PeerOnly);
        }
        self.person_check_local(remote_authenticated, m, params)
            .await
            .map(|()| PersonVerdict::Handle)
    }

    /// `person_check` for a request this daemon handles itself.
    async fn person_check_local(
        &self,
        remote_authenticated: bool,
        m: &str,
        params: &Value,
    ) -> Result<(), RpcError> {
        match m {
            method::MUX_PERMISSION_RESPOND => {
                let option = params.get("optionId").filter(|v| !v.is_null());
                let proved = option.is_some_and(|o| self.person_decided(params, o));
                // Who answered for the person is the person's own claim, or
                // comes with the person's decision proof (cx-0q7o).
                if !proved
                    && params
                        .pointer(&format!("/_meta/acpmux/{ANSWERED_BY_FIELD}"))
                        .is_some_and(|v| !v.is_null())
                {
                    return Err(person_required("answeredBy"));
                }
                // No option: a cancel.
                let Some(option) = option else {
                    return Ok(());
                };
                if proved || self.option_rejects(params, option) {
                    Ok(())
                } else {
                    Err(person_required("allowing a permission"))
                }
            }
            method::MUX_PERMISSION_GROUP_RESPOND => match params["decision"].as_str() {
                Some("deny") => Ok(()),
                _ => Err(person_required("allowing a permission group")),
            },
            method::MUX_SET_POLICY | "_acpmux/set_default_policy" => {
                if asking_policy_value(params.get("policy")) {
                    Ok(())
                } else {
                    Err(person_required("a permission policy other than ask or deny-all"))
                }
            }
            method::MUX_DEFAULTS | method::MUX_PRESETS => {
                let set = params.get("set");
                let env = set.and_then(|s| s.get("env")).is_some_and(|v| match v {
                    Value::Null => false,
                    Value::Object(o) => !o.is_empty(),
                    _ => true,
                });
                if env {
                    return Err(person_required("a spawn env"));
                }
                if !asking_policy_value(set.and_then(|s| s.get("policy"))) {
                    return Err(person_required("a permission policy other than ask or deny-all"));
                }
                // Removing a stored policy (a clear, or `policy: null`) lets
                // the next layer's policy apply, which may not ask.
                let removes = params.get("clear").and_then(Value::as_bool) == Some(true)
                    || set.and_then(|s| s.get("policy")).is_some_and(Value::is_null);
                if removes && self.stored_policy(m, params).await.is_some() {
                    return Err(person_required("removing a stored permission policy"));
                }
                Ok(())
            }
            method::MUX_SET_RULES => {
                if !rules_cannot_auto_approve(params.get("rules")) {
                    return Err(person_required("a permission rule that could auto-approve"));
                }
                // Under a policy that does not ask, a rule is what keeps a
                // tool asking: any change (a clear too) may widen it.
                let Some(s) =
                    crate::server::session_key(params).ok().and_then(|k| self.resolve(k).ok())
                else {
                    return Ok(());
                };
                let default = self.config.read().await.permission_policy;
                if asks(self.policy_for(&s, default)) {
                    Ok(())
                } else {
                    Err(person_required(
                        "changing the rules of a session whose policy does not ask",
                    ))
                }
            }
            // The handoff target tag decides which session a handoff adopts.
            method::MUX_TAG => {
                let sets = params
                    .get("set")
                    .and_then(Value::as_object)
                    .is_some_and(|o| o.contains_key(super::handoff::TARGET_TAG));
                let removes = params.get("remove").and_then(Value::as_array).is_some_and(|a| {
                    a.iter().any(|v| v.as_str() == Some(super::handoff::TARGET_TAG))
                });
                if sets || removes {
                    Err(person_required("the handoff target tag"))
                } else {
                    Ok(())
                }
            }
            method::SESSION_SET_MODE | method::SESSION_SET_CONFIG_OPTION => {
                let (id, value) = if m == method::SESSION_SET_MODE {
                    (None, params.get("modeId").and_then(Value::as_str))
                } else {
                    (
                        params.get("configId").and_then(Value::as_str),
                        params.get("value").and_then(Value::as_str),
                    )
                };
                if id.is_some_and(|i| crate::web_modes::FREE_CONFIG_IDS.contains(&i)) {
                    return Ok(());
                }
                // An unknown session is the handler's not-found; a peer's
                // session is checked by that peer.
                let Some(s) =
                    crate::server::session_key(params).ok().and_then(|k| self.resolve(k).ok())
                else {
                    return Ok(());
                };
                let family = crate::web_modes::family_of(&s.meta());
                if remote_authenticated && self.any_mode_for_web(&s.meta()) {
                    return Ok(());
                }
                if self.web_modes().config_value_asks(&family, id, value) {
                    Ok(())
                } else {
                    Err(person_required("a mode that does not ask"))
                }
            }
            _ => Ok(()),
        }
    }

    /// The policy a `_acpmux/defaults` or `_acpmux/presets` write would
    /// remove: the named family default's or preset's stored policy.
    async fn stored_policy(&self, m: &str, params: &Value) -> Option<PermissionPolicy> {
        let cfg = self.config.read().await;
        if m == method::MUX_DEFAULTS {
            let family = params.get("family").and_then(Value::as_str)?;
            cfg.defaults.get(family).and_then(|d| d.policy)
        } else {
            let name = params.get("name").and_then(Value::as_str)?;
            cfg.presets.get(name).and_then(|p| p.policy)
        }
    }

    /// Whether the request names a peer's session (this daemon does not
    /// have it): `server/peer_forward.rs` forwards it whole, and the peer
    /// checks it with its own key, which this daemon does not hold. The same
    /// condition as the forward's.
    fn is_peer_session(&self, params: &Value) -> bool {
        crate::server::session_key(params)
            .ok()
            .is_some_and(|k| self.resolve(k).is_err() && self.resolve_remote(k).is_some())
    }

    /// Whether a relayed allow carries the person's decision proof for the
    /// pending prompt it answers (module docs, cx-0q7o). Question answers
    /// are never covered by a proof.
    fn person_decided(&self, params: &Value, option: &Value) -> bool {
        let meta = params.pointer("/_meta/acpmux");
        let field = |f: &str| meta.and_then(|m| m.get(f)).and_then(Value::as_str);
        let (Some(nonce), Some(proof), Some(option)) =
            (field(DECISION_NONCE_FIELD), field(DECISION_FIELD), option.as_str())
        else {
            return false;
        };
        if params.get("answers").is_some_and(|v| !v.is_null()) {
            return false;
        }
        let Some(s) = crate::server::session_key(params).ok().and_then(|k| self.resolve(k).ok())
        else {
            return false;
        };
        let Some(pid) = params.get("permissionId").and_then(Value::as_str) else { return false };
        let pending_nonce = {
            let state = s.permissions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(p) = state.pending.get(pid) else { return false };
            p.decision_nonce.clone()
        };
        cmux_local_auth::tokens_match(nonce, &pending_nonce)
            && self.person.decision_proves(&s.id, pid, option, nonce, proof)
    }

    /// Whether `option` is a reject the pending permission offered. Unknown
    /// sessions, permissions and options are not rejects: the handler still
    /// answers not-found or invalid params for a person, and a client
    /// without the person learns nothing more than its refusal.
    fn option_rejects(&self, params: &Value, option: &Value) -> bool {
        let Some(s) = crate::server::session_key(params).ok().and_then(|k| self.resolve(k).ok())
        else {
            return false;
        };
        let Some(pid) = params.get("permissionId").and_then(Value::as_str) else { return false };
        let state = s.permissions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(p) = state.pending.get(pid) else { return false };
        let offered: Vec<&Value> = p.request["options"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|o| o["optionId"] == *option)
            .collect();
        matches!(offered.as_slice(), [one] if matches!(one["kind"].as_str(), Some("reject_once" | "reject_always")))
    }
}
