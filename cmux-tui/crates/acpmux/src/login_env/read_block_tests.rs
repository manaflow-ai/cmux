//! `read_env_block`: the login read takes the environment between its two markers, whatever
//! reads split them, and nothing else is a read.

use super::{END_SUFFIX, read_env_block};
use std::time::Duration;
use tokio::io::AsyncWriteExt;

const MARKER: &str = "__acpmux_test_marker";

/// The block read from `bytes`, written in pieces of `piece` bytes, the pipe left open after.
async fn read(bytes: &[u8], piece: usize) -> Option<String> {
    let (mut tx, rx) = tokio::io::duplex(1 << 16);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    let reading = tokio::spawn(read_env_block(rx, MARKER, deadline));
    for part in bytes.chunks(piece.max(1)) {
        tx.write_all(part).await.unwrap();
        tokio::task::yield_now().await;
    }
    let out = reading.await.unwrap();
    drop(tx);
    out
}

fn whole(env: &str) -> Vec<u8> {
    format!("rc noise\n{MARKER}\n{env}\n{MARKER}{END_SUFFIX}\n").into_bytes()
}

#[tokio::test]
async fn the_block_is_found_whatever_the_reads_split() {
    let bytes = whole("A=1\0PATH=/bin\0");
    for piece in 1..=bytes.len() {
        let text = read(&bytes, piece).await.unwrap_or_else(|| panic!("piece {piece}"));
        assert!(text.ends_with("A=1\0PATH=/bin\0"), "piece {piece}: {text:?}");
        assert!(text.contains(&format!("\n{MARKER}\n")), "piece {piece}");
    }
}

#[tokio::test]
async fn output_without_both_markers_is_no_read() {
    // A shell replaced before its command ran: the pipe ends with nothing.
    let (tx, rx) = tokio::io::duplex(64);
    drop(tx);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    assert_eq!(read_env_block(rx, MARKER, deadline).await, None);
    // The end marker with no start marker before it.
    let only_end = format!("A=1\0\n{MARKER}{END_SUFFIX}\n");
    assert_eq!(read(only_end.as_bytes(), 7).await, None);
}

#[tokio::test]
async fn a_shell_cut_off_mid_print_is_no_read() {
    let (mut tx, rx) = tokio::io::duplex(1 << 16);
    tx.write_all(format!("\n{MARKER}\nA=1\0PA").as_bytes()).await.unwrap();
    drop(tx);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    assert_eq!(read_env_block(rx, MARKER, deadline).await, None);
}

#[tokio::test]
async fn a_pipe_held_open_with_no_end_marker_fails_at_the_deadline() {
    let (mut tx, rx) = tokio::io::duplex(1 << 16);
    tx.write_all(format!("\n{MARKER}\nA=1\0").as_bytes()).await.unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_millis(200);
    let started = std::time::Instant::now();
    assert_eq!(read_env_block(rx, MARKER, deadline).await, None);
    assert!(started.elapsed() < Duration::from_secs(2));
    drop(tx);
}
