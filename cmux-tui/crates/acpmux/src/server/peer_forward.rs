//! Requests for a session that lives on a peer daemon: forwarded whole,
//! with the folder-trust gate's peer check (`trust_gate.rs`). Part of the
//! request handler (`requests.rs`).

use super::*;

/// Optional top-level peer selection for a trust question before its chat exists. A client
/// must see this extension on its own daemon before sending the selector to it.
pub(super) const TRUST_PEER_EXTENSION: &str = "acp.trust.peer-v1";

/// Peer aliases belong to this daemon's local caller, not to another daemon's clients. A
/// forwarded request has already consumed its selector; it cannot select a third machine.
pub(super) fn refuse_peer_selector(
    origin: Origin,
    m: &str,
    params: &Value,
) -> Result<(), RpcError> {
    let selects = match m {
        method::ACP_TRUST_GET | method::ACP_TRUST_SET => params.get("peer").is_some(),
        method::SESSION_NEW => params.pointer("/_meta/acpmux/peer").is_some(),
        _ => false,
    };
    if origin == Origin::Peer && selects {
        return Err(RpcError::invalid_params("a peer cannot select another peer on this daemon")
            .with_data(json!({"reason": "peer.forward_refused"})));
    }
    Ok(())
}

/// Methods that name no session, or that this daemon answers itself even
/// for a peer's session.
const SESSION_SCOPED_EXCLUDED: &[&str] = &[
    method::INITIALIZE,
    // The app pane's reply in place is checked against this daemon's chats (`app_reply.rs`).
    method::MUX_APP_REPLY,
    method::AUTHENTICATE,
    method::SESSION_NEW,
    method::SESSION_LIST,
    method::MUX_STATUS,
    method::MUX_PERF,
    method::MUX_CALLERS,
    method::MUX_FELT_SNAPSHOT,
    method::MUX_SESSIONS,
    method::MUX_USAGE,
    method::MUX_WEB_MODES,
    method::MUX_WEB_TOKEN_ROTATE,
    method::MUX_HARNESSES,
    method::MUX_COMPLETE,
    method::MUX_HUNK_SUMMARY,
    method::MUX_RELOAD_CONFIG,
    method::MUX_WATCH,
    super::controls::METHOD,
    method::MUX_HARNESS_INVENTORY_WATCH,
    method::MUX_HARNESS_INVENTORY_REFRESH,
    method::MUX_HARNESS_UPDATE_PLAN,
    method::MUX_HARNESS_UPDATE_PREPARE,
    method::MUX_WARM,
    method::MUX_PREWARM,
    method::MUX_START_MODE,
    method::MUX_IMPORT,
    method::MUX_SHUTDOWN,
    // Briefs are daemon-scoped and dispatch selects its peer explicitly.
    method::MUX_DISPATCH,
    method::MUX_STEER,
    method::MUX_BRIEFS,
    method::MUX_REPORT,
    // A GitHub action is for this daemon's own caller session (`github_broker.rs`).
    method::MUX_GITHUB_ACTION,
    // The app's cmux sign-in is for this daemon alone (`github_app_token.rs`).
    method::MUX_GITHUB_APP_LEASE,
    // So are the app's own GitHub calls with it (`github_rest_op.rs`).
    method::MUX_GITHUB_REST,
    // A task is this daemon's brief for one of its own sessions (`hub/tasks.rs`).
    method::MUX_TASK_NEW,
    method::MUX_TASKS,
    // Resolving reads this daemon's own and mirrored session lists (`hub/locate.rs`).
    method::MUX_RESOLVE,
    // An agent message is taken back on this daemon only (`hub/withdraw.rs`).
    method::MUX_PROMPT_WITHDRAW,
    // So is a chat's inbox drained (`hub/inbox_digest.rs`).
    method::MUX_INBOX_DIGEST,
    // A registration is for the caller's own session on this daemon (`hub/register.rs`): its
    // NAME is the name to take, never a peer session to forward to, and its token stays here.
    method::MUX_REGISTER,
    // So is an inbox relay: it serves the Claude Code session it runs under, on this machine.
    method::MUX_INBOX_RELAY,
    // A message to deliver is this daemon's (`outbox.rs`), whatever session it names.
    method::MUX_SEND_QUEUE,
    method::MUX_SEND_STATUS,
    // Mesh enqueue borrows only this daemon's identity, after its local-socket check.
    method::MUX_MESH_CONTROL,
    // Forwarded by its own handler, which answers for a peer that is down (`session_auth.rs`).
    method::MUX_SESSION_AUTH,
    // Agent pairs are this daemon's own (`hub/agent_pairs.rs`).
    method::MUX_AGENT_PAIR_RESUME,
    method::MUX_AGENT_HOLD,
    method::MUX_HANDOFF_PREPARE,
    method::MUX_HANDOFF_GET,
    method::MUX_HANDOFF_DRAFT,
    method::MUX_HANDOFF_START,
    method::MUX_HANDOFF_DISCARD,
    "_acpmux/peers",
    "_acpmux/peer_status",
    // This daemon's own queue and audit trail (`hub/review_queue.rs`, `hub/audit_log.rs`).
    method::MUX_REVIEW_QUEUE,
    method::MUX_REVIEW_VERDICT,
    method::MUX_AUDIT,
    // Names a peer machine, never a session (`vm_host.rs`).
    "_acpmux/vm_host",
    // Every live chat on this daemon (`host_notice.rs`).
    "_acpmux/host_notice",
    "_acpmux/host_health",
    // This machine's own load and swap, for its app's warning (`host_overload.rs`).
    "_acpmux/host_overload",
    "_acpmux/place",
    method::MUX_PLACE_CHAT,
    "_acpmux/move_targets",
    "_acpmux/models",
    crate::catalog::RPC_GET,
    crate::catalog::RPC_REFRESH,
    "_acpmux/peer_add",
    "_acpmux/peer_lease",
    "_acpmux/peer_remove",
    "_acpmux/peer_reconnect",
    // This daemon's own copy of a peer session's events (`hub/peer_snapshot.rs`),
    // answered here while the peer is down too.
    "_acpmux/peer_snapshot",
    "_acpmux/peer_snapshots_clear",
    // Saved prompts are this machine's library; their `name` is a prompt's, never a session's.
    method::MUX_PROMPTS_LIST,
    method::MUX_PROMPTS_SAVE,
    method::MUX_PROMPTS_DELETE,
    // So are the stashed drafts; their `chat` is the composer's key.
    method::MUX_STASH_LIST,
    method::MUX_STASH_PUSH,
    method::MUX_STASH_GET,
    method::MUX_STASH_DROP,
    method::MUX_STASH_MOVE,
    // A launch credential is for this daemon's own session only (`agent_credentials.rs`).
    crate::agent_credentials::UPDATE_METHOD,
    // The machine's own journal takes records only from its owner's link or its own socket
    // (`hub/journal_restore.rs`): never one this daemon passes on for a client, whose origin the
    // peer would read as this daemon's.
    "_acpmux/journal_restore",
    "_acpmux/attachments_held",
];

/// The requests a chat that moved to a peer still takes here, forwarded to its copy there
/// (`hub/moved_forward.rs`): what a client attached to the chat sends it. A move's own steps
/// (`_acpmux/transfer_*`) and everything that is about this daemon's record of the chat (kill,
/// delete, archive, rename, fork) stay here, answered as before.
const MOVED_FORWARDED: &[&str] = &[
    method::SESSION_PROMPT,
    method::SESSION_CANCEL,
    method::SESSION_LOAD,
    method::SESSION_RESUME,
    method::SESSION_SET_MODE,
    method::SESSION_SET_MODEL,
    method::SESSION_SET_CONFIG_OPTION,
    method::MUX_ATTACH,
    method::MUX_INFO,
    method::MUX_EVENTS,
    method::MUX_ATTACHMENT,
    method::MUX_ROWS,
    method::MUX_HISTORY,
    method::MUX_NATIVE_HISTORY,
    method::MUX_DRAFT_GET,
    method::MUX_DRAFT_SET,
    method::MUX_COMPOSER_SET,
    method::MUX_COMPOSERS,
    method::MUX_PERMISSION_RESPOND,
    method::MUX_QUEUE_GET,
    method::MUX_QUEUE_REMOVE,
    method::MUX_QUEUE_EDIT,
    method::MUX_QUEUE_TEXT,
    method::MUX_STEER_WITHDRAW,
];

/// Where request `m` for `key` goes when not here: a peer's chat, or for a request of
/// [`MOVED_FORWARDED`] the peer copy of a chat that moved away (`Hub::remote_or_moved`).
pub(super) fn target(
    hub: &Hub,
    m: &str,
    key: &str,
) -> Option<(Arc<crate::peer::Peer>, String, Value, bool)> {
    hub.remote_or_moved(key).filter(|(.., moved)| !moved || MOVED_FORWARDED.contains(&m))
}

/// Whether `m` names a session that a peer's session forwards for: not one this daemon answers
/// itself (`SESSION_SCOPED_EXCLUDED`).
pub(super) fn names_a_session(m: &str) -> bool {
    !SESSION_SCOPED_EXCLUDED.contains(&m)
}

/// The reply when `m` is for a peer's session (forwarded there), else None
/// (this daemon handles it).
/// `_meta.acpmux.fromAgent` for a forwarded `session/prompt` with no sender of its own, from the
/// session this connection proved it runs in: the peer sees neither that session nor the caller
/// proof (`mark_forwarded` drops the provenance), so without it the peer records the agent's
/// report as the person's (claude-sr2, 2026-10-24: every remote lane's report a plain bubble), and
/// a keyed prompt could replace another sender's (`hub/supersede.rs`). The person names no one.
/// That session's id and harness go too (`fromSessionId`, `fromHarness`), this daemon's word on
/// its proven caller; whatever a client wrote there is dropped first, and only a prompt that came
/// over a peer link itself keeps what that link said (`prompt_provenance::FROM_SESSION_ID`).
fn name_sender(hub: &Arc<Hub>, conn: &Arc<Conn>, p: &mut Value) {
    // This field is daemon-authored, even when a caller already supplied fromAgent.
    if let Some(meta) = p.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        meta.remove("messageSender");
    }
    if conn.origin != Origin::Peer {
        // A relay on this machine's unix socket (no proven session) keeps its relay record, read
        // again so only well-formed relay fields go on as this daemon's word
        // (`prompt_provenance::FROM_RELAY`); anything else a client wrote is dropped.
        let relay = (conn.origin == Origin::Local && conn.caller().is_none())
            .then(|| crate::prompt_provenance::relay_sender(p))
            .flatten();
        crate::prompt_provenance::drop_sender_fields(p);
        if let Some(relay) = relay {
            crate::hub::merge_mux_meta(p, relay.mux_fields());
        }
    }
    if conn.is_person() {
        return;
    }
    let Some(caller) = conn.caller() else { return };
    let mut message_sender = json!({
        "name": hub.session_name(caller),
        "sessionId": caller,
        "host": crate::hub::host_label(),
    });
    // Its given name too, so the peer's chat names it as people do (`session_handle.rs`).
    if let Some(given) = hub
        .resolve(caller)
        .ok()
        .and_then(|s| s.read_meta(|m| m.handle.clone()))
        .filter(|h| crate::session_handle::valid(h))
    {
        message_sender.set("displayName", json!(given));
    }
    let mut meta = json!({"messageSender": message_sender});
    if p.pointer("/_meta/acpmux/fromAgent").is_none_or(Value::is_null) {
        meta.set("fromAgent", json!(hub.session_name(caller)));
    }
    // Always replace a client-provided sender identity with the session proven by
    // this connection.  `fromAgent` remains caller-declared for display, but it
    // cannot alter the durable message sender.
    crate::hub::merge_mux_meta(p, meta);
    if let Ok(from) = hub.resolve(caller) {
        let sender = crate::prompt_provenance::BoundSender::of_session(&from.id, &from.meta());
        crate::hub::merge_mux_meta(p, sender.mux_fields());
    }
}

