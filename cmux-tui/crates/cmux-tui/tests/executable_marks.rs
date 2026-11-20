//! Scratch control only, never merged. It prints facts of this build's
//! `cmux-tui` executable: its size, its SHA-256 and how many times each of a
//! few byte strings is in it. Two steps, at two commits, compare the lines.
//!
//! Each line starts with `executable marks:`.

use std::fs;
use std::path::Path;

use sha2::{Digest, Sha256};

/// Four byte strings of the writer table's code (one writer's name and three
/// names of functions and statics), and a last one that each build has.
const MARKS: [&str; 5] = [
    "frontend_document",
    "scope_then_row",
    "KEEP_WRITER_SCOPE",
    "writer_commit_rows",
    "__store-schemas",
];

/// How many times `mark` is in `bytes`.
fn count(bytes: &[u8], mark: &[u8]) -> usize {
    bytes.windows(mark.len()).filter(|window| window[0] == mark[0] && *window == mark).count()
}

#[test]
fn executable_marks_of_this_build() {
    let built = Path::new(env!("CARGO_BIN_EXE_cmux-tui"));
    let bytes = fs::read(built).unwrap();
    let hash: String = Sha256::digest(&bytes).iter().map(|byte| format!("{byte:02x}")).collect();
    println!("executable marks: cmux-tui has {} bytes and the SHA-256 {hash}", bytes.len());
    for mark in MARKS {
        println!("executable marks: {mark:?} is in it {} times", count(&bytes, mark.as_bytes()));
    }
}
