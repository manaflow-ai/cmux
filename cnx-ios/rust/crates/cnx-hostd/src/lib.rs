//! cnx-hostd: the Mac side of cnx-ios links (cnx-ios/PROTOCOL.md).
//!
//! Registers the Mac with the backend, holds the signaling socket, admits
//! dials from the owner's own phones, answers WebRTC offers and WireGuard
//! handshakes, and serves link channels: `echo`, `daemon` (the cmux-tui
//! session socket through an allowlist), `acpmux` and `file`.

pub mod auth;
pub mod config;
pub mod host;
pub mod policy;
pub mod services;
