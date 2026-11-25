//! Part of `Hub`; see `hub/mod.rs`. Names that outlive a session (Leo, 2026-11-24: "well clearly
//! we need to have better listeners/scheduling to make sure those messages are recievable";
//! plans/cmux-next/message-delivery-successors.md):
//!
//! - `acpmux succeed OLD...` makes a session the successor of sessions that died or moved
//!   (`SessionMeta::succeeds`, `HOST/NAME` or a bare NAME here). A message to OLD reaches it.
//! - `acpmux role claim goal:SLUG` gives it a role address (`SessionMeta::roles`). A claim takes
//!   the address from every other session here; a message to the address reaches it.
//!
//! Both go out in the session's heartbeat row (`formerNames`, `roles`), so the mesh hub resolves
//! them for every other machine, and both resolve here first (`resolve_alias_here`,
//! `alias_remote_route`) before a send goes to the hub.

use super::*;
use crate::mesh::{MAX_FORMER_NAME, MAX_FORMER_NAMES, RoleClaim, valid_role};

/// The most sessions one session lists as taken over; the oldest goes first.
pub(crate) const MAX_SUCCEEDS: usize = MAX_FORMER_NAMES;

/// Whether `name` may be a successor entry: `HOST/NAME` or NAME, 1..=160 chars, no blank.
pub(crate) fn valid_succeeded(name: &str) -> bool {
    let n = name.chars().count();
    (1..=MAX_FORMER_NAME).contains(&n)
        && !name.chars().any(char::is_whitespace)
        && !name.starts_with('/')
        && !name.ends_with('/')
}

/// `succeeds` with `add` last (newest), no repeat, at most [`MAX_SUCCEEDS`].
fn push_succeeded(succeeds: &mut Vec<String>, add: &str) {
    succeeds.retain(|n| n != add);
    succeeds.push(add.to_owned());
    let over = succeeds.len().saturating_sub(MAX_SUCCEEDS);
    succeeds.drain(..over);
}

impl Hub {
    /// The session here a successor entry or a role address `key` names: None when none does.
    /// A role goes to its latest claim; several live successors of one name are refused with
    /// their names, never one picked.
    pub(super) fn resolve_alias_here(&self, key: &str) -> Option<Result<Arc<Session>, RpcError>> {
        if key.is_empty() {
            return None;
        }
        let role = valid_role(key);
        let sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut claims: Vec<(u64, Arc<Session>)> = Vec::new();
        let mut rows: Vec<(Arc<Session>, String, bool)> = Vec::new();
        for s in sessions.values() {
            let meta = s.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let closed = meta.status == SessionStatus::Closed;
            if role {
                if let Some(claim) = meta.roles.iter().find(|r| r.address == key)
                    && !closed
                {
                    claims.push((claim.claimed_at, s.clone()));
                }
            } else if meta.succeeds.iter().any(|n| n == key) {
                rows.push((s.clone(), format!("{} ({})", meta.name, s.id), closed));
            }
        }
        drop(sessions);
        if role {
            return claims.into_iter().max_by_key(|(at, _)| *at).map(|(_, s)| Ok(s));
        }
        let live = rows.iter().any(|(_, _, closed)| !closed);
        let mut rows: Vec<_> = rows.into_iter().filter(|(_, _, c)| !live || !c).collect();
        match rows.len() {
            0 => None,
            1 => rows.pop().map(|(s, _, _)| Ok(s)),
            _ => {
                let mut names: Vec<String> = rows.into_iter().map(|(_, n, _)| n).collect();
                names.sort();
                Some(Err(crate::session_name::ambiguous(key, &names)))
            }
        }
    }

