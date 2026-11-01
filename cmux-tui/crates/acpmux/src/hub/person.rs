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
//! - A relayed allow (cx-0q7o, #13742 D16): a prompt can be answered from another machine's app
//!   through a connection that is never the person (a peer daemon, the remote cmux-tui server).
//!   Each pending prompt has a new random `decisionNonce` and each daemon run a random
//!   `personInstance`; both are in `_acpmux/permission_pending`. `permission_respond` with an allow
//!   then counts only with `_meta.acpmux.decisionNonce` and `personDecision` = lowercase hex
//!   HMAC-SHA256(key, "acpmux-person-decision-v1" 0 instance 0 session 0 permission 0 option 0
//!   nonce) ([`decision_proof`]), for the prompt that is pending with that nonce. A nonce counts
//!   once: the answer that counts spends it under the prompt's lock, together with taking the
//!   prompt (so a refused answer spends nothing, and of two racing answers one counts), and a
//!   bounded store of spent nonces ([`SPENT_LIMIT`] entries, [`SPENT_TTL`]) refuses it again. A
//!   prompt the next daemon adopts gets a new nonce under the new run (`permission_reissued`, also
//!   a `permission_pending`). A restarted daemon has a new instance, so an old proof proves
//!   nothing. A question's answers, and their annotations, count only under
//!   [`decision_answers_proof`]. A decision proof never
//!   covers a group's allow, a policy, a rule or a mode: those widen and stay the person's own.
//!   One chat's policy raise has a proof of its own over a challenge this daemon issued
//!   ([`policy_grant`]). A keyed daemon is not dumpable (`daemon.rs`), so an
//!   agent it starts cannot read the key from its memory.
//! - A group's one-time allow from a connection that is not the person (peer-route approvals,
//!   `mac_approvers.rs`) counts only with `_meta.acpmux.approverDecisions`: for EVERY pending
//!   member of the group at the request's `revision`, by permission id, `{decisionNonce,
//!   approverDecision}`, an enrolled Mac's own single-prompt signature over the member's one-time
//!   allow option (no answers). Only a Mac's signature counts there, not a phone's: it binds the
//!   member's tool call, and `mac_approvers::may_allow` holds it to a plain tool ask. A missing
//!   member, an entry for anything else, a wrong nonce, a stale revision or one signature that
//!   does not count refuses the whole allow and answers nothing. The answer verifies every
//!   signature and spends every nonce together under the prompt state's lock and one hold of
//!   the Mac set's (`Hub::respond_permission_group`, `PersonGate::macs_spend`), so a revocation
//!   lands before or after the whole answer, never between two members. `allow_chat` stays the
//!   person's own. A non-person read of the groups says `macAllowOnce: true` beside
//!   `allowRefused`.
//! - Through a peer (slice 2a, 2b): a daemon that only mirrors a peer's session cannot check a
//!   proof made with the peer's key, so it forwards every answer for that session (allow, deny,
//!   cancel) and the peer decides; a forwarded answer counts hops (`server/peer_forward.rs`).
//!   `answeredBy` from a connection that is not the person counts only together with a proof that
//!   counts. `initialize` and `_acpmux/status` name the run (`personInstance`); status says whether
//!   it holds a key (`personKey`). `_acpmux/person_holds {nonce}` (slice 2c, unix socket only, 8
//!   per connection) answers HMAC(key, "acpmux-person-holds-v1" 0 instance 0 nonce), so the app can
//!   check that a daemon it started holds ITS key: a `person_prove` reply alone proves nothing
//!   (whatever answers on the socket path can say `person: true`).
//!   The key reaches a daemon that `acpmux daemon start --person-key-fd 0`
//!   launches over a socket pair, only after the daemon said it is not
//!   dumpable (`daemon.rs`).
//!
//! [`Hub::person_check`] is the one check, run for every request before it is handled or forwarded.
//! Without the person, a client may read prompts and deny or cancel them, and may narrow (ask,
//! deny-all, deny rules, asking modes). It may never allow (a permission answer, a question's
//! answer, a group's allow) without a proof or an approver's signature that counts (above), and never widen what runs without asking (a policy other than ask or
//! deny-all for a session, the daemon default, a family default or a preset; a rule that could
//! auto-approve; a mode the reviewed asking table does not list; a spawn env). Such a request gets
//! [`REASON`] and changes nothing: a prompt stays pending. One exception, off by default
//! (`agents.subsessions.answerQuestions`): a proven caller session (a) may answer a question a
//! session under it asked, never a permission prompt, a plan approval or a lasting allow. The hub
//! checks it under the prompt's lock ([`Answerer`] `ancestor`) and names the caller in
//! `answeredBy`; the threat model is in `hub/subsession_answer.rs`.
//!
//! Starting in a mode that does not ask (a `session/new` with
//! `_meta.acpmux.mode`, or a preset's `mode`), without the person, needs
//! one of these; each grants a mode the person already approved, never a
//! wider one, and nothing else:
//! - (a) Inherit: the caller is an acpmux session whose current mode is
//!   that exact mode on that same harness family (mode ids are per family).
//!   The daemon, not the request, says which session calls: each harness it
//!   starts gets `ACPMUX_SESSION_TOKEN` = lowercase hex HMAC-SHA256(run
//!   secret, "acpmux-caller-session-v1" 0 session id) ([`caller_token`]), a
//!   secret made at each daemon start and kept in memory only. A unix
//!   socket connection whose FIRST request is an `initialize` with
//!   `_meta.acpmux.callerSession {sessionId, token}` that matches (constant
//!   time) is that session for its whole life ([`take_caller`]); the field
//!   is stripped from every request and never read anywhere else, so a
//!   `parentSessionId` or a `callerSession` in any other request counts for
//!   nothing. The check reads the caller's mode at the time of the request:
//!   a caller the person moved back to asking inherits nothing. A peer or
//!   Web connection never has a caller. The harness also gets
//!   `ACPMUX_SESSION_TOKEN_SOCKET`, this daemon's socket, and the CLI sends
//!   the token only to that socket ([`caller_env`], `client.rs`). A
//!   profile's, preset's or request's env never sets either variable: the
//!   spawn drops them from every env it layers after `caller_env`; adoption: `adopted_callers`.
//! - No start mode that does not ask applies to an adopt without the
//!   person: an adopt may find a session already running
//!   (`hub/adoption.rs`, `ifLive: "open"`), and only the person widens a
//!   running session (`session/set_mode` above). Such a request is refused
//!   before anything starts.
//! - (b) A preset the person approved: `_acpmux/presets {name, approveMode:
//!   true}` from the person records `modeApproval`, the sha256 of the
//!   preset's contents (everything but its description and the approval
//!   itself, `Preset::approval_digest`). The approval counts only while the
//!   preset still hashes to it and only for that preset's own mode, with no
//!   other harness, no adopted conversation and no model, effort, policy,
//!   route or env of the request's own (a folder is fine). The contents are read
//!   three times for one start (the request check, the resolve of model,
//!   effort and env, the spawn of args, env and system prompt): each read
//!   records the digest of what it used, and the start counts the approval
//!   only when the resolve's and the spawn's digests are the approved one
//!   (`hub/start_gate/preset_bind.rs`), so an edit that is put back between
//!   reads gains nothing. The spawn's digest is recorded only by the cold
//!   start of the agent, under the session's spawn lock, for the profile it
//!   actually started; a request that finds the agent running or re-adopts
//!   its host records nothing. Such a preset never takes a pooled harness.
//!   The session records the approved digest; a later cold start from other
//!   contents (an edit, then a respawn) starts in the harness's own mode
//!   instead of replaying the approved one, and a running agent keeps the
//!   mode it runs, which its saved mode keeps saying. Bound to the
//!   contents, not cleared on a write, so every way the preset can change
//!   (a `_acpmux/presets` write from any client, a hand edit of config.json
//!   and a reload, a future write path) drops it without having to know
//!   about it; the exact contents the person approved are approved again.
//!   Without the person, `approveMode: true` and a preset `mode` that does
//!   not ask are refused; `approveMode: false` and an asking mode narrow and
//!   stay open.
//! - (d) The refusal ([`mode_person_required`]) is one sentence that names
//!   where to approve: cmux NEXT on this host ([`host_label`]), or the
//!   preset to approve there once; `error.data` carries `host`, `mode` and
//!   `preset` so an app can show its own (localized) text. A Web or peer
//!   client never gets this host's name, in the text or in `host`.
//! - (c) A pending prompt reaches every app that sees the session: a peer's
//!   `_acpmux/permission_pending` reaches the watchers of this daemon that
//!   did not attach the session (`hub/peers.rs`), with the peer's
//!   `decisionNonce` and `personInstance`; an answer still goes to the peer,
//!   which counts an allow only with its own person's proof (above). The
//!   proof covers the prompt's ids, not the text the app shows, so a peer
//!   that re-sends a real prompt with other text could get the person's
//!   allow of that text counted for the real one. A peer's prompt is
//!   therefore relayed only for a session that peer listed as its own and
//!   that is not this daemon's, in the run the peer named at its handshake,
//!   which is neither this daemon's run nor one another peer named; and only
//!   to unix socket and app watchers, never to a Web client or on to
//!   another peer daemon. The app holds the key of the daemons it enrolled,
//!   so this daemon's prompts (whose proofs it can make) never arrive with
//!   a peer's text. Binding the proof to the prompt's text would need the
//!   app to hash what it shows; not done.
//!   Residual: the run a peer names at its handshake is a claim. A peer can
//!   name a third daemon's run (one the app enrolled directly, say over
//!   ssh) and re-send that daemon's prompt with other text; this daemon
//!   cannot tell. The app has to refuse to prove a `via: "peer"` prompt whose
//!   `personInstance` is a daemon it enrolled directly (an app follow-up).
//!
//! The default start mode (`hub/start_mode.rs`, cx-wx93i) is not a request:
//! with no `mode` asked, a new chat starts in `defaultPermissionMode` /
//! `agents.defaultPermissionMode`, else the
//! harness's full-access mode, for every non-Web origin (also the unix
//! socket CLI). It never widens a proven caller session: one in a mode
//! that asks starts its chats in the harness's own mode
//! (`Hub::keeps_harness_mode`, as a handoff target of a source that asks
//! does). A request that names a mode skips the default; (a) and (b) gate
//! it as above. Presets, folder profiles, adopted chats and profiles that
//! pin a mode in their argv keep the harness's own mode, except a built-in
//! Chief subagent preset that names no mode, whose chat starts as a plain one
//! (`start_mode.rs` `plain_for_mode`, cmux#27847).
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
//!   the user's files. A preset's `modeApproval` is an unkeyed sha256 in
//!   config.json, so such a write can approve a preset itself.
//! - A preset approval covers the preset's `harness` string, not the
//!   profile it resolves to: `_acpmux/defaults` `prefer` or
//!   `_acpmux/harness/add` can point that name at another program, which
//!   `_acpmux/harness/add` can run anyway.
//! - The person's own pick of a no-ask mode on a preset session (not through
//!   an approval) stays on respawn even when the preset changed meanwhile.
//! - `_acpmux/harness/add` (a new harness profile), `_acpmux/defaults`
//!   `prefer` and a preset's `harness` (which profile, and so which profile
//!   default policy, a new session gets), a preset's `args`,
//!   `acp.trust.set`, `_acpmux/harness_enable` and `_acpmux/import` stay
//!   open to the unix socket.
//! - A caller token lives in its harness's environment, which any process
//!   of the same user may read (`/proc/<pid>/environ` on Linux, `ps -E` or
//!   `KERN_PROCARGS2` on macOS). A process that reads it starts sessions in
//!   that session's current mode only, which that session's own agent can
//!   already do without asking (a no-ask mode runs any command). The
//!   process still has to run somewhere: an agent of a session that asks
//!   needs an allowed command or read to get there. Binding the token to the
//!   connecting process's ancestry (peer pid) is a later hardening.
//! - A token dies with its daemon run: a harness that outlives a restart
//!   (an agent host) inherits nothing until the next spawn.
//! - `session/new` with a `policy` other than ask or deny-all is open to the
//!   unix socket (it predates this check); a mode is not.
//! - Open question (cx-wx93i): while the person's start mode is full
//!   access (the default), a unix socket client that is no proven session,
//!   such as `acpmux new` from a script, or an agent of a session that asks
//!   that leaves out its caller token, gets a full-access chat without the
//!   person. Limiting the default to the person (or LocalApp) would close
//!   it; the person's pick of `standard` or `ask` closes it today.
//! - DEV only: a same-uid process that starts the unsigned daemon before the
//!   app does gives it its own spawn key; the app then hands that daemon off
//!   (when its agents run under agent hosts), but the process held the
//!   person until then.

