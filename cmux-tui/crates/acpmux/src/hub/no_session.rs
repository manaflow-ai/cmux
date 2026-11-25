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
        let chat = self.unregistered_chat(&host, name, key);
        if let Some(chat) = &chat {
            text.push_str(&format!("; {}", chat.text));
        } else if close.is_empty() {
            text.push_str("; run `acpmux ls` for its sessions");
        } else {
            text.push_str(&format!("; did you mean: {}", close.join(", ")));
        }
        let mut data = json!({
            "reason": "no_session",
            "session": key,
            "host": host,
            "name": name,
            "candidates": close,
        });
        if let (Some(chat), Some(o)) = (chat, data.as_object_mut()) {
            let mut d = chat.data;
            if let Some(fields) = d.as_object_mut() {
                fields.insert("text".into(), json!(chat.text));
            }
            o.insert("unregisteredChat".into(), d);
        }
        (text, data)
    }

    /// What the refusal says when `name` reads as a Claude Code session id (Leo 2026-11-20, of a
    /// chat named by its id: "isn't one I can message through acpmux / well figure out a way
    /// then"). A Claude Code chat acpmux did not start (a terminal `claude`, the desktop app's
    /// Code tab) is reached once it registers from its own shell (`hub/register.rs`), so the
    /// refusal names that step instead of only "no session". On this machine the live Claude
    /// Code registry says whether such a chat runs (`claude_peers::live`); a peer's is not
    /// read from here, so the step is named as a possibility.
    fn unregistered_chat(&self, host: &str, name: &str, key: &str) -> Option<UnregisteredChat> {
        if !looks_like_session_id(name) {
            return None;
        }
        let local = !key
            .split_once('/')
            .is_some_and(|(h, rest)| !rest.is_empty() && self.peer(h).is_some());
        let lower = name.to_ascii_lowercase();
        let found = if local {
            let homes = self.harness_homes();
            // A folder walk: off the runtime's workers (RFD 0124 R6).
            crate::qos::off_worker(|| crate::claude_peers::live(&homes.claude))
                .into_iter()
                .find(|p| p.session_id.to_ascii_lowercase().starts_with(&lower))
        } else {
            None
        };
        Some(unregistered_chat_text(host, name, local, found.as_ref()))
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

/// [`Hub::unregistered_chat`]'s answer: the refusal's clause and its `data.unregisteredChat`.
pub struct UnregisteredChat {
    pub text: String,
    pub data: Value,
}

/// Whether `name` reads as a Claude Code session id or the start of one: 8 or more hex digits
/// and dashes, starting with a hex digit, as a deeplink or transcript name shows it.
pub fn looks_like_session_id(name: &str) -> bool {
    name.len() >= 8
        && name.starts_with(|c: char| c.is_ascii_hexdigit())
        && name.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
}

/// The name a chat that registers from its own shell takes when nobody picks one: the one its
/// first `acpmux send` takes (`cli/reply_address.rs` `auto_register_in`), `<harness>-<first 8 of
/// its id>`, the harness read from its entrypoint (`claude-code` when unknown).
fn register_name(id: &str, entrypoint: Option<&str>) -> String {
    let harness = match entrypoint {
        Some("claude-desktop") => "claude-desktop",
        Some("claude-vscode") => "claude-vscode",
        _ => "claude-code",
    };
    let short: String = id.chars().filter(char::is_ascii_alphanumeric).take(8).collect::<String>();
    format!("{harness}-{}", short.to_ascii_lowercase())
}

/// The clause for id-like `name` on `host`: a live chat found on this machine (`found`), none
/// found here (`local`), or a peer's, whose chats are not read from here.
pub fn unregistered_chat_text(
    host: &str,
    name: &str,
    local: bool,
    found: Option<&crate::claude_peers::Peer>,
) -> UnregisteredChat {
    let step = |alias: &str| {
        format!(
            "run `acpmux register {alias}` in that chat's own shell (its first `acpmux send` starts this itself), then send to {host}/{alias}"
        )
    };
    match found {
        Some(p) => {
            let alias = register_name(&p.session_id, p.entrypoint.as_deref());
            UnregisteredChat {
                text: format!(
                    "{name} is Claude Code chat {} (process {}) that acpmux did not start, so it has no acpmux address yet; {}",
                    p.session_id,
                    p.pid,
                    step(&alias)
                ),
                data: json!({"state": "running", "sessionId": p.session_id, "pid": p.pid,
                    "entrypoint": p.entrypoint, "register": alias}),
            }
        }
        None if local => {
            let alias = register_name(name, None);
            UnregisteredChat {
                text: format!(
                    "no running Claude Code chat on {host} has an id starting {name} either (closed, or another machine's); once it runs, {}",
                    step(&alias)
                ),
                data: json!({"state": "not_running", "register": alias}),
            }
        }
        None => {
            let alias = register_name(name, None);
            UnregisteredChat {
                text: format!(
                    "if {name} is a Claude Code chat acpmux did not start, it has no acpmux address until it registers: {}",
                    step(&alias)
                ),
                data: json!({"state": "unknown", "register": alias}),
            }
        }
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

    /// A send to a Claude Code chat by its id (Leo 2026-11-20: "isn't one I can message through
    /// acpmux") names the register step: with the running chat's id and pid when this machine
    /// runs it, as a possibility for a peer's.
    #[test]
    fn a_chat_named_by_its_id_names_the_register_step() {
        assert!(looks_like_session_id("6e0bad7d"));
        assert!(looks_like_session_id("6e0bad7d-9798-49c2-8d14-00d3d5ffeb25"));
        assert!(!looks_like_session_id("interim-coord"), "a name, not an id");
        assert!(!looks_like_session_id("6e0bad7"), "too short to be read as one");
        assert!(!looks_like_session_id("-6e0bad7d"));

        let peer = crate::claude_peers::Peer {
            pid: 4242,
            session_id: "6e0bad7d-9798-49c2-8d14-00d3d5ffeb25".into(),
            cwd: None,
            entrypoint: Some("claude-desktop".into()),
            kind: None,
            name: None,
            version: None,
            socket: None,
        };
        let running = unregistered_chat_text("mac-a", "6e0bad7d", true, Some(&peer));
        assert!(running.text.contains("process 4242"), "{}", running.text);
        assert!(
            running.text.contains("`acpmux register claude-desktop-6e0bad7d`")
                && running.text.ends_with("send to mac-a/claude-desktop-6e0bad7d"),
            "{}",
            running.text
        );
        assert_eq!(running.data["state"], "running");
        assert_eq!(running.data["pid"], 4242);

        let closed = unregistered_chat_text("here", "6e0bad7d", true, None);
        assert_eq!(closed.data["state"], "not_running", "{}", closed.text);
        let far = unregistered_chat_text("mac-a", "6e0bad7d", false, None);
        assert!(far.text.starts_with("if 6e0bad7d is a Claude Code chat"), "{}", far.text);
        assert_eq!(far.data["state"], "unknown");

        // Through the hub, a peer's id-like name says so, and a plain name keeps "did you mean".
        let hub = Hub::new(
            crate::config::Config::default(),
            Box::new(crate::store::MemoryStore::default()),
        );
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let b = crate::peer::Peer::new("b", "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert("b".into(), b.clone());
        let (text, data) = hub.no_session_text("b/6e0bad7d");
        assert!(text.starts_with("no session 6e0bad7d on b; if 6e0bad7d is"), "{text}");
        assert_eq!(data["unregisteredChat"]["register"], "claude-code-6e0bad7d");
        let (text, data) = hub.no_session_text("b/interim-coord");
        assert!(!text.contains("acpmux register"), "{text}");
        assert!(data.get("unregisteredChat").is_none());
    }

    #[test]
    fn edit_distance() {
        assert_eq!(distance("kitten", "sitting"), 3);
        assert_eq!(distance("", "abc"), 3);
        assert_eq!(distance("same", "same"), 0);
    }
}
