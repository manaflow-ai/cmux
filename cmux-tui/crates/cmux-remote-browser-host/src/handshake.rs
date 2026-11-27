//! The rd handshake of `--serve`: which service and caps the host grants a
//! viewer's hello. Pure, so the grant is tested on every platform.

use cmux_rd_core::service::{Negotiated, ServiceRefusal, caps, negotiate};
use cmux_rd_proto::SERVICE_REMOTE_BROWSER;

/// The rd caps the host supports: rb input arrives as service input events
/// (rd change C2), and the Mac client sends input only when the welcome
/// grants this cap.
pub const HOST_CAPS: &[&str] = &[caps::INPUT_SERVICE];

/// The welcome's service and caps for a hello of `service` that offers `offered`.
pub fn negotiate_hello(service: &str, offered: &[String]) -> Result<Negotiated, ServiceRefusal> {
    negotiate(service, offered, &[SERVICE_REMOTE_BROWSER], HOST_CAPS)
}
