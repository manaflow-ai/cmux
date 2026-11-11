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

    /// (`no session NAME on HOST; did you mean: a, b, c`, the refusal's data) for `key`.
    pub fn no_session_text(&self, key: &str) -> (String, Value) {
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
                .filter_map(|r| r.summary.get("name").and_then(Value::as_str))
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
        hub.apply_peer_notice("b", peer.generation, crate::peer::PeerNotice::Sessions(rows));
        let (text, data) = hub.no_session_text("b/review/chil");
        assert_eq!(text, "no session review/chil on b; did you mean: review/child", "{data}");
        assert_eq!(data["candidates"], serde_json::json!(["review/child"]));
        // Not connected, nothing listed: not final.
        assert!(!hub.no_session_is_final("b/x"));
        peer.connected.store(true, SeqCst);
        assert!(!hub.no_session_is_final("b/x"), "connected, list not applied yet");
        peer.rows_ready.store(true, SeqCst);
        assert!(hub.no_session_is_final("b/x"));
        // A name on this machine is always final.
        assert!(hub.no_session_is_final("nobody"));
        // Its link drops with the rows still cached: a send there is to a machine that is down.
        peer.connected.store(false, SeqCst);
        assert!(hub.resolve_remote("b/review/child").is_some(), "the row is still cached");
        assert!(hub.host_unreachable_for("b/review/child"));
        assert!(!hub.host_unreachable_for("nobody"), "a name here is no peer's");
    }

    #[test]
    fn edit_distance() {
        assert_eq!(distance("kitten", "sitting"), 3);
        assert_eq!(distance("", "abc"), 3);
        assert_eq!(distance("same", "same"), 0);
    }
}
