//! Auto mode's shared core: a chat keeps running in the Cloud when the laptop goes away, and
//! comes home when it returns. The contract is `plans/cmux-next/auto-mode/DESIGN.md`.
//!
//! - [`wire`]: every request and answer of the Cloud API, as serde types.
//! - [`consts`]: the lease, chunk and append numbers.
//! - [`cloud`]: the Cloud store as a trait ([`cloud::AutoCloud`]) and its error.
//!
//! No socket, clock or runtime is used here. The caller passes `now` in milliseconds and runs
//! the effects.

pub mod cloud;
pub mod consts;
pub mod holder;
pub mod wire;

pub use cloud::{AutoCloud, AutoCloudError, CloudResult};
