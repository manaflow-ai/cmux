//! The refusal `acpmux send` gives for a session the target machine does not have: `no session
//! NAME on HOST; did you mean: a, b, c`, naming the closest names on that machine.
//!
//! A send to a name the machine never had (a process title mistaken for the session's name)
//! used to be queued and tried again for a day, each attempt answering "no session matches";
//! the sender saw only "queued". The send refuses it at once when the machine is reachable
//! (`server/outbox.rs` `handle`), and a queued delivery that meets the same answer fails on the
//! first one (`server/outbox.rs` `Next::NoSession`).

use serde_json::{Value, json};

use super::{Hub, SessionStatus};
use crate::rpc::RpcError;

/// How many close names the refusal names.
const CLOSEST_SHOWN: usize = 3;

/// The prefix a delivery's error carries when it failed because the target has no such session
/// (`acpmux send --status` reads it as `failed: no_session`).
pub const NO_SESSION_PREFIX: &str = "no_session: ";

impl Hub {
    /// The no-session refusal for `key` (`NAME`, an id, or `HOST/NAME`): the host it was looked
    /// for on, the name, and the closest live names there (`data.candidates`). It keeps the
    /// `no session matches` start every client reads as no session.
    pub fn no_session_refusal(&self, key: &str) -> RpcError {
        let (text, data) = self.no_session_text(key);
        RpcError::not_found(format!("no session matches {key:?} ({text})")).with_data(data)
    }

