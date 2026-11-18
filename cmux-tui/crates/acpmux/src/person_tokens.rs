//! The caller token a session's harness gets, and a connection's nonce. The rules and the
//! threat model are in `hub/person.rs` ("Starting in a mode that does not ask"), (a).

/// The env var that carries a session's caller token to its harness (and
/// so to the acpmux CLI its agent runs).
pub const CALLER_TOKEN_ENV: &str = "ACPMUX_SESSION_TOKEN";
/// The env var that names the socket of the daemon that issued the caller
/// token: the CLI sends the token to that socket only (`client.rs`).
pub const CALLER_SOCKET_ENV: &str = "ACPMUX_SESSION_TOKEN_SOCKET";
/// The env vars `caller_env` sets: acpmux's alone, never a profile's,
/// preset's or request's (`agent/command.rs` drops them from those).
pub const CALLER_ENV_KEYS: [&str; 2] = [CALLER_TOKEN_ENV, CALLER_SOCKET_ENV];

/// This daemon run's caller secret: 32 random bytes, in memory only.
fn caller_secret() -> &'static [u8; 32] {
    static SECRET: std::sync::OnceLock<[u8; 32]> = std::sync::OnceLock::new();
    SECRET.get_or_init(|| {
        let mut bytes = [0u8; 32];
        // No randomness means no safe token: the daemon cannot serve.
        getrandom::fill(&mut bytes).expect("the OS random generator for the caller secret"); // crash-allow: no randomness, no safe token
        bytes
    })
}

/// The caller token of session `session_id` on this daemon run (`hub/person.rs`
/// (a)): lowercase hex HMAC-SHA256(run secret,
/// "acpmux-caller-session-v1" 0 session id).
pub fn caller_token(session_id: &str) -> String {
    let mut message = b"acpmux-caller-session-v1".to_vec();
    message.push(0);
    message.extend_from_slice(session_id.as_bytes());
    cmux_local_auth::frontend_proof::hex(&cmux_local_auth::frontend_proof::hmac_sha256(
        caller_secret(),
        &message,
    ))
}

/// The env a harness of session `session_id` gets for (a): its caller token
/// and this daemon's socket, the one place the token is sent.
pub fn caller_env(session_id: &str) -> [(&'static str, String); 2] {
    let socket = crate::config::socket_path().to_string_lossy().into_owned();
    [(CALLER_TOKEN_ENV, caller_token(session_id)), (CALLER_SOCKET_ENV, socket)]
}

/// A connection's nonce: 32 random bytes as lowercase hex.
pub fn new_nonce() -> String {
    let mut bytes = [0u8; 32];
    // No randomness means no safe challenge: the daemon cannot serve.
    getrandom::fill(&mut bytes).expect("the OS random generator for a connection nonce"); // crash-allow: no randomness, no safe challenge
    cmux_local_auth::frontend_proof::hex(&bytes)
}
