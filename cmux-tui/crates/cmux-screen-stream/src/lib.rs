//! The screen stream's protocol and policy, without WebRTC.
//!
//! The macOS and iPhone apps stream a Mac's screen over WebRTC (CmuxVNCWebRTC, CmuxScreenKit).
//! Capture, encoding and the peer connection stay in Swift; this crate owns the rules around
//! them, so both ends share one implementation:
//!
//! - [`wire`]: the data channel's messages (`ScreenInput`, `ScreenHostMessage`), their decoding
//!   (a fractional scroll delta rounds), capability lists and what reaches the backend.
//! - [`quality`]: the stream quality's frame rate and encoder settings, the capture cap, and the
//!   pointer's fraction of a display and its pixel.
//! - [`demand`]: the viewer's demanded picture size, with its holds (`ViewerDemand`).
//! - [`paste`]: image paste chunks, and the host's assembler.
//! - [`cursor`]: the cursor shapes a host has sent, and their ordered delivery.
//! - [`source`]: the source state reports (live, locked, asleep).
//! - [`session`]: the reconnect bounds and the RFB encoding names.
//! - [`ops`] and [`ffi`]: the C ABI (`include/cmux_screen_stream.h`, Swift module
//!   `CCmuxScreenStreamFFI`), linked into the app through cmux-app-ffi.

pub mod cursor;
pub mod demand;
pub mod ffi;
pub mod ops;
pub mod paste;
pub mod quality;
pub mod session;
pub mod source;
pub mod wire;
