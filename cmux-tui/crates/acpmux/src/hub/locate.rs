//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/resolve` (`acpmux resolve`): the session an agent
//! link (`agent_link.rs`, the `cmux.com/deeplink/agent?...` of every PR footer), a session id
//! or a name names, here or on a peer, with what a reader wants to know about it: its host,
//! ids, harness, model, folder, state, lane, pull requests and last turn. A link's `session=` is
//! the harness's own session id, so it is matched against `agentSessionId`. Reads the session
//! lists this daemon already keeps (its own sessions and each peer's mirrored list); it asks no
//! peer anything. Of the peers' rows it copies only those the query could name (`may_name`):
//! every lifecycle command (`acpmux send`, `last`, `wait`) resolves its name here, and copying and
//! sorting all of 8,000 peer rows for each kept a Mac's daemon at a core (cosmic-gray, 2026-11-02).

use super::*;

use crate::agent_link::AgentLink;

impl Hub {
    /// The session `query` names, newest first when several do (`matches`), else a not-found
    /// error that says where it looked. With `bead_only`, `query` is a bead id and only the
    /// sessions carrying it match (a session named like it does not hide them). Without
    /// `names_hosts` (a read-only machine's connection) it answers no more than the session list
    /// does: this machine's name and its peers' (those with no session, their state) stay out,
    /// and `local/NAME` names a session here.
    pub fn locate(
        &self,
        query: &str,
        bead_only: bool,
        names_hosts: bool,
    ) -> Result<Value, RpcError> {
        let query = query.trim();
        if query.is_empty() {
            return Err(RpcError::invalid_params(
                "query is required: an agent link, a session id or a session name",
            ));
        }
        let own = if names_hosts { crate::pairing::machine_name() } else { "local".into() };
        let shown = names_hosts.then_some(own.as_str());
        if !bead_only && let Some(id) = crate::opaque_agent_id::find(query) {
            return self.locate_opaque(query, &id, &own, shown);
        }
        let parsed = if bead_only { None } else { crate::agent_link::find(query) };
        let named = parsed.as_ref().and_then(|link| link.as_ref().ok());
        let names = Names::new(query, named, bead_only);
        let keep = |r: &RemoteSession| names.may_name(r);
        let mut summaries = self.located_summaries(&keep, false);
        // Whether `summaries` holds closed chats too (moved chats' targets are read as it was).
        let mut all = false;
        if bead_only {
            if !crate::beads::is_bead_id(query) {
                return Err(RpcError::invalid_params(format!("{query:?} is not a bead id")));
            }
            let mut found = by_bead(&summaries, query);
            if found.is_empty() {
                // Closed records are retained for explicit history lookups, but are not part of
                // the repeated live index walk.
                summaries = self.located_summaries(&keep, true);
                found = by_bead(&summaries, query);
            }
            if found.is_empty() {
                return Err(RpcError::not_found(self.unfound(query, None, shown)));
            }
            let matches: Vec<Value> = found.iter().map(|s| card(s, shown)).collect();
            return Ok(json!({"session": matches.first(), "matches": matches, "link": null}));
        }
        let (mut link, mut found) = match parsed.clone() {
            Some(Err(e)) => {
                return Err(RpcError::invalid_params(format!("not a usable agent link: {e}")));
            }
            Some(Ok(link)) => {
                let found = by_link(&summaries, &link, &own);
                (Some(link), found)
            }
            None => {
                let exact_live = by_key_exact(&summaries, query, &own);
                if !exact_live.is_empty() {
                    (None, exact_live)
                } else {
                    (summaries, all) = (self.located_summaries(&keep, true), true);
                    let exact_all = by_key_exact(&summaries, query, &own);
                    if !exact_all.is_empty() {
                        (None, exact_all)
                    } else if names_hosts
                        && (!crate::beads::is_bead_id(query)
                            || by_bead(&summaries, query).is_empty())
                        && let Some(route) = self.key_route(query)?.filter(|route| route != query)
                    {
                        // No exact name or id, and no session carries it as a bead (`by_key`
                        // reads those first): the one session every other command finds for it
                        // (`hub/key_route.rs`: another case before a prefix, a prefix here before
                        // a name without separators); several are refused, never picked.
                        return self.locate(&route, false, names_hosts);
                    } else {
                        (None, by_key(&summaries, query, &own))
                    }
                }
            }
        };
        if found.is_empty() && link.is_some() {
            // A name or id that explicitly asks for a closed chat is resolved on demand. The
            // common live lookup above never walks those records.
            (summaries, all) = (self.located_summaries(&keep, true), true);
            (link, found) = match parsed.clone() {
                Some(Err(e)) => {
                    return Err(RpcError::invalid_params(format!("not a usable agent link: {e}")));
                }
                Some(Ok(link)) => {
                    let found = by_link(&summaries, &link, &own);
                    (Some(link), found)
                }
                None => (None, by_key(&summaries, query, &own)),
            };
        }
        if found.is_empty() && link.is_none() && !all {
            (summaries, all) = (self.located_summaries(&keep, true), true);
            found = by_key(&summaries, query, &own);
        }
        if found.is_empty() {
            let e = RpcError::not_found(self.unfound(query, link.as_ref(), shown));
            // Close names only for a caller that may read them all: never a peer daemon's or a
            // read-only machine's connection (`names_hosts`).
            if link.is_some() || !names_hosts {
                return Err(e);
            }
            // The names it nearly matched, as `Hub::unknown_session` gives them: every name that
            // contains the query, any case (`session_name::candidates`), closed chats' included.
            let names = self.names_containing(&query.to_ascii_lowercase());
            let close = crate::session_name::candidates(names.iter().map(String::as_str), query);
            if close.is_empty() {
                return Err(e);
            }
            let list = crate::session_name::candidate_list(&close);
            let shown_close: Vec<&String> =
                close.iter().take(crate::session_name::CANDIDATES_SHOWN).collect();
            return Err(RpcError::not_found(format!("{}; close matches: {list}", e.message))
                .with_data(json!({"candidates": shown_close})));
        }
        self.answer(found, all, &own, shown, link)
    }

