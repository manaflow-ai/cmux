//! Hello service routing and feature negotiation (rd change C1,
//! plans/cmux-next/remote-tab-protocol.md section 7). Every service shares
//! overlay port 4103 and one rd session per peer pair; the host routes a
//! session by the hello `service` and refuses a service it does not serve.
//! A peer uses an optional rd feature only when both sides list it: the
//! viewer offers `caps` in hello, the host answers the intersection in welcome.

/// The remote desktop service (the default when a hello names none).
pub const SERVICE_DESKTOP: &str = "desktop";
/// The remote browser tab service (`cmux.rb/1`).
pub const SERVICE_REMOTE_BROWSER: &str = "rb/1";

/// Most caps in one hello.
pub const MAX_CAPS: usize = 32;
/// Longest cap name.
pub const MAX_CAP_LEN: usize = 64;

/// Names of optional rd features (remote-desktop coordination note, C1-C8).
pub mod caps {
    /// The service input event tag 0x80 (C2).
    pub const INPUT_SERVICE: &str = "input.service";
    /// Lossless tile streams (C3).
    pub const TILE: &str = "tile";
    /// Viewer-to-host media (C4).
    pub const UP_MEDIA: &str = "up_media";
    /// Bulk stream frames (C5).
    pub const BULK: &str = "bulk";
    /// Streams other than 0, opened with `stream.open` (C6).
    pub const STREAM_OPEN: &str = "stream.open";
    /// Session clock offset (C8).
    pub const CLOCK: &str = "clock";
    /// Every named cap.
    pub const ALL: [&str; 6] = [INPUT_SERVICE, TILE, UP_MEDIA, BULK, STREAM_OPEN, CLOCK];
}

/// Why a hello is refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceRefusal {
    /// The host does not serve this service (reason `"service"`).
    Service,
    /// Too many caps or a cap name too long (reason `"caps"`).
    Malformed,
}

impl ServiceRefusal {
    /// The `refused.reason` on the wire.
    pub fn reason(self) -> &'static str {
        match self {
            Self::Service => "service",
            Self::Malformed => "caps",
        }
    }
}

/// What the host answers in welcome.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Negotiated {
    pub service: String,
    /// The offered caps the host also supports, in the host's order.
    pub caps: Vec<String>,
}

/// Routes a hello: `services` the host serves, `host_caps` the features it
/// supports. Unknown offered caps are ignored (a newer viewer).
pub fn negotiate(
    service: &str,
    offered: &[String],
    services: &[&str],
    host_caps: &[&str],
) -> Result<Negotiated, ServiceRefusal> {
    if offered.len() > MAX_CAPS || offered.iter().any(|c| c.len() > MAX_CAP_LEN) {
        return Err(ServiceRefusal::Malformed);
    }
    if !services.contains(&service) {
        return Err(ServiceRefusal::Service);
    }
    let caps = host_caps
        .iter()
        .filter(|cap| offered.iter().any(|o| o == *cap))
        .map(|cap| (*cap).to_owned())
        .collect();
    Ok(Negotiated { service: service.to_owned(), caps })
}