use super::*;

pub use super::start_gate::{
    CALLER_ENV_KEYS, CALLER_FIELD, CALLER_SOCKET_ENV, CALLER_TOKEN_ENV, START_MODE_FIELD,
    StartMode, caller_env, caller_proves, caller_token, host_label, mode_person_required,
    take_caller,
};
use cmux_json::JsonSet as _;

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
    /// A phone's signed decision (`approvers.rs`), with its `decisionNonce`.
    pub approver: Option<(&'a str, &'a Value)>,
    /// A caller session answering its descendant's question: set by the hub, never by a request.
    pub(crate) ancestor: Option<&'a str>,
    /// That answer's fence (`subsession_answer.rs`): handed to the asking task only if it wins.
    pub(crate) fence: Option<&'a crate::agent::Fence>,
    /// The person who answered (`author.rs`), recorded in `answeredBy`: it proves nothing.
    pub author: Option<&'a crate::author::Author>,
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
        let approver = match (
            field(DECISION_NONCE_FIELD),
            meta.and_then(|m| m.get(super::approvers::DECISION_FIELD)).filter(|v| v.is_object()),
        ) {
            (Some(nonce), Some(signed)) => Some((nonce, signed)),
            _ => None,
        };
        Self { person, decision, approver, ancestor: None, fence: None, author: None }
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
    /// The open challenges of a policy raise from another machine's app (`policy_grant.rs`).
    policy_challenges: StdMutex<std::collections::VecDeque<policy_grant::Challenge>>,
    /// The person's phones that may allow with a signature (`approvers.rs`).
    pub approvers: super::approvers::ApproverSet,
    /// The Macs whose app may allow here over the peer link (`mac_approvers.rs`).
    pub macs: super::mac_approvers::MacApprovers,
    /// The folders of the workspaces the person's app lists now
    /// (`_acpmux/workspace_roots_set`, memory only): a Web session may start
    /// there too (`remote_guard::web_roots`, which drops `/`, home and its
    /// ancestors and resolves symlinks).
    pub workspace_roots: StdMutex<Vec<String>>,
    /// The agent and model the person's app picked last for a new chat
    /// (`_acpmux/new_chat_picks_set`, memory only), shown in
    /// `_acpmux/harnesses` as `lastPicks`.
    pub new_chat_picks: StdMutex<Option<Value>>,
}

