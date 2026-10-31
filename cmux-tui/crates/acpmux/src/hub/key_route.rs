//! Part of `Hub`; see `hub/mod.rs`. One rule for the session a bare key names, on this machine
//! and its peers alike (Leo, 2026-10-30: "various not as ergonomic/one-command-y as i'd liike set
//! of commands for interacting with stuff"): a whole name or an id prefix names the one live
//! session that has it across this daemon and every peer it lists (a name prefix still names a
//! session here when nothing else matches, as it always did; a sub-session's short name, on any
//! host, comes last). Several live matches are refused
//! with each one's `HOST/NAME`; nothing is picked silently, and a session here does not hide a
//! peer's of the same name (as `locate.rs` already holds for control callers). Closed sessions
//! count only when no live one matches. A sub-session's whole name (`parent/child`) is routed
//! the same way. Keys this daemon already reads exactly (an id, a qualified id, `HOST/NAME` with
//! a peer's or this machine's name) are left as they are.
//!
//! The request path (`server/requests.rs`, the unix socket only) asks [`Hub::key_route`] before
//! anything else reads the key, and swaps a name for the route it found, so every session
//! method, `send` (through the outbox) included, finds the same session.

use super::*;

/// The `reason` of the refusal for a key several live sessions match.
pub(crate) const AMBIGUOUS: &str = "session_ambiguous";

/// The most choices a refusal's message names; its data lists every one.
const SHOWN: usize = 10;

/// One session a bare key matches.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Candidate {
    /// Its machine: a peer's name, or this machine's.
    pub host: String,
    /// Its name without its peer's `peer/` prefix.
    pub name: String,
    /// What this daemon routes exactly: a local id, or the peer row's `peer/id`.
    pub route: String,
    pub closed: bool,
}

impl Hub {
    /// The exact route `key` names, when it is a bare name or prefix: `Ok(None)` when it is
    /// already exact or matches nothing (the usual not-found answer follows), an error when
    /// several live sessions match.
    pub(crate) fn key_route(&self, key: &str) -> Result<Option<String>, RpcError> {
        if key.is_empty()
            || self
                .sessions
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .contains_key(key)
        {
            return Ok(None);
        }
        // `HOST/NAME` and a qualified id are read exactly (`own_host.rs`, `resolve_remote`).
        let slash = key.split_once('/').map(|(host, _)| host);
        if slash.is_some_and(|host| {
            host == crate::session_identity::LOCAL_HOST_ID
                || super::own_host::is_own_machine_name(host)
                || self.peer(host).is_some()
        }) {
            return Ok(None);
        }
        let own = crate::pairing::machine_name();
        let [named, prefixed, short] = self.key_candidates(key, &own);
        // Any other `/` is in a sub-session's whole name (`parent/child`): that name only, on
        // every host, never a prefix or a short name.
        let found = if slash.is_some() {
            named.into_iter().filter(|c| c.name == key).collect()
        } else {
            [named, prefixed, short].into_iter().find(|tier| !tier.is_empty()).unwrap_or_default()
        };
        pick(key, &found).map(|c| c.map(|c| c.route.clone()))
    }