/// A peer's answer for a prompt id it took before (`hub/turns.rs`): the acceptance notice's
/// `duplicate`, or the first run's outcome marked `_meta.acpmux.duplicate`.
fn is_duplicate(v: &Value) -> bool {
    v.get("duplicate").and_then(Value::as_bool) == Some(true)
        || v.pointer("/_meta/acpmux/duplicate").and_then(Value::as_bool) == Some(true)
}

/// The peer's acceptance names the message its journal kept and that message's sender session
/// (`hub/message_events.rs` `name_message`), and either is not ours (`(sender, message id)`).
/// A peer that names messages (`names`: it lists `session-messages-v1`) and names none kept no
/// session's message under this prompt id (a person's prompt): not ours either. A peer from
/// before that never names one: nothing to check.
fn kept_another(v: &Value, ours: Option<(&str, &str)>, names: bool) -> bool {
    let Some((sender, message_id)) = ours else { return false };
    let differs = |key: &str, ours: &str| match v.get(key).and_then(Value::as_str) {
        Some(kept) => kept != ours,
        None => names,
    };
    differs("messageId", message_id) || differs("messageSenderId", sender)
}

/// `e` with `data.peer` = `peer`, this daemon's own name for the peer that
/// answered: any `peer` the peer's own answer gave is replaced, so the app
/// enrolls this Mac only on a peer of this daemon, never on a host the peer named.
fn name_peer(mut e: RpcError, peer: &str) -> RpcError {
    let data = e.data.get_or_insert_with(|| json!({}));
    if let Some(obj) = data.as_object_mut() {
        obj.insert("peer".into(), Value::String(peer.to_owned()));
    }
    e
}

/// A pending chat has no session yet. Its trust question can name one existing peer instead;
/// mixing that selector with a session is ambiguous and never chooses either machine.
pub(super) fn trust_peer<'a>(m: &str, params: &'a Value) -> Result<Option<&'a str>, RpcError> {
    if !matches!(m, method::ACP_TRUST_GET | method::ACP_TRUST_SET) {
        return Ok(None);
    }
    let Some(value) = params.get("peer") else { return Ok(None) };
    let peer = value
        .as_str()
        .filter(|name| !name.is_empty())
        .ok_or_else(|| RpcError::invalid_params("peer must be a nonempty peer name"))?;
    if ["sessionId", "session", "name"].iter().any(|key| params.get(*key).is_some()) {
        return Err(RpcError::invalid_params("peer trust cannot also name a session"));
    }
    Ok(Some(peer))
}

/// How long a prompt for a peer's chat waits for that peer's link before it is refused as
/// unreachable, for a sender that keeps such a message itself: a peer daemon's forward (its own
/// outbox tries it again) and the acpmux CLI, which queues a refused send in this daemon's outbox
/// ("machine is unreachable; queued here", `cli/run/standard.rs`). Every other client's prompt is
/// held instead ([`PROMPT_QUEUED_AFTER`]). The wait wakes the peer (`Peer::wake`), so a connect
/// attempt comes at most `Backoff::WANTED_CAP` (1 s) after the last while it waits
/// (`peer_wanted.rs`). 8 s is about seven attempts, each with its handshake: a daemon's restart
/// handoff or a Wi-Fi drop of a few seconds.
pub(super) const PROMPT_LINK_WAIT: std::time::Duration = std::time::Duration::from_secs(8);

/// How long a prompt from a unix-socket client that keeps no refused message itself (the app's
/// and the phone's chats, through cmux-tui-core) waits for its peer's link on its request before
/// it is kept in this daemon's outbox and answered as queued for the link ([`LinkWait::Outbox`]):
/// the same live wait as [`PROMPT_LINK_WAIT`], so a blip still answers with the turn there, and a
/// longer outage is queued, never refused (Leo, 2026-11-24: "10s timeout for messages being
/// sendsble is a shame. if it's making good progress, it shiukd be allowed to keep going?").
pub(super) const PROMPT_QUEUED_AFTER: std::time::Duration = PROMPT_LINK_WAIT;

/// How often a held prompt asks for its peer again while it waits (`Peer::wake`, which keeps the
/// peer wanted and runs the wake hook at most once per `WAKE_FOR`): the reconnects keep coming
/// within `Backoff::WANTED_CAP` for as long as the prompt waits, not only for the first
/// `WANTED_FOR` (Leo, 2026-11-24: "let's just keep optimistically connecting and reinforcing the
/// connection").
pub(super) const PROMPT_LINK_REINFORCE: std::time::Duration = std::time::Duration::from_secs(30);

/// How long a held prompt waits for its peer's link at most: the outbox's day
/// (`hub/outbox.rs` `RETRY_FOR_MS`). Past it the prompt is refused as unreachable.
pub(super) const PROMPT_HOLD_FOR: std::time::Duration =
    std::time::Duration::from_millis(crate::hub::outbox::RETRY_FOR_MS);

/// The upload methods that wait for a peer's link (`await_link`).
pub(super) fn waits_for_link(m: &str) -> bool {
    matches!(
        m,
        method::MUX_FILE_PUT
            | method::MUX_FILE_PUT_BEGIN
            | method::MUX_FILE_PUT_CHUNK
            | method::MUX_FILE_PUT_FINISH
            | method::MUX_FILE_PUT_STATUS
    )
}

/// A file the person dropped, or a prompt, for a chat on `peer` waits, up to `within`, for the
/// peer's link to be up instead of failing at once while it reconnects: the peer is wanted
/// (`peer_wanted.rs`), so the next attempt comes within a second, and each settled attempt is
/// checked. Before, the first try of a pasted video met a link that was reconnecting and failed,
/// and only the person's Retry got it through (Leo, 2026-11-01: "i had to retry to get it to
/// load???"). Whether it came up: a link still down is refused as unreachable by the request, as
/// before, and a peer removed or replaced ends the wait at once (`Peer::stopped`).
pub(super) async fn await_link(peer: &crate::peer::Peer, within: std::time::Duration) -> bool {
    let mut stopped = peer.stopped();
    if *stopped.borrow() {
        return false;
    }
    if peer.ready() {
        return true;
    }
    let mut settled = peer.settled();
    peer.want();
    let deadline = tokio::time::Instant::now() + within;
    while !peer.ready() && !*stopped.borrow() {
        tokio::select! {
            // A settled connect attempt may restore the link or produce an error.
            changed = settled.changed() => if changed.is_err() { break },
            // An explicit remove/replacement can have no connect attempt in flight.
            // Every upload waiter hears this broadcast instead of sitting for 30 s.
            changed = stopped.changed() => if changed.is_err() { break },
            () = tokio::time::sleep_until(deadline) => break,
        }
    }
    peer.ready() && !*stopped.borrow()
}

/// A file upload for a chat on `peer`, whose link is down, waits for the link as a held prompt
/// does: asking for the peer again every [`PROMPT_LINK_REINFORCE`] (`await_link` wants it, so the
/// reconnects keep coming within `Backoff::WANTED_CAP`), up to [`PROMPT_HOLD_FOR`]. The caller
/// races it with the client's connection, so the client's own call deadline (the app gives each
/// upload call 120 s, `AcpmuxStatusClient.putFile`) or its cancel ends it. Before, a fixed 30 s
/// refused the upload while the app was still waiting and the link was still coming back (Leo,
/// 2026-11-24: "if it's making good progress, it shiukd be allowed to keep going?"). A peer
/// removed or replaced ends it at once (`Peer::stopped`): false.
async fn hold_upload_for_link(peer: &crate::peer::Peer) -> bool {
    let until = tokio::time::Instant::now() + PROMPT_HOLD_FOR;
    loop {
        let left = until.saturating_duration_since(tokio::time::Instant::now());
        if left.is_zero() {
            return false;
        }
        if await_link(peer, PROMPT_LINK_REINFORCE.min(left)).await {
            return true;
        }
        if *peer.stopped().borrow() {
            return false;
        }
    }
}

pub(super) async fn forward(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    // Cloud mobile forwarding is refused by the existing gated/inner path. Skip the lazy-demand
    // path first so a refused request cannot wake or dial a peer before that guard runs. A listing
    // read of any other peer left undialed is answered from its last-known row, with no dial.
    if !super::remote_guard::cloud_mobile(params)
        && let Some(row) = super::peer_demand_wait::use_peer(hub, m, params).await
    {
        return Some(Ok(row));
    }
    let reply = gated(hub, conn, m, params).await;
    // A message this daemon handed to a peer's session is a cross-host send (`xhost_audit.rs`).
    // A prompt kept for its peer's link (`queue_for_link`) is sent by the outbox, which records it.
    if matches!(m, method::SESSION_PROMPT | method::MUX_SEND_QUEUE)
        && matches!(&reply, Some(Ok(v)) if v.get("waitingFor").is_none())
    {
        let mut fields = crate::xhost_audit::prompt_fields(params);
        let peer = session_key(params)
            .ok()
            .and_then(|key| hub.resolve_remote(key))
            .map(|r| r.0.name.clone());
        fields.set("via", json!("peer"));
        fields.set("toHost", json!(peer));
        crate::xhost_audit::record("sent", fields);
    }
    // A client waits on a peer that is down (a chat it opens): the peer reconnects within
    // seconds (`peer_wanted.rs`). A peer daemon's connection is no client waiting here. A
    // message for a session there, from any connection (a peer daemon's forward and this
    // daemon's own outbox included), also asks the peer's route to wake a paused machine
    // (`Peer::wake`); the sender's outbox delivers it once the link is back.
    if let Some(Err(e)) = &reply
        && let Some(peer) = unreachable_peer(hub, e)
    {
        ask_back(&peer, m, params, conn.origin);
    }
    if conn.origin == Origin::Peer {
        return reply.map(|r| r.map_err(super::redact::hide_unreachable_peer));
    }
    reply
}

