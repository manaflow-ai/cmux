//! Opaque agent links: `https://cmux.com/deeplink/agent?id=aid-<20 hex>`, the link a public PR
//! footer or commit trailer carries instead of one that names a host and session. The id is
//! HMAC-SHA256(key, lower(host) NUL harness NUL session) cut to 80 bits, so it says nothing to
//! anyone without the key. `acpmux resolve` (`hub/locate.rs`) reads one only on a machine that
//! holds the key: it hashes the sessions this daemon already lists (its own and its peers'
//! mirrored rows) and takes the one whose id is the link's. Nothing is looked up anywhere else,
//! and with no key, or no session that hashes to the id, the id names nothing (the caller falls
//! back to the web page).

use std::path::{Path, PathBuf};

use base64::Engine;

/// The key file in an acpmux home: base64 of at least 16 bytes, readable by its owner only.
pub const KEY_FILE: &str = "agent-link.key";

const PREFIX: &str = "aid-";
const HEX_LEN: usize = 20;

/// The opaque id `text` holds: `text` itself (`aid-` and 20 lowercase hex digits), or a web
/// agent link (`agent_link::web_query`, so also a line that carries one) whose query names it
/// once as `id=`. None for anything else.
pub fn find(text: &str) -> Option<String> {
    let text = text.trim();
    if is_id(text) {
        return Some(text.to_owned());
    }
    let query = crate::agent_link::web_query(text)?.replace("&amp;", "&");
    let found: Vec<&str> = query.split('&').filter_map(|p| p.strip_prefix("id=")).collect();
    match found.as_slice() {
        [one] if is_id(one) => Some((*one).to_owned()),
        _ => None,
    }
}

fn is_id(v: &str) -> bool {
    v.strip_prefix(PREFIX).is_some_and(|hex| {
        hex.len() == HEX_LEN
            && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

/// The key opaque ids are made with, when this machine holds it.
pub struct Key(Vec<u8>);

impl Key {
    /// The key in `home` (`KEY_FILE`), else in the default acpmux home; None when neither holds
    /// a usable one, or the file can be read by anyone but its owner.
    pub fn load(home: &Path) -> Option<Key> {
        let default = crate::config::default_home();
        let mut dirs: Vec<PathBuf> = vec![home.to_path_buf()];
        if default != home {
            dirs.push(default);
        }
        dirs.iter().find_map(|dir| Self::read(&dir.join(KEY_FILE)))
    }

    fn read(path: &Path) -> Option<Key> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let meta = std::fs::metadata(path).ok()?;
            if meta.mode() & 0o077 != 0 {
                return None;
            }
        }
        let text = std::fs::read_to_string(path).ok()?;
        let key = base64::engine::general_purpose::STANDARD.decode(text.trim()).ok()?;
        (key.len() >= 16).then_some(Key(key))
    }

    #[cfg(test)]
    pub fn from_bytes(key: &[u8]) -> Key {
        Key(key.to_vec())
    }

    /// The opaque id of a session: its host (any case), harness family and harness session id.
    pub fn id(&self, host: &str, harness: &str, session: &str) -> String {
        let msg = format!("{}\0{harness}\0{session}", host.to_ascii_lowercase());
        let mac = cmux_local_auth::frontend_proof::hmac_sha256(&self.0, msg.as_bytes());
        let hex = cmux_local_auth::frontend_proof::hex(&mac);
        // `hex` is 64 ASCII digits, so the prefix always exists; `get` keeps the panic ratchet at zero.
        format!("{PREFIX}{}", hex.get(..HEX_LEN).unwrap_or(&hex))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "aid-0123456789abcdef0123";

    #[test]
    fn an_opaque_id_is_found_bare_or_in_its_web_link() {
        assert_eq!(find(ID).as_deref(), Some(ID));
        assert_eq!(find(&format!("https://cmux.com/deeplink/agent?id={ID}")).as_deref(), Some(ID));
        assert_eq!(
            find(&format!("https://www.cmux.com/zh-CN/deeplink/agent/?id={ID}")).as_deref(),
            Some(ID)
        );
        assert_eq!(
            find(&format!("[big-red](https://cmux.com/deeplink/agent?id={ID})")).as_deref(),
            Some(ID)
        );
        assert_eq!(find("aid-0123"), None);
        assert_eq!(find(&format!("https://example.com/deeplink/agent?id={ID}")), None);
        assert_eq!(find(&format!("https://cmux.com/deeplink/agent?id={ID}&id={ID}")), None);
        assert_eq!(find("https://cmux.com/deeplink/agent?harness=claude&session=a1"), None);
        assert_eq!(find("reviewer"), None);
    }

    #[test]
    fn an_id_is_the_keyed_hash_of_host_harness_and_session() {
        // The same vector the private tool that mints these ids makes (HMAC-SHA256, 80 bits).
        let key = Key::from_bytes(b"0123456789abcdef");
        let id = key.id("Lane-Host", "claude", "s1");
        assert_eq!(id, "aid-6ca1e7736f56c73fb9b8");
        assert_ne!(id, key.id("lane-host", "codex", "s1"));
        assert_ne!(id, Key::from_bytes(b"fedcba9876543210").id("lane-host", "claude", "s1"));
    }

    #[cfg(unix)]
    #[test]
    fn a_key_others_can_read_is_not_used() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(KEY_FILE);
        std::fs::write(&path, "MDEyMzQ1Njc4OWFiY2RlZg==\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(Key::read(&path).is_some());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(Key::read(&path).is_none());
    }
}
