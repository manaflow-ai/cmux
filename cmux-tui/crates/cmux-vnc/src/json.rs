//! The VNC client's rules over JSON (`vnc_*`), for Packages/Shared/CmuxVNC:
//! the Mac reaches it over cmux-layout-reducer-ffi's C ABI, iOS over
//! cmux-mobile-link-ffi's `vnc_json`, so both apps answer every op the same
//! way. Bytes travel as base64.
//!
//! - `vnc_address_parse`: a typed or pasted address and its credentials.
//! - `vnc_keysym`: the keysym of a character, a HID usage or an F key.
//! - `vnc_security_choose` / `vnc_security_server_chosen`: the security type.
//! - `vnc_version`: the server banner's minor and the reply to send.
//! - `vnc_password_response` / `vnc_apple_dh`: the authentication responses.

use std::fmt;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::auth::{ard, des};
use crate::rules::{self, Refusal};

/// The prefix every op of [`respond`] carries.
pub const OPERATION_PREFIX: &str = "vnc_";

/// Whether `operation` is one of [`respond`]'s.
pub fn handles(operation: &str) -> bool {
    operation.starts_with(OPERATION_PREFIX)
}

/// Why [`respond`] gave no answer. A refusal the rules make (no usable
/// security type) is an answer (`{"refusal": ...}`), not this.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JsonError {
    /// No op of that name.
    UnknownOperation(String),
    /// The request is not the op's JSON.
    Invalid(String),
}

impl fmt::Display for JsonError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownOperation(op) => write!(f, "unknown vnc op {op:?}"),
            Self::Invalid(detail) => write!(f, "invalid vnc request: {detail}"),
        }
    }
}

impl std::error::Error for JsonError {}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, JsonError> {
    serde_json::from_slice(request).map_err(|e| JsonError::Invalid(e.to_string()))
}

fn bytes(field: &str, text: &str) -> Result<Vec<u8>, JsonError> {
    STANDARD.decode(text).map_err(|e| JsonError::Invalid(format!("{field}: {e}")))
}

fn refusal(refusal: Refusal) -> Value {
    match refusal {
        Refusal::CredentialsRequired => json!({ "refusal": "credentialsRequired" }),
        Refusal::PasswordRequired => json!({ "refusal": "passwordRequired" }),
        Refusal::NoSupportedSecurityType(offered) => {
            json!({ "refusal": "noSupportedSecurityType", "offered": offered })
        }
    }
}

fn random(count: usize) -> Result<Vec<u8>, JsonError> {
    let mut out = vec![0; count];
    getrandom::fill(&mut out).map_err(|e| JsonError::Invalid(format!("no randomness: {e}")))?;
    Ok(out)
}

pub fn respond(operation: &str, request: &[u8]) -> Result<Value, JsonError> {
    let answer = match operation {
        // An address and the credentials a vnc:// URL carried (null: not an address).
        "vnc_address_parse" => {
            #[derive(Deserialize)]
            struct Request {
                text: String,
            }
            let r: Request = read(request)?;
            match rules::parse_address(&r.text) {
                Some(a) => json!({
                    "host": a.host,
                    "port": a.port,
                    "username": a.username,
                    "password": a.password,
                    "label": rules::label(&a.host, a.port),
                }),
                None => Value::Null,
            }
        }
        // One of `character`, `hidUsage` or `function`: the keysym (null: none).
        "vnc_keysym" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(default)]
                character: Option<String>,
                #[serde(default)]
                hid_usage: Option<u32>,
                #[serde(default)]
                function: Option<i64>,
            }
            let r: Request = read(request)?;
            let keysym = match (r.character, r.hid_usage, r.function) {
                (Some(c), None, None) => Some(rules::character_keysym(&c)),
                (None, Some(usage), None) => rules::hid_keysym(usage),
                (None, None, Some(n)) => Some(rules::function_keysym(n)),
                _ => {
                    return Err(JsonError::Invalid(
                        "exactly one of character, hidUsage, function".into(),
                    ));
                }
            };
            json!({ "keysym": keysym })
        }
        // RFB 3.7+: the type to send back from the server's list.
        "vnc_security_choose" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                offered: Vec<u8>,
                #[serde(default)]
                has_username: bool,
                #[serde(default)]
                has_password: bool,
            }
            let r: Request = read(request)?;
            match rules::choose_security(&r.offered, r.has_username, r.has_password) {
                Ok(t) => json!({ "type": t }),
                Err(e) => refusal(e),
            }
        }
        // RFB 3.3: the server's word (not 0, the refusal the caller reads).
        "vnc_security_server_chosen" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                word: u32,
                #[serde(default)]
                has_username: bool,
            }
            let r: Request = read(request)?;
            match rules::server_chosen_security(r.word, r.has_username) {
                Ok(t) => json!({ "type": t }),
                Err(e) => refusal(e),
            }
        }
        // The 12-byte banner: the minors and the banner to answer (null: not RFB 3.x).
        "vnc_version" => {
            #[derive(Deserialize)]
            struct Request {
                banner: String,
            }
            let r: Request = read(request)?;
            match rules::server_minor(&bytes("banner", &r.banner)?) {
                Some(server) => {
                    let client = rules::client_minor(server);
                    json!({
                        "serverMinor": server,
                        "minor": client,
                        "reply": STANDARD.encode(format!("RFB 003.00{client}\n")),
                    })
                }
                None => Value::Null,
            }
        }
        // VNC authentication: DES of the 16-byte challenge keyed by the password.
        "vnc_password_response" => {
            #[derive(Deserialize)]
            struct Request {
                password: String,
                challenge: String,
            }
            let r: Request = read(request)?;
            let challenge: [u8; 16] = bytes("challenge", &r.challenge)?
                .try_into()
                .map_err(|_| JsonError::Invalid("challenge: not 16 bytes".into()))?;
            json!({ "response": STANDARD.encode(des::vnc_response(r.password.as_bytes(), challenge)) })
        }
        // Apple DH: the encrypted credentials and this side's public key (null: bad key).
        "vnc_apple_dh" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                generator: u16,
                prime: String,
                server_public_key: String,
                username: String,
                password: String,
                /// Fixed in tests; random in a session.
                #[serde(default)]
                private_key: Option<String>,
                #[serde(default)]
                padding: Option<String>,
            }
            let r: Request = read(request)?;
            let prime = bytes("prime", &r.prime)?;
            let server = bytes("serverPublicKey", &r.server_public_key)?;
            if prime.len() > ard::MAX_KEY_BYTES {
                return Ok(Value::Null);
            }
            let private_key = match r.private_key {
                Some(key) => bytes("privateKey", &key)?,
                None => random(prime.len())?,
            };
            let padding = match r.padding {
                Some(p) => bytes("padding", &p)?,
                None => random(128)?,
            };
            let padding: [u8; 128] = padding
                .try_into()
                .map_err(|_| JsonError::Invalid("padding: not 128 bytes".into()))?;
            match ard::response(
                r.generator,
                &prime,
                &server,
                &r.username,
                &r.password,
                &private_key,
                padding,
            ) {
                Some(out) => json!({
                    "encryptedCredentials": STANDARD.encode(out.encrypted_credentials),
                    "clientPublicKey": STANDARD.encode(out.client_public_key),
                }),
                None => Value::Null,
            }
        }
        _ => return Err(JsonError::UnknownOperation(operation.to_owned())),
    };
    Ok(answer)
}

#[cfg(test)]
#[path = "json_tests.rs"]
mod tests;
