//! The session host's Noise static public key, for the bind record
//! (`daemon_noise_key`, cmux design/cloud-carrier.md "One carrier" item 2):
//! the platform stores it with the machine and hands it to the Mac, which
//! pins it before its first carrier handshake.
//!
//! The key comes from the session host's own remote identity file, which
//! cmux-remote writes when the daemon starts its remote runtime
//! (`identity.json` under its state dir: `{version: 1, private_key}`, the
//! X25519 private key in base64url). Only the public half leaves this
//! module, and the private bytes are zeroed after use. A missing or
//! unreadable file sends no key: the field is optional.

use std::path::{Path, PathBuf};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde_json::Value;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

/// cmux-remote's identity file version.
const IDENTITY_VERSION: u64 = 1;

/// The session host's identity file under its home: cmux-remote's default
/// state dir (`~/.local/state/cmux/remote`), the session's folder (its name
/// in base64url), then `auth/identity.json`.
pub fn identity_path(home: &Path, session: &str) -> PathBuf {
    home.join(".local/state/cmux/remote/sessions")
        .join(URL_SAFE_NO_PAD.encode(session.as_bytes()))
        .join("auth/identity.json")
}

/// The base64url public key of an identity file's text, or `None` when it
/// is not a version 1 identity with a 32-byte key.
pub fn public_key(text: &str) -> Option<String> {
    let value: Value = serde_json::from_str(text).ok()?;
    if value.get("version").and_then(Value::as_u64) != Some(IDENTITY_VERSION) {
        return None;
    }
    let encoded = value.get("private_key")?.as_str()?;
    let bytes = Zeroizing::new(URL_SAFE_NO_PAD.decode(encoded).ok()?);
    let private: Zeroizing<[u8; 32]> = Zeroizing::new(bytes.as_slice().try_into().ok()?);
    let public = PublicKey::from(&StaticSecret::from(*private));
    Some(URL_SAFE_NO_PAD.encode(public.as_bytes()))
}

/// The session host's public key from its identity file at `file`.
pub fn read(file: &Path) -> Option<String> {
    let text = Zeroizing::new(std::fs::read_to_string(file).ok()?);
    public_key(&text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_public_half_of_a_generated_identity() {
        let private = [9_u8; 32];
        let expected = PublicKey::from(&StaticSecret::from(private));
        let text =
            format!(r#"{{"version": 1, "private_key": "{}"}}"#, URL_SAFE_NO_PAD.encode(private));
        assert_eq!(public_key(&text), Some(URL_SAFE_NO_PAD.encode(expected.as_bytes())));
    }

    #[test]
    fn anything_else_gives_no_key() {
        for text in [
            "",
            "{}",
            r#"{"version": 2, "private_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#,
            r#"{"version": 1, "private_key": "short"}"#,
            r#"{"version": 1}"#,
        ] {
            assert_eq!(public_key(text), None, "{text}");
        }
    }

    #[test]
    fn the_cloud_session_identity_lives_under_its_encoded_name() {
        assert_eq!(
            identity_path(Path::new("/home/cmux"), "cloud"),
            Path::new("/home/cmux/.local/state/cmux/remote/sessions/Y2xvdWQ/auth/identity.json")
        );
    }
}
