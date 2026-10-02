//! The baked release keys (server.md 4.2 step 2: current and next).
//!
//! CI sets `CMUX_SERVER_RELEASE_KEYS` at build time to
//! `<id>:<64 hex public key>[,<id>:<hex>]`. A build without it has no keys
//! and refuses every manifest (exit 7). Keys never come from the runtime
//! environment, so a process environment cannot widen trust.

use cmux_server_core::manifest::TrustedKey;

use crate::host::unhex32;

/// Parses `<id>:<hex>[,…]`; malformed entries are dropped.
pub fn parse(spec: &str) -> Vec<TrustedKey> {
    spec.split(',')
        .filter_map(|entry| {
            let (id, key) = entry.trim().split_once(':')?;
            let public_key = unhex32(&key.to_ascii_lowercase())?;
            (!id.is_empty()).then(|| TrustedKey { id: id.to_owned(), public_key })
        })
        .collect()
}

/// The keys baked into this build.
pub fn baked() -> Vec<TrustedKey> {
    option_env!("CMUX_SERVER_RELEASE_KEYS").map(parse).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    #[test]
    fn parses_two_keys_and_drops_bad_entries() {
        let a = "11".repeat(32);
        let b = "AB".repeat(32);
        let keys = super::parse(&format!("current:{a}, next:{b},bad:12,:{a}"));
        assert_eq!(keys.len(), 2);
        assert_eq!(keys[0].id, "current");
        assert_eq!(keys[1].public_key, [0xab; 32]);
    }
}
