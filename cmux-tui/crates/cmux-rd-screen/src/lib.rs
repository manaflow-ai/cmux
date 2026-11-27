//! The WebRTC screen stream's rules (Packages/Shared/CmuxVNCWebRTC), in Rust so
//! the Swift there keeps only the platform work (ScreenCaptureKit, VideoToolbox,
//! libwebrtc, the cursor reader, the Secure Enclave signer). Pure: no I/O, time
//! is an argument. The Mac app reaches it as `screen_*` JSON ops
//! (cmux-layout-reducer-ffi `screen.rs`).
//!
//! - [`ticket`]: the device hub session ticket, the SDP fingerprint and its
//!   `fpSig`, and the signaling frames (TicketSignaling.swift).
//! - [`focus`]: follow mode's focus signals: geometry, the event JSON, damage
//!   regions and the producer's per-tick plan (FocusSignals.swift).
//! - [`demand`]: the capture size a viewer's demand asks for (ViewerDemand.swift).
//! - [`cursor_shape`]: the host's cursor shape id, drawability, the viewer's
//!   `caps` and which shape messages still go (ScreenCursorShape.swift).

pub mod cursor_shape;
pub mod demand;
pub mod focus;
pub mod geometry;
pub mod ticket;
