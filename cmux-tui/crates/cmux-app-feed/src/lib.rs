//! The cmux macOS app's Feed rules, moved out of `CmuxNextApp/Feed` (swift-out step A).
//!
//! Pure: the app reads acpmux, the Feed owner and the phone's presence keys, hands the facts here
//! over the app FFI (cmux-app-ffi `src/app_feed.rs`, JSON ops in [`ops`]) and does what comes back.
//!
//! - [`text`]: what a person sees of agent text (secrets scrubbed, bidi and zero-width controls
//!   shown, cut by grapheme like Swift's `String.count`).
//! - [`json`]: the sorted-key JSON `JSONSerialization` writes, and its SHA-256.
//! - [`prompt`]: an acpmux permission prompt (`AcpmuxPermissionPrompt`): its digest, shown command,
//!   input summary, options and whether it is a question.
//! - [`proof`]: the phone's presence-key approve proof (`FeedApproveProofCheck`,
//!   `FeedApproveShownText`, `FeedApproveProofMessage`) and the install token's claims.
//! - [`bridge`]: what the permission bridge posts and which answer it sends back
//!   (`AcpmuxPermissionFeedBridge`).
//! - [`desk`]: the agent dialogs the control socket lists and answers (`AgentDialogDesk`).
//! - [`control`]: the Feed's control methods' bodies and errors (`FeedControl`, `FeedService`).
//! - [`github`]: a GitHub card's actions and where an item opens (`FeedGitHubActions`).
//! - [`needs_you`]: the phone's Needs You list (`FeedNeedsYouPhone`).
//! - [`update`]: the update card and its posting step (`UpdateFeedPosting`).

pub mod bridge;
pub mod control;
pub mod desk;
pub mod github;
pub mod json;
pub mod needs_you;
pub mod ops;
pub mod prompt;
pub mod proof;
pub mod text;
pub mod update;

pub use ops::{AppFeed, OpError};
