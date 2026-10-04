//! cmux Cloud app server (`cmux/cloud`, plans/cmux-next/cloud-app.md L3).
//!
//! The server runs the Cloud catalog ops (`catalog/cloud-catalog.json`) and
//! keeps the machine projection on this machine. It reaches the cmux Cloud
//! API (`/api/vm`, the owner of every machine record) only through a
//! [`api::ControlPlane`]: the host credential relay adds the sign-in, so the
//! server never sees the bearer.

pub mod api;
pub mod ops;

pub use api::{
    CloudError, ControlPlane, HttpCall, HttpReply, Origin, RelayError, Request, SessionStatus,
};
pub use ops::Server;
