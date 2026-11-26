//! `modules!()`: one `#[path] mod` per test file of cmux-tui's `tests/` folder, for the crate
//! root of its one test binary (`tests/it/main.rs`). `build.rs` writes the list.

include!(concat!(env!("OUT_DIR"), "/modules.rs"));
