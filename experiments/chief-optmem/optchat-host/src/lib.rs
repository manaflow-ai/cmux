//! The I/O half of OptChat for the placements that run on one machine (the
//! user's MacBook or an always-on Mac mini): the append-only file store, the
//! single-writer lock, the compactor runner and a thread-safe facade over
//! `optchat-core`. Section numbers in comments refer to Victor Taelin's
//! OptChat specification, which the core follows.

mod anthropic;
mod cap;
mod chat;
mod clock;
mod compactor;
mod config;
mod files;
mod lines;
mod lock;
mod model;
mod report;

pub use anthropic::AnthropicModel;
pub use cap::cap_tool_result;
pub use chat::{Cancel, Error, Failure, OptChat, Status};
pub use clock::{Clock, ManualClock, SystemClock};
pub use config::{Config, BASE_URL_ENV, DEFAULT_BASE_URL, DEFAULT_MODEL};
pub use model::{CompactModel, Followup, ModelError, Reply};
pub use report::{Report, Reporter};

pub use optchat_core::{CompactPrompt, CompactRequest, Kind, NodeId, RenderedView, ZoomError};

use std::time::Duration;

/// Wait before a failed compactor node is tried again: fixed, never
/// exponential, because the next turn waits on the compactor (section 4.1).
pub const RETRY: Duration = Duration::from_secs(10);
