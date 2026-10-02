//! App passwords for user mode (server.md 8.3): a random 32-byte secret, its
//! SCRAM-SHA-256 verifier for `CREATE ROLE … PASSWORD`, and the pgpass line.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

use super::AppDb;

type HmacSha256 = Hmac<Sha256>;

/// Iterations Postgres itself uses (`scram_iterations` default).
pub const SCRAM_ITERATIONS: u32 = 4096;

/// The password text for 32 random bytes from the caller: lowercase hex, so
/// it needs no SASLprep and no pgpass escaping.
pub fn password_from_random(bytes: &[u8; 32]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn hmac(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC takes any key length");
    mac.update(data);
    mac.finalize().into_bytes().into()
}

/// PBKDF2-HMAC-SHA-256 with one output block (RFC 5802 `Hi`).
fn hi(password: &[u8], salt: &[u8], iterations: u32) -> [u8; 32] {
    let mut first = salt.to_vec();
    first.extend_from_slice(&1u32.to_be_bytes());
    let mut u = hmac(password, &first);
    let mut out = u;
    for _ in 1..iterations {
        u = hmac(password, &u);
        for (o, x) in out.iter_mut().zip(u.iter()) {
            *o ^= x;
        }
    }
    out
}

/// The verifier Postgres stores for `password` (RFC 7677):
/// `SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>`.
/// `salt` comes from the caller's random source. `password` must be ASCII
/// without control characters (SASLprep is then the identity), which
/// [`password_from_random`] guarantees.
pub fn scram_verifier(password: &str, salt: &[u8; 16], iterations: u32) -> Option<String> {
    if iterations == 0 || !password.bytes().all(|b| (0x20..0x7f).contains(&b)) {
        return None;
    }
    let salted = hi(password.as_bytes(), salt, iterations);
    let client_key = hmac(&salted, b"Client Key");
    let stored_key = Sha256::digest(client_key);
    let server_key = hmac(&salted, b"Server Key");
    Some(format!(
        "SCRAM-SHA-256${iterations}:{}${}:{}",
        STANDARD.encode(salt),
        STANDARD.encode(stored_key),
        STANDARD.encode(server_key)
    ))
}

/// The line for `<state>/postgres/admin.pgpass` (user mode and Windows):
/// any host, port and database (including `replication`), the admin role.
pub fn admin_pgpass_line(password: &str) -> String {
    format!("*:*:*:{}:{}\n", super::ADMIN_ROLE, password.replace('\\', "\\\\").replace(':', "\\:"))
}

/// The line for `<state>/apps/<app>/pgpass`: any host and port, the app's
/// database and role. Fields escape `\` and `:` as libpq requires.
pub fn pgpass_line(app: &AppDb, password: &str) -> String {
    let esc = |s: &str| s.replace('\\', "\\\\").replace(':', "\\:");
    format!("*:*:{}:{}:{}\n", esc(&app.database()), esc(&app.id.role()), esc(password))
}