    /// `locate`'s answer for the sessions it found (newest first; `all`: read with closed chats
    /// too): each chat that moved after where it went (`follow_moves`), as cards, and the link.
    fn answer(
        &self,
        found: Vec<&Value>,
        all: bool,
        own: &str,
        shown: Option<&str>,
        link: Option<AgentLink>,
    ) -> Result<Value, RpcError> {
        // Where moved chats went: those rows only, from the list the matches came from.
        let targets: Vec<&str> =
            found.iter().filter_map(|s| s.pointer("/movedTo/sessionId")?.as_str()).collect();
        let moved = if targets.is_empty() {
            Vec::new()
        } else {
            let to = |r: &RemoteSession| targets.contains(&r.receipt.mux_session_id.as_str());
            self.located_summaries(&to, all)
        };
        let found = follow_moves(found, &moved, own);
        let matches: Vec<Value> = found.iter().map(|s| card(s, shown)).collect();
        Ok(json!({
            "session": matches.first(),
            "matches": matches,
            "link": link.map(|l| json!({
                "harness": l.harness,
                "session": l.session,
                "host": l.host,
                "name": l.name,
                "message": l.message,
            })),
        }))
    }

    /// The session opaque id `id` (`opaque_agent_id.rs`, the `?id=aid-...` link of a public PR)
    /// stands for: the one listed here or on a peer whose host, harness and session hash to it
    /// under this machine's key, live chats before closed ones. Without the key, or with no
    /// session that hashes to it, the same not-found as any unknown session (the caller opens
    /// the web page). A peer row is hashed in place and copied only when it matches, so a
    /// lookup copies no other peer row (`may_name`). Its answer names no link: the id is all a
    /// reader has.
    fn locate_opaque(
        &self,
        query: &str,
        id: &str,
        own: &str,
        shown: Option<&str>,
    ) -> Result<Value, RpcError> {
        let unfound = || RpcError::not_found(self.unfound(query, None, shown));
        let Some(key) = crate::opaque_agent_id::Key::load(&crate::config::home()) else {
            return Err(unfound());
        };
        // The names this machine's sessions are minted under: its peer name, and the host an
        // agent here was told it runs on.
        let mut here = vec![crate::pairing::machine_name()];
        if let Ok(host) = std::env::var("CMUX_AGENT_HOST")
            && !host.is_empty()
            && !here.iter().any(|h| h.eq_ignore_ascii_case(&host))
        {
            here.push(host);
        }
        let hashes = |s: &Value, hosts: &[&str]| {
            s["agentSessionId"]
                .as_str()
                .is_some_and(|session| hosts.iter().any(|h| key.id(h, family_of(s), session) == id))
        };
        let keep = |r: &RemoteSession| {
            r.summary.agent_session_id().is_some_and(|session| {
                key.id(r.peer.as_str(), r.summary.family().unwrap_or_default(), session) == id
            })
        };
        let here: Vec<&str> = here.iter().map(String::as_str).collect();
        for all in [false, true] {
            let summaries = self.located_summaries(&keep, all);
            let found: Vec<&Value> = summaries
                .iter()
                .filter(|s| match s["peer"].as_str() {
                    Some(peer) => hashes(s, &[peer]),
                    None => hashes(s, &here),
                })
                .collect();
            if !found.is_empty() {
                return self.answer(found, all, own, shown, None);
            }
        }
        Err(unfound())
    }

