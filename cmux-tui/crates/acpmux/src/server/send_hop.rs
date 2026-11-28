//! One hop for a send to a host this daemon does not peer (#58731).
//!
//! `acpmux send HOST/NAME` where HOST is no peer of this daemon was a bare `no session`, though a
//! peer of this daemon (the coordinator hub) peers HOST. Now the origin asks its connected peers
//! whether they peer HOST and take hops ([`MUX_SEND_HOP`] with no `send`, a probe), and hands the
//! send to the first that does. That peer queues it in its own outbox as a relayed message
//! (`fromRelay`, `by: acpmux-hop`), so the far chat names the true sender, not the peer's person.
//!
//! The settled rule "a peer cannot select another peer" stays: a daemon takes hops only when its
//! own config says `sendHop: true` (default off), only from a paired peer daemon, only to a host
//! it peers directly, and a hop never hops again (`outbox::queue`'s `hop_in`). With no route the
//! refusal names every peer it asked and why each could not carry it.

use super::*;
use std::time::Duration;

/// With `send`, queue it toward `host`; without, a probe.
use crate::rpc::method::MUX_SEND_HOP;
/// How the relay names itself in the relay record (`prompt_provenance::FROM_RELAY`).
pub const HOP_RELAY: &str = "acpmux-hop";
/// How long a probe of one peer may take; a peer that does not answer is no route.
const PROBE_WAIT: Duration = Duration::from_secs(3);
/// How long the hop's queueing on the relaying peer may take.
const SEND_WAIT: Duration = Duration::from_secs(15);

/// What the origin's hop came to.
pub(super) enum Hop {
    /// A peer queued it: its answer, with `via` naming the peer.
    Sent(Value),
    /// A peer that takes hops refused it or did not answer: that refusal, with the route.
    Failed(RpcError),
    /// No peer could carry it: each peer asked, and why not (empty when no hop applies).
    NoRoute(Vec<Value>),
}

/// The host `target` names when it is `HOST/NAME` on a host that is neither this machine nor a
/// peer of this daemon: the only targets a hop is for.
pub(super) fn hop_host<'a>(
    target: &'a str,
    here: &str,
    peered: impl Fn(&str) -> bool,
) -> Option<&'a str> {
    let (host, name) = target.split_once('/')?;
    if host.is_empty() || name.is_empty() || host.eq_ignore_ascii_case(here) || peered(host) {
        return None;
    }
    Some(host)
}

/// Adds the route a send tried to a no-session refusal's text and data.
pub(super) fn note_route(text: &mut String, data: &mut Value, tried: &[Value]) {
    if tried.is_empty() {
        return;
    }
    let route: Vec<String> = tried
        .iter()
        .map(|t| {
            let peer = t.get("peer").and_then(Value::as_str).unwrap_or("?");
            let why = t.get("why").and_then(Value::as_str).unwrap_or("?");
            format!("{peer} ({why})")
        })
        .collect();
    text.push_str(&format!("; tried a hop via: {}", route.join(", ")));
    if let Some(o) = data.as_object_mut() {
        o.insert("hop".into(), json!({"tried": tried}));
    }
}

/// Why a probe's answer is no route through that peer, or `None` when the peer carries it.
pub(super) fn probe_refusal(answer: &Value) -> Option<&'static str> {
    let flag = |k: &str| answer.get(k).and_then(Value::as_bool) == Some(true);
    if !flag("peered") {
        Some("does not peer the host")
    } else if !flag("relays") {
        Some("peers the host, sendHop off")
    } else {
        None
    }
}

fn refused(reason: &str, message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": reason}))
}

