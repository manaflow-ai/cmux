//! Which callers upstream confirmed can read which repository, for a short time.
//!
//! The key is the SHA-256 of the caller's `Authorization` value ("anon" without one), the
//! tenant and the repository. Only upstream's 200 grants; any refusal revokes. The token
//! itself is never kept.

use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// The caller's key: a hash, safe to log (its first 12 characters are what logs show).
pub fn caller_key(authorization: Option<&[u8]>) -> String {
    match authorization {
        None => "anon".to_owned(),
        Some(value) => hex::encode(Sha256::digest(value)),
    }
}

/// The part of a caller key a log line may show.
pub fn short(key: &str) -> &str {
    key.get(..key.floor_char_boundary(key.len().min(12))).unwrap_or_default()
}

pub struct AuthCache {
    ttl: Duration,
    map: Mutex<HashMap<(String, String, String), Instant>>,
}

impl AuthCache {
    pub fn new(ttl: Duration) -> Self {
        Self { ttl, map: Mutex::new(HashMap::new()) }
    }

    fn key(caller: &str, tenant: &str, repo: &str) -> (String, String, String) {
        (caller.to_owned(), tenant.to_owned(), repo.to_owned())
    }

    pub fn allowed(&self, caller: &str, tenant: &str, repo: &str) -> bool {
        let mut map = self.map.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let key = Self::key(caller, tenant, repo);
        match map.get(&key) {
            Some(until) if *until > Instant::now() => true,
            Some(_) => {
                map.remove(&key);
                false
            }
            None => false,
        }
    }

    pub fn grant(&self, caller: &str, tenant: &str, repo: &str) {
        let mut map = self.map.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let now = Instant::now();
        if map.len() > 4096 {
            map.retain(|_, until| *until > now);
        }
        map.insert(Self::key(caller, tenant, repo), now + self.ttl);
    }

    pub fn revoke(&self, caller: &str, tenant: &str, repo: &str) {
        let mut map = self.map.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        map.remove(&Self::key(caller, tenant, repo));
    }
}

#[cfg(test)]
#[path = "auth_tests.rs"]
mod tests;
