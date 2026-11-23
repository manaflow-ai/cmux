//! The session host's Noise static public key, for the bind record
//! (`daemon_noise_key`, cmux design/cloud-carrier.md "One carrier" item 2):
//! the platform stores it with the machine and hands it to the Mac, which
//! pins it before its first carrier handshake.
//!
//! The key comes from the session host's own remote identity file, which
//! cmux-remote writes when the daemon starts its remote runtime
//! (`identity.json` under its state dir: `{version: 1, private_key}`, the
//! X25519 private key in base64url). Only the public half leaves this
//! module, and the private bytes are zeroed after use.
//!
//! The file is under the session host's own home, which the supervisor picks
//! per machine (`linux/spawn.rs` `select_layout`) and records in
//! `/etc/cmux/daemon-layout` before each spawn: `/root` on an image laid out
//! for root, `/home/cmux` otherwise ([`session_home`]). The device's dial
//! requires the key (#37211), so a carrier bind waits for the file
//! ([`wait_after`]) and never goes out without it.

use std::path::{Path, PathBuf};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde_json::Value;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

/// cmux-remote's identity file version.
const IDENTITY_VERSION: u64 = 1;

/// How long a carrier bind waits for the identity file: the bind token's own
/// lifetime (it expires 15 minutes after the provider reports the machine
/// running, plans/cmux-next/state-placement.md 5.8). Past it the token is
/// spent or dead, so a bind would be refused anyway.
pub const WAIT_DEADLINE_MS: u64 = 15 * 60 * 1000;
/// The wait's retry interval: fast while a starting host writes the file,
/// then slower.
const WAIT_FAST_MS: u64 = 500;
const WAIT_FAST_FOR_MS: u64 = 15_000;
const WAIT_SLOW_MS: u64 = 5_000;

/// The session host's home from the layout marker's text (`root` or
/// `user`), the same home `select_layout` gives the host it spawns (its
/// `HOME`, under which cmux-remote keeps its state). `None` before the
/// first spawn wrote the marker.
pub fn session_home(marker: Option<&str>) -> Option<PathBuf> {
    use crate::daemon_spec::{LayoutKind, ROOT_HOME, WORK_HOME};
    match marker.map(str::trim) {
        Some(kind) if kind == LayoutKind::Root.as_str() => Some(PathBuf::from(ROOT_HOME)),
        Some(kind) if kind == LayoutKind::User.as_str() => Some(PathBuf::from(WORK_HOME)),
        _ => None,
    }
}

/// After a carrier bind has waited `waited_ms` for the key: the delay to
/// the next look, or `None` once [`WAIT_DEADLINE_MS`] has passed.
pub fn wait_after(waited_ms: u64) -> Option<u64> {
    let left = WAIT_DEADLINE_MS.checked_sub(waited_ms).filter(|left| *left > 0)?;
    let step = if waited_ms < WAIT_FAST_FOR_MS { WAIT_FAST_MS } else { WAIT_SLOW_MS };
    Some(step.min(left))
}

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

    /// #37199 review F1: an image laid out for root keeps the session host's
    /// state under /root, so its key is read there, not under /home/cmux.
    #[test]
    fn a_root_layout_reads_the_identity_under_root() {
        let home = session_home(Some("root\n")).unwrap();
        assert_eq!(
            identity_path(&home, "cloud"),
            Path::new("/root/.local/state/cmux/remote/sessions/Y2xvdWQ/auth/identity.json")
        );
    }

    #[test]
    fn a_user_layout_reads_the_identity_under_the_work_home() {
        let home = session_home(Some("user\n")).unwrap();
        assert_eq!(
            identity_path(&home, "cloud"),
            Path::new("/home/cmux/.local/state/cmux/remote/sessions/Y2xvdWQ/auth/identity.json")
        );
    }

    #[test]
    fn no_or_an_unknown_marker_names_no_home() {
        for marker in [None, Some(""), Some("admin\n")] {
            assert_eq!(session_home(marker), None, "{marker:?}");
        }
    }

    /// The wait keeps looking until the bind token's lifetime is over, then
    /// stops; it never ends in a bind without the key.
    #[test]
    fn the_key_wait_is_bounded_by_the_bind_token_lifetime() {
        assert_eq!(wait_after(0), Some(500));
        assert_eq!(wait_after(14_999), Some(500));
        assert_eq!(wait_after(15_000), Some(5_000));
        assert_eq!(wait_after(WAIT_DEADLINE_MS - 1_000), Some(1_000));
        assert_eq!(wait_after(WAIT_DEADLINE_MS), None);
        assert_eq!(wait_after(u64::MAX), None);
    }

    #[test]
    fn the_cloud_session_identity_lives_under_its_encoded_name() {
        assert_eq!(
            identity_path(Path::new("/home/cmux"), "cloud"),
            Path::new("/home/cmux/.local/state/cmux/remote/sessions/Y2xvdWQ/auth/identity.json")
        );
    }
}