    /// The sessions `locate` reads, newest first: this daemon's (with `closed`, its closed ones
    /// too) and the peers' rows `keep` takes, copying no other. The order is the full list's
    /// (`all_session_summaries`), restricted to them.
    fn located_summaries(&self, keep: &dyn Fn(&RemoteSession) -> bool, closed: bool) -> Vec<Value> {
        let mut v: Vec<Value> = if closed {
            self.sessions().iter().map(|s| self.cached_closed_summary(s, true)).collect()
        } else {
            self.indexed_live_sessions().iter().map(|s| self.session_summary(s)).collect()
        };
        let open = |r: &RemoteSession| !r.summary.closed();
        self.visit_remote_sessions(|r| (closed || open(r)) && keep(r), |row| v.push(row));
        super::session_pages::sort_session_summaries(&mut v);
        v
    }

    /// Every session name here or on a peer, closed ones included, that contains `lower` in
    /// any case.
    fn names_containing(&self, lower: &str) -> Vec<String> {
        let mut names: Vec<String> = self
            .sessions()
            .iter()
            .filter_map(|s| {
                self.cached_closed_summary(s, true).get("name")?.as_str().map(str::to_owned)
            })
            .filter(|n| crate::session_name::contains_ignore_case(n, lower))
            .collect();
        names.extend(self.remote_names_containing(lower));
        names
    }

    /// Read one exact mux session id without rebuilding the complete session list.
    /// This is an opt-in operation for native callers that already have the id;
    /// the normal resolver above keeps its name, prefix and link semantics.
    pub fn locate_exact(&self, query: &str, names_hosts: bool) -> Result<Value, RpcError> {
        let query = query.trim();
        if query.is_empty() {
            return Err(RpcError::invalid_params("sessionId is required"));
        }
        let own = if names_hosts { crate::pairing::machine_name() } else { "local".into() };
        let shown = names_hosts.then_some(own.as_str());
        let summary = self
            .session_summaries_of(&[query.to_owned()])
            .remove(query)
            .ok_or_else(|| RpcError::not_found(self.unfound(query, None, shown)))?;
        // `card` derives the display host from the cached row's peer marker.
        // Session summaries do not carry a host field, so do not overwrite
        // that derived locality with a missing value.
        let session = card(&summary, None);
        Ok(json!({"session": session}))
    }

    /// Where `locate` looked, for its not-found error: this machine and its peers by name, which
    /// are down, and a link's host that is neither, when `own` (the hosts) may be shown.
    fn unfound(&self, query: &str, link: Option<&AgentLink>, own: Option<&str>) -> String {
        let Some(own) = own else {
            return not_found_text(query, link, "on this daemon or its peers");
        };
        let peers = self.peers();
        let names: Vec<&str> = peers.iter().filter_map(|p| p["name"].as_str()).collect();
        let looked = if names.is_empty() {
            format!("on {own} (this daemon has no peers)")
        } else {
            format!("on {own} or its peers ({})", names.join(", "))
        };
        let mut text = not_found_text(query, link, &looked);
        if let Some(host) = link.and_then(|l| l.host.as_deref())
            && !host.eq_ignore_ascii_case(own)
            && !names.iter().any(|n| n.eq_ignore_ascii_case(host))
        {
            text.push_str(&format!(
                "; the link names host {host}, which is neither this machine nor one of its peers: resolve it there, or add {host} as a peer"
            ));
        }
        let down: Vec<String> = peers
            .iter()
            .filter(|p| p["connected"] != true)
            .filter_map(|p| Some(format!("{} ({})", p["name"].as_str()?, p["state"].as_str()?)))
            .collect();
        if !down.is_empty() {
            text.push_str(&format!("; not connected now: {}", down.join(", ")));
        }
        text
    }
}

