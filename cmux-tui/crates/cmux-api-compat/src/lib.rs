//! Forwards and backwards JSON API compatibility between any two revisions
//! of a protocol.
//!
//! - Every API change is a rule on an RFC 6901 JSON pointer ([`Change`]),
//!   recorded per revision and per message kind in a [`Schema`].
//! - For each `(message kind, from, to)` that is actually used, the rules in
//!   between are compiled lazily into one trie keyed by path tokens
//!   ([`Compat::program`]); a 10,000-revision chain still yields one pass.
//! - A forward-only streaming editor applies the trie. Values whose key
//!   matches no trie subtree are copied byte for byte without parsing.
//! - Equal chains are interned: a broadcast to many peers is translated once
//!   per distinct chain, not once per peer ([`Compat::broadcast`]).
//! - Both directions use the same rules: upgrades apply them, downgrades
//!   apply their exact inverses ([`handshake::negotiate`] picks the side
//!   that translates).
//!
//! ```
//! use cmux_api_compat::{Change, Compat, MessageChange, Schema};
//!
//! let mut schema = Schema::new("demo", 1);
//! schema.push("name is now title", vec![MessageChange {
//!     message: "event:workspace".into(),
//!     change: Change::Rename { path: "/workspace/name".into(), to: "title".into() },
//! }]);
//! let compat = Compat::new(schema).unwrap();
//! let old = br#"{"workspace":{"name":"a","id":1}}"#;
//! let new = compat.translate("event:workspace", 1, 2, old).unwrap();
//! assert_eq!(&*new, br#"{"workspace":{"title":"a","id":1}}"#);
//! let back = compat.translate("event:workspace", 2, 1, &new).unwrap();
//! assert_eq!(&*back, old);
//! ```

mod change;
mod compat;
pub mod coverage;
pub mod handshake;
pub mod pointer;
mod schema;
mod stream;
mod trie;

pub use change::{Change, Conversion, Direction};
pub use compat::{Broadcast, Compat, Program};
pub use schema::{MessageChange, Revision, Schema};

/// Everything that can go wrong.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CompatError {
    /// A pointer is not valid RFC 6901.
    BadPointer(String),
    /// A change cannot be compiled (for example a move into itself).
    InvalidChange(String),
    /// The compat file is malformed or out of order.
    InvalidSchema(String),
    /// A peer's revision is outside what this build knows.
    UnsupportedRevision { rev: u32, base: u32, current: u32 },
    /// The message is not valid JSON at this byte offset.
    Malformed(usize),
}

impl std::fmt::Display for CompatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadPointer(p) => write!(f, "bad JSON pointer `{p}`"),
            Self::InvalidChange(why) => write!(f, "invalid change: {why}"),
            Self::InvalidSchema(why) => write!(f, "invalid compat schema: {why}"),
            Self::UnsupportedRevision { rev, base, current } => {
                write!(f, "API revision {rev} is outside the supported range {base}..={current}")
            }
            Self::Malformed(at) => write!(f, "malformed JSON at byte {at}"),
        }
    }
}

impl std::error::Error for CompatError {}
