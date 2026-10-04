//! Install identity. Red stub: the API surface only.

use std::path::Path;

use serde::Serialize;

use crate::error::{Error, Result};

pub const INSTALL_KEY_FILE: &str = "install-key.p8";
pub const WG_KEY_FILE: &str = "wg-key";

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct PublicJwk {
    pub kty: &'static str,
    pub crv: &'static str,
    pub x: String,
    pub y: String,
}

pub fn jwk_thumbprint(_x: &str, _y: &str) -> [u8; 32] {
    [0; 32]
}

pub fn begin_proof_message(_env: &str, _thumbprint: &str, _wg: &str, _issued_at: u64) -> String {
    String::new()
}

#[derive(Debug)]
pub struct InstallIdentity;

impl InstallIdentity {
    pub fn from_parts(_pkcs8: &[u8], _wg_secret: [u8; 32]) -> Result<InstallIdentity> {
        Err(Error::internal("not implemented"))
    }

    pub fn load_or_create(_dir: &Path) -> Result<InstallIdentity> {
        Err(Error::internal("not implemented"))
    }

    pub fn public_jwk(&self) -> PublicJwk {
        PublicJwk { kty: "", crv: "", x: String::new(), y: String::new() }
    }

    pub fn thumbprint(&self) -> [u8; 32] {
        [0; 32]
    }

    pub fn thumbprint_b64u(&self) -> String {
        String::new()
    }

    pub fn wg_public_key(&self) -> String {
        String::new()
    }

    pub fn sign_b64u(&self, _message: &[u8]) -> Result<String> {
        Err(Error::internal("not implemented"))
    }
}
