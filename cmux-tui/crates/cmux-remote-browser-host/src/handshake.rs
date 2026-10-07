//! The rd handshake of `--serve`: which service and caps the host grants a
//! viewer's hello. Pure, so the grant is tested on every platform.

use cmux_rd_core::service::{Negotiated, ServiceRefusal, negotiate};
use cmux_rd_proto::SERVICE_REMOTE_BROWSER;

/// The rd caps the host supports.
pub const HOST_CAPS: &[&str] = &[];

/// The welcome's service and caps for a hello of `service` that offers `offered`.
pub fn negotiate_hello(service: &str, offered: &[String]) -> Result<Negotiated, ServiceRefusal> {
    negotiate(service, offered, &[SERVICE_REMOTE_BROWSER], HOST_CAPS)
}