/// [`forward_inner`], for a prompt to a peer after its link's restores are decided: run first, it
/// would take the seqs they need (`hub/peer_snapshot/restore.rs`). It goes on the link the
/// decision was of, or not at all (review of #37284 at 4dcbe192, F2): a link that replaced it
/// meanwhile refuses it, and it goes back through the gate, of the new link, a few times at most.
async fn gated(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    let remote = (m == method::SESSION_PROMPT)
        .then(|| session_key(params).ok())
        .flatten()
        .and_then(|key| target(hub, m, key));
    let Some((peer, id, _, _)) = remote else {
        return forward_inner(hub, conn, m, params, None).await.transpose();
    };
    let mut hold = None;
    'held: loop {
        match wait_for_prompt_link(hub, conn, &peer, params, &mut hold).await {
            Ok(Some(queued)) => return Some(Ok(queued)),
            Ok(None) => {}
            Err(e) => return Some(Err(e)),
        }
        let mut tries = 0;
        loop {
            tries += 1;
            let link = match hub.peer_snapshots.restores_done(&peer, &id).await {
                Ok(link) => link,
                Err(e) if holds_again(conn, &peer, hold.as_ref(), &e) => continue 'held,
                Err(e) => return Some(Err(e)),
            };
            let reply = forward_inner(hub, conn, m, params, link).await.transpose();
            let moved = link.is_some_and(|l| (peer.generation, peer.link_epoch()) != l);
            if tries < 4 && moved && matches!(&reply, Some(Err(e)) if unsent(e)) && peer.ready() {
                continue;
            }
            // The link went again before the prompt left: it is held again, not refused.
            if let Some(Err(e)) = &reply
                && holds_again(conn, &peer, hold.as_ref(), e)
            {
                continue 'held;
            }
            return reply;
        }
    }
}

/// Whether `e` is a refusal of a request that never left this daemon: the peer's link took
/// nothing (`peer_link::unreachable_error`).
fn unsent(e: &RpcError) -> bool {
    e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str)
        == Some("peer_unreachable")
}

/// How a prompt for a peer's chat whose link is down waits for the link.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LinkWait {
    /// Up to [`PROMPT_LINK_WAIT`], then refused as unreachable: a sender that keeps a refused
    /// message itself. A peer daemon's forward (its own outbox tries it again) and the acpmux
    /// CLI, which declares itself at `initialize` (`cli_caller.rs`) and queues a refused send in
    /// this daemon's outbox ("machine is unreachable; queued here", `cli/run/standard.rs`).
    Brief,
    /// Up to [`PROMPT_QUEUED_AFTER`], then kept in this daemon's outbox under its prompt id and
    /// answered as queued for the link: any other unix-socket client (the app's and the phone's
    /// chats, through cmux-tui-core). The outbox delivers as the unix socket does, so only its
    /// clients' prompts go there (`outbox::handle`).
    Outbox,
    /// As long as the link takes, up to [`PROMPT_HOLD_FOR`], on the request: a client on the
    /// app's or the web listener, whose prompts the outbox does not carry. Its request answers
    /// when the turn there ends, as any prompt's does; a client that leaves takes it along, and
    /// its own sender sends it again under the same prompt id (`sendWhenReady.ts`).
    Request,
}

/// How a prompt from `conn` waits for its peer's link ([`LinkWait`]). This daemon's own outbox
/// is [`LinkWait::Brief`] and never held: it keeps its delivery and tries it again the moment the
/// link is ready (`Outbox::peer_ready`), so holding its unsent refusal again (`holds_again`) would
/// spin, since its link wait returns at once.
fn link_wait(conn: &Conn) -> LinkWait {
    if conn.socket_peer == crate::sender_harness::SocketPeer::Outbox {
        return LinkWait::Brief;
    }
    match conn.origin {
        Origin::Peer => LinkWait::Brief,
        _ if conn.declared().is_some() => LinkWait::Brief,
        Origin::Local => LinkWait::Outbox,
        Origin::Web | Origin::LocalApp => LinkWait::Request,
    }
}

/// Whether a prompt the peer's link refused unsent (`e`) after its wait waits for the link again:
/// a prompt held on its request ([`LinkWait::Request`]) whose link went down again before it
/// left, a peer that is not stopped, inside its [`PROMPT_HOLD_FOR`].
fn holds_again(conn: &Conn, peer: &crate::peer::Peer, hold: Option<&Hold>, e: &RpcError) -> bool {
    unsent(e)
        && link_wait(conn) != LinkWait::Brief
        && !peer.ready()
        && !*peer.stopped().borrow()
        && hold.is_none_or(|h| tokio::time::Instant::now() < h.until)
}

/// A prompt held for its peer's link: when the hold ends.
struct Hold {
    until: tokio::time::Instant,
}

/// A prompt for a chat on `peer`, whose link is down, waits for it (`await_link`) before it goes
/// through the gate, so it goes on the link that came back once that link's restores are decided.
/// How long, and what then, is [`LinkWait`]'s:
///
/// - Brief: up to [`PROMPT_LINK_WAIT`], then refused by `forward_inner` as unreachable, as before.
/// - Outbox: up to [`PROMPT_QUEUED_AFTER`], then kept in this daemon's outbox under its prompt id
///   (as `send --no-wait` keeps one), which tries it the moment the link is ready and keeps trying
///   for a day, and delivers it once. The connection hears `_acpmux/prompt_accepted` with
///   `queued: true`, `state: "queued"`, `waitingFor: "peer_link"` and its `deliveryId`, and the
///   request is answered at once (`Some`) with the same fields and `stopReason: "queued"`.
/// - Request: as long as it takes, up to [`PROMPT_HOLD_FOR`], asking for the peer again every
///   [`PROMPT_LINK_REINFORCE`].
///
/// Leo, 2026-11-24: "let's just keep optimistically connecting and reinforcing the connection and
/// sync-ups can be satisfying instead of making the user think they're constsntly suspended in a
/// state of connection limbo".
///
/// Nothing went out while it waited: a cancel (`request_cancel.rs` drops this future) or a
/// client that leaves before the outbox kept it ends the wait with nothing sent. A peer removed
/// or replaced ends any wait at once, and the prompt is refused (`Peer::stopped`).
///
/// The prompt is checked first, so a bad one is refused at once, as is one the remote guard
/// keeps off every peer (`remote_guard::cloud_mobile`).
async fn wait_for_prompt_link(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    peer: &crate::peer::Peer,
    params: &Value,
    hold: &mut Option<Hold>,
) -> Result<Option<Value>, RpcError> {
    if peer.ready() || conn.socket_peer == crate::sender_harness::SocketPeer::Outbox {
        return Ok(None);
    }
    crate::author::of_prompt(params)?;
    crate::prompt_provenance::notice_checked(params)?;
    if super::remote_guard::cloud_mobile(params) {
        return Err(super::remote_guard::refuse_cloud_mobile_forward());
    }
    // A message wakes the peer's machine as its refusal would have (`ask_back`), now instead of
    // after the wait.
    peer.wake();
    let closed = || RpcError::internal("the client closed the connection");
    let wait = link_wait(conn);
    let first = match wait {
        LinkWait::Brief => PROMPT_LINK_WAIT,
        LinkWait::Outbox => PROMPT_QUEUED_AFTER,
        LinkWait::Request => PROMPT_LINK_REINFORCE,
    };
    let up = tokio::select! {
        up = await_link(peer, first) => up,
        () = conn.closed() => return Err(closed()),
    };
    if up || *peer.stopped().borrow() || wait == LinkWait::Brief {
        return Ok(None);
    }
    if wait == LinkWait::Outbox {
        return queue_for_link(hub, conn, peer, params).await.map(Some);
    }
    let hold =
        hold.get_or_insert_with(|| Hold { until: tokio::time::Instant::now() + PROMPT_HOLD_FOR });
    loop {
        let left = hold.until.saturating_duration_since(tokio::time::Instant::now());
        if left.is_zero() {
            return Ok(None);
        }
        // Asked for again: the reconnects keep coming within `Backoff::WANTED_CAP` while it waits.
        peer.wake();
        let up = tokio::select! {
            up = await_link(peer, PROMPT_LINK_REINFORCE.min(left)) => up,
            () = conn.closed() => return Err(closed()),
        };
        if up || *peer.stopped().borrow() {
            return Ok(None);
        }
    }
}

/// Keeps a prompt for `peer`'s chat, whose link is still down, in this daemon's outbox under its
/// prompt id (`outbox::handle`, as `send --no-wait` keeps one): the outbox tries it the moment the
/// link is ready (`Outbox::peer_ready`) and keeps trying for a day, and the far daemon runs a
/// prompt id once. The same prompt id again (a client's retry) is that delivery, never a second.
/// Tells the connection so (`_acpmux/prompt_accepted`, `waitingFor: "peer_link"`) and answers
/// the request with the same fields and `stopReason: "queued"`. A refusal to keep it (over the
/// caps, a disk that cannot take it) is the request's error.
async fn queue_for_link(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    peer: &crate::peer::Peer,
    params: &Value,
) -> Result<Value, RpcError> {
    let request = json!({"request": params});
    let kept = Box::pin(super::outbox::handle(hub, conn, method::MUX_SEND_QUEUE, &request)).await?;
    let prompt_id = params.pointer("/_meta/acpmux/promptId").and_then(Value::as_str);
    let prompt_id =
        prompt_id.or_else(|| kept.get("promptId").and_then(Value::as_str)).map(str::to_owned);
    let mut accepted = json!({
        "sessionId": params.get("sessionId").cloned().unwrap_or(Value::Null),
        "promptId": prompt_id,
        "turnId": Value::Null,
        "queued": true,
        "state": "queued",
        "waitingFor": "peer_link",
        "deliveryId": kept.get("deliveryId").cloned().unwrap_or(Value::Null),
        // The kept delivery's state: `queued`, or what a delivery under this prompt id came to.
        "delivery": kept.get("status").cloned().unwrap_or(Value::Null),
        "peer": peer.name,
    });
    conn.send(&Message::notification(method::MUX_PROMPT_ACCEPTED, accepted.clone()));
    accepted.set("stopReason", json!("queued"));
    Ok(accepted)
}

/// What a request refused because `peer`'s link is down asks of the peer: a message (from any
/// connection) wakes it (`Peer::wake`), and so does a client's sign that a person is writing one
/// ([`composing`]; typing reaches it from `forward_inner`, which answers typing itself), a
/// client's other request wants it back (`Peer::want`), and a peer daemon's
/// other request asks nothing.
///
/// Waking on the first keystroke instead of on Send starts the paused machine's resume while the
/// person types, so it is mostly done when the message goes (HQ#6694: Freestyle's resume through
/// the app is seconds, typing a message is longer). A draft that is never sent costs one resume,
/// which the machine's idle pause takes back.
fn ask_back(peer: &crate::peer::Peer, m: &str, params: &Value, origin: Origin) {
    if m == method::SESSION_PROMPT {
        peer.wake();
    } else if !wake_if_composing(peer, m, params, origin) && origin != Origin::Peer {
        peer.want();
    }
}

