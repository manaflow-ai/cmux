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
    Stats {
        kbps: u32,
        frames: u64,
        keyframes: u64,
        cpu_pct: f64,
        encode_ms_p50: f64,
        loss_pct: f64,
    },
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
