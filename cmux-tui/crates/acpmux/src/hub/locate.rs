//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/resolve` (`acpmux resolve`): the session an agent
//! link (`agent_link.rs`, the `cmux.com/deeplink/agent?...` of every PR footer), a session id
//! or a name names, here or on a peer, with what a reader wants to know about it: its host,
//! ids, harness, model, folder, state, lane, pull requests and last turn. A link's `session=` is
//! the harness's own session id, so it is matched against `agentSessionId`. Reads the session
//! lists this daemon already keeps (its own sessions and each peer's mirrored list); it asks no
//! peer anything.

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
        let mut summaries = self.live_session_summaries();
        if bead_only {
            if !crate::beads::is_bead_id(query) {
                return Err(RpcError::invalid_params(format!("{query:?} is not a bead id")));
            }
            let mut found = by_bead(&summaries, query);
            if found.is_empty() {
                // Closed records are retained for explicit history lookups, but are not part of
                // the repeated live index walk.
                summaries = self.all_session_summaries_including_closed();
                found = by_bead(&summaries, query);
            }
            if found.is_empty() {
                return Err(RpcError::not_found(self.unfound(query, None, shown)));
            }
            let matches: Vec<Value> = found.iter().map(|s| card(s, shown)).collect();
            return Ok(json!({"session": matches.first(), "matches": matches, "link": null}));
        }
        let (mut link, mut found) = match crate::agent_link::find(query) {
            Some(Err(e)) => {
                return Err(RpcError::invalid_params(format!("not a usable agent link: {e}")));
            }
            Some(Ok(link)) => {
                let found = by_link(&summaries, &link, &own);
                (Some(link), found)
            }
            None => {
                // Exact ids and names outrank prefixes, including a closed exact name. This
                // preserves `locate review` when a live `review-2` was created later.
                let exact = by_key_exact(&summaries, query, &own);
                if !exact.is_empty() {
                    (None, exact)
                } else {
                    let full = self.all_session_summaries_including_closed();
                    let closed_exact = by_key_exact(&full, query, &own);
                    if !closed_exact.is_empty() {
                        summaries = full;
                        (None, closed_exact)
                    } else {
                        (None, by_key(&summaries, query, &own))
                    }
                }
            }
        };
        if found.is_empty() && link.is_some() {
            // A name or id that explicitly asks for a closed chat is resolved on demand. The
            // common live lookup above never walks those records.
            summaries = self.all_session_summaries_including_closed();
            (link, found) = match crate::agent_link::find(query) {
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
        if found.is_empty() && link.is_none() && summaries.iter().all(|s| s["status"] != "closed") {
            let full = self.all_session_summaries_including_closed();
            found = by_key(&full, query, &own);
            summaries = full;
        }
        if found.is_empty() {
            let e = RpcError::not_found(self.unfound(query, link.as_ref(), shown));
            // Close names only for a caller that may read them all: never a peer daemon's or a
            // read-only machine's connection (`names_hosts`).
            if link.is_some() || !names_hosts {
                return Err(e);
            }
            // The names it nearly matched, as `Hub::unknown_session` gives them.
            let names = summaries.iter().filter_map(|s| s.get("name")?.as_str());
            let close = crate::session_name::candidates(names, query);
            if close.is_empty() {
                return Err(e);
            }
            let list = crate::session_name::candidate_list(&close);
            let shown_close: Vec<&String> =
                close.iter().take(crate::session_name::CANDIDATES_SHOWN).collect();
            return Err(RpcError::not_found(format!("{}; close matches: {list}", e.message))
                .with_data(json!({"candidates": shown_close})));
        }
        let found = follow_moves(found, &summaries, &own);
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
    let mut out: Vec<&Value> = Vec::new();
    for s in found {
        let to = &s["movedTo"];
        if let Some(id) = to["sessionId"].as_str() {
            let host = to["host"].as_str().unwrap_or(own);
            let there = summaries.iter().find(|t| {
                t["sessionId"].as_str() == Some(id) && host_of(t, own).eq_ignore_ascii_case(host)
            });
            if let Some(there) = there
                && !out.iter().any(|o| std::ptr::eq(*o, there))
            {
                out.push(there);
            }
        }
        if !out.iter().any(|o| std::ptr::eq(*o, s)) {
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

/// Exact id/name portion of [`by_key`], used before prefix matching so a closed exact name keeps
/// winning over a newer live prefix.
fn by_key_exact<'a>(summaries: &'a [Value], key: &str, own: &str) -> Vec<&'a Value> {
    if let Some((host, rest)) = key.split_once('/') {
        return summaries
            .iter()
            .filter(|s| host_of(s, own).eq_ignore_ascii_case(host))
            .filter(|s| {
                s["sessionId"].as_str() == Some(rest)
                    || s["qualifiedSessionId"].as_str() == Some(key)
                    || bare_name(s) == rest
                    || s["name"].as_str() == Some(key)
            })
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
mod tests {
    use super::*;

    fn link(text: &str) -> AgentLink {
        crate::agent_link::find(text).unwrap().unwrap()
    }

    fn rows() -> Vec<Value> {
        vec![
            json!({"sessionId": "m1", "qualifiedSessionId": "local/m1", "agentSessionId": "a1",
                   "name": "review", "family": "claude", "harness": "claude"}),
            json!({"sessionId": "m2", "qualifiedSessionId": "hb/m2", "agentSessionId": "a2",
                   "name": "hb/builder", "family": "codex", "harness": "codex", "peer": "hb"}),
            json!({"sessionId": "m3", "qualifiedSessionId": "hb/m3", "agentSessionId": "a1",
                   "name": "hb/review", "family": "claude", "harness": "claude", "peer": "hb",
                   "tags": {"bead:cx-ab1.2": "1"}}),
        ]
    }

    fn ids(found: &[&Value]) -> Vec<String> {
        found.iter().map(|s| s["sessionId"].as_str().unwrap().to_owned()).collect()
    }

    #[test]
    fn a_link_finds_its_harness_session_on_the_host_it_names_first() {
        let rows = rows();
        let here = link("https://cmux.com/deeplink/agent?harness=claude&session=a1");
        assert_eq!(ids(&by_link(&rows, &here, "big-red")), ["m1", "m3"]);
        let on_hb = link("https://cmux.com/deeplink/agent?harness=claude&session=a1&host=hb");
        assert_eq!(ids(&by_link(&rows, &on_hb, "big-red")), ["m3", "m1"]);
        // The link's harness must be the session's family, or an older peer's harness.
        let wrong = link("https://cmux.com/deeplink/agent?harness=codex&session=a1");
        assert!(by_link(&rows, &wrong, "big-red").is_empty());
        let old = [
            json!({"sessionId": "o1", "agentSessionId": "a7", "name": "x", "harness": "codex"}),
            json!({"sessionId": "o2", "agentSessionId": "a7", "name": "y", "harness": "claude"}),
        ];
        let claude = link("https://cmux.com/deeplink/agent?harness=claude&session=a7");
        assert_eq!(ids(&by_link(&old, &claude, "big-red")), ["o2"]);
    }

    /// A peer's connection reads a card's session text masked, as it reads a summary's.
    #[test]
    fn a_card_reads_masked_on_a_peers_connection() {
        let token = format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234");
        let summary = json!({
            "sessionId": "m1", "harness": "claude", "lastSeq": 3, "name": "deploy",
            "title": format!("rotate {token}"), "lastPrompt": format!("push {token}"),
            "lastMessage": {"role": "agent", "text": format!("used {token}")},
            "lastTurn": {"status": "failed", "errorText": format!("bad {token}")},
        });
        let reply = json!({"session": card(&summary, Some("big-red")), "matches": [card(&summary, Some("big-red"))]});
        let msg = crate::rpc::Message::ok(json!(1), reply);
        let Some(crate::rpc::Message::Response { result: Some(masked), .. }) =
            crate::server::peer_text::masked(&msg)
        else {
            panic!("a card with a secret is not masked for a peer");
        };
        assert!(!masked.to_string().contains("ghp_"), "{masked}");
        assert_eq!(masked["session"]["lastMessage"]["text"], "used [GitHub Personal Access Token]");
        assert_eq!(masked["session"]["name"], "deploy");
    }

    #[test]
    fn a_link_to_a_moved_chat_leads_to_where_it_runs_now() {
        // m1 ran on desk-mac and moved to gcp-1, keeping its ids (`transfer_in.rs`).
        let rows = vec![
            json!({"sessionId": "m1", "agentSessionId": "a1", "name": "fix", "family": "codex",
                   "harness": "codex", "status": "closed",
                   "movedTo": {"host": "gcp-1", "sessionId": "m1", "cwd": "/home/cmux/w"}}),
            json!({"sessionId": "m1", "agentSessionId": "a1", "name": "gcp-1/fix",
                   "family": "codex", "harness": "codex", "peer": "gcp-1", "status": "idle"}),
        ];
        let footer = link("https://cmux.com/deeplink/agent?harness=codex&session=a1&host=desk-mac");
        let found = follow_moves(by_link(&rows, &footer, "desk-mac"), &rows, "desk-mac");
        assert_eq!(found[0]["peer"], "gcp-1", "the live copy first: {found:?}");
        assert!(found[1]["movedTo"].is_object());
        // By id or name too, and the target joins even when only the moved copy matched.
        let found = follow_moves(by_key(&rows, "desk-mac/fix", "desk-mac"), &rows, "desk-mac");
        assert_eq!(found.len(), 2, "{found:?}");
        assert_eq!(found[0]["peer"], "gcp-1");
        // A target not listed (its peer is gone): the moved copy answers, saying where it went.
        let alone = &rows[..1];
        let found = follow_moves(by_key(alone, "m1", "desk-mac"), alone, "desk-mac");
        assert_eq!(found.len(), 1);
        assert_eq!(card(found[0], Some("desk-mac"))["movedTo"]["host"], "gcp-1");
    }

    #[test]
    fn a_key_finds_by_id_then_host_and_name_then_bare_name() {
        let rows = rows();
        assert_eq!(ids(&by_key(&rows, "hb/m2", "big-red")), ["m2"]);
        assert_eq!(ids(&by_key(&rows, "a2", "big-red")), ["m2"]);
        assert_eq!(ids(&by_key(&rows, "review", "big-red")), ["m1", "m3"]);
        assert_eq!(ids(&by_key(&rows, "big-red/review", "big-red")), ["m1"]);
        assert_eq!(ids(&by_key(&rows, "builder", "big-red")), ["m2"]);
        assert!(by_key(&rows, "nobody", "big-red").is_empty());
    }

    #[test]
    fn an_exact_closed_name_beats_a_live_prefix() {
        let closed = json!({"sessionId": "closed", "name": "review", "status": "closed"});
        let live = json!({"sessionId": "live", "name": "review-2", "status": "idle"});
        let live_rows = vec![live.clone()];
        let all_rows = vec![live, closed];
        assert!(by_key_exact(&live_rows, "review", "local").is_empty());
        assert_eq!(ids(&by_key_exact(&all_rows, "review", "local")), ["closed"]);
        assert_eq!(ids(&by_key(&live_rows, "review", "local")), ["live"]);
    }

    #[test]
    fn a_bead_id_finds_the_sessions_that_carry_it() {
        let rows = rows();
        assert_eq!(ids(&by_key(&rows, "cx-ab1.2", "big-red")), ["m3"]);
        assert!(by_key(&rows, "cx-ab1", "big-red").is_empty());
        // A session named like the bead wins a plain lookup, never a bead-only one.
        let mut named = rows.clone();
        named.push(json!({"sessionId": "m4", "name": "cx-ab1.2", "harness": "claude"}));
        assert_eq!(ids(&by_key(&named, "cx-ab1.2", "big-red")), ["m4"]);
        assert_eq!(ids(&by_bead(&named, "cx-ab1.2")), ["m3"]);
        assert_eq!(card(&rows[2], Some("big-red"))["beads"], json!(["cx-ab1.2"]));
        assert_eq!(card(&rows[0], Some("big-red"))["beads"], json!([]));
    }

    /// A sub-session (`PARENT/SHORT`) is found by its short name, here or on a peer, on a `/`
    /// boundary only, and only when no whole name matches.
    #[test]
    fn a_sub_session_is_found_by_its_short_name() {
        let mut rows = rows();
        rows.push(json!({"sessionId": "m5", "name": "claude-sr2/mac-ci-3", "harness": "claude"}));
        rows.push(json!({"sessionId": "m6", "name": "hb/claude-sr2/mac-ci-4", "peer": "hb",
                         "harness": "claude"}));
        assert_eq!(ids(&by_key(&rows, "mac-ci-3", "mac-a")), ["m5"]);
        assert_eq!(ids(&by_key(&rows, "mac-ci-4", "mac-a")), ["m6"]);
        assert_eq!(ids(&by_key(&rows, "hb/mac-ci-4", "mac-a")), ["m6"]);
        assert_eq!(ids(&by_key(&rows, "mac-a/mac-ci-3", "mac-a")), ["m5"]);
        assert!(by_key(&rows, "ci-3", "mac-a").is_empty());
        rows.push(json!({"sessionId": "m7", "name": "mac-ci-3", "harness": "claude"}));
        assert_eq!(ids(&by_key(&rows, "mac-ci-3", "mac-a")), ["m7"], "a whole name wins");
    }

    /// Review of #27791: a host-qualified key keeps that host's exact name first, and a short
    /// name never crosses to another host.
    #[test]
    fn a_host_qualified_short_name_stays_on_its_host_after_its_exact_names() {
        let rows = vec![
            json!({"sessionId": "m1", "name": "lane", "harness": "claude"}),
            json!({"sessionId": "m2", "name": "parent/hb/lane", "harness": "claude"}),
            json!({"sessionId": "m3", "name": "cg/parent/hb/x", "peer": "cg", "harness": "claude"}),
            json!({"sessionId": "m4", "name": "a/x", "harness": "claude"}),
        ];
        assert_eq!(ids(&by_key(&rows, "hb/lane", "hb")), ["m1"]);
        assert!(by_key(&rows, "nohost/x", "hb").is_empty());
        assert_eq!(ids(&by_key(&rows, "hb/x", "hb")), ["m4"], "on host hb only, not cg's m3");
        assert_eq!(ids(&by_key(&rows, "x", "hb")), ["m3", "m4"], "a bare one: both, a tie");
        // A prefix still wins, as before short names.
        let mut rows = rows;
        rows.push(json!({"sessionId": "m5", "name": "xy", "harness": "claude"}));
        assert_eq!(ids(&by_key(&rows, "x", "hb")), ["m5"]);
    }

    #[test]
    fn a_card_carries_the_sessions_own_link() {
        let rows = rows();
        let card = card(&rows[2], Some("big-red"));
        assert_eq!(card["host"], "hb");
        assert_eq!(
            card["link"],
            "https://cmux.com/deeplink/agent?harness=claude&session=a1&host=hb&name=review"
        );
        let none = card_without_agent_id();
        assert_eq!(none["link"], Value::Null);
    }

    fn card_without_agent_id() -> Value {
        card(&json!({"sessionId": "m9", "name": "new one", "harness": "claude"}), Some("big-red"))
    }
}