/// Wakes `peer` when a client (never a peer daemon's forward) says a person is writing to its
/// chat ([`composing`]); whether it did.
fn wake_if_composing(peer: &crate::peer::Peer, m: &str, params: &Value, origin: Origin) -> bool {
    let wakes = origin != Origin::Peer && composing(m, params);
    if wakes {
        peer.wake();
    }
    wakes
}

/// Whether request `m` says a person is writing to the chat: typing turned on
/// (`_acpmux/typing`), or a surface's unsent draft that is not blank: text, or an image
/// (`_acpmux/composer_set`).
/// Clearing it or stopping typing is not, and neither is `_acpmux/draft_set`: the pane saves the
/// last chat's draft when it switches away, unchanged, which is no one writing.
pub(super) fn composing(m: &str, params: &Value) -> bool {
    match m {
        method::MUX_TYPING => params.get("on").and_then(Value::as_bool) == Some(true),
        method::MUX_COMPOSER_SET => {
            params.get("text").and_then(Value::as_str).is_some_and(|text| !text.trim().is_empty())
                || params.get("images").and_then(Value::as_array).is_some_and(|i| !i.is_empty())
        }
        _ => false,
    }
}

/// The peer of this daemon that `e` refused a request for because its link is down.
fn unreachable_peer(hub: &Hub, e: &RpcError) -> Option<Arc<crate::peer::Peer>> {
    let data = e.data.as_ref()?;
    if data.get("reason").and_then(Value::as_str) != Some("peer_unreachable") {
        return None;
    }
    hub.peer_by_name(data.get("peer").and_then(Value::as_str)?)
}