    /// The route of a connected peer's session that lists `key` (a `HOST/NAME` it took over, or
    /// a role address) in its `formerNames`: None when none does; refused when several do.
    pub(super) fn alias_remote_route(&self, key: &str) -> Option<Result<String, RpcError>> {
        if key.is_empty() {
            return None;
        }
        let map = self.remote_sessions.read();
        let mut rows: Vec<(String, String)> = map
            .iter()
            .filter(|(_, r)| !r.summary.closed() && r.summary.has_former_name(key))
            .filter(|(_, r)| {
                self.peer(&r.peer)
                    .is_some_and(|p| p.connected.load(std::sync::atomic::Ordering::SeqCst))
            })
            .map(|(route, r)| (route.clone(), r.summary.name().unwrap_or_default().to_owned()))
            .collect();
        drop(map);
        match rows.len() {
            0 => None,
            1 => rows.pop().map(|(route, _)| Ok(route)),
            _ => {
                let mut names: Vec<String> = rows.into_iter().map(|(_, n)| n).collect();
                names.sort();
                Some(Err(crate::session_name::ambiguous(key, &names)))
            }
        }
    }

    /// Where a send to `target` goes instead, when `target` names no live session it can reach
    /// (nothing here, or a session on a peer that is down) and a successor or a role claim names
    /// a session here or on a connected peer: that session's key (its id here, its route on the
    /// peer). None leaves `target` as it is.
    pub fn successor_for(&self, target: &str) -> Option<Result<String, RpcError>> {
        let reachable = self.resolve(target).is_ok()
            || (self.resolve_remote(target).is_some() && self.peer_down_for(target).is_none());
        if reachable {
            return None;
        }
        if let Some(found) = self.resolve_alias_here(target) {
            return Some(found.map(|s| s.id.clone()));
        }
        self.alias_remote_route(target)
    }

    /// `acpmux succeed OLD... [--session S]`: `session` takes over each of `olds`. Each one's own
    /// former names come along, from a peer's row or a session here that still lists them: a
    /// bare one qualified by its host (`HOST/NAME`), a successor entry as it is. Every other
    /// session here gives up each name it takes.
    pub fn succeed(&self, session: &Arc<Session>, olds: &[String]) -> Result<Value, RpcError> {
        if olds.is_empty() {
            return Err(RpcError::invalid_params("name at least one session to succeed"));
        }
        let mut taken: Vec<String> = Vec::new();
        for old in olds {
            let old = old.trim();
            if !valid_succeeded(old) {
                return Err(RpcError::invalid_params(format!(
                    "{old:?} is no session name: give HOST/NAME or NAME (1..{MAX_FORMER_NAME} chars)"
                ))
                .with_data(json!({"reason": "succeed.invalid"})));
            }
            let own = session.read_meta(|m| m.name == old || session.id == old);
            if own {
                return Err(RpcError::invalid_params(format!("{old} is this session")));
            }
            taken.push(old.to_owned());
            taken.extend(self.former_names_of(old));
        }
        let own_name = session.read_meta(|m| m.name.clone());
        taken.retain(|n| n != &own_name && valid_succeeded(n));
        // One successor per name here: every other session gives each one up.
        let others: Vec<Arc<Session>> = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .filter(|s| s.id != session.id)
            .cloned()
            .collect();
        for other in others {
            let changed = {
                let mut m = other.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                let before = m.succeeds.len();
                m.succeeds.retain(|n| !taken.contains(n));
                m.succeeds.len() != before
            };
            if changed {
                self.save_meta(&other);
            }
        }
        let succeeds = {
            let mut m = session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            for name in &taken {
                push_succeeded(&mut m.succeeds, name);
            }
            m.succeeds.clone()
        };
        self.append(session, "mux", "succeeded", json!({"names": taken}));
        self.save_meta_kept(session)?;
        Ok(json!({"sessionId": session.id, "succeeds": succeeds, "added": taken}))
    }