    /// The sessions here and on peers that `key` names as a whole name or by their id (a prefix
    /// of it), all in one tier, so a name never hides an id another session has; then, only for
    /// sessions here, those whose name starts with `key` (the rule this daemon always had); last,
    /// on any host, the sub-sessions whose short name `key` is (`mac-ci-3` for
    /// `claude-sr2/mac-ci-3`, `session_name::ends_with_segments`). A prefix of a peer's name
    /// names nothing, as `resolve_remote` never matched one: a short key never reaches another
    /// machine's chat nobody named. Names are read under each session's meta lock, never cloned
    /// (`resolve_here`).
    fn key_candidates(&self, key: &str, own: &str) -> [Vec<Candidate>; 3] {
        let (mut named, mut prefixed, mut short) = (Vec::new(), Vec::new(), Vec::new());
        for s in self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner).values() {
            let meta = s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let tier = if meta.name == key || s.id.starts_with(key) {
                &mut named
            } else if meta.name.starts_with(key) {
                &mut prefixed
            } else if crate::session_name::ends_with_segments(&meta.name, key) {
                &mut short
            } else {
                continue;
            };
            tier.push(Candidate {
                host: own.to_owned(),
                name: meta.name.clone(),
                route: s.id.clone(),
                closed: meta.status == SessionStatus::Closed,
            });
        }
        for (route, r) in
            self.remote_sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner).iter()
        {
            let name = r.summary.get("name").and_then(Value::as_str).unwrap_or_default();
            let bare = name.strip_prefix(&format!("{}/", r.peer)).unwrap_or(name);
            let tier = if bare == key || r.receipt.mux_session_id.starts_with(key) {
                &mut named
            } else if crate::session_name::ends_with_segments(bare, key) {
                &mut short
            } else {
                continue;
            };
            tier.push(Candidate {
                host: r.peer.clone(),
                name: bare.to_owned(),
                route: route.clone(),
                closed: r.summary.get("status").and_then(Value::as_str) == Some("closed"),
            });
        }
        [named, prefixed, short]
    }
}

/// The one session of `found` a key names: the one live session, else (none live) the one
/// closed session; several are refused.
pub(crate) fn pick<'a>(
    key: &str,
    found: &'a [Candidate],
) -> Result<Option<&'a Candidate>, RpcError> {
    let live: Vec<&Candidate> = found.iter().filter(|c| !c.closed).collect();
    let choices: Vec<&Candidate> = if live.is_empty() { found.iter().collect() } else { live };
    match choices.as_slice() {
        [] => Ok(None),
        [one] => Ok(Some(one)),
        many => Err(ambiguous(key, many)),
    }
}

