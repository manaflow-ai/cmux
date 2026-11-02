//! An RFB (VNC) client for cmux: shows and drives a remote screen.
//!
//! It targets the servers a cmux Cloud VM or a person's machine runs:
//! macOS Screen Sharing (RFB 3.889, Apple DH or VNC password), Windows
//! (TightVNC, UltraVNC, RealVNC with VNC password) and Linux (TigerVNC
//! `Xvnc`, x11vnc; none, VNC password or VeNCrypt without TLS).
//!
//! - [`Session::start`] runs the handshake over a [`Transport`] (TCP or a
//!   proxy command), asks for RGBX pixels and the encodings in
//!   [`decode::encoding::advertised`], and requests the first frame.
//! - [`Session::next_event`] (one reader thread) decodes server messages
//!   into the RGBA [`Framebuffer`] and reports the damage.
//! - [`Input`] (any thread) sends keys ([`keysym`]), pointer, clipboard,
//!   SetDesktopSize resizes and closes the session.
//! - [`Backoff`] says when to reconnect.
//!
//! Every server-supplied size and length is bounded; a hostile server ends
//! the session with [`VncError::Protocol`], never a panic or an unbounded
//! allocation.

pub mod auth;
pub mod decode;
pub mod endpoint;
mod error;
pub mod framebuffer;
pub mod handshake;
pub mod keysym;
pub mod message;
pub mod pixel;
pub mod reconnect;
mod session;
pub mod transport;
mod wire;

pub use auth::Credentials;
pub use decode::Cursor;
pub use endpoint::Endpoint;
pub use error::{Result, VncError};
pub use framebuffer::{Framebuffer, Rect};
pub use reconnect::Backoff;
pub use session::{Event, Input, Session, SessionOptions, Update};
pub use transport::{Closer, ProxyStderr, Transport};