/// The origin's side: a hop for `target` when it names a host this daemon does not peer.
pub(super) async fn try_hop(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    request: &Value,
    target: &str,
) -> Hop {
    let here = crate::hub::host_label();
    let Some(host) = hop_host(target, here, |h| hub.peer_by_name(h).is_some()) else {
        return Hop::NoRoute(vec![]);
    };
    let peers = hub.connected_peers();
    if peers.is_empty() {
        return Hop::NoRoute(vec![json!({"peer": "none", "why": "no peer connected"})]);
    }
    let probe = json!({"host": host});
    let asks = peers.iter().map(|p| {
        let probe = probe.clone();
        async move {
            let answer = tokio::time::timeout(PROBE_WAIT, p.request(MUX_SEND_HOP, probe)).await;
            (p.clone(), answer)
        }
    });
    let mut tried = vec![];
    let mut carriers: Vec<(bool, Arc<crate::peer::Peer>)> = vec![];
    for (p, answer) in futures::future::join_all(asks).await {
        let why = match answer {
            Ok(Ok(v)) => match probe_refusal(&v) {
                None => {
                    let up = v.get("connected").and_then(Value::as_bool) == Some(true);
                    carriers.push((up, p));
                    continue;
                }
                Some(why) => why.to_owned(),
            },
            Ok(Err(e)) => format!("probe refused: {}", e.message),
            Err(_) => "probe timed out".to_owned(),
        };
        tried.push(json!({"peer": p.name, "why": why}));
    }
    // A peer whose link to the host is up first; one whose link is down still queues it.
    carriers.sort_by_key(|(up, _)| !*up);
    let Some((_, via)) = carriers.into_iter().next() else {
        return Hop::NoRoute(tried);
    };
    let session = conn.caller().map(|id| hub.session_name(id));
    let send = json!({
        "host": host,
        "send": {"request": request},
        "from": {"machine": here, "session": session},
    });
    let route = |why: String| json!({"peer": via.name, "why": why});
    match tokio::time::timeout(SEND_WAIT, via.request(MUX_SEND_HOP, send)).await {
        Ok(Ok(mut answer)) => {
            if let Some(o) = answer.as_object_mut() {
                o.insert("via".into(), json!(via.name));
            }
            Hop::Sent(answer)
        }
        Ok(Err(mut e)) => {
            tried.push(route(format!("refused: {}", e.message)));
            e.message = format!("{} (hop via {})", e.message, via.name);
            let mut data = e.data.take().unwrap_or_else(|| json!({}));
            if let Some(o) = data.as_object_mut() {
                o.insert("hop".into(), json!({"tried": tried, "via": via.name}));
            }
            Hop::Failed(e.with_data(data))
        }
        Err(_) => {
            tried.push(route("no answer".to_owned()));
            Hop::Failed(
                RpcError::internal(format!(
                    "send to {target}: hop via {} did not answer in {}s; it may still be queued there",
                    via.name,
                    SEND_WAIT.as_secs()
                ))
                .with_data(json!({"reason": "hop.no_answer", "hop": {"tried": tried, "via": via.name}})),
            )
        }
    }
}

/// The relaying daemon's side of [`MUX_SEND_HOP`].
pub(super) async fn serve(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
) -> Result<Value, RpcError> {
    if conn.origin != Origin::Peer || !conn.auth.peer_daemon() {
        return Err(refused("hop.peers_only", "send_hop is for a paired peer daemon"));
    }
    let host = params
        .get("host")
        .and_then(Value::as_str)
        .filter(|h| !h.is_empty())
        .ok_or_else(|| RpcError::invalid_params("host is required"))?;
    let relays = hub.config.read().await.send_hop == Some(true);
    let peer = hub.peer_by_name(host);
    let peered = peer.is_some();
    let connected =
        peer.as_ref().is_some_and(|p| p.connected.load(std::sync::atomic::Ordering::SeqCst));
    let Some(send) = params.get("send") else {
        return Ok(
            json!({"host": host, "peered": peered, "connected": connected, "relays": relays}),
        );
    };
    if !relays {
        return Err(refused(
            "hop.off",
            format!("{} takes no hops (sendHop off)", crate::hub::host_label()),
        ));
    }
    if !peered {
        return Err(refused(
            "hop.not_peered",
            format!("{} does not peer {host}", crate::hub::host_label()),
        ));
    }
    let mut send = send.clone();
    let request = send
        .get_mut("request")
        .filter(|r| r.is_object())
        .ok_or_else(|| RpcError::invalid_params("send.request is required"))?;
    let on_host = request
        .get("sessionId")
        .and_then(Value::as_str)
        .and_then(|t| t.split_once('/'))
        .is_some_and(|(h, _)| h == host);
    if !on_host {
        return Err(refused("hop.wrong_host", format!("send.request.sessionId must be on {host}")));
    }
    let from = params.get("from").cloned().unwrap_or_else(|| json!({}));
    stamp_relay(request, &from)?;
    super::outbox::queue(hub, conn, &send, true).await
}

/// Replaces whatever sender a hop's request names with the relay record of the machine and
/// session it came from: the far chat shows who sent it, never the relaying daemon's person.
pub(super) fn stamp_relay(request: &mut Value, from: &Value) -> Result<(), RpcError> {
    crate::prompt_provenance::drop_sender_fields(request);
    let record = json!({
        "by": HOP_RELAY,
        "machine": from.get("machine").cloned().unwrap_or(Value::Null),
        "session": from.get("session").cloned().unwrap_or(Value::Null),
    });
    let relay = crate::prompt_provenance::RelaySender::of(&record)
        .ok_or_else(|| refused("hop.bad_sender", "from.machine must name the sending machine"))?;
    let mux = request
        .as_object_mut()
        .map(|r| r.entry("_meta").or_insert_with(|| json!({})))
        .and_then(Value::as_object_mut)
        .map(|meta| meta.entry("acpmux").or_insert_with(|| json!({})))
        .and_then(Value::as_object_mut)
        .ok_or_else(|| RpcError::invalid_params("request._meta.acpmux must be an object"))?;
    mux.insert(crate::prompt_provenance::FROM_RELAY.into(), relay.to_value());
    mux.insert("fromAgent".into(), json!(relay.name()));
    Ok(())
}