/// The refusal for `key` naming several sessions: each as `HOST/NAME`, or its route when two
/// share that.
fn ambiguous(key: &str, many: &[&Candidate]) -> RpcError {
    let qualified = |c: &Candidate| format!("{}/{}", c.host, c.name);
    let choices: Vec<Value> = many
        .iter()
        .map(|c| {
            let unique = many.iter().filter(|o| qualified(o) == qualified(c)).count() == 1;
            json!({
                "host": c.host,
                "name": c.name,
                "route": c.route,
                "status": if c.closed { "closed" } else { "live" },
                "use": if unique { qualified(c) } else { c.route.clone() },
            })
        })
        .collect();
    let mut list: Vec<String> =
        choices.iter().take(SHOWN).filter_map(|c| c["use"].as_str()).map(str::to_owned).collect();
    if many.len() > SHOWN {
        list.push(format!("and {} more (`--json` lists every one)", many.len() - SHOWN));
    }
    let live = if many.iter().all(|c| c.closed) { "closed" } else { "live" };
    RpcError::invalid_params(format!(
        "{key:?} names {} {live} sessions: {}; name one of them",
        many.len(),
        list.join(", ")
    ))
    .with_data(
        json!({"reason": AMBIGUOUS, "session": key, "count": many.len(), "choices": choices}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session_identity::SessionReceipt;

    fn test_hub() -> Arc<Hub> {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut cfg: crate::config::Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        Hub::new(cfg, store)
    }

    /// Peer `peer`'s session `id`, listed as peers list them: under `peer/id`, named `peer/name`.
    fn list(hub: &Hub, peer: &str, id: &str, name: &str, status: &str) {
        let row = RemoteSession {
            peer: peer.into(),
            summary: json!({"sessionId": id, "name": format!("{peer}/{name}"), "status": status}),
            receipt: SessionReceipt {
                host_id: peer.into(),
                mux_session_id: id.into(),
                agent_session_id: None,
                generation: 1,
            },
        };
        hub.remote_sessions.lock().unwrap().insert(format!("{peer}/{id}"), row);
    }

    async fn named(hub: &Arc<Hub>, name: &str) -> Arc<Session> {
        let start = NewRequest {
            name: Some(name.into()),
            cwd: Some(std::env::temp_dir()),
            ..NewRequest::default()
        };
        hub.new_session(start).await.unwrap()
    }

    #[tokio::test]
    async fn a_bare_name_only_a_peer_has_routes_to_that_peer() {
        let hub = test_hub();
        list(&hub, "hb", "0199aaaa-1111", "acpmux-owner", "idle");
        list(&hub, "cmux16", "0199bbbb-2222", "builder", "idle");
        assert_eq!(hub.key_route("acpmux-owner").unwrap().as_deref(), Some("hb/0199aaaa-1111"));
        assert_eq!(hub.key_route("nobody").unwrap(), None);
        // Exact keys are left to the usual lookup.
        assert_eq!(hub.key_route("hb/acpmux-owner").unwrap(), None);
    }

    #[tokio::test]
    async fn a_name_on_this_machine_and_a_peer_is_refused_never_picked() {
        let hub = test_hub();
        let here = named(&hub, "review").await;
        list(&hub, "hb", "0199aaaa-1111", "review", "running");
        let e = hub.key_route("review").unwrap_err();
        let data = e.data.clone().unwrap();
        assert_eq!(data["reason"], AMBIGUOUS, "{e:?}");
        let routes: Vec<&str> = data["choices"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|c| c["route"].as_str())
            .collect();
        assert!(
            routes.contains(&here.id.as_str()) && routes.contains(&"hb/0199aaaa-1111"),
            "{e:?}"
        );
        assert!(e.message.contains("hb/review"), "{}", e.message);
        // The session's own id still names it alone.
        assert_eq!(hub.key_route(&here.id).unwrap(), None);
    }

    #[tokio::test]
    async fn an_id_prefix_names_a_peers_session_or_one_here() {
        let hub = test_hub();
        list(&hub, "hb", "0199aaaa-1111-7000", "builder", "idle");
        list(&hub, "hb", "0199cccc-3333-7000", "other", "idle");
        assert_eq!(hub.key_route("0199aaaa").unwrap().as_deref(), Some("hb/0199aaaa-1111-7000"));
        let here = named(&hub, "lane").await;
        assert_eq!(hub.key_route(&here.id[..12]).unwrap().as_deref(), Some(here.id.as_str()));
        // A prefix several sessions share is refused like a shared name.
        assert_eq!(hub.key_route("0199").unwrap_err().data.unwrap()["reason"], AMBIGUOUS);
        // A prefix of a peer's name is no route there.
        assert_eq!(hub.key_route("build").unwrap(), None);
        // A name here and another session's id prefix are one tier: a tie, not the name.
        named(&hub, "0199aaaa").await;
        let e = hub.key_route("0199aaaa").unwrap_err();
        assert_eq!(e.data.unwrap()["choices"].as_array().unwrap().len(), 2);
    }

    /// A sub-session's short name is the last tier, on every host: one is routed, two tie with
    /// each `HOST/NAME`, and a whole name or a name here starting with the key wins.
    #[tokio::test]
    async fn a_short_name_routes_to_its_one_sub_session_on_any_host() {
        let hub = test_hub();
        list(&hub, "hb", "0199aaaa-1111", "coord/lane-3", "idle");
        assert_eq!(hub.key_route("lane-3").unwrap().as_deref(), Some("hb/0199aaaa-1111"));
        let here = named(&hub, "boss/lane-3").await;
        let e = hub.key_route("lane-3").unwrap_err();
        let uses: Vec<String> = e.data.unwrap()["choices"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|c| c["use"].as_str().map(str::to_owned))
            .collect();
        assert!(uses.contains(&"hb/coord/lane-3".to_owned()), "{uses:?}");
        assert!(uses.iter().any(|u| u.ends_with("/boss/lane-3")), "{uses:?} {}", here.id);
        // `ci-3` is no segment of either name.
        assert_eq!(hub.key_route("ci-3").unwrap(), None);
        let whole = named(&hub, "lane-3x").await;
        assert_eq!(hub.key_route("lane-3").unwrap().as_deref(), Some(whole.id.as_str()));
    }

    /// Review of #28000: a sub-session's whole name has a `/`, and is routed like any name.
    #[tokio::test]
    async fn a_sub_sessions_whole_name_is_routed_across_hosts_too() {
        let hub = test_hub();
        list(&hub, "hb", "0199aaaa-1111", "coord/lane", "idle");
        assert_eq!(hub.key_route("coord/lane").unwrap().as_deref(), Some("hb/0199aaaa-1111"));
        // A prefix of it names nothing.
        assert_eq!(hub.key_route("coord/la").unwrap(), None);
        named(&hub, "coord/lane").await;
        let e = hub.key_route("coord/lane").unwrap_err();
        assert_eq!(e.data.unwrap()["choices"].as_array().unwrap().len(), 2);
        // `local/ID` and this machine's own `HOST/NAME` stay exact.
        assert_eq!(hub.key_route("local/0199aaaa").unwrap(), None);
    }

    #[tokio::test]
    async fn closed_sessions_do_not_count_while_a_live_one_matches() {
        let hub = test_hub();
        list(&hub, "hb", "0199aaaa-1111", "deploy", "closed");
        list(&hub, "cmux16", "0199bbbb-2222", "deploy", "idle");
        assert_eq!(hub.key_route("deploy").unwrap().as_deref(), Some("cmux16/0199bbbb-2222"));
        let old = named(&hub, "fixer").await;
        hub.set_status(&old, SessionStatus::Closed);
        list(&hub, "hb", "0199dddd-4444", "fixer", "idle");
        assert_eq!(hub.key_route("fixer").unwrap().as_deref(), Some("hb/0199dddd-4444"));
        // Only closed ones: still one to name, so `session info` reads a finished lane.
        list(&hub, "hb", "0199eeee-5555", "done", "closed");
        assert_eq!(hub.key_route("done").unwrap().as_deref(), Some("hb/0199eeee-5555"));
    }

    fn c(host: &str, name: &str, route: &str, closed: bool) -> Candidate {
        Candidate { host: host.into(), name: name.into(), route: route.into(), closed }
    }

    #[test]
    fn one_live_session_wins_over_closed_ones() {
        let found = [c("hb", "review", "hb/m3", false), c("mac-a", "review", "m1", true)];
        assert_eq!(pick("review", &found).unwrap().unwrap().route, "hb/m3");
        let closed = [c("mac-a", "review", "m1", true)];
        assert_eq!(pick("review", &closed).unwrap().unwrap().route, "m1");
        assert_eq!(pick("review", &[]).unwrap(), None);
    }

    #[test]
    fn several_live_sessions_are_refused_with_each_host_and_name() {
        let found = [
            c("mac-a", "review", "m1", false),
            c("hb", "review", "hb/m3", false),
            c("hb", "review", "hb/m4", false),
            c("cmux16", "review", "cmux16/m5", true),
        ];
        let e = pick("review", &found).unwrap_err();
        assert_eq!(
            e.message,
            "\"review\" names 3 live sessions: mac-a/review, hb/m3, hb/m4; name one of them"
        );
        let data = e.data.unwrap();
        assert_eq!(data["reason"], AMBIGUOUS);
        assert_eq!(data["session"], "review");
        let uses: Vec<&str> =
            data["choices"].as_array().unwrap().iter().filter_map(|c| c["use"].as_str()).collect();
        assert_eq!(uses, ["mac-a/review", "hb/m3", "hb/m4"]);
        // The message names ten; the data lists every one.
        let many: Vec<Candidate> =
            (0..12).map(|i| c(&format!("h{i}"), "review", &format!("h{i}/m"), false)).collect();
        let e = pick("review", &many).unwrap_err();
        assert!(e.message.contains("h9/review, and 2 more"), "{}", e.message);
        assert_eq!(e.data.unwrap()["choices"].as_array().unwrap().len(), 12);
    }
}
