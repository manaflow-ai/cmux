//! A person key's proof for one connection's challenge (`hub/person.rs`), which the CLI
//! (`client.rs`) and the daemon compute alike.

/// The transport a unix socket connection proves on (`transport` of [`person_proof`]).
pub const TRANSPORT_UNIX: &str = "unix";
/// The transport a proven LocalApp WebSocket connection proves on.
pub const TRANSPORT_APP: &str = "app";

/// The bytes a person proof covers.
fn proof_message(transport: &str, nonce: &str, connection: &str) -> Vec<u8> {
    let mut message = b"acpmux-person-v1\0".to_vec();
    for part in [transport, nonce, connection] {
        message.extend_from_slice(part.as_bytes());
        message.push(0);
    }
    message.pop();
    message
}

/// The proof for one connection's challenge, as lowercase hex; None when
/// `key` is not a person key. `transport` is the one the CLIENT knows it
/// uses ([`TRANSPORT_UNIX`] or [`TRANSPORT_APP`]), never a value from the
/// challenge: a relay that hands a unix connection's challenge to the app's
/// WebSocket gets a proof for the other transport.
pub fn person_proof(key: &str, transport: &str, nonce: &str, connection: &str) -> Option<String> {
    let key = cmux_local_auth::frontend_proof::unhex::<32>(key).filter(|_| valid_key(key))?;
    Some(cmux_local_auth::frontend_proof::hex(&cmux_local_auth::frontend_proof::hmac_sha256(
        &key,
        &proof_message(transport, nonce, connection),
    )))
}

/// 32 bytes as lowercase hex.
pub fn valid_key(key: &str) -> bool {
    key.len() == 64 && key.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
