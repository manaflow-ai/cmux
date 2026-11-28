//! The provider handshake: `hello` in, `hello.ack` out.

use super::*;
use crate::provider::{MAX_HELLO_BYTES, ProviderSecret, read_frame_limited};

/// The `hello` the provider sent, once accepted.
#[derive(Debug, Clone)]
pub struct ProviderInfo {
    pub provider_id: String,
    pub install_id: String,
    pub engines: Vec<String>,
    pub tabs: Vec<TabAnnounce>,
}

/// Reads and checks `hello`, then sends `hello.ack`. Frames before
/// authentication are limited to [`MAX_HELLO_BYTES`].
pub fn accept(
    reader: &mut impl Read,
    writer: &mut impl Write,
    expected: &ProviderSecret,
    agent_bundle: &str,
) -> Result<ProviderInfo, DriverError> {
    let first = read_frame_limited(reader, MAX_HELLO_BYTES)
        .map_err(|e| DriverError::closed(format!("provider hello: {e}")))?
        .ok_or_else(|| DriverError::closed("provider closed before hello"))?;
    let Frame::Hello { version, provider_id, install_id, secret, engines, tabs } = first else {
        return Err(DriverError::new(
            crate::protocol::ErrorCode::Forbidden,
            "provider must start with hello",
        ));
    };
    if !secret.matches(expected) {
        return Err(DriverError::new(
            crate::protocol::ErrorCode::Forbidden,
            "provider secret does not match",
        ));
    }
    if version != crate::provider::PROVIDER_VERSION {
        return Err(DriverError::invalid(format!("provider version {version} is not supported")));
    }
    let sha = format!("{:016x}", fnv1a(agent_bundle.as_bytes()));
    write_frame(
        writer,
        &Frame::HelloAck { agent_bundle: agent_bundle.to_owned(), agent_bundle_sha: sha },
    )
    .map_err(|e| DriverError::closed(format!("provider hello.ack: {e}")))?;
    Ok(ProviderInfo { provider_id, install_id, engines, tabs })
}

/// A cheap content fingerprint so the app can skip reinstalling an unchanged bundle.
fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    })
}