async fn forward_inner(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
    gate: Option<crate::hub::peer_snapshot::Link>,
) -> Result<Option<Value>, RpcError> {
    if super::remote_guard::cloud_mobile(params)
        && let Ok(key) = session_key(params)
        && target(hub, m, key).is_some()
    {
        return Err(super::remote_guard::refuse_cloud_mobile_forward());
    }
    if let Some(name) = trust_peer(m, params)? {
        let peer = hub
            .peer_by_name(name)
            .ok_or_else(|| RpcError::not_found(format!("no peer {name:?}")))?;
        if !peer.connected.load(Ordering::SeqCst) {
            return Err(peer.unreachable_error());
        }
        // The new selector is consumed here; the destination only needs the existing trust
        // protocol, but it must advertise that support even for a local unix caller.
        if !peer.supports_trust_gate() {
            return Err(super::trust_gate::peer_unsupported(&peer.name));
        }
        let mut forwarded = params.clone();
        if let Some(object) = forwarded.as_object_mut() {
            // This selects the next hop only. Keeping it would ask that daemon to find another
            // peer by our local alias, or loop back to us if it happens to have the same alias.
            object.remove("peer");
        }
        super::remote_guard::mark_forwarded(conn.origin, conn.auth, params, &mut forwarded);
        super::remote_guard::attest_person(
            &mut forwarded,
            super::requests::person_admitted(conn, params),
        );
        let mut result = peer.request(m, forwarded).await?;
        if let Some(object) = result.as_object_mut() {
            object.insert("peer".into(), Value::String(peer.name.clone()));
        }
        return Ok(Some(result));
    }
    // Trust answers for a remote session belong to the daemon that owns it.
    if matches!(m, method::ACP_TRUST_GET | method::ACP_TRUST_SET)
        && let Ok(key) = session_key(params)
        && hub.resolve(key).is_err()
        && let Some((peer, id, _)) = hub.resolve_remote(key)
    {
        if super::trust_gate::gated(conn.origin, params) && !peer.supports_trust_gate() {
            return Err(super::trust_gate::peer_unsupported(&peer.name));
        }
        let mut forwarded = params.clone();
        if let Some(object) = forwarded.as_object_mut() {
            object.insert("sessionId".into(), Value::String(id));
        }
        super::remote_guard::mark_forwarded(conn.origin, conn.auth, params, &mut forwarded);
        super::remote_guard::attest_person(
            &mut forwarded,
            super::requests::person_admitted(conn, params),
        );
        let mut result = peer.request(m, forwarded).await?;
        if let Some(object) = result.as_object_mut() {
            object.insert("peer".into(), Value::String(peer.name.clone()));
        }
        return Ok(Some(result));
    }
    // A session that lives on a peer: forward the whole request there.
    if !SESSION_SCOPED_EXCLUDED.contains(&m)
        && let Ok(key) = session_key(params)
        && let Some((peer, id, row, moved)) = target(hub, m, key)
    {
        // A request for a chat that moved there has followed one more move: past the bound it
        // is answered here, as a chat that moved (`hub/moved_forward.rs`).
        let moved_hops = moved.then(|| {
            params
                .pointer(&format!("/_meta/acpmux/{}", crate::hub::MOVED_HOPS_FIELD))
                .and_then(Value::as_u64)
                .unwrap_or(0)
        });
        if moved_hops.is_some_and(|hops| hops >= crate::hub::MAX_MOVES_FOLLOWED) {
            return Ok(None);
        }
        // A link that is down lists no features (`link_ended`), so every feature check below (the
        // trust gate, attachments, a prompt that waits for the owner) would call a prompt
        // unsupported: final for the outbox, and the peer never asked to wake. The prompt is
        // refused as unreachable instead, which `forward` turns into a wake and the outbox tries
        // again; the checks run on that try, once the link is back.
        if m == method::SESSION_PROMPT && !peer.ready() {
            crate::author::of_prompt(params)?;
            crate::prompt_provenance::notice_checked(params)?;
            return Err(peer.unreachable_error());
        }
        if super::trust_gate::gated(conn.origin, params) && !peer.supports_trust_gate() {
            return Err(super::trust_gate::peer_unsupported(&peer.name));
        }
        // A switch onto another harness goes only to a peer that takes one: an older build forks
        // on the chat's own harness and the next message would reach the old provider (review of
        // cmux#41030, F3).
        if m == method::SESSION_FORK
            && super::fork_through::asks_retarget(params)
            && !peer.lists(super::fork_through::RETARGET_FEATURE)
        {
            return Err(super::fork_through::retarget_unsupported(&peer.name));
        }
        // A subagent's fork, or one in a picked mode or on a model of the chat's own harness, goes
        // only to a peer that takes them: an older build would fork the whole chat as it is.
        if m == method::SESSION_FORK
            && super::fork_through::asks_start(params)
            && !peer.lists(crate::hub::fork_subagent::FEATURE)
        {
            return Err(super::fork_through::start_unsupported(&peer.name));
        }
        // A conditional stop runs only where the session lives: an older peer would ignore the
        // condition and stop it anyway (`hub/stop_if_idle.rs`).
        if m == method::MUX_KILL && crate::hub::stop_if_idle::StopCondition::asked(params) {
            return Err(crate::hub::stop_if_idle::remote_refusal(&peer.name));
        }
        // An upload waits for a link that is reconnecting for as long as its client waits
        // (`hold_upload_for_link`); the client that leaves stops the wait.
        if waits_for_link(m) && !peer.ready() {
            let ready = tokio::select! {
                ready = hold_upload_for_link(&peer) => ready,
                () = conn.closed() => return Err(RpcError::internal("the client closed the connection")),
            };
            // The old peer instance may have been removed or replaced while
            // waiting. Refuse on that instance; the caller can resolve again.
            if !ready {
                return Err(peer.unreachable_error());
            }
        }
        // A legacy dropped file is adapted to bounded chunks before crossing the peer link,
        // and only to a peer that takes uploads (`hub/file_uploads.rs`).
        if m == method::MUX_FILE_PUT {
            let (_, data) = crate::hub::file_uploads::check(params)?;
            if !peer.supports_file_put() {
                return Err(crate::hub::file_uploads::peer_unsupported(&peer));
            }
            if crate::hub::file_uploads::decoded_len(data)
                > crate::hub::file_uploads::LEGACY_MAX_BYTES
            {
                let mut header = json!({"sessionId": id});
                super::remote_guard::mark_forwarded(conn.origin, conn.auth, params, &mut header);
                super::remote_guard::attest_person(
                    &mut header,
                    super::requests::person_admitted(conn, params),
                );
                let mut result =
                    crate::hub::file_uploads::forward_put(&peer, header, params).await?;
                result.set("peer", json!(peer.name));
                return Ok(Some(result));
            }
        }
        // A person's prompt is checked here, before `mark_forwarded` drops its provenance
        // (`author.rs`). A tool's notice goes on as it came (`mark_forwarded` keeps it), checked
        // here first so a bad one is refused by this daemon, not the peer
        // (`prompt_provenance::notice_of`).
        if m == method::SESSION_PROMPT {
            crate::author::of_prompt(params)?;
            crate::prompt_provenance::notice_checked(params)?;
        }
        // A prompt that waits for the owner, and the owner's answer to one, go only to a peer
        // that holds it (`hub/queue_approve.rs`): an older one would run it unapproved.
        // It goes on the link that listed the feature, never on one a reconnect brought since.
        let held = m == method::SESSION_PROMPT
            && crate::author::author(params)?.is_some_and(|a| a.awaits_owner);
        let approval = held || matches!(m, method::MUX_QUEUE_APPROVE | method::MUX_QUEUE_DECLINE);
        let feature = match m {
            method::MUX_QUEUE_GET => Some(crate::author::QUEUE_GET_FEATURE),
            _ => approval.then_some(crate::author::QUEUE_APPROVAL_FEATURE),
        };
        let bound = feature.map(|f| peer.lists_on(f));
        if bound.is_some_and(|link| link.is_none()) {
            return Err(crate::author::approval_unsupported(&peer));
        }
        // So do a message's attachments, under their caps (`attach.rs`).
        if m == method::SESSION_PROMPT
            && let Some(blocks) = params.get("prompt").and_then(Value::as_array)
        {
            crate::attach::check_wire(params)?;
            if crate::attach::any(blocks) && !peer.lists(crate::attach::FEATURE) {
                return Err(crate::attach::peer_unsupported(&peer));
            }
            if crate::prompt_uploads::any(blocks) && !peer.lists(crate::prompt_uploads::FEATURE) {
                return Err(crate::prompt_uploads::peer_unsupported(&peer));
            }
        }
        // An upload for a prompt (`attach::blocks_for`) to a peer that would refuse the prompt
        // naming it: refused before its bytes are sent, so none is left behind.
        if m == method::MUX_FILE_PUT_BEGIN
            && params.get("forPrompt") == Some(&Value::Bool(true))
            && !peer.lists(crate::prompt_uploads::FEATURE)
        {
            return Err(crate::prompt_uploads::peer_unsupported(&peer));
        }
        // An older peer would answer status as unknown and finish without checking `sha256`.
        let checked =
            m == method::MUX_FILE_PUT_FINISH && params.get("sha256").is_some_and(|h| !h.is_null());
        if (checked || m == method::MUX_FILE_PUT_STATUS)
            && !peer.lists(crate::hub::file_uploads::RESUME_FEATURE)
        {
            return Err(crate::hub::file_uploads::peer_unsupported(&peer));
        }
        if m == method::MUX_FILE_PUT_CHUNK {
            crate::hub::file_uploads::check_chunk(params)?;
        }
        // A peer with only the one-shot `file_put` would refuse the upload part way through.
        if matches!(m, method::MUX_FILE_PUT_BEGIN | method::MUX_FILE_PUT_CHUNK)
            && !peer.supports_file_put_chunks()
        {
            return Err(crate::hub::file_uploads::peer_unsupported(&peer));
        }
        // The media reader runs on the peer that owns the chat, if it has one (`hub/media_read.rs`).
        if matches!(m, method::MUX_MEDIA_OPEN | method::MUX_MEDIA_RANGE)
            && !peer.supports_media_read()
        {
            return Err(crate::hub::media_read::peer_unsupported(&peer, m));
        }
        // A peer on an older build replays the chat for `session/resume`, as for a load, and
        // the replay would reach this client: the resume `initialize` advertises would not hold.
        // The resume then goes on the link that listed it, or fails (`Peer::session_resume_link`).
        let resume_link = (m == method::SESSION_RESUME).then(|| peer.session_resume_link());
        // A link that is down says nothing of the peer's build: the client hears it is down.
        if resume_link == Some(None) && !peer.ready() {
            return Err(peer.unreachable_error());
        }
        if resume_link == Some(None) {
            let build = peer.remote_build().unwrap_or_else(|| "unknown".into());
            return Err(RpcError::method_not_found(&format!(
                "{m} (peer {} runs acpmux build {build}, whose resume replays the chat; run `acpmux machine update {}`)",
                peer.name, peer.name
            ))
            .with_data(json!({"reason": "sessionResume.unsupported", "peer": peer.name})));
        }
        // So does a subagent's transcript (`hub/subagent_transcript.rs`).
        if m == method::MUX_SUBAGENT_TRANSCRIPT && !peer.supports_subagent_transcript() {
            return Err(crate::hub::media_read::peer_unsupported(&peer, m)
                .with_data(json!({"reason": "transcriptRead.unsupported"})));
        }
        // And a chat's older native turns (`hub/native_history.rs`): a pane stops paging on it.
        if m == method::MUX_NATIVE_HISTORY && !peer.supports_native_history() {
            return Err(crate::hub::media_read::peer_unsupported(&peer, m)
                .with_data(json!({"reason": "transcriptRead.unsupported"})));
        }
        // Every other method a peer feature gates (`peer::PEER_FEATURES`) goes only to a peer
        // that listed one of its features; a link that is down lists none, so it is unreachable.
        let features = crate::peer::features_gating(m);
        if !features.is_empty() && !features.iter().any(|f| peer.lists(f)) {
            if !peer.ready() {
                return Err(peer.unreachable_error());
            }
            return Err(peer_feature_unsupported(&peer, m, &features));
        }
        // Typing and an authored view are this daemon's own chats only (`hub/presence.rs`):
        // forwarded, whatever the peer serves this link as, one entry there would stand for
        // every client here.
        if m == method::MUX_TYPING || (m == method::MUX_VIEW && crate::author::present(params)) {
            // A person typing to the chat of a peer that is down still wakes it before they
            // send (`ask_back`); the typing itself stays this daemon's own.
            if !peer.ready() {
                wake_if_composing(&peer, m, params, conn.origin);
            }
            return Err(crate::hub::presence::peer_unsupported());
        }
        // A read the session list's row answers (`ROW_WILL_DO`), while the link's rows are
        // current: its notices keep the row as current as the peer's answer would be, one round
        // trip sooner.
        if m == method::MUX_INFO && row_will_do(params) && peer.rows_current() && !row.is_null() {
            return Ok(Some(from_row(&row, &peer.name)));
        }
        let mut p = if params.is_null() { json!({}) } else { params.clone() };
        if let Some(obj) = p.as_object_mut() {
            obj.remove(ROW_WILL_DO);
            obj.remove("session");
            obj.remove("name");
            obj.insert("sessionId".into(), Value::String(id.clone()));
        }
        super::remote_guard::mark_forwarded_with_person(
            conn.origin,
            conn.auth,
            params,
            &mut p,
            super::requests::person_admitted(conn, params),
        );
        // The owner's own phone controls a Claude chat the peer started, as it does one here (D13).
        super::remote_guard::attest_owner_phone(hub, conn, params, &mut p);
        // A held prompt names its hold to the peer: a link guest's waits with `approval` left
        // off here, which a peer that reads only `approval` would run unapproved.
        if held
            && let Some(author) =
                p.pointer_mut("/_meta/acpmux/author").and_then(Value::as_object_mut)
        {
            author.insert("approval".into(), json!(crate::author::APPROVAL_OWNER));
        }
        if m == method::SESSION_CANCEL {
            super::requests::person_stop::mark(conn, params, &peer, &mut p);
        }
        bound_page(m, params, &mut p);
        drop_local_kinds(&mut p);
        // An older peer refuses a fork's own `requestId` (it took one only with a boundary): it
        // forks once without it, as before (`hub/fork_request.rs`).
        if m == method::ACP_SESSION_FORK
            && p.get("beforePromptId").is_none()
            && !peer.lists(super::fork_through::FORK_REQUEST_FEATURE)
            && let Some(obj) = p.as_object_mut()
        {
            obj.remove("requestId");
        }
        // This connection's own reopen hears the chat's messages again; the replay comes over
        // the link every viewer here shares (`MessageNotices`).
        if matches!(m, method::SESSION_LOAD | method::SESSION_RESUME) {
            conn.message_notices
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .reopen(Some(&peer.name), &id);
        }
        // A peer's handles are this connection's own here (`media_forward.rs`).
        if matches!(m, method::MUX_MEDIA_OPEN | method::MUX_MEDIA_RANGE) {
            return super::media_forward::forward(&conn.remote_media, &peer, &id, m, p)
                .await
                .map(Some);
        }
        // The peer cannot see the session this connection runs in: it gets that session's name.
        if m == method::SESSION_PROMPT {
            // The person's answer to the suggestion this daemon showed them for the chat, counted
            // in their own tally before the turn can bring the next one (`suggestion_gate.rs`).
            let person = super::requests::person_asks(conn)
                && conn.caller().is_none()
                && crate::prompt_provenance::relay_sender(params).is_none()
                && params.pointer("/_meta/acpmux/fromAgent").is_none_or(Value::is_null);
            crate::suggestion_gate::note_relayed_prompt(
                &hub.suggestion_gate,
                &peer.name,
                &id,
                params,
                person,
            );
            name_sender(hub, conn, &mut p);
        }
        if m == method::MUX_PERMISSION_RESPOND {
            count_hop(&mut p)?;
        }
        if let Some(hops) = moved_hops {
            crate::hub::merge_mux_meta(&mut p, json!({crate::hub::MOVED_HOPS_FIELD: hops + 1}));
            // Its stream comes from the peer now, and returns here with the chat (`follow.rs`).
            conn.follows.forwarded(&id);
        }
        let mut first_attach = false;
        if matches!(
            m,
            method::MUX_ATTACH
                | method::SESSION_PROMPT
                | method::SESSION_LOAD
                | method::SESSION_RESUME
                | method::SESSION_FORK
                | method::ACP_SESSION_FORK
        ) {
            if m == method::MUX_ATTACH {
                if let Some(error) = hold_attach_peer_refusal(params) {
                    return Err(error);
                }
                let filter = crate::hub::EventFilter::parse(params.get("kinds"))?;
                let event_stream =
                    params.get("eventStream").and_then(Value::as_bool).unwrap_or(false);
                let opts = SubOpts { event_stream, filter, ..SubOpts::default() };
                super::view::subscribe_remote(hub, conn, &id, Some(opts));
            } else {
                super::view::subscribe_remote(hub, conn, &id, None);
            }
            first_attach = peer.mark_attached(&id);
            if first_attach && m != method::MUX_ATTACH {
                // The link is not a person: only a client's own attach or view shows the chat.
                // Its own task, so the attach the marker stands for always goes out, whoever else
                // relies on it; only this client's wait for it ends when the client leaves.
                let attach = tokio::spawn({
                    let (peer, id) = (peer.clone(), id.clone());
                    async move {
                        // A failed attach is logged there, and unmarked when the peer refused
                        // it; the prompt still goes, and answers with the peer's own error if
                        // the chat is gone. Its answer is the chat's replay baseline.
                        let _ = peer.attach_hidden(&id).await;
                    }
                });
                tokio::select! {
                    _ = attach => {}
                    () = conn.closed() => {
                        return Err(RpcError::internal("the client closed the connection"));
                    }
                }
            }
        }
        // A prompt without a client id still needs an acceptance key so the sender-side
        // journal copy can be recorded when the peer accepts it.  The generated id is
        // internal to this forwarded request and is not exposed as a client id.
        if m == method::SESSION_PROMPT
            && p.pointer("/_meta/acpmux/promptId")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .is_none()
        {
            crate::hub::merge_mux_meta(
                &mut p,
                json!({"promptId": uuid::Uuid::now_v7().to_string()}),
            );
        }
        // The peer answers a prompt when its turn (or a steer's step) ends; the client hears
        // the peer's acceptance as soon as it comes (`hub/outbox.rs` `PeerAccepts`).
        let accept = (m == method::SESSION_PROMPT)
            .then(|| p.pointer("/_meta/acpmux/promptId").and_then(Value::as_str))
            .flatten()
            .map(str::to_owned);
        // Only a link the peer serves as a peer daemon carries the sender's identity there
        // (`requests.rs` takes `messageSender` from a Peer connection alone), and only a peer
        // that lists `session-messages-v1` records the message: over a link added with the
        // dashboard token, or to an older peer, the receiver records no message, so the sender
        // records none and waits on none either.
        let sender_message = if m == method::SESSION_PROMPT
            && !conn.is_person()
            && peer.served_as().as_deref() == Some("peer")
            && peer.supports_session_messages()
        {
            conn.caller().map(|sender_session| {
                let sender =
                    p.pointer("/_meta/acpmux/messageSender").cloned().unwrap_or_else(|| {
                        json!({
                            "name": hub.session_name(sender_session),
                            "sessionId": sender_session,
                            "host": crate::hub::host_label(),
                        })
                    });
                let text = p
                    .get("prompt")
                    .and_then(Value::as_array)
                    .map(|blocks| crate::hub::prompt_text(blocks))
                    .or_else(|| p.get("text").and_then(Value::as_str).map(str::to_owned))
                    .unwrap_or_default();
                let message_id = super::outbox::forwarded_message_id(&p).to_owned();
                (sender_session.to_owned(), sender, text, message_id)
            })
        } else {
            None
        };
        let forward_intent = if let Some((sender_session, ..)) = &sender_message {
            Some(super::outbox::remember_forward(hub, &peer.name, &id, sender_session, &p).await?)
        } else {
            None
        };
        // The peer's acceptance said this prompt id was a duplicate (`is_duplicate`) or kept
        // another send's message (`kept_another`): its answer records nothing either.
        let duplicate = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let token = accept.as_ref().map(|prompt_id| {
            let (conn, peer_name) = (conn.clone(), peer.name.clone());
            let duplicate_seen = duplicate.clone();
            let callback_hub = hub.clone();
            let sender_message = sender_message.clone();
            let forward_intent = forward_intent.clone();
            let (target_peer, target_id) = (peer.name.clone(), id.clone());
            let (provisional_conn, provisional_peer) = (conn.clone(), peer_name.clone());
            let names = peer.supports_session_messages();
            hub.peer_accepts.wait(
                &peer.name,
                &id,
                prompt_id,
                Box::new(move |mut v| {
                    let ours = sender_message
                        .as_ref()
                        .map(|(sender, _, _, message_id)| (sender.as_str(), message_id.as_str()));
                    if is_duplicate(&v) || kept_another(&v, ours, names) {
                        // The peer ran this prompt id before, or kept another send's message
                        // under it (a direct send and its `send_queue` retry both hear the one
                        // acceptance): only its journal says whether this message is there.
                        duplicate_seen.store(true, std::sync::atomic::Ordering::SeqCst);
                        if let Some(intent) = forward_intent {
                            super::outbox::forward_unconfirmed(&callback_hub, &intent);
                        }
                    } else {
                        let stored = if let Some((sender_session, sender, text, message_id)) =
                            sender_message
                        {
                            callback_hub.append_sender_message_event(
                                &sender_session,
                                sender,
                                text,
                                message_id,
                                crate::store::now_ms(),
                                &target_peer,
                                &target_id,
                            )
                        } else {
                            false
                        };
                        if let Some(intent) = forward_intent {
                            super::outbox::forward_accepted(
                                &callback_hub,
                                &intent,
                                v.clone(),
                                stored,
                            );
                        }
                    }
                    if let Some(obj) = v.as_object_mut() {
                        obj.insert("peer".into(), Value::String(peer_name));
                    }
                    conn.send(&Message::notification(method::MUX_PROMPT_ACCEPTED, v));
                }),
                Arc::new(move |mut v| {
                    if let Some(obj) = v.as_object_mut() {
                        obj.insert("peer".into(), Value::String(provisional_peer.clone()));
                    }
                    provisional_conn.send(&Message::notification(method::MUX_PROMPT_ACCEPTED, v));
                }),
            )
        });
        // The link the request goes on and the generation the row names as it goes: a page is
        // kept only while that link is the peer's, and only as that generation's.
        let link = peer.link_epoch();
        // A client here opens peer chats: their copies are read ahead from now on, so the next
        // one opens on its copy even while its peer reconnects (`hub/peer_snapshot/warm.rs`).
        if m == method::MUX_ATTACH && conn.origin != Origin::Peer {
            hub.want_peer_copies();
        }
        let pages = matches!(m, method::MUX_ATTACH | method::MUX_EVENTS);
        let purge =
            m == method::MUX_KILL && params.get("purge").and_then(Value::as_bool).unwrap_or(false);
        // The row the request was resolved by names it: a purge removes only that generation, even
        // when the row went (and the id came back as another session) before the answer.
        let asked =
            (pages || purge).then(|| row.get("createdAt").and_then(Value::as_u64)).flatten();
        // A client that left takes its prompt or wait along: those wait on the peer's turn with no
        // deadline (`peer.rs` `waits_on_turn`), and nobody would read the answer. Every other
        // request keeps its deadline and always goes out: an attach the marker above stands for
        // must reach the peer even when its client is gone.
        // A page goes on the link it is labelled with, or fails; so does a held prompt, an
        // answer to one or a read of one, on the link that listed its feature.
        let mut on = bound.unwrap_or_else(|| pages.then_some(link).or(resume_link.flatten()));
        // A prompt goes on the link whose restore decision let it go, and no other.
        if let Some((generation, epoch)) = gate {
            if peer.generation != generation || on.is_some_and(|o| o != epoch) {
                return Err(peer.unreachable_error());
            }
            on = Some(epoch);
        }
        let result = if matches!(
            m,
            method::MUX_INFO
                | method::MUX_EVENTS
                | method::MUX_HISTORY
                | method::MUX_SESSION_SEARCH
        ) {
            // History reads answer from the current snapshot, even during a running turn.
            // A connected link can still have a stuck handler; do not inherit its ten-minute
            // generic deadline. Dropping this future releases its pending reply entry. Attach
            // keeps its existing lifecycle: it installs a live subscription before replying.
            tokio::time::timeout(std::time::Duration::from_secs(30), peer.request_on(m, p, on))
                .await
                .unwrap_or_else(|_| Err(RpcError::internal(format!(
                    "reading {m} from peer {} did not finish within 30 seconds; check the peer connection and retry this read",
                    peer.name
                )).with_data(json!({"reason": "peer_read_timeout", "peer": peer.name, "method": m}))))
        } else if crate::peer::waits_on_turn(m) {
            tokio::select! {
                result = peer.request_on(m, p, on) => result,
                () = conn.closed() => Err(RpcError::internal("the client closed the connection")),
            }
        } else {
            peer.request_on(m, p, on).await
        };
        // Older peers can answer without a separate acceptance notification.
        // Reconcile that successful result too, before the intent is settled.
        if let Some(intent) = forward_intent.as_deref() {
            match &result {
                Ok(accepted)
                    if is_duplicate(accepted)
                        || duplicate.load(std::sync::atomic::Ordering::SeqCst) =>
                {
                    super::outbox::forward_unconfirmed(hub, intent);
                }
                Ok(accepted) => {
                    let stored =
                        if let Some((sender_session, sender, text, message_id)) = sender_message {
                            hub.append_sender_message_event(
                                &sender_session,
                                sender,
                                text,
                                message_id,
                                crate::store::now_ms(),
                                &peer.name,
                                &id,
                            )
                        } else {
                            false
                        };
                    super::outbox::forward_accepted(hub, intent, accepted.clone(), stored);
                }
                Err(error) => super::outbox::forward_refused(hub, intent, error),
            }
        }
        if let (Some(prompt_id), Some(token)) = (&accept, token) {
            hub.peer_accepts.forget(&peer.name, &id, prompt_id, token);
        }
        // `Peer::request` already took the peer's display lines out of the result and the error.
        if first_attach
            && m == method::MUX_ATTACH
            && let Err(e) = &result
        {
            // Do not strand the marker when the first baseline request failed.
            // A retry must be able to establish a fresh no-history cursor.
            peer.clear_attached(&id);
            // The client was subscribed to the chat, and the link has no stream of it: one the
            // peer did not refuse is attached again on this link while it stays up.
            if !crate::peer::refuses_attach(e) {
                peer.retry_attach(&id, link);
            }
        }
        let mut result = result.map_err(|e| {
            if matches!(m, method::MUX_FILE_PUT_BEGIN | method::MUX_FILE_PUT_CHUNK | method::MUX_FILE_PUT_FINISH | method::MUX_FILE_PUT_CANCEL | method::MUX_FILE_PUT_STATUS)
                && e.message.contains("Method not found")
            {
                crate::hub::file_uploads::peer_unsupported(&peer)
            } else if e.message.contains("Method not found") {
                            RpcError::internal(format!("peer {} does not support {m}; it runs acpmux build {} (this daemon: {}); run `acpmux machine update {}`", peer.name, peer.remote_build().unwrap_or_else(|| "unknown".into()), crate::hub::build(), peer.name))
                                .with_data(json!({
                                    "reason": "peer_version_skew",
                                    "try": format!("acpmux machine update {}", peer.name),
                                    "peer": peer.name,
                                    "method": m,
                                }))
                        } else if matches!(m, method::MUX_PERMISSION_RESPOND | method::MUX_PERMISSION_GROUP_RESPOND) {
                            // A refused answer names the peer that refused it, so the app can say
                            // where to enroll this Mac (`hub/mac_approvers.rs`).
                            name_peer(e, &peer.name)
                        } else {
                            e
                        }
                    })?;
        let held = |r: &Value| r.get("events").and_then(Value::as_array).map(Vec::len);
        let before = held(&result);
        strip_asks(hub, &peer.name, &id, m, &mut result);
        if m == method::MUX_ATTACH
            && first_attach
            && peer.link_epoch() == link
            && params.get("beforeSeq").is_none_or(Value::is_null)
        {
            // Only the first attachment establishes a baseline. A later client's
            // page can outrun queued live events still owed to existing subscribers.
            if params.get("limit").and_then(Value::as_u64) == Some(0)
                && params.get("afterSeq").is_none_or(Value::is_null)
            {
                peer.note_hidden_attach_page(&id, &result);
            } else if let Some(after) = params.get("afterSeq").and_then(Value::as_u64) {
                peer.note_attached_page_after(&id, after, &result);
            } else if held(&result).is_some_and(|n| n > 0)
                || (params.get("kinds").is_none_or(Value::is_null) && held(&result) == before)
            {
                // Advance only after permission-history filtering. An empty page settles the
                // baseline at its `pageThrough` only when it held every record through it: no
                // `kinds` left some out, and no ask was taken out here.
                peer.note_attached_page(&id, &result);
            }
        }
        // What the client reads of a peer's chat is kept here too, so the chat
        // paints while the peer is paused or offline (`hub/peer_snapshot.rs`).
        // A page that lost records here no longer holds every seq it covers.
        if matches!(m, method::MUX_ATTACH | method::MUX_EVENTS) && held(&result) == before {
            let on = (peer.name.as_str(), peer.generation, link, asked);
            hub.capture_peer_page(on, (&id, m == method::MUX_EVENTS), params, &result);
        }
        // This daemon does not carry a peer chat's presence (`hub/presence.rs`).
        if m == method::MUX_ATTACH
            && let Some(obj) = result.as_object_mut()
        {
            obj.insert("presence".into(), crate::hub::presence::none(&id));
        }
        if m == method::MUX_PERMISSION_GROUPS && result.is_object() {
            mac_group_read(&mut result, conn.is_person() && hub.person.macs.has_own());
        }
        if matches!(m, method::SESSION_FORK | method::ACP_SESSION_FORK)
            && let Some(new_id) = result.get("sessionId").and_then(Value::as_str)
        {
            super::view::subscribe_remote(hub, conn, new_id, None);
            peer.mark_attached(new_id);
        }
        if purge {
            hub.forget_remote((&peer.name, peer.generation), &id, asked);
        }
        // Qualify race references only for the local viewer, after saving the raw peer page.
        if conn.origin != Origin::Peer
            && let Some(events) = result.get_mut("events").and_then(Value::as_array_mut)
        {
            for event in events {
                super::races::peer::qualify_event(&peer.name, event);
            }
        }
        if let Some(obj) = result.as_object_mut() {
            obj.insert("peer".into(), Value::String(peer.name.clone()));
        }
        return Ok(Some(result));
    }
    // `PEER/name` for a peer that is down (or whose list is not in yet) and lists no such session:
    // say the peer is unreachable, not that the session does not exist. A peer daemon's
    // connection never learns this host's peers or their state (`redact::hide_peers_from_peer`):
    // it gets the answer a name no peer has gets.
    if !SESSION_SCOPED_EXCLUDED.contains(&m)
        && conn.origin != Origin::Peer
        && let Ok(key) = session_key(params)
        && hub.resolve(key).is_err()
        && let Some(e) = hub.peer_down_for(key).or_else(|| hub.peer_unlisted_for(key))
    {
        return Err(e);
    }
    Ok(None)
}

