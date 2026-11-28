//! Where a cmux address points, for the web client (cmuxterm-hq docs/rfd/0083-cmux-web-client.md,
//! Deeplinks) and every reader of an agent session link.
//!
//! - [`agent_link`]: the agent session link, `https://cmux.com/deeplink/agent?harness=&session=
//!   &host=&name=&message=&machine=` and the native `cmux://agent/<harness>/<session>?...`
//!   (`schemas/deeplinks/agent-link.json`). `acpmux resolve` reads links through it.
//! - [`route`]: the web client's own routes, which mirror the app's grammar:
//!   `/m/<machine>/agent/<harness>/<session>`, `/m/<machine>/ws/<workspace>`, the
//!   `/deeplink/agent?...` page on the same site, and a pasted `cmux://` or cmux.com link
//!   (`schemas/deeplinks/web-routes.json`, whose vectors the web host's reader runs too).
//! - [`resolve`]: one route against the chats a machine lists: exactly one chat, or a typed
//!   refusal. Never another chat in its place.
//!
//! A link is an address and never runs anything: of its query only `message` (one message to
//! bring into view) is read; every other parameter is ignored by name. Nothing here does I/O.

pub mod agent_link;
pub mod resolve;
pub mod route;

pub use resolve::{Candidate, ResolveError, Resolved, WorkspaceCandidate, resolve};
pub use route::{Machine, Route, RouteError, parse};
