//! A session's event log as a pack: content-addressed zstd segments with an index, so the log is
//! about 13x smaller than its JSON lines, any range of it (or one tool result) reads back in
//! milliseconds without reading the rest, and moving it to another machine ships only the chunks
//! that machine lacks. The design and its measurements are cmuxterm-hq's RFD "Session pack".
//!
//! Leo, 2026-11-23: "i want ultra good compression and being able to rapidly partially decompact
//! or wahteer the heck, idk if we want to have a specific data storing protocol or whatever
//! perhaps... if it can \"move to cloud\" in the BACKEND but i still am able to interact with it
//! with no percievable lag or whatever here".
//!
//! # The log and the pack
//!
//! The log is what it is today: newline-separated records, appended only (acpmux's
//! `events/NNNNNN.ndjson`, a Claude Code transcript, a Codex rollout). A line's number in the log,
//! counted from 0, is its id; nothing in a pack ever renumbers a line. The pack reads back every
//! byte of the log, whatever the lines hold (JSON or not).
//!
//! A pack is a manifest (`sessions/<name>.json`, [`Manifest`]) over chunks in a store shared by
//! every session on the machine (`chunks/<aa>/<id>`). A chunk's id is the BLAKE3 hash of its
//! kind and its bytes before compression, so the same bytes are the same chunk wherever and
//! however they were compressed: a fork shares its parent's chunks, and a chunk that arrives from
//! another machine is checked against its name.
//!
//! The log is cut into segments of about 4 MiB of lines ([`Params::segment_bytes`]). A segment is
//! up to three chunks (`codec.rs`):
//!
//! - **events**: the segment's lines, with three things done to them first. Every JSON string of
//!   384 bytes or more is taken out and replaced by a blob number (the same string appears in a
//!   tool call's update, in the harness's raw line and in the permission record, megabytes apart,
//!   which no compressor window pairs up). An acpmux record's `seq`, `at`, `dir` and `kind` go
//!   into a column of their own as differences. And the lines' remainders are stored grouped by
//!   kind, so like sits next to like.
//! - **blobs**: the strings this segment was the first to hold, back to back. A string that is
//!   base64 (a screenshot) is stored decoded.
//! - **blob table**: each of those blobs' length, encoding and hash.
//!
//! A full segment is sealed and never changes. The last, partial one is rewritten by the next
//! [`pack`], which hashes the log to find the sealed segments it still holds and encodes only
//! what follows them.
//!
//! # Reading
//!
//! [`Pack::read_lines`] finds the segments a range of lines is in from the manifest, reads those
//! events chunks and only the blob chunks the range's lines name. [`Pack::blob`] reads one blob.
//! The manifest also lists the lines that start a turn, so "the last 50 turns" is one range: an
//! acpmux record of a kind in [`Params::marks`], or, in a Claude Code transcript, a person's
//! prompt (told by the line's shape, `claude.rs`). A range's name (`<session>@<first line>-<last line>`,
//! [`RangeId`]) is what a compaction summary keeps in place of the text it summarized: the agent,
//! or the view, asks for that name and gets the lines back (partial decompaction), as the
//! records themselves or as a few kilobytes of text ([`digest`]) that name each tool result it
//! cut short.
//!
//! # Moving
//!
//! [`ship::bundle`] writes the manifest and the chunks the other side says it lacks
//! ([`ship::want`]); [`ship::unbundle`] checks each chunk against its id and puts the manifest in
//! place last. A machine that holds an older copy of the session holds every sealed segment of
//! it, so it is sent the segments sealed since and the partial one.

mod claude;
mod codec;
pub mod digest;
mod manifest;
mod pack;
mod read;
pub mod ship;
mod store;

pub use manifest::{Manifest, Params, RangeId, SCHEMA, Segment, TURN_RULE};
pub use pack::{PackStats, pack, pack_after};
pub use read::Pack;
pub use store::{Id, MISSING, Store, hex, unhex};

/// This crate's error: a message that says what was read or written and what was wrong with it.
pub type Error = Box<dyn std::error::Error + Send + Sync>;
/// `Result` with [`Error`].
pub type Result<T> = std::result::Result<T, Error>;