    /// The names a predecessor `old` still answers to: a peer row's `formerNames` (a bare one as
    /// `HOST/NAME`), or a session here's former names and successor entries.
    fn former_names_of(&self, old: &str) -> Vec<String> {
        let mut out = Vec::new();
        if let Some((_, route, summary)) = self.resolve_remote(old) {
            let host = old
                .split_once('/')
                .map(|(h, _)| h)
                .or_else(|| route.split_once('/').map(|(h, _)| h));
            if let Some(names) = summary.get("formerNames").and_then(Value::as_array) {
                for n in names.iter().filter_map(Value::as_str) {
                    match host {
                        Some(h) if !n.contains('/') && !valid_role(n) => {
                            out.push(format!("{h}/{n}"))
                        }
                        _ if !valid_role(n) => out.push(n.to_owned()),
                        _ => {}
                    }
                }
            }
            return out;
        }
        if let Ok(s) = self.resolve_here(old) {
            s.read_meta(|m| {
                out.extend(m.former_names.iter().cloned());
                out.extend(m.succeeds.iter().cloned());
            });
        }
        out
    }

    /// `acpmux role claim ADDRESS`: `session` holds `address`; every other session here gives it
    /// up (the latest claim wins, here as on the hub).
    pub fn claim_role(&self, session: &Arc<Session>, address: &str) -> Result<Value, RpcError> {
        let address = address.trim();
        if !valid_role(address) {
            return Err(RpcError::invalid_params(format!(
                "{address:?} is no role address: give goal:SLUG, area:NAME or topic:NAME \
                 (letters, digits, '.', '_', '-', up to 128)"
            ))
            .with_data(json!({"reason": "role.invalid"})));
        }
        let mut released = Vec::new();
        let others: Vec<Arc<Session>> = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .filter(|s| s.id != session.id)
            .cloned()
            .collect();
        for other in others {
            let changed = {
                let mut m = other.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                let before = m.roles.len();
                m.roles.retain(|r| r.address != address);
                (m.roles.len() != before).then(|| m.name.clone())
            };
            if let Some(name) = changed {
                self.append(
                    &other,
                    "mux",
                    "role_released",
                    json!({"address": address, "to": session.id}),
                );
                self.save_meta(&other);
                released.push(name);
            }
        }
        let claimed_at = crate::store::now_ms();
        {
            let mut m = session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            m.roles.retain(|r| r.address != address);
            m.roles.push(RoleClaim { address: address.to_owned(), claimed_at });
            let over = m.roles.len().saturating_sub(crate::mesh::MAX_ROLES);
            m.roles.drain(..over);
        }
        self.append(session, "mux", "role_claimed", json!({"address": address}));
        self.save_meta_kept(session)?;
        Ok(json!({
            "sessionId": session.id,
            "address": address,
            "claimedAt": claimed_at,
            "releasedFrom": released,
        }))
    }

    /// `acpmux role release ADDRESS`: `session` gives `address` up.
    pub fn release_role(&self, session: &Arc<Session>, address: &str) -> Result<Value, RpcError> {
        let address = address.trim();
        let had = {
            let mut m = session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let before = m.roles.len();
            m.roles.retain(|r| r.address != address);
            m.roles.len() != before
        };
        if !had {
            return Err(RpcError::invalid_params(format!(
                "{} holds no role {address}",
                session.id
            ))
            .with_data(json!({"reason": "role.not_held"})));
        }
        self.append(session, "mux", "role_released", json!({"address": address}));
        self.save_meta_kept(session)?;
        Ok(json!({"sessionId": session.id, "address": address, "released": true}))
    }

    /// `acpmux role ls`: every role and successor entry the sessions here hold.
    pub fn roles_list(&self) -> Value {
        let sessions: Vec<Arc<Session>> = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .cloned()
            .collect();
        let mut rows: Vec<Value> = sessions
            .iter()
            .filter_map(|s| {
                s.read_meta(|m| {
                    (m.status != SessionStatus::Closed
                        && (!m.roles.is_empty() || !m.succeeds.is_empty()))
                    .then(|| {
                        json!({
                            "sessionId": s.id,
                            "name": m.name,
                            "roles": m.roles,
                            "succeeds": m.succeeds,
                        })
                    })
                })
            })
            .collect();
        rows.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
        json!({"sessions": rows})
    }
}

#[cfg(test)]
#[path = "successors_tests.rs"]
mod tests;
