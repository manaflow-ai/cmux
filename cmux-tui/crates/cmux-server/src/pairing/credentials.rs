//! Read a completed enrollment for the host's own transport and API client.
//! This never creates state, rotates a key, approves an account or grants an op.

use std::path::Path;

use cmux_server_core::install_key::{InstallKey, SystemRandom};
use cmux_server_core::pairing::enrollment::Paired;
use zeroize::Zeroizing;

use crate::error::{Error, Result};

/// An OS-account-owned enrollment. Deliberately neither serializable nor Debug:
/// only public metadata and the transport key accessors cross crate boundaries.
pub struct EnrolledIdentity {
    api: String,
    paired: Paired,
    wireguard_key: Zeroizing<[u8; 32]>,
    signing_key: InstallKey,
    native: Option<cmux_server_core::pairing::native::Registration>,
}

impl EnrolledIdentity {
    /// A completed private record readable by this service's actual OS account.
    /// Permission checks, protected-key opening and key/JWK matching are shared
    /// with enrollment; no state is created when the record is absent or pending.
    pub fn load(path: &Path) -> Result<Self> {
        let record = super::identity::read(path)?
            .ok_or_else(|| Error::rejected("server.pair.not_enrolled"))?;
        let paired = record
            .paired
            .as_ref()
            .ok_or_else(|| Error::rejected("server.pair.not_enrolled"))?
            .clone();
        // Verify that the stored public identity still matches its private key.
        let signing_key = record.signing_key()?;
        let native = super::native::registration_for_link(&record)?;
        let wireguard_key = record.wg_private()?;
        Ok(Self { api: record.api, paired, wireguard_key, signing_key, native })
    }

    /// Load the current server enrollment using the same user/system layout as the CLI.
    pub fn load_current() -> Result<Self> {
        let layout =
            crate::host::layout_for(crate::host::resolve_mode(false), &crate::host::layout_env())?;
        Self::load(&crate::fsx::local(&layout.state).join("pairing/identity.json"))
    }

    /// Sign a challenge with this enrolled install key; private material never leaves this value.
    pub fn sign(&self, message: &[u8]) -> Result<String> {
        self.signing_key
            .sign(message, &SystemRandom::new())
            .map_err(|_| Error::verification("server.pair.sign_failed"))
    }

    pub fn api_origin(&self) -> &str {
        &self.api
    }

    pub fn paired(&self) -> &Paired {
        &self.paired
    }
    pub fn native_network(&self) -> Option<&cmux_server_core::pairing::native::Registration> {
        self.native.as_ref()
    }

    /// The key used in `pair/begin`, for an in-process WireGuard transport.
    /// It must not be copied to another persistent key file or public response.
    pub fn wireguard_key(&self) -> Zeroizing<[u8; 32]> {
        self.wireguard_key.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_server_core::install_key::InstallKey;
    use cmux_server_core::pairing::enrollment::Paired;

    #[test]
    fn sign_uses_the_registered_es256_public_key() {
        let key = InstallKey::generate(&SystemRandom::new()).unwrap();
        let public = key.public_jwk();
        let identity = EnrolledIdentity {
            api: "https://cloud-api.cmux.dev".into(),
            paired: Paired {
                host: "host_abcdefghijklmnopqrst".into(),
                team: "team_abcdefghijklmnopqrst".into(),
                user: "user_abcdefghijklmnopqrst".into(),
                install: "inst_abcdefghijklmnopqrst".into(),
            },
            wireguard_key: Zeroizing::new([0; 32]),
            signing_key: key,
            native: None,
        };
        let message = b"cmux-turn-attestation-test";
        let signature = identity.sign(message).unwrap();
        assert!(cmux_server_core::install_key::verify(&public, message, &signature));
    }

    #[test]
    fn missing_enrollment_is_refused_without_creating_state() {
        let dir = tempfile::tempdir().unwrap();
        let err = match EnrolledIdentity::load(&dir.path().join("pairing/identity.json")) {
            Ok(_) => panic!("missing enrollment unexpectedly loaded"),
            Err(error) => error,
        };
        assert_eq!(err.message, "server.pair.not_enrolled");
        assert!(!dir.path().join("pairing").exists());
    }
}
