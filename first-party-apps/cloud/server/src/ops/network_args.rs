//! Argument checks for the network, tunnel, firewall, domain and
//! publication ops. Every value that enters a path or a query string is
//! checked against a closed alphabet first, so no argument can add a path
//! segment, a query parameter or a fragment.

use crate::api::CloudError;
use serde_json::{Map, Value};

/// A provider token (network, rule, tunnel id) or a device fingerprint:
/// `[A-Za-z0-9._:-]{1,128}`, the Cloud API's client identifier alphabet.
/// Safe in a query value without encoding.
pub(super) fn token<'a>(map: &'a Map<String, Value>, field: &str) -> Result<&'a str, CloudError> {
    optional_token(map, field)?.ok_or_else(|| CloudError::invalid(format!("{field} is required")))
}

pub(super) fn optional_token<'a>(
    map: &'a Map<String, Value>,
    field: &str,
) -> Result<Option<&'a str>, CloudError> {
    match map.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if is_token(s) => Ok(Some(s)),
        Some(_) => Err(CloudError::invalid(format!(
            "{field} must be 1 to 128 letters, digits, '.', '_', ':' or '-'"
        ))),
    }
}

fn is_token(s: &str) -> bool {
    (1..=128).contains(&s.len())
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-'))
}

/// One DNS host name as the Cloud API takes it (no scheme, port, path or
/// wildcard): labels of `[A-Za-z0-9-]`, 1 to 63 characters, joined by
/// dots, at most 253 characters. A publication UUID passes too.
pub(super) fn is_hostname(s: &str) -> bool {
    (1..=253).contains(&s.len())
        && s.split('.').all(|label| {
            (1..=63).contains(&label.len())
                && label.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                && !label.starts_with('-')
                && !label.ends_with('-')
        })
}

/// A required host name or publication id for a path segment.
pub(super) fn host_ref<'a>(
    map: &'a Map<String, Value>,
    field: &str,
) -> Result<&'a str, CloudError> {
    match map.get(field) {
        Some(Value::String(s)) if is_hostname(s) => Ok(s),
        None | Some(Value::Null) => Err(CloudError::invalid(format!("{field} is required"))),
        Some(_) => Err(CloudError::invalid(format!(
            "{field} must be a host name or an id (letters, digits, '-' and '.')"
        ))),
    }
}

/// An optional enum value from `allowed`.
pub(super) fn one_of<'a>(
    map: &'a Map<String, Value>,
    field: &str,
    allowed: &[&str],
) -> Result<Option<&'a str>, CloudError> {
    match map.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if allowed.contains(&s.as_str()) => Ok(Some(s)),
        Some(_) => {
            Err(CloudError::invalid(format!("{field} must be one of {}", allowed.join(", "))))
        }
    }
}

/// An optional boolean.
pub(super) fn flag(map: &Map<String, Value>, field: &str) -> Result<Option<bool>, CloudError> {
    match map.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(b)) => Ok(Some(*b)),
        Some(_) => Err(CloudError::invalid(format!("{field} must be true or false"))),
    }
}

/// A WireGuard public key: standard base64 of exactly 32 bytes, 44
/// characters with one `=` pad, in canonical form (the last character
/// carries no bits past the key). Same rule as the Cloud API
/// (`isWireGuardPublicKey`). A private key has the same form, so the check
/// cannot tell them apart: the op takes only a field named for the public
/// key and documents that the private key never leaves `cmux link`.
pub(super) fn is_wireguard_public_key(s: &str) -> bool {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes = s.as_bytes();
    if bytes.len() != 44 || bytes[43] != b'=' {
        return false;
    }
    let mut last = 0;
    for &b in &bytes[..43] {
        match ALPHABET.iter().position(|&c| c == b) {
            Some(v) => last = v,
            None => return false,
        }
    }
    // 43 characters carry 258 bits; the last 2 must be zero for 256.
    last & 0b11 == 0
}

/// True when a WireGuard configuration text has a `PrivateKey` line with a
/// value. The Cloud API sends the line blank (the caller keeps its key).
pub(super) fn config_has_private_key(config: &str) -> bool {
    config.lines().any(|line| {
        let mut parts = line.splitn(2, '=');
        let name = parts.next().unwrap_or_default().trim();
        let value = parts.next().unwrap_or_default().trim();
        name.eq_ignore_ascii_case("PrivateKey") && !value.is_empty()
    })
}

/// A CIDR range: an IPv4 or IPv6 address and a prefix length that fits it.
pub(super) fn is_cidr(s: &str) -> bool {
    let Some((address, prefix)) = s.rsplit_once('/') else { return false };
    if prefix.is_empty() || !prefix.bytes().all(|b| b.is_ascii_digit()) || prefix.len() > 3 {
        return false;
    }
    let Ok(prefix) = prefix.parse::<u8>() else { return false };
    match address.parse::<std::net::IpAddr>() {
        Ok(std::net::IpAddr::V4(_)) => prefix <= 32,
        Ok(std::net::IpAddr::V6(_)) => prefix <= 128,
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wireguard_keys() {
        assert!(is_wireguard_public_key("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
        assert!(is_wireguard_public_key("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA="));
        assert!(is_wireguard_public_key("+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/+/8="));
        assert!(!is_wireguard_public_key("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB="));
        assert!(!is_wireguard_public_key("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="));
        assert!(!is_wireguard_public_key(" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
    }

    #[test]
    fn hostnames_and_cidrs() {
        assert!(is_hostname("app.example.test"));
        assert!(is_hostname("00000000-0000-4000-8000-000000000001"));
        assert!(!is_hostname("a..b"));
        assert!(!is_hostname("-a.test"));
        assert!(!is_hostname("*.example.test"));
        assert!(is_cidr("10.0.0.0/8") && is_cidr("fd00::/48") && is_cidr("0.0.0.0/0"));
        assert!(!is_cidr("10.0.0.0/33") && !is_cidr("10.0.0.0") && !is_cidr("x/8"));
        assert!(!is_cidr("10.0.0.0/+8"));
    }

    #[test]
    fn private_key_lines() {
        assert!(!config_has_private_key("[Interface]\nPrivateKey = \nAddress = 10.0.0.2/32\n"));
        assert!(!config_has_private_key("PrivateKey="));
        assert!(config_has_private_key("[Interface]\nprivatekey = abc\n"));
    }
}
