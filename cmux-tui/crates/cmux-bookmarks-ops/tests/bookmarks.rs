//! The codec, search and import suites, under `bookmark_*::` so the fleet's
//! one-substring test filter (`bookmark`) selects them.

#[path = "bookmarks/codec.rs"]
mod bookmark_codec;

#[path = "bookmarks/search.rs"]
mod bookmark_search;