/// At most this many folders in the new-chat picks (the app keeps 50).
pub const MAX_PICK_FOLDERS: usize = 64;

/// At most this many workspace roots.
pub const MAX_WORKSPACE_ROOTS: usize = 256;

impl PersonGate {
    /// `_acpmux/workspace_roots_set {roots}` (the person only): replaces the
    /// workspace folders. Absolute paths without control characters.
    pub fn set_workspace_roots(&self, params: &Value) -> Result<Value, RpcError> {
        let list = params
            .get("roots")
            .and_then(Value::as_array)
            .ok_or_else(|| RpcError::invalid_params("roots must be a list of absolute folders"))?;
        if list.len() > MAX_WORKSPACE_ROOTS {
            return Err(RpcError::invalid_params(format!("at most {MAX_WORKSPACE_ROOTS} roots")));
        }
        let mut roots = Vec::with_capacity(list.len());
        for root in list {
            let root = root
                .as_str()
                .filter(|r| {
                    r.starts_with('/') && !r.chars().any(char::is_control) && r.len() <= 4096
                })
                .ok_or_else(|| RpcError::invalid_params("each root is an absolute folder"))?;
            if !roots.iter().any(|r: &String| r == root) {
                roots.push(root.to_owned());
            }
        }
        let count = roots.len();
        *self.workspace_roots.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = roots;
        Ok(serde_json::json!({"count": count}))
    }