    /// (`HOST`, `NAME`) when `key` is `HOST/NAME` naming a machine this daemon does not have:
    /// neither one of its machines nor this machine's own name. No session on such a machine
    /// could be found here, whether or not it exists there, so its absence is not the cause and
    /// its name is not what the sender should doubt.
    pub fn host_not_a_peer<'k>(&self, key: &'k str) -> Option<(String, &'k str)> {
        let (host, name) = key.split_once('/')?;
        (!host.is_empty()
            && !name.is_empty()
            && self.peer(host).is_none()
            && !super::own_host::is_own_machine_name(host))
        .then(|| (host.to_owned(), name))
    }

    /// (`no session NAME on HOST; did you mean: a, b, c`, the refusal's data) for `key`.
    pub fn no_session_text(&self, key: &str) -> (String, Value) {
        // A machine this daemon does not have is the whole cause: say that, and say it first.
        // Before this, such a key fell through `names_on_host_of` to this machine, so the
        // refusal read `no session HOST/NAME on <this machine>; did you mean: <local names>`:
        // it blamed the session name, and offered local sessions that could never be the remote
        // one asked for (2026-11-21, `acpmux send gcp-agent-lane-8/efficiency-scout` on big-red,
        // where the machine was reachable, its daemon up and the session live).
        if let Some((host, name)) = self.host_not_a_peer(key) {
            let text = not_a_peer_text(&host, name, "acpmux");
            // The reason stays `no_session` so a delivery still fails at once instead of being
            // tried again for a day (`server/outbox.rs` `Next::NoSession`); `hostNotAPeer` is
            // what tells a reader, and `cli/errors.rs`, that the machine is the cause.
            let data = json!({
                "reason": "no_session",
                "session": key,
                "host": host,
                "name": name,
                "candidates": Vec::<String>::new(),
                "hostNotAPeer": true,
            });
            return (text, data);
        }
        let (host, name, names) = self.names_on_host_of(key);
        let close = closest(&names, name);
        let mut text = format!("no session {name} on {host}");
        if close.is_empty() {
            text.push_str("; run `acpmux ls` for its sessions");
        } else {
            text.push_str(&format!("; did you mean: {}", close.join(", ")));
        }
        let data = json!({
            "reason": "no_session",
            "session": key,
            "host": host,
            "name": name,
            "candidates": close,
        });
        (text, data)
    }

    /// Whether "no such session" for `key` is final: a session here, or a peer whose link is
    /// up and whose session list this hub applied. A peer that just reconnected may not have
    /// listed the session yet, and one that is down lists nothing new.
    pub fn no_session_is_final(&self, key: &str) -> bool {
        let Some(peer) = key.split_once('/').and_then(|(host, _)| self.peer(host)) else {
            return true;
        };
        peer.connected.load(std::sync::atomic::Ordering::SeqCst)
            && peer.rows_ready.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// Peer `peer`'s link listed its whole list, applied just before (`PeerNotice::Listed`): a
    /// name it lacks is no session there.
    pub(super) fn peer_listed(&self, peer: &str, generation: u64) {
        if let Some(p) = self.peer(peer).filter(|p| p.generation == generation) {
            p.rows_ready.store(true, std::sync::atomic::Ordering::SeqCst);
            p.note_rows_applied();
        }
        // Messages waiting for a name this list has go now, not after the rest of their retry
        // delay (`server/outbox.rs` `deliver`).
        self.outbox.peer_ready.notify_waiters();
    }

    /// Peer `peer`'s link is ready (`PeerNotice::Connected`). Most links' list came before it;
    /// one after a far restart or a path switch reads its list after (`Peer::lists_after_ready`),
    /// and until that list is applied a name missing from the rows (the last link's) is not
    /// final, though the restart left the rows ready (`peer_unlisted_for`).
    pub(super) fn peer_ready_rows(&self, peer: &str, generation: u64) {
        if let Some(p) = self.peer(peer).filter(|p| p.generation == generation) {
            p.rows_ready.store(p.rows_listed(), std::sync::atomic::Ordering::SeqCst);
        }
    }

    /// `peer`'s whole list `rows` and its link ready, applied as a first link sends them: the
    /// list, `Listed`, then `Connected`.
    #[cfg(test)]
    pub(crate) fn seed_peer_listed(&self, peer: &crate::peer::Peer, rows: Vec<Value>) {
        use crate::peer::PeerNotice::{self, Connected, Listed};
        for notice in [PeerNotice::sessions_from_values(rows), Listed, Connected] {
            self.apply_peer_notice(&peer.name, peer.generation, notice);
        }
    }

    /// The refusal for `PEER/name` when PEER's link is ready but this link's list is not in yet
    /// (one read after ready, `Peer::lists_after_ready`) and its rows lack the name: the
    /// session may be in the list still coming, so the answer is the retryable one a peer that
    /// is down gives (`peer_down_for`), not that the session does not exist.
    pub fn peer_unlisted_for(&self, key: &str) -> Option<RpcError> {
        use std::sync::atomic::Ordering::SeqCst;
        let (name, rest) = key.split_once('/')?;
        let peer = self.peer(name).filter(|_| !rest.is_empty())?;
        (peer.connected.load(SeqCst) && !peer.rows_ready.load(SeqCst))
            .then(|| peer.unreachable_error())
    }

    /// Whether a send to `key` goes to a peer whose link is down now: queued, and the answer
    /// says `hostUnreachable`. A row cached from before the peer went down does not make it
    /// reachable; a session here never counts.
    pub fn host_unreachable_for(&self, key: &str) -> bool {
        self.resolve(key).is_err() && self.peer_down_for(key).is_some()
    }

    /// (the machine `key` names, the name on it, that machine's live session names): a peer's
    /// rows for `PEER/NAME`, this machine's sessions for a bare key or this machine's own name.
    fn names_on_host_of<'k>(&self, key: &'k str) -> (String, &'k str, Vec<String>) {
        if let Some((host, rest)) = key.split_once('/')
            && !rest.is_empty()
            && self.peer(host).is_some()
        {
            let map = self.remote_sessions.read();
            let names = map
                .values()
                .filter(|r| r.peer == host && !super::peers::remote_closed(r))
                .filter_map(|r| r.summary.name())
                .map(|n| {
                    n.strip_prefix(host).and_then(|n| n.strip_prefix('/')).unwrap_or(n).to_owned()
                })
                .collect();
            return (host.to_owned(), rest, names);
        }
        let (host, name) = match key.split_once('/') {
            Some((host, rest))
                if !rest.is_empty() && super::own_host::is_own_machine_name(host) =>
            {
                (host.to_owned(), rest)
            }
            _ => (crate::pairing::machine_name(), key),
        };
        let names = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .filter_map(|s| {
                let meta = s.meta.lock().unwrap_or_else(|e| e.into_inner());
                (meta.status != SessionStatus::Closed && !meta.name.is_empty())
                    .then(|| meta.name.clone())
            })
            .collect();
        (host, name, names)
    }
}

