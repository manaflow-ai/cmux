//! The macOS app's one mirror of acpmux's chat index (`_acpmux/chats_watch`).
//!
//! acpmux (cmux-chat-index) owns the index. The app kept a Swift copy, decoded every
//! multi-megabyte page through `JSONSerialization`, and held it twice (the sidebar's chat
//! history kept the previous copy-on-write value), so each change on the main thread copied
//! all 5000 chats. This crate is that mirror in Rust, behind the C ABI in
//! `include/cmux_chats_mirror.h` (linked into the app through cmux-app-ffi):
//!
//! - [`Line::parse`] decodes one watch line off the main thread (a page builds its sorted
//!   [`Index`] there too).
//! - [`Feed::apply`] applies a batch on the owner's thread: a page is a move, a change is
//!   O(log n), and nothing is copied.
//! - Readers ask for what they show ([`Index::listed`], [`Index::get`], [`Index::projects`]).

pub mod chat;
pub mod feed;
pub mod ffi;
pub mod index;

pub use chat::Chat;
pub use feed::{Feed, Line, Outcome};
pub use index::{Change, Index};
