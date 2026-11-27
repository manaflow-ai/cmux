//! The WebRTC screen stream's rules (Packages/Shared/CmuxVNCWebRTC), in Rust so
//! the Swift there keeps only the platform work (ScreenCaptureKit, VideoToolbox,
//! libwebrtc, the cursor reader, the Secure Enclave signer). Pure: no I/O, time
//! is an argument. Both apps reach it through [`json`]'s `screen_*` ops: the
//! Mac over cmux-layout-reducer-ffi's C ABI, iOS over cmux-mobile-ffi's
//! `screen_json`.
//!
//! - [`ticket`]: the device hub session ticket, the SDP fingerprint and its
//!   `fpSig`, and the signaling frames (TicketSignaling.swift).
//! - [`focus`]: follow mode's focus signals: geometry, the event JSON, damage
//!   regions and the producer's per-tick plan (FocusSignals.swift).
//! - [`demand`]: the capture size a viewer's demand asks for (ViewerDemand.swift).
//! - [`cursor_shape`]: the host's cursor shape id, drawability, the viewer's
//!   `caps` and which shape messages still go (ScreenCursorShape.swift).
//! - [`quality`]: a quality preset's frame rate and sender encoding
//!   (ScreenQuality in ScreenStream.swift).
//! - [`json`]: the `screen_*` op dispatcher both app libraries share.

pub mod cursor_shape;
pub mod demand;
pub mod focus;
pub mod geometry;
pub mod json;
pub mod quality;
pub mod ticket;