/// The refusal for `HOST/NAME` whose `HOST` is not one of this daemon's machines, rendered in
/// one place so the daemon's text and the one `cli/errors.rs` rebuilds from the refusal's data
/// cannot drift. It names the machine first, because that is the cause, and ends with the two
/// next steps: add the machine, or run the send on it (the route that works meanwhile). It
/// suggests no session names: a name on this machine can never be the one asked for on another.
pub fn not_a_peer_text(host: &str, name: &str, program: &str) -> String {
    format!(
        "{host} is not a machine of this daemon, so no session {name} on it can be found here, \
         whether or not it exists there; add it with `{program} machine add ssh://{host}` \
         (`{program} machine ls` lists them), or send from that machine: \
         ssh {host} '{program} send {name} -'"
    )
}

/// The names in `names` closest to `key`, nearest first: those it is a segment, prefix or part
/// of (`session_name::candidates`), then the rest by edit distance, at most [`CLOSEST_SHOWN`].
pub fn closest(names: &[String], key: &str) -> Vec<String> {
    let mut out = crate::session_name::candidates(names.iter().map(String::as_str), key);
    out.truncate(CLOSEST_SHOWN);
    if out.len() < CLOSEST_SHOWN {
        let lower = key.to_ascii_lowercase();
        let mut rest: Vec<(usize, &String)> = names
            .iter()
            .filter(|n| !out.contains(n))
            .map(|n| (distance(&n.to_ascii_lowercase(), &lower), n))
            .collect();
        rest.sort();
        rest.dedup_by(|a, b| a.1 == b.1);
        out.extend(rest.into_iter().take(CLOSEST_SHOWN - out.len()).map(|(_, n)| n.clone()));
    }
    out
}