fn hold_attach_peer_refusal(params: &Value) -> Option<RpcError> {
    (params.get("hold") == Some(&Value::Bool(true))).then(|| {
        RpcError::invalid_params("attach hold is local-only; peer chats retain the v1 attach")
            .with_data(json!({"reason": "attach_hold.peer_refused"}))
    })
}

/// A peer's `_acpmux/permission_groups` reply, as this daemon's client may draw it. This
/// daemon's link is never the person on the peer, so the peer refuses every group allow it
/// forwards (`hub/person.rs`), whatever its build says: the client draws none
/// (`allowRefused`). One exception: the peer counts an enrolled Mac's signed Allow once
/// (`macAllowOnce`), and the reader is this machine's person whose app holds this Mac's
/// approver key (`mac_signs`): it may draw Allow once and Deny, never Allow for the chat.
fn mac_group_read(result: &mut Value, mac_signs: bool) {
    if !(mac_signs && result.get("macAllowOnce") == Some(&Value::Bool(true))) {
        result["allowRefused"] = json!(crate::hub::person::REASON);
        return;
    }
    if let Some(obj) = result.as_object_mut() {
        obj.remove("allowRefused");
    }
    for group in result.get_mut("groups").and_then(Value::as_array_mut).into_iter().flatten() {
        if let Some(decisions) = group.get_mut("decisions").and_then(Value::as_array_mut) {
            decisions.retain(|d| d != "allow_chat");
        }
    }
}

