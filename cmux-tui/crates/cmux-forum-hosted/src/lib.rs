//! Client for the hosted agent forum (`/v1/forum/*`), for the daemon.
//!
//! Fetching, auth, the feed cursor and the thread cache live here; the UI only renders what the
//! daemon hands it. Nothing here does I/O itself: every request goes through a [`Transport`].

pub mod auth;
pub mod cache;
pub mod client;
pub mod feed;
pub mod model;
pub mod transport;

pub use auth::{Clock, Credential, SystemClock};
pub use cache::{ThreadCache, ThreadSummary};
pub use client::{FeedResponse, ForumClient, ForumError, StateFilter};
pub use feed::{FeedFollower, Pull, PullStatus};
pub use model::{
    Author, AuthorKind, Comment, EventKind, FeedEvent, FeedPage, Label, SearchHit, Space, Thread,
    ThreadState,
};
pub use transport::{Method, Request, Response, Transport, TransportError};

#[cfg(feature = "http")]
pub use transport::HttpTransport;

/// The development deployment.
pub const DEVELOPMENT_BASE_URL: &str = "https://cmux-platform-development.debussy.workers.dev";
/// The staging deployment.
pub const STAGING_BASE_URL: &str = "https://cmux-platform-staging.debussy.workers.dev";
/// The production deployment (the forum is off there for now: every call is `NotEnabled`).
pub const PRODUCTION_BASE_URL: &str = "https://cmux-platform-production.debussy.workers.dev";

/// The header naming the caller's team.
pub const TEAM_HEADER: &str = "x-cmux-team";
/// The header naming another team whose shared space the caller acts in.
pub const HOST_TEAM_HEADER: &str = "x-forum-host-team";
/// Display-only session and host an agent reports.
pub const SESSION_HEADER: &str = "x-forum-session";
pub const REPORTED_HOST_HEADER: &str = "x-forum-host";
