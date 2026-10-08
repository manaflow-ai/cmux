//! The cmux pane protocol (draft v0): one typed, engine-neutral protocol
//! between surfaces (pages), providers and the control-plane router.
//!
//! - [`envelope`]: the JSON envelope; [`frame`]: length-prefixed framing.
//! - [`transport`], [`ws`]: one transport interface and its adapters;
//!   [`rpc`]: typed calls and subscriptions on top.
//! - [`stream`]: credit-based byte-stream flow control.
//! - [`token`]: Ed25519 capability tokens.
//! - [`op`], [`ir`], [`catalog`]: op declarations and the emitted IR.
//! - [`provider`]: data-plane serving with first-frame auth.
//! - [`router`]: the control plane (its sockets are unix only).
//! - [`git`]: `cmux.git.status` and `cmux.git.diff`.

pub mod catalog;
pub mod envelope;
pub mod error;
pub mod example;
pub mod frame;
pub mod git;
pub mod ir;
mod ir_merge;
pub mod net;
pub mod op;
pub mod provider;
pub mod router;
pub mod rpc;
pub mod scope_class;
pub mod stream;
pub mod token;
pub mod transport;
pub mod vectors;
pub mod ws;
