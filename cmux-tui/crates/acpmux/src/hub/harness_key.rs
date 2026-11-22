//! Part of `Hub`; see `hub/mod.rs`. A key that is a harness's name (`claude`, `codex`), and no
//! session's name, id, handle or former name, names no one session, even when one session's
//! name starts with it (`claude-3`, a default `HARNESS-N` name) or one session runs that
//! harness: `acpmux send HOST/claude` reached `ux-error-recovery` (alias
//! `claude-sr2`) by a name prefix, and four of a coordinator's replies went to the wrong session
//! in two hours (2026-11-21). [`Hub::harness_key_refusal`] refuses such a key before
//! `key_route`'s prefix and short-name tiers (and the exact lookup's prefixes after it) can pick
//! one, listing the sessions it might mean with each one's name and id. A harness's family
//! (`claude` for a `claude-sr2` profile) counts as its name.

use super::key_route::{AMBIGUOUS, Candidate, choices};
use super::*;

/// The most candidates a refusal's message names; its data lists up to [`LISTED`].
const SHOWN: usize = 10;

/// The most candidates a refusal's data lists (a harness can run hundreds of sessions).
const LISTED: usize = 50;

/// Where a key's sessions are looked for: every machine (a bare key), or one.
enum Scope<'a> {
    Everywhere,
    Here,
    Peer(&'a str),
}

impl Hub {
    /// The refusal for `key` when its name part is a harness some session in its scope runs and
    /// no session there has it as its name, id (or id prefix), handle or former name: `None`
    /// for every other key, and for one that names no session at all (the usual not-found
    /// answer follows).
    pub(super) fn harness_key_refusal(&self, key: &str, own: &str) -> Option<RpcError> {
        let (scope, word) = match key.split_once('/') {
            None => (Scope::Everywhere, key),
            Some((host, rest)) if !rest.is_empty() && !rest.contains('/') => {
                if host == crate::session_identity::LOCAL_HOST_ID
                    || super::own_host::is_own_machine_name(host)
                {
                    (Scope::Here, rest)
                } else if self.peer(host).is_some()
                    || self.remote_sessions.read().iter().any(|(_, r)| r.peer == host)
                {
                    (Scope::Peer(host), rest)
                } else {
                    return None;
                }
            }
            // A sub-session's whole name (`parent/child`): never a harness's name.
            Some(_) => return None,
        };
        let names = |name: &str, id: &str, handle: Option<&str>, former: bool| {
            former
                || name == word
                || id.starts_with(word)
                || crate::session_handle::matches(handle, id, word)
        };
        let near = |name: &str| {
            crate::name_match::step(name, word).is_some()
                || crate::name_match::short_step(name, word).is_some()
        };
        let mut harness_runs = false;
        let mut found: Vec<Candidate> = Vec::new();
        if matches!(scope, Scope::Everywhere | Scope::Here) {
            // A profile's family (`claude` for `claude-sr2`) is read only for a harness whose name
            // starts with the key; a config being reloaded right now leaves families unread.
            let cfg = self.config.try_read().ok();
            let family_is = |harness: &str| {
                harness.starts_with(word)
                    && cfg.as_ref().and_then(|c| c.family(harness)).is_some_and(|f| f == word)
            };
            for s in
                self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner).values()
            {
                let meta = s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                let former = meta.former_names.iter().any(|n| n == word);
                if names(&meta.name, &s.id, meta.handle.as_deref(), former) {
                    return None;
                }
                let runs = meta.harness == word || family_is(&meta.harness);
                harness_runs |= runs;
                if runs || near(&meta.name) {
                    found.push(Candidate {
                        host: own.to_owned(),
                        name: meta.name.clone(),
                        route: s.id.clone(),
                        closed: meta.status == SessionStatus::Closed,
                    });
                }
            }
        }
        if !matches!(scope, Scope::Here) {
            for (route, r) in self.remote_sessions.read().iter() {
                if let Scope::Peer(host) = scope
                    && r.peer != host
                {
                    continue;
                }
                let name = r.summary.name().unwrap_or_default();
                let bare = name.strip_prefix(&format!("{}/", r.peer)).unwrap_or(name);
                let id = r.receipt.mux_session_id.as_str();
                if names(bare, id, r.summary.handle(), r.summary.has_former_name(word)) {
                    return None;
                }
                let runs = r.summary.harness() == Some(word) || r.summary.family() == Some(word);
                harness_runs |= runs;
                if runs || near(bare) {
                    found.push(Candidate {
                        host: r.peer.clone(),
                        name: bare.to_owned(),
                        route: route.clone(),
                        closed: r.summary.closed(),
                    });
                }
            }
        }
        if !harness_runs || found.is_empty() {
            return None;
        }
        let live = found.iter().any(|c| !c.closed);
        let mut many: Vec<&Candidate> = found.iter().filter(|c| !live || !c.closed).collect();
        many.sort_by(|a, b| (&a.host, &a.name, &a.route).cmp(&(&b.host, &b.name, &b.route)));
        let count = many.len();
        many.truncate(LISTED);
        let mut list: Vec<String> = many
            .iter()
            .take(SHOWN)
            .map(|c| format!("{}/{} ({})", c.host, c.name, c.route))
            .collect();
        if count > SHOWN {
            list.push(format!("and {} more (`--json` lists up to {LISTED})", count - SHOWN));
        }
        let state = if live { "live" } else { "closed" };
        Some(
            RpcError::invalid_params(format!(
                "{key:?} names a harness ({word}), not one session: no session is named {word:?}, \
                 and {count} {state} session{} could be meant: {}; pass a session name or id",
                if count == 1 { "" } else { "s" },
                list.join(", ")
            ))
            .with_data(json!({
                "reason": AMBIGUOUS,
                "session": key,
                "harness": word,
                "count": count,
                "choices": choices(&many),
            })),
        )
    }
}