/// That nothing `query` names was found `looked` ("on … or its peers").
fn not_found_text(query: &str, link: Option<&AgentLink>, looked: &str) -> String {
    match link {
        Some(l) => format!("no {} session {} {looked}", l.harness, l.session),
        None if crate::beads::is_bead_id(query) => {
            format!("no session named, with the id or carrying the bead {query:?} {looked}")
        }
        None => format!("no session named or with the id {query:?} {looked}"),
    }
}

/// The host a summary's session runs on: its peer's name, or this machine's.
fn host_of<'a>(summary: &'a Value, own: &'a str) -> &'a str {
    summary["peer"].as_str().unwrap_or(own)
}

/// A summary's name without its peer's `peer/` prefix.
fn bare_name(summary: &Value) -> &str {
    let name = summary["name"].as_str().unwrap_or_default();
    summary["peer"]
        .as_str()
        .and_then(|peer| name.strip_prefix(peer)?.strip_prefix('/'))
        .unwrap_or(name)
}

/// The harness family a summary's link names: its family, else (an older peer's summary) its
/// harness. `link_of` writes the same.
fn family_of(summary: &Value) -> &str {
    summary["family"].as_str().or(summary["harness"].as_str()).unwrap_or_default()
}

/// The sessions whose harness session id and family are the link's, those on the host the link
/// names first, then this daemon's, newest first within.
fn by_link<'a>(summaries: &'a [Value], link: &AgentLink, own: &str) -> Vec<&'a Value> {
    let mut found: Vec<&Value> = summaries
        .iter()
        .filter(|s| s["agentSessionId"].as_str() == Some(link.session.as_str()))
        .filter(|s| family_of(s) == link.harness)
        .collect();
    let on_hint =
        |s: &Value| link.host.as_deref().is_some_and(|h| host_of(s, own).eq_ignore_ascii_case(h));
    // Stable: the newest-first order of `all_session_summaries` stays within each rank.
    found.sort_by_key(|s| (!on_hint(s), s["peer"].is_string()));
    found
}

/// `found`, with each chat that moved away (`movedTo`) after where it went: the copy it moved to
/// (on the host the move names, with the id it has there) joins the matches when it is listed,
/// and every moved-away copy ranks after every live one. A link written while the chat ran here
/// (a PR footer naming this host) so leads to where it runs now; a moved-away copy whose
/// target is not listed stays, its card saying where it went.
fn follow_moves<'a>(found: Vec<&'a Value>, summaries: &'a [Value], own: &str) -> Vec<&'a Value> {
    // One row per session: `summaries` is read apart from `found`, so the same row can be in both.
    let same = |a: &Value, b: &Value| {
        a["sessionId"] == b["sessionId"] && host_of(a, own).eq_ignore_ascii_case(host_of(b, own))
    };
    let mut out: Vec<&Value> = Vec::new();
    for s in found {
        let to = &s["movedTo"];
        if let Some(id) = to["sessionId"].as_str() {
            let host = to["host"].as_str().unwrap_or(own);
            let there = summaries.iter().find(|t| {
                t["sessionId"].as_str() == Some(id) && host_of(t, own).eq_ignore_ascii_case(host)
            });
            if let Some(there) = there
                && !out.iter().any(|o| same(o, there))
            {
                out.push(there);
            }
        }
        if !out.iter().any(|o| same(o, s)) {
            out.push(s);
        }
    }
    // Stable: the order within live and within moved-away copies stays.
    out.sort_by_key(|s| s["movedTo"].is_object());
    out
}

