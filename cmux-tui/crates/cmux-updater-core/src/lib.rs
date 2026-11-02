//! The pure update rules of the cmux NEXT updater (values in, values out):
//! Sparkle's version order, the appcast parse and what it offers this Mac, the
//! way back from a faster ring, the channels view's tracks, the rollback
//! decision, the pulled list, the release-line rules of the running build and
//! the judgment of the last install.
//!
//! Sparkle (its driver, signature checks and installs) and the UI stay in the
//! Swift app, which will call these rules over the app FFI ([`wire`]; the
//! link, the re-pin and the Swift calls land together in one move PR).

pub mod appcast;
pub mod channel_track;
pub mod civil;
pub mod install_check;
pub mod pulled;
pub mod ring_return;
pub mod rollback;
pub mod select;
pub mod track;
pub mod version;
pub mod wire;