    /// `_acpmux/new_chat_picks_set {lastAgent?, global?: {harness, model},
    /// folders?: [{folder, harness, model}]}` (the person only): replaces the
    /// app's last picks. Short identifiers and absolute folders only; a
    /// malformed entry refuses the whole set.
    pub fn set_new_chat_picks(&self, params: &Value) -> Result<Value, RpcError> {
        let bad = |what: &str| RpcError::invalid_params(format!("new chat picks: {what}"));
        let ident = |v: Option<&Value>, max: usize| {
            v.and_then(Value::as_str)
                .filter(|s| !s.is_empty() && s.len() <= max && !s.chars().any(char::is_control))
                .map(str::to_owned)
        };
        let pick = |v: &Value| -> Option<Value> {
            Some(serde_json::json!({
                "harness": ident(v.get("harness"), 128)?,
                "model": ident(v.get("model"), 256)?,
            }))
        };
        let mut out = serde_json::Map::new();
        if let Some(agent) = params.get("lastAgent").filter(|v| !v.is_null()) {
            out.insert(
                "lastAgent".into(),
                ident(Some(agent), 128).ok_or_else(|| bad("lastAgent"))?.into(),
            );
        }
        if let Some(global) = params.get("global").filter(|v| !v.is_null()) {
            out.insert("global".into(), pick(global).ok_or_else(|| bad("global"))?);
        }
        let folders = params.get("folders").and_then(Value::as_array).cloned().unwrap_or_default();
        if folders.len() > MAX_PICK_FOLDERS {
            return Err(bad(&format!("at most {MAX_PICK_FOLDERS} folders")));
        }
        let mut kept = Vec::with_capacity(folders.len());
        for f in &folders {
            let folder = ident(f.get("folder"), 4096)
                .filter(|p| p.starts_with('/'))
                .ok_or_else(|| bad("each folder is absolute"))?;
            let mut row =
                pick(f).ok_or_else(|| bad("each folder pick names a harness and a model"))?;
            row.set("folder", folder.into());
            kept.push(row);
        }
        out.insert("folders".into(), Value::Array(kept));
        let count = out.get("folders").and_then(Value::as_array).map_or(0, Vec::len);
        *self.new_chat_picks.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some(Value::Object(out));
        Ok(serde_json::json!({"count": count}))
    }

