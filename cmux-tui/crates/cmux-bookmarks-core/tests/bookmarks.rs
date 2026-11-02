//! The reducer corpus (`bookmark_tree::`), the app's mirror
//! (`bookmark_mirror::`) and its 100,000-bookmark bench
//! (`bookmark_mirror_bench::`), under module names the fleet's
//! one-substring test filter selects (`bookmark`).

#[path = "bookmarks/mirror.rs"]
mod bookmark_mirror;
#[path = "bookmarks/mirror_bench.rs"]
mod bookmark_mirror_bench;
#[path = "bookmarks/tree.rs"]
mod bookmark_tree;
