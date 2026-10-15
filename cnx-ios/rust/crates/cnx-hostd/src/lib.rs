//! cnx-hostd: the Mac side of cnx-ios links (cnx-ios/PROTOCOL.md).
//!
//! Registers the Mac with the backend, holds the signaling socket, admits
//! dials from the owner's own phones, answers WebRTC offers and WireGuard
//! handshakes, and serves link channels: `echo`, `daemon` (the cmux-tui
//! session socket through an allowlist), `chief` (the Chief's conversation
//! owner, scoped to the owner's agent conversations), `acpmux`, `file` and
//! `browser` (a streamed Mac browser tab, `browser.rs`).

pub mod acpmux_policy;
pub mod auth;
pub mod browser;
pub mod browser_track;
pub mod chief_answers;
pub mod chief_policy;
pub mod config;
pub mod control;
pub mod host;
pub mod netwatch;
pub mod notify;
pub mod pairing;
pub mod policy;
pub mod services;