/// Drop from a peer's reply for its session `id` every ask the peer may
/// not put before this daemon's clients: the `pending` entries of an
/// `_acpmux/info` detail or an `_acpmux/attach` `session` that fail
/// `Hub::peer_ask_counts`, and the ask records in `events`
/// (`_acpmux/attach`, `_acpmux/events`), which the app reads a nonce and run
/// from too, that `Hub::peer_history_ask_counts` drops (its own asks from an
/// older run stay there without their nonce). The rest of the reply, and the
/// session, stay.
pub(crate) fn strip_asks(hub: &Hub, peer: &str, id: &str, m: &str, result: &mut Value) {
    let pending = match m {
        method::MUX_INFO => Some("/pending"),
        method::MUX_ATTACH => Some("/session/pending"),
        _ => None,
    };
    if let Some(Value::Array(asks)) = pending.and_then(|p| result.pointer_mut(p)) {
        asks.retain(|ask| hub.peer_ask_counts(peer, id, ask));
    }
    if let Some(Value::Array(records)) = result.get_mut("events") {
        records.retain_mut(|r| {
            let kind = r.get("kind").and_then(Value::as_str).unwrap_or("");
            if !crate::hub::is_permission_ask(kind) {
                return true;
            }
            match r.get_mut("msg") {
                Some(msg) => hub.peer_history_ask_counts(peer, id, msg),
                None => false,
            }
        });
    }
}

/// An `_acpmux/info`'s flag: the session list's row will do for its answer. For a peer's chat
/// whose link's rows are current ([`crate::peer::Peer::rows_current`]), this daemon answers from
/// its mirrored row instead of asking the peer (`acpmux send` saves a round trip over the link).
/// The answer says `row: true`. Never sent on to the peer.
///
/// A send's `_acpmux/attach` still goes to the peer: attaches from several clients here share
/// the link's one subscription at the peer and are applied there in no fixed order, so this
/// daemon cannot know which `kinds` filter that subscription has.
pub const ROW_WILL_DO: &str = "row";

fn row_will_do(params: &Value) -> bool {
    params.get(ROW_WILL_DO).and_then(Value::as_bool) == Some(true)
}

/// A peer chat's mirrored row as a read's answer, marked so (`ROW_WILL_DO`).
pub(super) fn from_row(row: &Value, peer: &str) -> Value {
    let mut reply = row.clone();
    if let Some(obj) = reply.as_object_mut() {
        obj.insert("peer".into(), json!(peer));
        obj.insert(ROW_WILL_DO.into(), json!(true));
    }
    reply
}

/// `_meta.acpmux` field of a forwarded `permission_respond`: how many
/// daemons forwarded it so far.
pub const PEER_HOPS_FIELD: &str = "peerHops";
/// At most this many forwards: a chain of peers needs a few, and two
/// daemons that each list the session as the other's cannot pass an
/// answer back and forth without end.
pub const MAX_PEER_HOPS: u64 = 4;

/// The sudo card's record kinds (`hub/elevation.rs`) stay off a forwarded read: a peer chat never
/// has one (elevation is this daemon's own chats only), and a peer on an older build refuses an
/// attach or read naming more than 8 kinds, which a phone asking for them would then hit.
fn drop_local_kinds(forwarded: &mut Value) {
    if let Some(kinds) = forwarded.get_mut("kinds").and_then(Value::as_array_mut) {
        kinds.retain(|k| !matches!(k.as_str(), Some("elevation_request" | "elevation_decision")));
    }
}

/// A history read (`attach`, `events`) goes to the peer with the byte limit this daemon would
/// page to: a peer on an older build has no limit of its own and answers in one reply however
/// large, and one of 32.8 MB reset the link with its 29 chats (2026-10-21).
fn bound_page(m: &str, params: &Value, forwarded: &mut Value) {
    if matches!(m, method::MUX_ATTACH | method::MUX_EVENTS)
        && let Some(object) = forwarded.as_object_mut()
    {
        object.insert("maxBytes".into(), json!(crate::hub::page_bytes(params)));
    }
}

