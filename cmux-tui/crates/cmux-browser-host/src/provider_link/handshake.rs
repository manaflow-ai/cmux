//! The provider handshake: `hello` in, `hello.ack` out; or the app's
//! Chromium Host's `relay.hello`, answered by the relay.

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

/// An accepted first frame on the provider socket.
#[derive(Debug)]
pub enum Opening {
    /// The app: `hello` with the launch's secret. It gets its `hello.ack`
    /// ([`send_hello_ack`]) once the host serves it.
    Provider(ProviderInfo),
    /// The app's Chromium Host: `relay.hello` with the relay credential, and
    /// the link id the app gave it. The connected provider's relay answers it
    /// ([`ProviderDriver::attach_relay_link`]).
    RelayLink { link: String },
}

fn forbidden(message: &str) -> DriverError {
    DriverError::new(crate::protocol::ErrorCode::Forbidden, message)
}

/// Reads and checks `hello`, then sends `hello.ack`. Frames before
/// authentication are limited to [`MAX_HELLO_BYTES`].
pub fn accept(
    reader: &mut impl Read,
    writer: &mut impl Write,
    expected: &ProviderSecret,
    agent_bundle: &str,
) -> Result<ProviderInfo, DriverError> {
    let Opening::Provider(info) = read_opening(reader, expected)? else {
        return Err(forbidden("provider must start with hello"));
    };
    send_hello_ack(writer, agent_bundle)?;
    Ok(info)
}

/// Reads and checks the first frame: `hello` with the secret, or
/// `relay.hello` with the relay credential derived from it
/// ([`ProviderSecret::relay_credential`]). The secret never opens a relay
/// link and the credential never opens a provider. Sends nothing.
pub fn read_opening(
    reader: &mut impl Read,
    expected: &ProviderSecret,
) -> Result<Opening, DriverError> {
    let first = read_frame_limited(reader, MAX_HELLO_BYTES)
        .map_err(|e| DriverError::closed(format!("provider hello: {e}")))?
        .ok_or_else(|| DriverError::closed("provider closed before hello"))?;
    match first {
        Frame::Hello { version, provider_id, install_id, secret, engines, tabs } => {
            if !secret.matches(expected) {
                return Err(forbidden("provider secret does not match"));
            }
            if version != crate::provider::PROVIDER_VERSION {
                return Err(DriverError::invalid(format!(
                    "provider version {version} is not supported"
                )));
            }
            Ok(Opening::Provider(ProviderInfo { provider_id, install_id, engines, tabs }))
        }
        Frame::RelayHello { version, link, credential } => {
            if !credential.matches(&expected.relay_credential()) {
                return Err(forbidden("relay credential does not match"));
            }
            if version != crate::provider::RELAY_VERSION {
                return Err(DriverError::invalid(format!(
                    "relay version {version} is not supported"
                )));
            }
            Ok(Opening::RelayLink { link })
        }
        _ => Err(forbidden("provider must start with hello")),
    }
}

/// Answers an accepted `hello` with the page agent bundle.
pub fn send_hello_ack(writer: &mut impl Write, agent_bundle: &str) -> Result<(), DriverError> {
    let sha = format!("{:016x}", fnv1a(agent_bundle.as_bytes()));
    write_frame(
        writer,
        &Frame::HelloAck { agent_bundle: agent_bundle.to_owned(), agent_bundle_sha: sha },
    )
    .map_err(|e| DriverError::closed(format!("provider hello.ack: {e}")))
}

/// A cheap content fingerprint so the app can skip reinstalling an unchanged bundle.
fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    })
}
