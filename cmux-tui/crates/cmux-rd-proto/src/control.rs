//! Typed `cmux.rd/1` control messages (JSON on the stream carrier's type-1
//! frames; rd change C7). One definition for every Rust host and viewer;
//! the Swift viewer's copy (`RemoteRdControl`) is pinned by the same golden
//! vectors (tests/vectors/control.json).

use serde::{Deserialize, Serialize};

use crate::SERVICE_DESKTOP;

fn default_service() -> String {
    SERVICE_DESKTOP.to_owned()
}

/// Control messages (JSON) on the stream.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum Control {
    /// Client to host, first message. Phase 1: the claims are trusted because the host
    /// listens only on the private VPC or overlay address; the link `hello` token replaces them.
    Hello {
        user: String,
        install: String,
        class: String,
        interactive: bool,
        udp_port: Option<u16>,
        max_datagram: usize,
        /// The per-launch session token (64 hex characters); see `token.rs`.
        #[serde(default)]
        token: Option<SecretHex>,
        /// The service this session is for (C1): `desktop` unless named.
        #[serde(default = "default_service")]
        service: String,
        /// Optional rd features the viewer supports (C1).
        #[serde(default)]
        caps: Vec<String>,
    },
    Start {
        key: String,
        mode: String,
    },
    Stop,
    Welcome {
        encoder: String,
        width: u32,
        height: u32,
        max_datagram: usize,
        carrier: String,
        /// The service the host routed this session to.
        service: String,
        /// The offered caps the host also supports.
        caps: Vec<String>,
    },
    Started {
        session: u64,
    },
    Refused {
        reason: String,
    },
    Ended {
        reason: String,
    },
    /// A message of the session's service (for example an `rb/1` message of
    /// the remote browser), carried on the rd control stream. rd never
    /// parses `body`; the source's carrier loop hands it to the service
    /// unchanged and refuses a `service` that is not the session's.
    Service {
        service: String,
        body: serde_json::Value,
    },
    /// Bulk flow control (rd change C5): the receiver of transfer
    /// `transfer` allows bytes before `offset`.
    BulkCredit {
        transfer: u64,
        offset: u64,
    },
    /// Opens stream `stream` (rd changes C3, C4, C6); sent only when welcome
    /// lists the `stream.open` cap. The viewer opens upstream media streams
    /// (`up_audio`, `up_video`, also with `up_media`) after the user's consent
    /// for that kind; the host answers `stream_opened` or `stream_refused`
    /// and sends nothing for a stream it did not open.
    StreamOpen {
        stream: u16,
        kind: StreamKind,
        /// `opus` for audio, `h264` for video.
        codec: String,
        /// A tile stream's surface stream (C3).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        of: Option<u16>,
    },
    /// The peer accepted `stream_open` for `stream`.
    StreamOpened {
        stream: u16,
    },
    /// The peer refused `stream_open` for `stream` (`caps`, `kind`, `codec`,
    /// `unsupported`, `in_use`, `too_many`).
    StreamRefused {
        stream: u16,
        reason: String,
    },
    /// Closes an opened stream (the viewer revoked the kind's consent, or the
    /// peer stops it); no answer.
    StreamClose {
        stream: u16,
    },
    Stats {
        kbps: u32,
        frames: u64,
        keyframes: u64,
        cpu_pct: f64,
        encode_ms_p50: f64,
        loss_pct: f64,
    },
}

/// What a stream carries (`stream_open`). A kind this build does not know
/// parses as `Unknown`, so a newer peer's message does not end the session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StreamKind {
    Video,
    Audio,
    Tiles,
    Popup,
    /// Viewer to host: microphone (rd change C4).
    UpAudio,
    /// Viewer to host: camera or screen share (rd change C4).
    UpVideo,
    #[serde(other)]
    Unknown,
}

impl StreamKind {
    /// Media the viewer sends to the host.
    pub fn is_upstream(self) -> bool {
        matches!(self, Self::UpAudio | Self::UpVideo)
    }

    /// The codec a stream of this kind carries, if fixed.
    pub fn codec(self) -> Option<&'static str> {
        match self {
            Self::Audio | Self::UpAudio => Some("opus"),
            Self::Video | Self::Popup | Self::UpVideo => Some("h264"),
            Self::Tiles | Self::Unknown => None,
        }
    }
}

/// A secret in a message; Debug never prints it.
#[derive(Clone, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SecretHex(pub String);

impl std::fmt::Debug for SecretHex {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("<redacted>")
    }
}
