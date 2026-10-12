//! Provider-managed workspace authority: the redacted, zeroized credential a
//! machine provider installs, its public status, rotation errors, and the
//! constant-time comparison used to authorize provider lifecycle requests.

use std::fmt;

use zeroize::Zeroize;

const PROVIDER_WORKSPACE_AUTHORITY_MIN_BYTES: usize = 32;
const PROVIDER_WORKSPACE_AUTHORITY_MAX_BYTES: usize = 512;

/// An opaque per-mux credential provisioned by the external machine
/// provider. Debug output is deliberately redacted.
#[derive(PartialEq, Eq)]
pub struct ProviderWorkspaceAuthority(Box<str>);

impl ProviderWorkspaceAuthority {
    pub fn new(value: impl Into<String>) -> anyhow::Result<Self> {
        let mut value = value.into();
        if !(PROVIDER_WORKSPACE_AUTHORITY_MIN_BYTES..=PROVIDER_WORKSPACE_AUTHORITY_MAX_BYTES)
            .contains(&value.len())
            || value.bytes().any(|byte| byte.is_ascii_control())
        {
            value.zeroize();
            anyhow::bail!(
                "provider workspace authority must be 32 to 512 bytes without control characters"
            );
        }
        Ok(Self(value.into_boxed_str()))
    }

    pub(crate) fn expose(&self) -> &[u8] {
        self.0.as_bytes()
    }
}

/// Public, non-secret state exposed by the provider management socket.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ProviderWorkspaceAuthorityStatus {
    pub managed: bool,
    pub mux_generation: Option<String>,
    pub authority_generation: u64,
    pub authority_installed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderWorkspaceAuthorityUpdateError {
    Unmanaged,
    MuxGenerationMismatch,
    ExpectedGenerationMismatch,
    GenerationConflict,
    InvalidGeneration,
}

impl fmt::Display for ProviderWorkspaceAuthorityUpdateError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Unmanaged => "workspace lifecycle is not provider-managed",
            Self::MuxGenerationMismatch => "mux generation does not match the running process",
            Self::ExpectedGenerationMismatch => "authority generation changed concurrently",
            Self::GenerationConflict => {
                "authority generation already contains a different credential"
            }
            Self::InvalidGeneration => "authority generation must advance by exactly one",
        })
    }
}

impl std::error::Error for ProviderWorkspaceAuthorityUpdateError {}

#[derive(Default)]
pub(crate) struct ProviderWorkspaceState {
    pub(super) managed: bool,
    pub(super) mux_generation: Option<Box<str>>,
    pub(super) authority_generation: u64,
    pub(super) authority: Option<ProviderWorkspaceAuthority>,
}

impl ProviderWorkspaceState {
    pub(super) fn status(&self) -> ProviderWorkspaceAuthorityStatus {
        ProviderWorkspaceAuthorityStatus {
            managed: self.managed,
            mux_generation: self.mux_generation.as_deref().map(str::to_owned),
            authority_generation: self.authority_generation,
            authority_installed: self.authority.is_some(),
        }
    }
}

impl fmt::Debug for ProviderWorkspaceAuthority {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ProviderWorkspaceAuthority([redacted])")
    }
}

impl Drop for ProviderWorkspaceAuthority {
    fn drop(&mut self) {
        // NUL bytes remain valid UTF-8, so the boxed string can be cleared in
        // place before its allocation is released.
        self.0.zeroize();
    }
}

pub(super) fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    let mut difference = left.len() ^ right.len();
    let length = left.len().max(right.len());
    for index in 0..length {
        difference |= usize::from(
            left.get(index).copied().unwrap_or(0) ^ right.get(index).copied().unwrap_or(0),
        );
    }
    difference == 0
}

pub(super) fn validate_mux_generation(value: &str) -> anyhow::Result<()> {
    if value.len() != 32
        || !value.bytes().all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        anyhow::bail!("mux generation must be 32 lowercase hexadecimal characters");
    }
    Ok(())
}
