//! Read a completed enrollment for the host's own transport and API client.
//! This never creates state, rotates a key, approves an account or grants an op.

use std::path::Path;

use cmux_server_core::pairing::enrollment::Paired;
use zeroize::Zeroizing;

use crate::error::{Error, Result};

/// An OS-account-owned enrollment. Deliberately neither serializable nor Debug:
/// only public metadata and the transport key accessors cross crate boundaries.
pub struct EnrolledIdentity {
    api: String,
    paired: Paired,
    wireguard_key: Zeroizing<[u8; 32]>,
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
        record.signing_key()?;
        let native = super::native::registration_for_link(&record)?;
        let wireguard_key = record.wg_private()?;
        Ok(Self { api: record.api, paired, wireguard_key, native })
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
