//! What a cmux host lets the agent pane page send to acpmux, and how the host
//! reaches acpmux (design B, plans/cmux-next/localapp-isolation-spike.md): the
//! host owns the WebSocket, puts the LocalApp token in the first frame, checks
//! every page frame and relays it; the page never sees an endpoint or a token.
//!
//! The rules are cmux-next's Swift host's (CmuxNextAgentPane), in one place a
//! Rust host (the GPUI app) and later the Swift app read: the lists are data
//! (`policy.json`), the checks are functions with no host state. A host runs
//! one function on every page frame, [`check::check_frame`] (Swift
//! `AgentPaneTransport.checkOne`, in its order), and relays only the object
//! it returns ([`check::encode`]). The shared case files in `tests/cases` run
//! against this crate (`tests/parity.rs`) and against the Swift functions
//! (CmuxNextAgentPaneTests `AgentPanePolicyParityTests`; `check.json` against
//! `checkOne`); `tests/typescript.rs` checks the lists against what the page
//! sends (webviews/src/agent-session/acpmux).
//!
//! Host-owned (state or disk; the Rust host that adopts this crate implements
//! them, owner: the GPUI lane, cmux2-gpui `apps/cmux2` agent pane host, with
//! the acpmux owner's review; Swift counterparts in CmuxNextAgentPane):
//! - the folder check against the pane's roots, which reads the disk
//!   (`AcpmuxPathPolicy.check`, `canonical`); this crate only says which
//!   frames wait for it ([`check::needs_path_check`], `policy.json` `path_keys`);
//! - feeding the pane's scope: [`sessions::PaneSessions`] ports
//!   `AcpmuxPaneSessions` (`add`, `sent`, `observe`, `holdsSource`), the host
//!   calls it with what the pane sent and the daemon answered, and decides the
//!   click's scope credit; the session folders (`observeFolder`) stay here;
//! - feeding [`gesture::PermissionOptions`] every daemon frame (`observe`):
//!   it tells a deny from an allow and a question from a tool permission (only
//!   a question's `_acpmux/permission_respond` may carry `answers`; the shared
//!   bounds are in `policy.json` `question_answers`, with Swift's Codex wrapper
//!   exception recorded as `swift_gap` in the parity fixture);
//! - gesture tickets, records and the mode confirmation sheet
//!   (`AgentPaneUserGestures`, `AgentPaneModeConfirmation`), and the folder
//!   harness sheet (`confirmHarnessEnable`: the user's Enable, the confirmed
//!   `sha256` the host adds; `Facts::harness_enable` says when);
//! - request ids: the relay id map, the in-flight refusal and the reply id
//!   rewrite (`AcpmuxRequestIds`); this crate gives the reply filter
//!   ([`reply`]) and the encoding with a relay id ([`check::encode`]);
//! - the socket: closing with 1008 on a first frame that is not `initialize`
//!   ([`check::closes_connection`] says when), the outbound limits.
//!
//! Review: the protocol/origin lead (ad349) and the acpmux owner. A change to
//! `policy.json` needs that review.

pub mod answers;
pub mod check;
pub mod connection;
pub mod data;
pub mod environment;
pub mod error;
pub mod frame;
pub mod gesture;
pub mod json_keys;
pub mod params;
pub mod reply;
pub mod sessions;

pub use check::{Checked, Facts, FrameState, PaneScope, check_frame};
pub use data::{GestureRule, Policy, ReplyShape, policy};
pub use error::Refusal;
pub use frame::{Decision, Refused, allowlist_check, allowlist_decision, refusal_frame};
pub use sessions::PaneSessions;
