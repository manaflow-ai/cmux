//! cmux Cloud app server (`cmux/cloud`, plans/cmux-next/cloud-app.md L3).
//!
//! The server runs the Cloud catalog ops (`catalog/cloud-catalog.json`) and
//! keeps the machine projection on this machine. It reaches the cmux Cloud
//! API (`/api/vm`, the owner of every machine record) only through a
//! [`api::ControlPlane`]: the host credential relay adds the sign-in, so the
//! server never sees the bearer.

pub mod api;
pub mod app_env;
pub mod clock;
pub mod connector;
pub mod fs;
pub mod link;
pub mod ops;
pub mod ports;
pub mod proxy;
pub mod rescue;

pub use api::{
    CloudError, ControlPlane, HttpCall, HttpReply, Origin, RelayError, Request, SessionStatus,
    WireCall, WireError, WireReply, WireResult,
};
pub use ops::Server;