    /// The new-chat picks the person's app last set.
    pub fn new_chat_picks(&self) -> Option<Value> {
        self.new_chat_picks.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    /// The workspace folders the person's app last set.
    pub fn workspace_roots(&self) -> Vec<String> {
        self.workspace_roots.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

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
    #[allow(clippy::too_many_arguments)]
    pub fn decision_proves(
        &self,
        session: &str,
        permission: &str,
        option: &str,
        nonce: &str,
        answers: Option<&Value>,
        annotations: Option<&Value>,
        proof: &str,
    ) -> bool {
        let key = self.key.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
        let instance = self.instance();
        let annotations = annotations.filter(|a| !a.is_null());
        let Some(expected) = key.and_then(|k| match answers.filter(|a| !a.is_null()) {
            // Annotations go only with answers: no proof covers them alone.
            None if annotations.is_some() => None,
            None => decision_proof(&k, instance, session, permission, option, nonce),
            Some(a) => decision_answers_proof(
                &k,
                instance,
                session,
                permission,
                option,
                nonce,
                a,
                annotations,
            ),
        }) else {
            return false;
        };
        cmux_local_auth::tokens_match(proof, &expected) && !self.spent(nonce)
    }

    /// Whether `signed` is an enrolled approver's (a phone's, or an enrolled
    /// Mac's, `mac_approvers.rs`) signature for this exact prompt `request`,
    /// option, nonce and answers on this daemon run, unexpired, with a nonce
    /// that has not counted yet. It spends nothing.
    #[allow(clippy::too_many_arguments)]
    pub fn approver_proves(
        &self,
        session: &str,
        permission: &str,
        request: &Value,
        option: &str,
        nonce: &str,
        answers: Option<&Value>,
        signed: &Value,
    ) -> bool {
        let now = super::approvers::unix_now();
        let instance = self.instance();
        (self
            .approvers
            .verifies(instance, session, permission, option, nonce, answers, signed, now)
            || self.macs.verifies_then(
                instance,
                session,
                permission,
                request,
                option,
                nonce,
                answers,
                signed,
                now,
                || true,
            ))
            && !self.spent(nonce)
    }

    /// `approver_proves`, and the answer counting: its nonce spent while the approver is still
    /// enrolled (`ApproverSet::verifies_then`, `MacApprovers::verifies_then`), so a revocation
    /// that has returned stops it. Called under the prompt's lock by the answer that counts.
    #[allow(clippy::too_many_arguments)]
    pub fn approver_spends(
        &self,
        session: &str,
        permission: &str,
        request: &Value,
        option: &str,
        nonce: &str,
        answers: Option<&Value>,
        signed: &Value,
    ) -> bool {
        let now = super::approvers::unix_now();
        let instance = self.instance();
        self.approvers.verifies_then(
            instance,
            session,
            permission,
            option,
            nonce,
            answers,
            signed,
            now,
            || self.spend_decision(nonce),
        ) || self.macs.verifies_then(
            instance,
            session,
            permission,
            request,
            option,
            nonce,
            answers,
            signed,
            now,
            || self.spend_decision(nonce),
        )
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
        self.spend_decisions(&[nonce])
    }

    /// Spends every nonce of `nonces` at once, or none: false when one was spent already or
    /// one is there twice. Called under the prompts' lock by the answer that counts.
    pub fn spend_decisions(&self, nonces: &[&str]) -> bool {
        let mut spent = self.spent.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let now = std::time::Instant::now();
        while spent.front().is_some_and(|(_, at)| now.duration_since(*at) > SPENT_TTL) {
            spent.pop_front();
        }
        let fresh = nonces.iter().enumerate().all(|(i, nonce)| {
            !nonces.get(..i).unwrap_or_default().contains(nonce)
                && !spent.iter().any(|(n, _)| n == nonce)
        });
        if nonces.is_empty() || !fresh {
            return false;
        }
        for nonce in nonces {
            if spent.len() >= SPENT_LIMIT {
                spent.pop_front();
            }
            spent.push_back(((*nonce).to_owned(), now));
        }
        true
    }

    /// A group's one-time allow from a connection that is not the person (`permission_groups.rs`):
    /// whether every one of `proofs` is an enrolled Mac's valid signature over its own member,
    /// with a nonce that has not counted yet. Only a Mac's proof counts here: it binds the
    /// member's tool call and passes `mac_approvers::may_allow` (a plain tool ask), which a
    /// phone's does not. It spends nothing.
    pub fn macs_prove(&self, session: &str, proofs: &[super::mac_approvers::MacProof<'_>]) -> bool {
        let now = super::approvers::unix_now();
        self.macs.all_verify_then(self.instance(), session, proofs, now, || {
            proofs.iter().all(|p| !self.spent(p.nonce))
        })
    }

    /// [`Self::macs_prove`], and the answer counting: every nonce spent together while the
    /// Macs are still enrolled, under one hold of the Mac set's lock (`all_verify_then`), so a
    /// revocation lands before (nothing spent, nothing answered) or after the whole answer.
    /// Lock order as a single answer: the prompts' lock (the caller's), the Mac set's, then the
    /// spent store.
    pub fn macs_spend(&self, session: &str, proofs: &[super::mac_approvers::MacProof<'_>]) -> bool {
        let now = super::approvers::unix_now();
        let nonces: Vec<&str> = proofs.iter().map(|p| p.nonce).collect();
        self.macs.all_verify_then(self.instance(), session, proofs, now, || {
            self.spend_decisions(&nonces)
        })
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

mod decision_answers;
pub mod policy_grant;
pub use decision_answers::decision_answers_proof;
pub use policy_grant::policy_proof;
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
    /// `caller`: the acpmux session the connection proved it runs in
    /// (module docs, (a)), never a value from the request. `starts_modes`:
    /// a `session/new` on this connection starts in its mode (the unix
    /// socket and the local app; a Web or peer one is settled to an asking
    /// mode instead, `server/remote_guard.rs`).
    pub async fn person_check(
        &self,
        person: bool,
        remote_authenticated: bool,
        caller: Option<&str>,
        starts_modes: bool,
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
        self.person_check_local(remote_authenticated, caller, starts_modes, m, params)
            .await
            .map(|()| PersonVerdict::Handle)
    }

    /// `person_check` for a request this daemon handles itself.
    async fn person_check_local(
        &self,
        remote_authenticated: bool,
        caller: Option<&str>,
        starts_modes: bool,
        m: &str,
        params: &Value,
    ) -> Result<(), RpcError> {
        match m {
            method::SESSION_NEW if starts_modes => self.session_new_check(caller, params).await,
            // Who may sign an allow is the person's own choice (`approvers.rs`).
            method::MUX_APPROVERS_SET | method::MUX_APPROVERS => {
                Err(person_required("changing or reading trusted approvers"))
            }
            // Which key this machine's `host enroll` enrolls on a peer (`mac_approvers.rs`).
            method::MUX_MAC_APPROVER_SET => Err(person_required("setting this Mac's approver key")),
            // Which folders a remote connection may start sessions in.
            method::MUX_WORKSPACE_ROOTS_SET => {
                Err(person_required("changing the workspace folders"))
            }
            method::MUX_NEW_CHAT_PICKS_SET => Err(person_required("changing the new chat picks")),
            method::MUX_PERMISSION_RESPOND => {
                // Answered already: `respond_permission` tells this one who answered first
                // (`permission_settled.rs`), and it changes nothing.
                if self.permission_settled(params) {
                    return Ok(());
                }
                let option = params.get("optionId").filter(|v| !v.is_null());
                // A phone's signed allow or answer (`approvers.rs`). Never
                // with `answeredBy`: that stays the person's own claim.
                if option.is_some_and(|o| self.approver_decided(params, o))
                    && params
                        .pointer(&format!("/_meta/acpmux/{ANSWERED_BY_FIELD}"))
                        .is_none_or(Value::is_null)
                {
                    return Ok(());
                }
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
                // An enrolled approver's signed one-time allow of every pending member
                // (`permission_groups.rs`): the answer checks it again and spends it.
                Some("allow_once") if self.approver_allows_group(params) => Ok(()),
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
                if m == method::MUX_PRESETS {
                    self.preset_mode_check(params).await?;
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
                if asks(Self::stored_policy_for(&s, default)) {
                    Ok(())
                } else {
                    Err(person_required(
                        "changing the rules of a session whose policy does not ask",
                    ))
                }
            }
            // The handoff target tag decides which session a handoff adopts; the agent hold tag
            // holds a manager's messages (`agent_hold.rs`), which its manager must not lift.
            method::MUX_TAG => {
                let guarded = |k: &str| k == super::handoff::TARGET_TAG || k == super::agent_hold::HOLD_TAG;
                let sets = params
                    .get("set")
                    .and_then(Value::as_object)
                    .is_some_and(|o| o.keys().any(|k| guarded(k)));
                let removes = params.get("remove").and_then(Value::as_array).is_some_and(|a| {
                    a.iter().any(|v| v.as_str().is_some_and(guarded))
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
                } else if let (None | Some("mode"), Some(mode)) = (id, value) {
                    Err(mode_person_required(mode, None, false, starts_modes))
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

    /// Whether a phone's allow (or answer) carries an enrolled approver's
    /// signature for the pending prompt it answers (`approvers.rs`). The
    /// answer checks it again under the prompt's lock and spends the nonce.
    fn approver_decided(&self, params: &Value, option: &Value) -> bool {
        let Some(option) = option.as_str() else { return false };
        let Some((nonce, signed)) = Answerer::of(false, params).approver else { return false };
        let Some(s) = crate::server::session_key(params).ok().and_then(|k| self.resolve(k).ok())
        else {
            return false;
        };
        let Some(pid) = params.get("permissionId").and_then(Value::as_str) else { return false };
        let (pending_nonce, request) = {
            let state = s.permissions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(p) = state.pending.get(pid) else { return false };
            (p.decision_nonce.clone(), p.request.clone())
        };
        cmux_local_auth::tokens_match(nonce, &pending_nonce)
            && self.person.approver_proves(
                &s.id,
                pid,
                &request,
                option,
                nonce,
                params.get("answers"),
                signed,
            )
    }

    /// Whether a relayed allow carries the person's decision proof for the
    /// pending prompt it answers (module docs, cx-0q7o), over its answers and
    /// annotations too.
    fn person_decided(&self, params: &Value, option: &Value) -> bool {
        let meta = params.pointer("/_meta/acpmux");
        let field = |f: &str| meta.and_then(|m| m.get(f)).and_then(Value::as_str);
        let (Some(nonce), Some(proof), Some(option)) =
            (field(DECISION_NONCE_FIELD), field(DECISION_FIELD), option.as_str())
        else {
            return false;
        };
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
            && self.person.decision_proves(
                &s.id,
                pid,
                option,
                nonce,
                params.get("answers"),
                params.get("annotations"),
                proof,
            )
    }

    /// What a `_acpmux/permission_respond` with `params` does, for the
    /// Web's asking rule (`Hub::web_answer_check`): whether it only narrows
    /// (a cancel, or a reject the pending prompt offered) and whether its
    /// allow carries the person's decision proof or an approver's signature
    /// that counts now. The answer checks both again under the prompt's lock.
    pub(crate) fn answer_shape(&self, params: &Value) -> (bool, bool) {
        let Some(option) = params.get("optionId").filter(|v| !v.is_null()) else {
            return (true, false);
        };
        let answered_by = params
            .pointer(&format!("/_meta/acpmux/{ANSWERED_BY_FIELD}"))
            .is_some_and(|v| !v.is_null());
        let proved = self.person_decided(params, option)
            || (!answered_by && self.approver_decided(params, option));
        (self.option_rejects(params, option), proved)
    }

    /// Whether `option` is a reject the pending permission offered. Unknown
    /// sessions, permissions and options are not rejects: the handler still
    /// answers not-found or invalid params for a person, and a client
    /// without the person learns nothing more than its refusal.
    /// Whether the prompt a `permission_respond` names was answered, and is no longer pending.
    fn permission_settled(&self, params: &Value) -> bool {
        let Some(s) = crate::server::session_key(params).ok().and_then(|k| self.resolve(k).ok())
        else {
            return false;
        };
        let Some(pid) = params.get("permissionId").and_then(Value::as_str) else { return false };
        let state = s.permissions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        !state.pending.contains_key(pid) && state.settled.lost(pid).is_some()
    }

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
