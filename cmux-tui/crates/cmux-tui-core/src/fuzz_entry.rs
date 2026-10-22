//! Entry points for the cmux-tui/fuzz targets. Hidden from the docs
//! and called only by the fuzz targets; nothing in cmux calls them.
//!
//! Each function takes bytes the daemon reads from outside (a socket line, a
//! file it wrote earlier and reads back) and must return without panicking
//! for every input. The terminal host frame decoder is public already
//! (`terminal_host_protocol`), so it needs no entry here.

/// One daemon socket line: the auth and pairing probes, the old-client
/// revision upgrade, the resource envelope and the classic request parse.
/// The first byte is the API revision the client declares.
pub fn socket_line(data: &[u8]) {
    crate::server::connection_frame::fuzz::socket_line(data);
}

/// One sealed journal segment row whose JSON body is `data` (the gzip, length
/// and digest are made to match, so the decode reaches the record parse).
pub fn journal_segment(data: &[u8]) {
    crate::workspace_registry::session_journal::digest_reader::fuzz::segment(data);
}

/// The output store's segment and snapshot files with contents from `data`.
pub fn output_store_files(data: &[u8]) {
    crate::output_store::fuzz::files(data);
}

/// Whether the output store harness still reads a well-formed segment and
/// snapshot it wrote (false means its copy of the file layout drifted).
pub fn output_store_self_check() -> bool {
    crate::output_store::fuzz::self_check()
}
