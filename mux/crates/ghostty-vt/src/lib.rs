//! Safe Rust wrapper around libghostty-vt.
//!
//! The terminal engine is the exact same VT parser and state machine used
//! by the Ghostty app (built from the `ghostty/` submodule), so anything
//! rendered from this crate matches what a real Ghostty surface would show.

mod key;
mod render;
mod terminal;

/// Raw bindings, re-exported for key/mode constants.
pub use ghostty_vt_sys as sys;

pub use key::{key_input_from_chord, KeyAction, KeyEncoder, KeyInput, Mods};
pub use render::{Cell, ColorSpec, CursorInfo, CursorShape, Dirty, RenderState};
pub use terminal::{Callbacks, NotifyFn, PtyWriteFn, Rgb, Screen, Scrollbar, Terminal};

pub(crate) fn check(result: ghostty_vt_sys::GhosttyResult) -> std::result::Result<(), Error> {
    match result {
        ghostty_vt_sys::GHOSTTY_SUCCESS => Ok(()),
        ghostty_vt_sys::GHOSTTY_OUT_OF_MEMORY => Err(Error::OutOfMemory),
        ghostty_vt_sys::GHOSTTY_INVALID_VALUE => Err(Error::InvalidValue),
        ghostty_vt_sys::GHOSTTY_OUT_OF_SPACE => Err(Error::OutOfSpace),
        ghostty_vt_sys::GHOSTTY_NO_VALUE => Err(Error::NoValue),
        other => Err(Error::Unknown(other)),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    OutOfMemory,
    InvalidValue,
    OutOfSpace,
    NoValue,
    Unknown(i32),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::OutOfMemory => write!(f, "libghostty-vt: out of memory"),
            Error::InvalidValue => write!(f, "libghostty-vt: invalid value"),
            Error::OutOfSpace => write!(f, "libghostty-vt: buffer too small"),
            Error::NoValue => write!(f, "libghostty-vt: no value"),
            Error::Unknown(code) => write!(f, "libghostty-vt: unknown error {code}"),
        }
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;