/// Levenshtein distance over chars, one row at a time.
fn distance(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut next = Vec::with_capacity(row.len());
        next.push(i + 1);
        for ((cb, diag), up) in b.iter().zip(&row).zip(row.iter().skip(1)) {
            let left = next.last().copied().unwrap_or(usize::MAX - 1);
            next.push((up + 1).min(left + 1).min(diag + usize::from(ca != *cb)));
        }
        row = next;
    }
    row.last().copied().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn the_closest_names_come_first_and_at_most_three() {
        let all = names(&["review-lane", "lane-2", "feed-lane", "lane", "zzz"]);
        assert_eq!(closest(&all, "lane"), ["lane", "lane-2", "feed-lane"]);
        // Nothing contains it: the nearest by edit distance, still three.
        let near = closest(&all, "feed-lan");
        assert_eq!((near[0].as_str(), near.len()), ("feed-lane", 3), "{near:?}");
        assert!(closest(&[], "lane").is_empty());
    }

    /// A peer's names are suggested whole under that peer (a nested `review/child` stays
    /// so), and "no such session" on a peer is final only once its list was applied.
    #[test]
    fn a_peers_names_keep_their_path_and_count_once_listed() {
        use std::sync::atomic::Ordering::SeqCst;
        let hub = Hub::new(
            crate::config::Config::default(),
            Box::new(crate::store::MemoryStore::default()),
        );
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = crate::peer::Peer::new("b", "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert("b".into(), peer.clone());
        let rows = vec![
            serde_json::json!({"sessionId": "s1", "name": "review/child", "status": "ready"}),
            serde_json::json!({"sessionId": "s2", "name": "gone-lane", "status": "closed"}),
        ];
        hub.apply_peer_notice(
            "b",
            peer.generation,
            crate::peer::PeerNotice::sessions_from_values(rows),
        );
        let (text, data) = hub.no_session_text("b/review/chil");
        assert_eq!(text, "no session review/chil on b; did you mean: review/child", "{data}");
        assert_eq!(data["candidates"], serde_json::json!(["review/child"]));
        // Not connected, nothing listed: not final.
        assert!(!hub.no_session_is_final("b/x"));
        peer.connected.store(true, SeqCst);
        assert!(!hub.no_session_is_final("b/x"), "connected, list not applied yet");
        // A request for it gets the retryable answer a peer that is down gives, not no session.
        let unlisted = hub.peer_unlisted_for("b/x").expect("its list is not in yet");
        assert_eq!(unlisted.data.as_ref().unwrap()["retryable"], true, "{unlisted:?}");
        assert!(hub.peer_down_for("b/x").is_none(), "the link is up");
        peer.rows_ready.store(true, SeqCst);
        assert!(hub.no_session_is_final("b/x"));
        assert!(hub.peer_unlisted_for("b/x").is_none(), "listed: no session is the answer");
        // A name on this machine is always final.
        assert!(hub.no_session_is_final("nobody"));
        // Its link drops with the rows still cached: a send there is to a machine that is down.
        peer.connected.store(false, SeqCst);
        assert!(hub.resolve_remote("b/review/child").is_some(), "the row is still cached");
        assert!(hub.host_unreachable_for("b/review/child"));
        assert!(!hub.host_unreachable_for("nobody"), "a name here is no peer's");
    }

    /// A machine this daemon does not have is the refusal's subject: named first, with no session
    /// names suggested, and never read as a name on this machine.
    ///
    /// 2026-11-21 12:25Z on big-red: `acpmux send gcp-agent-lane-8/efficiency-scout -` answered
    /// `no_session: no session gcp-agent-lane-8/efficiency-scout on big-red; did you mean:
    /// ci-fleet-v2-design, actions-queue-stall, fleet-capacity-routing`. Every part of that was
    /// wrong. The machine was reachable, its daemon up and `efficiency-scout` live there; it was
    /// simply not one of big-red's machines, so the session could never be found from there. The
    /// three names offered were big-red's own, and a name here can never be the one asked for on
    /// another machine. Four calls were spent before the working route was found.
    #[test]
    fn a_machine_this_daemon_does_not_have_is_named_as_the_cause() {
        let cfg: crate::config::Config =
            serde_json::from_value(serde_json::json!({"store": {"mode": "memory"}})).unwrap();
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        // A live session here, of the kind that used to be suggested for a remote target.
        let meta: crate::store::SessionMeta = serde_json::from_value(serde_json::json!({
            "schema": crate::store::META_SCHEMA, "id": "s1", "name": "ci-fleet-v2-design",
            "harness": "claude", "cwd": "/w", "status": "idle", "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap();
        let session = hub.make_session(meta);
        hub.sessions.lock().unwrap().insert("s1".into(), session.clone());
        hub.update_live_session_index(&session);

        let key = "gcp-agent-lane-8/efficiency-scout";
        assert_eq!(
            hub.host_not_a_peer(key),
            Some(("gcp-agent-lane-8".to_owned(), "efficiency-scout"))
        );
        let (text, data) = hub.no_session_text(key);
        // The machine, first: not the session name, and not this machine's name.
        assert!(text.starts_with("gcp-agent-lane-8 is not a machine of this daemon"), "{text}");
        assert_eq!(data["hostNotAPeer"], serde_json::json!(true));
        assert_eq!(data["host"], serde_json::json!("gcp-agent-lane-8"));
        assert_eq!(data["name"], serde_json::json!("efficiency-scout"));
        // Nothing suggested, and above all nothing of this machine's (defect 2).
        assert_eq!(data["candidates"], serde_json::json!([]));
        assert!(!text.contains("did you mean"), "{text}");
        assert!(
            !text.contains("ci-fleet-v2-design"),
            "a name here is never the one asked for: {text}"
        );
        // Both next steps: add the machine, or send from it.
        assert!(text.contains("machine add ssh://gcp-agent-lane-8"), "{text}");
        assert!(
            text.contains("ssh gcp-agent-lane-8 'acpmux send efficiency-scout -'"),
            "the route that works meanwhile: {text}"
        );
        // Still final, so a delivery fails at once instead of being retried for a day.
        assert!(hub.no_session_is_final(key));
        assert!(hub.peer_unlisted_for(key).is_none());
        assert!(!hub.host_unreachable_for(key));

        // A bare name, and this machine's own name, are unchanged: its own sessions are suggested.
        let (bare, bare_data) = hub.no_session_text("ci-fleet-v2-desgin");
        assert!(bare.contains("did you mean: ci-fleet-v2-design"), "{bare}");
        assert_eq!(bare_data["hostNotAPeer"], Value::Null);
        assert!(hub.host_not_a_peer("ci-fleet-v2-desgin").is_none());
        // A peer's own name still reads as that peer's (`a_peers_names_keep_their_path...`).
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = crate::peer::Peer::new("b", "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert("b".into(), peer.clone());
        assert!(hub.host_not_a_peer("b/anything").is_none());
        let (peer_text, _) = hub.no_session_text("b/anything");
        assert!(peer_text.starts_with("no session anything on b"), "{peer_text}");
    }

    #[test]
    fn edit_distance() {
        assert_eq!(distance("kitten", "sitting"), 3);
        assert_eq!(distance("", "abc"), 3);
        assert_eq!(distance("same", "same"), 0);
    }
}
