//! What a cmux host lets the agent pane page send to acpmux, and how the host
//! reaches acpmux (design B, plans/cmux-next/localapp-isolation-spike.md): the
//! host owns the WebSocket, puts the LocalApp token in the first frame, checks
//! every page frame and relays it; the page never sees an endpoint or a token.
//!
//! The rules are cmux-next's Swift host's (CmuxNextAgentPane), in one place a
//! Rust host (the GPUI app) and later the Swift app read: the lists are data
//! (`policy.json`), the checks are functions with no host state. The shared
//! case files in `tests/cases` run against this crate (`tests/parity.rs`) and
//! against the Swift functions (CmuxNextAgentPaneTests
//! `AgentPanePolicyParityTests`); `tests/typescript.rs` checks the lists
//! against what the page sends (webviews/src/agent-session/acpmux).
//!
//! Not here (host state): the path roots (`AcpmuxPathPolicy`), the pane's
//! session scope and handoff records (`AcpmuxPaneSessions`), gesture
//! bookkeeping, the mode confirmation sheet, request id mapping.
//!
//! Review: the protocol/origin lead (ad349) and the acpmux owner. A change to
//! `policy.json` needs that review.

pub mod connection;
pub mod data;
pub mod environment;
pub mod error;
pub mod frame;
pub mod gesture;
pub mod json_keys;
pub mod params;
pub mod reply;

pub use data::{GestureRule, Policy, ReplyShape, policy};
pub use error::Refusal;
pub use frame::{Decision, Refused, decide, decide_frame, refusal_frame};
