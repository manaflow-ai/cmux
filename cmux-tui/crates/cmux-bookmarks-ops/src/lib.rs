//! The home daemon's bookmark reads and imports beyond the op reducer
//! (plans/cmux-next/bookmarks.md sections 3 and 5): the Netscape file codec
//! ([`netscape`]), the text search and the omnibar rank ([`search`]), and
//! where a browser's or a file's bookmarks land ([`import_plan`]). The daemon
//! serves them as the routed `bookmarks` namespace (cmux-tui-core
//! `server/bookmarks_routed.rs`); the app and its pages call those ops.
//!
//! The tree rules stay in cmux-bookmarks-core, which the app also links
//! through the app FFI; nothing here runs in the app, so this crate is not an
//! FFI input.

#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::indexing_slicing,
        clippy::string_slice
    )
)]

pub mod import_plan;
pub mod netscape;
pub mod search;