/// Count one more forward of an answer, or refuse one past the limit.
fn count_hop(forwarded: &mut Value) -> Result<(), RpcError> {
    let hops = forwarded
        .pointer(&format!("/_meta/acpmux/{PEER_HOPS_FIELD}"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    if hops >= MAX_PEER_HOPS {
        return Err(RpcError::invalid_params(format!(
            "this permission answer was forwarded between peers {hops} times (at most {MAX_PEER_HOPS} hops)"
        )));
    }
    crate::hub::merge_mux_meta(forwarded, json!({PEER_HOPS_FIELD: hops + 1}));
    Ok(())
}

/// The `_meta.acpmux` fields of a `session/new` that stay on this daemon when it is forwarded
/// to a peer (`_meta.acpmux.peer`).
pub(super) fn strip_new_meta(p: &mut Value) {
    if let Some(m) = p.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        m.remove("peer");
        // A family lives on one daemon: this daemon's caller is no session there.
        m.remove(crate::hub::lineage::PARENT_FIELD);
        m.remove(crate::hub::lineage::TOOL_CALL_FIELD);
        // The peer would tie it to this daemon's long-lived connection, never to the
        // client's: the client's own kill purges it (`ephemeral.rs`).
        m.remove("ephemeral");
        // Retry hints use the original params here; the peer does not need the
        // CLI argv or a second copy of the prompt file to create the session.
        m.remove("argv");
        m.remove("promptFileText");
        // Only this daemon decides the VM boundary, never its caller.
        m.remove(crate::hub::vm_boundary::FIELD);
        // A launch credential never leaves this daemon (`agent_credentials.rs`).
        m.remove(crate::agent_credentials::FIELD);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A saved prompt's `name` is never a session's: no peer gets the library's requests.
    #[test]
    fn saved_prompts_stay_on_this_daemon() {
        for m in [
            method::MUX_PROMPTS_LIST,
            method::MUX_PROMPTS_SAVE,
            method::MUX_PROMPTS_DELETE,
            method::MUX_STASH_LIST,
            method::MUX_STASH_PUSH,
            method::MUX_STASH_GET,
            method::MUX_STASH_DROP,
            method::MUX_STASH_MOVE,
        ] {
            assert!(!names_a_session(m), "{m}");
        }
    }

    #[test]
    fn a_forwarded_start_keeps_its_name_and_asks_to_keep_a_taken_one() {
        let mut p = json!({"_meta": {"acpmux": {
            "peer": "far-host", "name": "slam-09", "harness": "codex",
            "ifNameTaken": crate::hub::SUFFIX_TAKEN_NAME,
        }}});
        strip_new_meta(&mut p);
        assert_eq!(p["_meta"]["acpmux"]["name"], "slam-09");
        assert_eq!(p["_meta"]["acpmux"]["ifNameTaken"], "suffix");
        assert!(p["_meta"]["acpmux"].get("peer").is_none());
    }

    #[test]
    fn a_peer_hold_attach_is_refused_before_forwarding() {
        let error = hold_attach_peer_refusal(&json!({"hold": true})).expect("refusal");
        assert_eq!(error.data.unwrap()["reason"], "attach_hold.peer_refused");
        assert!(hold_attach_peer_refusal(&json!({"hold": false})).is_none());
    }

    /// A registration's NAME is never a destination: it is not forwarded to a peer session of that
    /// name, so the caller's messaging token never leaves this daemon.
    #[test]
    fn a_registration_is_never_forwarded_to_a_peer() {
        assert!(!names_a_session(method::MUX_REGISTER));
    }

    /// A phone's read of a peer chat keeps within the kinds an older peer takes: the sudo card's
    /// kinds, which a peer chat never has, are dropped (review F1 of cc3c3cf).
    #[test]
    fn a_forwarded_read_leaves_the_sudo_card_kinds_here() {
        let kinds = [
            "transcript",
            "queue_updated",
            "queue_order",
            "queue_paused",
            "queue_resumed",
            "claude.system.api_retry",
            "bookmarks",
            "elevation_request",
            "elevation_decision",
        ];
        let mut p = json!({"sessionId": "s", "kinds": kinds});
        drop_local_kinds(&mut p);
        assert_eq!(p["kinds"], json!(&kinds[..7]));
        let mut none = json!({"sessionId": "s"});
        drop_local_kinds(&mut none);
        assert_eq!(none, json!({"sessionId": "s"}));
    }

    /// An explicit peer removal must release *every* upload waiting for the
    /// reconnect. The old waiter listened only to completed connection attempts,
    /// so an idle/stopped peer kept these calls for 30 seconds.
    #[tokio::test]
    async fn removed_peer_wakes_all_waiting_uploads_without_a_connect_attempt() {
        let (notices, _receiver) = tokio::sync::mpsc::channel(1);
        let peer = crate::peer::Peer::new("gone", "ws://127.0.0.1:9", None, None, notices);
        let mut pending = Vec::new();
        for _ in 0..2 {
            let peer = peer.clone();
            pending.push(tokio::spawn(async move {
                await_link(&peer, std::time::Duration::from_secs(30)).await
            }));
        }
        // Peer::run is deliberately absent: removal itself, not a later
        // connection outcome, must wake each waiter.
        tokio::task::yield_now().await;
        peer.stop();
        for task in pending {
            let result = tokio::time::timeout(std::time::Duration::from_secs(1), task)
                .await
                .expect("a stopped peer left its upload waiting for the 30 s timeout")
                .unwrap();
            assert!(!result, "stopped peer was reported ready");
        }
    }

    /// An upload for a peer whose link is down keeps waiting past one reinforce interval (the
    /// old fixed 30 s refused it there while the app still waited), and ends at once, refused,
    /// when the peer is removed.
    #[tokio::test(start_paused = true)]
    async fn an_upload_holds_for_the_link_past_one_reinforce_until_the_peer_goes() {
        let (notices, _receiver) = tokio::sync::mpsc::channel(1);
        let peer = crate::peer::Peer::new("down", "ws://127.0.0.1:9", None, None, notices);
        let held = tokio::spawn({
            let peer = peer.clone();
            async move { hold_upload_for_link(&peer).await }
        });
        tokio::time::sleep(PROMPT_LINK_REINFORCE * 3).await;
        assert!(!held.is_finished(), "the upload gave up while its client still waited");
        peer.stop();
        let ready = tokio::time::timeout(std::time::Duration::from_secs(1), held)
            .await
            .expect("a removed peer left its upload waiting")
            .unwrap();
        assert!(!ready, "a removed peer was reported ready");
    }

    /// A message for a down peer's session wakes the peer whoever sent it, a peer daemon's
    /// forward of another daemon's send included; any other request from a peer daemon asks
    /// nothing, and a client's wants the link back without asking its route to wake a machine.
    #[test]
    fn only_a_message_asks_a_down_peers_route_to_wake_it() {
        let peer = || {
            let (notices, _receiver) = tokio::sync::mpsc::channel(1);
            crate::peer::Peer::new("fs-lane-3", "ssh://fs-lane-3", None, None, notices)
        };
        let none = json!({});
        for origin in [Origin::Peer, Origin::Local, Origin::Web] {
            let p = peer();
            ask_back(&p, method::SESSION_PROMPT, &none, origin);
            assert!(p.waking() && p.is_wanted(), "{origin:?}");
        }
        let p = peer();
        ask_back(&p, method::MUX_ATTACH, &none, Origin::Peer);
        assert!(!p.waking() && !p.is_wanted());
        let p = peer();
        ask_back(&p, method::MUX_ATTACH, &none, Origin::Local);
        assert!(!p.waking() && p.is_wanted());
    }

    /// A person starting to write to a down peer's chat wakes the peer before they send: typing
    /// on, or surface text that is not blank. Typing off, cleared text and a saved draft only
    /// want the link back, and a peer daemon's forward of any of them asks nothing. Typing,
    /// which `forward_inner` answers itself, wakes through `wake_if_composing` there.
    #[test]
    fn typing_to_a_down_peers_chat_wakes_it_before_the_send() {
        let peer = || {
            let (notices, _receiver) = tokio::sync::mpsc::channel(1);
            crate::peer::Peer::new("fs-lane-3", "ssh://fs-lane-3", None, None, notices)
        };
        let writing = [
            (method::MUX_TYPING, json!({"sessionId": "s", "on": true})),
            (method::MUX_COMPOSER_SET, json!({"sessionId": "s", "surface": "pane", "text": "h"})),
        ];
        for (m, params) in &writing {
            for origin in [Origin::Local, Origin::Web] {
                let p = peer();
                ask_back(&p, m, params, origin);
                assert!(p.waking() && p.is_wanted(), "{m} from {origin:?}");
            }
            let p = peer();
            ask_back(&p, m, params, Origin::Peer);
            assert!(!p.waking() && !p.is_wanted(), "{m} forwarded by a peer daemon");
        }
        let idle = [
            (method::MUX_TYPING, json!({"sessionId": "s", "on": false})),
            (
                method::MUX_COMPOSER_SET,
                json!({"sessionId": "s", "surface": "pane", "text": "  \n"}),
            ),
            // The pane saves the chat it leaves as is: a draft write is no one typing.
            (method::MUX_DRAFT_SET, json!({"sessionId": "s", "text": "fix the"})),
            (method::MUX_COMPOSER_SET, json!({"sessionId": "s", "surface": "pane", "text": ""})),
        ];
        for (m, params) in &idle {
            let p = peer();
            ask_back(&p, m, params, Origin::Local);
            assert!(!p.waking() && p.is_wanted(), "{m} with nothing written");
        }
        let p = peer();
        assert!(wake_if_composing(&p, method::MUX_TYPING, &writing[0].1, Origin::Local));
        assert!(p.waking());
        let p = peer();
        assert!(!wake_if_composing(&p, method::MUX_TYPING, &writing[0].1, Origin::Peer));
        assert!(!p.waking() && !p.is_wanted());
    }

    /// A refused answer for a peer's prompt names that peer, so the app can say where to
    /// enroll this Mac; a peer the answer named itself is replaced by this daemon's name.
    #[test]
    fn a_refused_answer_names_the_peer() {
        let e = name_peer(crate::hub::person::person_required("allowing a permission"), "hb");
        assert_eq!(e.data.as_ref().unwrap()["peer"], "hb");
        assert_eq!(e.data.as_ref().unwrap()["reason"], crate::hub::person::REASON);
        let e = name_peer(RpcError::internal("x").with_data(json!({"peer": "far"})), "hb");
        assert_eq!(e.data.unwrap()["peer"], "hb");
    }

    /// A peer's group read: the person here whose app holds this Mac's key draws Allow once and
    /// Deny when the peer counts a Mac's signed allow; every other reader, or a peer that does
    /// not say so, draws no Allow.
    #[test]
    fn a_peers_group_read_draws_allow_once_only_for_a_mac_that_signs() {
        let read = || {
            json!({"groups": [{"decisions": ["allow_once", "allow_chat", "deny"]}],
                   "allowRefused": crate::hub::person::REASON, "macAllowOnce": true})
        };
        let mut r = read();
        mac_group_read(&mut r, true);
        assert!(r.get("allowRefused").is_none(), "{r}");
        assert_eq!(r["groups"][0]["decisions"], json!(["allow_once", "deny"]));
        let mut r = read();
        mac_group_read(&mut r, false);
        assert_eq!(r["allowRefused"], crate::hub::person::REASON);
        assert_eq!(r["groups"][0]["decisions"].as_array().unwrap().len(), 3);
        for old in [json!({"groups": []}), json!({"groups": [], "macAllowOnce": false})] {
            let mut r = old;
            mac_group_read(&mut r, true);
            assert_eq!(r["allowRefused"], crate::hub::person::REASON, "{r}");
        }
    }

    /// A history read forwarded to a peer names its byte limit: a peer on an older build pages to
    /// no limit of its own, and 5000 records of long tool outputs were one 32.8 MB reply that reset
    /// the link with its 29 chats (2026-10-21).
    #[test]
    fn a_forwarded_history_read_names_its_byte_limit() {
        for m in [method::MUX_ATTACH, method::MUX_EVENTS] {
            let mut p = json!({"sessionId": "s", "limit": 5000});
            bound_page(m, &json!({"limit": 5000}), &mut p);
            assert_eq!(p["maxBytes"], crate::hub::page_bytes(&json!({})), "{m}");
            // A limit the client asked for goes as this daemon caps it.
            let mut p = json!({"sessionId": "s"});
            bound_page(m, &json!({"maxBytes": 1u64 << 40}), &mut p);
            assert_eq!(p["maxBytes"], crate::hub::MAX_PAGE_BYTES, "{m}");
        }
        let mut p = json!({"sessionId": "s"});
        bound_page(method::SESSION_PROMPT, &json!({}), &mut p);
        assert!(p.get("maxBytes").is_none());
    }
}

#[cfg(test)]
mod message_identity_tests {
    use super::{is_duplicate, kept_another};
    use serde_json::json;

    /// A sender's copy is recorded only for the message the peer's acceptance names, and only
    /// when that acceptance is no duplicate; a peer that names none is taken at its word.
    #[test]
    fn an_acceptance_confirms_only_the_message_it_names() {
        let named = json!({"sessionId": "t", "promptId": "p", "messageId": "p",
                           "messageSenderId": "sender-a"});
        for names in [true, false] {
            assert!(!kept_another(&named, Some(("sender-a", "p")), names));
            assert!(kept_another(&named, Some(("sender-a", "delivery-1")), names));
            // Another session's send of the same prompt id is not ours either.
            assert!(kept_another(&named, Some(("sender-b", "p")), names));
            assert!(!kept_another(&named, None, names));
        }
        // An acceptance naming no message: from a peer that names messages it is another
        // prompt's (a person's, under the same id), so it confirms no session's send; from a
        // peer that never names one it is taken at its word.
        let unnamed = json!({"sessionId": "t", "promptId": "p"});
        assert!(kept_another(&unnamed, Some(("sender-a", "p")), true));
        assert!(!kept_another(&unnamed, Some(("sender-a", "delivery-1")), false));
        let half = json!({"sessionId": "t", "promptId": "p", "messageId": "p"});
        assert!(kept_another(&half, Some(("sender-a", "p")), true));
        assert!(!kept_another(&half, Some(("sender-a", "p")), false));
        assert!(is_duplicate(&json!({"promptId": "p", "duplicate": true, "turnId": "t1"})));
        assert!(is_duplicate(&json!({"stopReason": "end_turn",
                                     "_meta": {"acpmux": {"duplicate": true}}})));
        assert!(!is_duplicate(&named));
    }

    /// An empty `messageId` is no id: the receiver keeps the prompt id, and so does the sender.
    #[test]
    fn a_forwarded_message_is_named_as_its_receiver_names_it() {
        use super::super::outbox::forwarded_message_id;
        let with = |meta: serde_json::Value| json!({"_meta": {"acpmux": meta}});
        assert_eq!(forwarded_message_id(&with(json!({"messageId": "", "promptId": "p"}))), "p");
        assert_eq!(forwarded_message_id(&with(json!({"messageId": "m", "promptId": "p"}))), "m");
        assert_eq!(forwarded_message_id(&with(json!({"promptId": "p"}))), "p");
    }
}

#[cfg(test)]
#[path = "row_read_tests.rs"]
mod row_read_tests;

/// A method `features` gate, for a peer that listed none of them: its build does not serve it.
fn peer_feature_unsupported(peer: &crate::peer::Peer, m: &str, features: &[&str]) -> RpcError {
    RpcError::method_not_found(&format!(
        "{m} (peer {} runs acpmux build {}, which lists none of {features:?}; run `acpmux machine update {}`)",
        peer.name,
        peer.remote_build().unwrap_or_else(|| "unknown".into()),
        peer.name
    ))
    .with_data(json!({"reason": "peerFeature.unsupported", "peer": peer.name, "features": features}))
}

#[cfg(test)]
#[path = "prompt_link_wait_tests.rs"]
mod prompt_link_wait_tests;