/// The sessions `key` names: ids take precedence over names. A bare name includes every
/// host, so a local chat cannot hide a peer's chat with the same name from control callers.
/// Qualified names select their host; bead ids still find the sessions that carry them. A
/// sub-session's short name (`mac-ci-3` for `claude-sr2/mac-ci-3`,
/// `session_name::ends_with_segments`) names it only where no id, name or prefix does: a bare
/// one on every host, `HOST/SHORT` on that host only.
fn by_key<'a>(summaries: &'a [Value], key: &str, own: &str) -> Vec<&'a Value> {
    let exact: Vec<&Value> = summaries
        .iter()
        .filter(|s| {
            ["sessionId", "qualifiedSessionId", "agentSessionId"]
                .iter()
                .any(|f| s[*f].as_str() == Some(key))
        })
        .collect();
    if !exact.is_empty() {
        return exact;
    }
    let named: Vec<&Value> = summaries
        .iter()
        .filter(|s| s["name"].as_str() == Some(key) || bare_name(s) == key)
        .collect();
    if !named.is_empty() {
        return named;
    }
    if crate::beads::is_bead_id(key) {
        let carry = by_bead(summaries, key);
        if !carry.is_empty() {
            return carry;
        }
    }
    if let Some((host, rest)) = key.split_once('/') {
        let on_host: Vec<&Value> =
            summaries.iter().filter(|s| host_of(s, own).eq_ignore_ascii_case(host)).collect();
        let exact: Vec<&Value> = on_host
            .iter()
            .copied()
            .filter(|s| bare_name(s) == rest || s["sessionId"].as_str() == Some(rest))
            .collect();
        if !exact.is_empty() {
            return exact;
        }
        let prefixed: Vec<&Value> =
            on_host.iter().copied().filter(|s| key_prefix(s, rest)).collect();
        if !prefixed.is_empty() || rest.contains('/') {
            return prefixed;
        }
        return by_short_name(on_host, rest);
    }
    let prefixed: Vec<&Value> = summaries.iter().filter(|s| key_prefix(s, key)).collect();
    if !prefixed.is_empty() {
        return prefixed;
    }
    // A bare short name, on every host, only where nothing above matched: several are the tie
    // a control caller refuses.
    by_short_name(summaries.iter().collect(), key)
}

/// The sessions `key` names exactly: an id first, then a whole name on any host before
/// `HOST/NAME` is read as a host and a name on it, as `by_key` reads them (a local `coord/lane`
/// is never peer `coord`'s `lane-extra`, which the loose `key_route` would find next, and a
/// session named `hb/ID` never hides peer `hb`'s session `ID`).
fn by_key_exact<'a>(summaries: &'a [Value], key: &str, own: &str) -> Vec<&'a Value> {
    if let Some((host, rest)) = key.split_once('/') {
        let ids: Vec<&Value> = summaries
            .iter()
            .filter(|s| {
                s["qualifiedSessionId"].as_str() == Some(key)
                    || (s["sessionId"].as_str() == Some(rest)
                        && host_of(s, own).eq_ignore_ascii_case(host))
            })
            .collect();
        if !ids.is_empty() {
            return ids;
        }
        let whole: Vec<&Value> = summaries
            .iter()
            .filter(|s| s["name"].as_str() == Some(key) || bare_name(s) == key)
            .collect();
        if !whole.is_empty() {
            return whole;
        }
        return summaries
            .iter()
            .filter(|s| host_of(s, own).eq_ignore_ascii_case(host))
            .filter(|s| bare_name(s) == rest || s["name"].as_str() == Some(key))
            .collect();
    }
    summaries
        .iter()
        .filter(|s| {
            ["sessionId", "qualifiedSessionId", "agentSessionId"]
                .iter()
                .any(|field| s[*field].as_str() == Some(key))
                || s["name"].as_str() == Some(key)
                || bare_name(s) == key
        })
        .collect()
}

/// What a `locate` query could name, to judge each peer row before it is copied (`may_name`).
struct Names<'q> {
    query: &'q str,
    link: Option<&'q AgentLink>,
    bead_only: bool,
    /// The bead tag a bead id (or a `bead_only` query) is carried by.
    bead: Option<String>,
    /// The host a `HOST/...` key names.
    host: Option<&'q str>,
}

impl<'q> Names<'q> {
    fn new(query: &'q str, link: Option<&'q AgentLink>, bead_only: bool) -> Self {
        let bead =
            (bead_only || crate::beads::is_bead_id(query)).then(|| crate::beads::tag_key(query));
        let host = query.split_once('/').map(|(host, _)| host);
        Self { query, link, bead_only, bead, host }
    }

