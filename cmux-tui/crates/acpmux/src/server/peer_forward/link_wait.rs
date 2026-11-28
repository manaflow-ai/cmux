//! A forwarded request's wait for its peer's link: a read that ends on a quiet link
//! (`peer_read`), an upload and a prompt held for a link that is down (`await_link`,
//! [`LinkWait`]). Part of `peer_forward.rs`.

use super::*;

/// How long a forwarded read waits with less than `PEER_READ_STEP` arriving on its link before it
/// fails: a stuck handler on a link carrying only pings and pongs ends here.
pub(in crate::server) const PEER_READ_IDLE: std::time::Duration =
    std::time::Duration::from_secs(30);
/// The link bytes that count as the reply coming in: well above a ping, a pong and the odd
/// notice, well below one reply page (`rpc::REPLY_PAGE_BYTES`, mesh pages of 4 KiB or more).
pub(in crate::server) const PEER_READ_STEP: u64 = 16 * 1024;
/// The most a read may take however busy its link stays: other chats' traffic can move the link
/// while this read's handler never answers.
pub(in crate::server) const PEER_READ_CAP: std::time::Duration =
    std::time::Duration::from_secs(5 * 60);

/// Why a forwarded read ended without its answer.
#[derive(Debug, PartialEq, Eq)]
pub(in crate::server) enum ReadStalled {
    /// Less than `PEER_READ_STEP` arrived in this long.
    Idle(std::time::Duration),
    /// The link kept moving but no answer came in this long.
    Cap(std::time::Duration),
}

impl std::fmt::Display for ReadStalled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Idle(d) => write!(f, "the link brought no reply for {} seconds", d.as_secs()),
            Self::Cap(d) => write!(f, "no answer after {} seconds", d.as_secs()),
        }
    }
}

/// `fut`, ended when `read` (the link's transport bytes) moves less than `PEER_READ_STEP` in
/// `idle`, or at `cap`. A slow link bringing a large page keeps the read alive; a silent one ends
/// at `idle` as before.
pub(in crate::server) async fn peer_read<F: std::future::Future>(
    read: &cmux_deadline::Progress,
    idle: std::time::Duration,
    cap: std::time::Duration,
    fut: F,
) -> Result<F::Output, ReadStalled> {
    let started = tokio::time::Instant::now();
    let mut since = started;
    let mut mark = read.count();
    let tick = (idle / 8).max(std::time::Duration::from_millis(50));
    tokio::pin!(fut);
    loop {
        let now = tokio::time::Instant::now();
        let count = read.count();
        if count.saturating_sub(mark) >= PEER_READ_STEP {
            mark = count;
            since = now;
        }
        if now.saturating_duration_since(started) >= cap {
            return Err(ReadStalled::Cap(cap));
        }
        if now.saturating_duration_since(since) >= idle {
            return Err(ReadStalled::Idle(idle));
        }
        let wake = (since + idle).min(started + cap).min(now + tick);
        tokio::select! {
            out = &mut fut => return Ok(out),
            () = tokio::time::sleep_until(wake) => {}
        }
    }
}

/// How long a prompt for a peer's chat waits for that peer's link before it is refused as
/// unreachable, for a sender that keeps such a message itself: a peer daemon's forward (its own
/// outbox tries it again) and the acpmux CLI, which queues a refused send in this daemon's outbox
/// ("machine is unreachable; queued here", `cli/run/standard.rs`). Every other client's prompt is
/// held instead ([`PROMPT_QUEUED_AFTER`]). The wait wakes the peer (`Peer::wake`), so a connect
/// attempt comes at most `Backoff::WANTED_CAP` (1 s) after the last while it waits
/// (`peer_wanted.rs`). 8 s is about seven attempts, each with its handshake: a daemon's restart
/// handoff or a Wi-Fi drop of a few seconds.
pub(in crate::server) const PROMPT_LINK_WAIT: std::time::Duration =
    std::time::Duration::from_secs(8);

/// How long a prompt from a unix-socket client that keeps no refused message itself (the app's
/// and the phone's chats, through cmux-tui-core) waits for its peer's link on its request before
/// it is kept in this daemon's outbox and answered as queued for the link ([`LinkWait::Outbox`]):
/// the same live wait as [`PROMPT_LINK_WAIT`], so a blip still answers with the turn there, and a
/// longer outage is queued, never refused (Leo, 2026-11-24: "10s timeout for messages being
/// sendsble is a shame. if it's making good progress, it shiukd be allowed to keep going?").
pub(in crate::server) const PROMPT_QUEUED_AFTER: std::time::Duration = PROMPT_LINK_WAIT;

/// How often a held prompt asks for its peer again while it waits (`Peer::wake`, which keeps the
/// peer wanted and runs the wake hook at most once per `WAKE_FOR`): the reconnects keep coming
/// within `Backoff::WANTED_CAP` for as long as the prompt waits, not only for the first
/// `WANTED_FOR` (Leo, 2026-11-24: "let's just keep optimistically connecting and reinforcing the
/// connection").
pub(in crate::server) const PROMPT_LINK_REINFORCE: std::time::Duration =
    std::time::Duration::from_secs(30);

/// How long a held prompt waits for its peer's link at most: the outbox's day
/// (`hub/outbox.rs` `RETRY_FOR_MS`). Past it the prompt is refused as unreachable.
pub(in crate::server) const PROMPT_HOLD_FOR: std::time::Duration =
    std::time::Duration::from_millis(crate::hub::outbox::RETRY_FOR_MS);

/// The upload methods that wait for a peer's link (`await_link`).
pub(in crate::server) fn waits_for_link(m: &str) -> bool {
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
pub(in crate::server) async fn await_link(
    peer: &crate::peer::Peer,
    within: std::time::Duration,
) -> bool {
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
pub(super) async fn hold_upload_for_link(peer: &crate::peer::Peer) -> bool {
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

/// Whether `e` is a refusal of a request that never left this daemon: the peer's link took
/// nothing (`peer_link::unreachable_error`).
pub(super) fn unsent(e: &RpcError) -> bool {
    e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str)
        == Some("peer_unreachable")
}

/// How a prompt for a peer's chat whose link is down waits for the link.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum LinkWait {
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
pub(super) fn link_wait(conn: &Conn) -> LinkWait {
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
pub(super) fn holds_again(
    conn: &Conn,
    peer: &crate::peer::Peer,
    hold: Option<&Hold>,
    e: &RpcError,
) -> bool {
    unsent(e)
        && link_wait(conn) != LinkWait::Brief
        && !peer.ready()
        && !*peer.stopped().borrow()
        && hold.is_none_or(|h| tokio::time::Instant::now() < h.until)
}

/// A prompt held for its peer's link: when the hold ends.
pub(super) struct Hold {
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
pub(super) async fn wait_for_prompt_link(
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
    if super::super::remote_guard::cloud_mobile(params) {
        return Err(super::super::remote_guard::refuse_cloud_mobile_forward());
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
pub(super) async fn queue_for_link(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    peer: &crate::peer::Peer,
    params: &Value,
) -> Result<Value, RpcError> {
    let request = json!({"request": params});
    let kept =
        Box::pin(super::super::outbox::handle(hub, conn, method::MUX_SEND_QUEUE, &request)).await?;
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
