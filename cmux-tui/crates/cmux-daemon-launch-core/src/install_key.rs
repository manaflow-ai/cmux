//! The app's install key (P8 slice 3b-2, plans/cmux-next/identity.md): 32
//! bytes and an install id. The app hands it to a daemon it starts (`server
//! ensure --install-key-stdin`) in its stored form ([`payload`]) and proves
//! itself on each connection with `client-hello` ([`proof`], the bytes the
//! daemon checks: cmux-local-auth `frontend_proof`). The app keeps the
//! random source and the file.

use cmux_local_auth::frontend_proof::{
    INSTALL_KEY_LEN, NONCE_LEN, hello_proof, hex, unhex, valid_install_id,
};

/// An install key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallKey {
    pub install_id: String,
    pub key: [u8; INSTALL_KEY_LEN],
}

impl InstallKey {
    /// A key with a valid install id (1-128 ASCII letters, digits, `-`, `_`)
    /// and not all zero.
    pub fn new(install_id: &str, key: [u8; INSTALL_KEY_LEN]) -> Option<Self> {
        (valid_install_id(install_id) && key.iter().any(|b| *b != 0))
            .then(|| Self { install_id: install_id.into(), key })
    }

    /// A fresh key from the app's random bytes: the key, and `inst_` plus the
    /// first 20 hex digits of `id_random`.
    pub fn generate(key: [u8; INSTALL_KEY_LEN], id_random: &[u8]) -> Option<Self> {
        let suffix: String = hex(id_random).chars().take(20).collect();
        Self::new(&format!("inst_{suffix}"), key)
    }

    /// `cmuxik1 <install_id> <hex key>\n`: the launcher pipe payload and the
    /// stored form.
    pub fn payload(&self) -> String {
        format!("cmuxik1 {} {}\n", self.install_id, hex(&self.key))
    }

    /// Parses [`InstallKey::payload`] (surrounding newlines ignored).
    pub fn parse(payload: &str) -> Option<Self> {
        let words: Vec<&str> =
            payload.trim_matches(|c| c == '\n' || c == '\r').split(' ').collect();
        let [tag, id, key] = words.as_slice() else { return None };
        if *tag != "cmuxik1" {
            return None;
        }
        Self::new(id, unhex::<INSTALL_KEY_LEN>(key)?)
    }

    /// The `client-hello` proof over the daemon's nonce (64 hex digits).
    pub fn proof(&self, nonce_hex: &str) -> Option<String> {
        let nonce = unhex::<NONCE_LEN>(nonce_hex)?;
        Some(hello_proof(&self.key, &self.install_id, &nonce))
    }
}