    /// Whether peer row `r` could be among the matches: whatever `by_bead` (`bead_only`),
    /// `by_link` (a link) or `by_key_exact` and `by_key` could take, and every row of the host a
    /// `HOST/...` key names. It reads the row's peer and receipt (its summary's `sessionId` and
    /// `qualifiedSessionId` are theirs, `remote_summary`) and two of its summary's fields, so a
    /// row costs a few compares; the matchers then decide on the rows it took.
    fn may_name(&self, r: &RemoteSession) -> bool {
        let s = &r.summary;
        // Its tags are parsed only for a bead's lookup.
        let bead =
            || self.bead.as_ref().is_some_and(|tag| s.tags().is_some_and(|t| t.get(tag).is_some()));
        if self.bead_only {
            return bead();
        }
        if let Some(link) = self.link {
            return s.agent_session_id() == Some(link.session.as_str());
        }
        let q = self.query;
        let mux = r.receipt.mux_session_id.as_str();
        let name = s.name().unwrap_or_default();
        let bare =
            name.strip_prefix(r.peer.as_str()).and_then(|n| n.strip_prefix('/')).unwrap_or(name);
        mux.starts_with(q)
            || bare.starts_with(q)
            || name == q
            || crate::session_name::ends_with_segments(bare, q)
            || self.host.is_some_and(|host| r.peer.eq_ignore_ascii_case(host))
            || q.strip_prefix(r.peer.as_str()).and_then(|q| q.strip_prefix('/')) == Some(mux)
            || s.agent_session_id() == Some(q)
            || bead()
    }
}

/// The sessions whose last name segment is `key` (`session_name::ends_with_segments`).
fn by_short_name<'a>(rows: Vec<&'a Value>, key: &str) -> Vec<&'a Value> {
    rows.into_iter()
        .filter(|s| crate::session_name::ends_with_segments(bare_name(s), key))
        .collect()
}

/// Keep the CLI's unique id/name prefixes, collecting all candidates before a control
/// caller chooses one. A prefix never wins over an exact id or name.
fn key_prefix(summary: &Value, key: &str) -> bool {
    summary["sessionId"].as_str().is_some_and(|id| id.starts_with(key))
        || bare_name(summary).starts_with(key)
}

/// The sessions that carry bead `id` (`beads.rs`).
fn by_bead<'a>(summaries: &'a [Value], id: &str) -> Vec<&'a Value> {
    let tag = crate::beads::tag_key(id);
    summaries.iter().filter(|s| s["tags"].get(&tag).is_some()).collect()
}

/// What `locate` answers for one session. It keeps the keys every summary has (`sessionId`,
/// `harness`, `lastSeq`), so a peer's connection reads its session text masked like a
/// summary's (`server/peer_text.rs`). Without `own` a session here has no host and no link.
fn card(s: &Value, own: Option<&str>) -> Value {
    let host = s["peer"].as_str().or(own);
    json!({
        "host": host,
        "lastSeq": s.get("lastSeq").cloned().unwrap_or(json!(0)),
        "peer": s["peer"],
        "sessionId": s["sessionId"],
        "qualifiedSessionId": s["qualifiedSessionId"],
        "agentSessionId": s["agentSessionId"],
        "name": s["name"],
        "harness": s["harness"],
        "family": s["family"],
        "model": s["model"],
        "cwd": s["cwd"],
        "gitBranch": s["gitBranch"],
        "status": s["status"],
        "lane": s["lane"],
        "title": s["title"],
        "pullRequests": s["pullRequests"],
        "lastTurn": s["lastTurn"],
        "lastPrompt": s["lastPrompt"],
        "lastMessage": s["lastMessage"],
        "createdAt": s["createdAt"],
        "updatedAt": s["updatedAt"],
        "tags": s["tags"],
        "beads": crate::beads::of_tags(&s["tags"]),
        "peerState": s["peerState"],
        "stale": s["stale"],
        "movedTo": s["movedTo"],
        "link": link_of(s, host),
    })
}

/// The session's own agent link (`schemas/deeplinks/agent-link.json`), or null when it has no
/// harness session id yet or no host to name.
fn link_of(s: &Value, host: Option<&str>) -> Value {
    let (Some(session), Some(host)) = (s["agentSessionId"].as_str(), host) else {
        return Value::Null;
    };
    let link = AgentLink {
        harness: family_of(s).to_owned(),
        session: session.to_owned(),
        host: Some(host.to_owned()),
        name: Some(bare_name(s).to_owned()),
        ..Default::default()
    };
    link.web_url().map_or(Value::Null, Value::String)
}

#[cfg(test)]
mod tests;
