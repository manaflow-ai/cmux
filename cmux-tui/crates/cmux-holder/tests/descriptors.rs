//! Descriptors stay with the frame that passed them (holder-core review): a
//! LISTED that passes no master must not take the next terminal's, and a
//! frame that says it passes a descriptor it never sent ends the link
//! instead of shifting every later frame's descriptors by one. The test
//! plays both ends of a link on a socket pair.

#![cfg(unix)]

use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::UnixStream;
use std::time::{SystemTime, UNIX_EPOCH};

use cmux_holder::wire::{self, Frame, Kind, Out, Reader};

/// The header bits of a frame that states how many descriptors it passes
/// (`wire::FLAG_FDS_STATED`, the count in the three bits above it): written
/// out here, as the wire carries them, so the test pins the frozen format.
const fn stated(count: u16) -> u16 {
    1 << 12 | count << 13
}

/// A frame built byte by byte, as a sender of any build (or a broken one)
/// may write it: the encoder of this build states its own count.
fn frame(kind: Kind, flags: u16, chan: u32, payload: &[u8]) -> Vec<u8> {
    let mut bytes = wire::MAGIC.to_vec();
    bytes.extend_from_slice(&(kind as u16).to_le_bytes());
    bytes.extend_from_slice(&flags.to_le_bytes());
    bytes.extend_from_slice(&chan.to_le_bytes());
    bytes.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    bytes.extend_from_slice(payload);
    bytes
}

fn listed_payload(pid: i32) -> Vec<u8> {
    Out::default().i32(pid).u64(0).u64(0).u8(0).bytes(&[0; 16]).0
}

/// A file only this test opened: its inode names the descriptor that
/// passed it.
fn marker() -> std::fs::File {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let path = std::env::temp_dir().join(format!("cmhd-{}-{stamp}", std::process::id()));
    let file = std::fs::File::create(&path).unwrap();
    std::fs::remove_file(&path).unwrap();
    file
}

fn inode(fd: &OwnedFd) -> u64 {
    std::fs::File::from(fd.try_clone().unwrap()).metadata().unwrap().ino()
}

/// Read until `count` frames arrived, the stream ended or a frame was bad.
fn read_frames(stream: &UnixStream, count: usize) -> io::Result<Vec<Frame>> {
    let mut reader = Reader::default();
    let mut frames = Vec::new();
    while frames.len() < count {
        while let Some(frame) = reader.next_frame()? {
            frames.push(frame);
        }
        if frames.len() < count && !reader.fill(stream.as_raw_fd())? {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "the stream ended"));
        }
    }
    Ok(frames)
}

#[test]
fn a_listed_that_passes_no_master_takes_none_and_the_next_keeps_its_own() {
    let (holder, daemon) = UnixStream::pair().unwrap();
    let marker = marker();
    let first = frame(Kind::Listed, stated(0), 3, &listed_payload(30));
    let second = frame(Kind::Listed, stated(1), 4, &listed_payload(40));
    // Both are written before the daemon reads: one read may return the
    // first frame's bytes together with the second's descriptor.
    wire::send_all(holder.as_raw_fd(), &first, &[]).unwrap();
    wire::send_all(holder.as_raw_fd(), &second, &[marker.as_raw_fd()]).unwrap();
    let frames = read_frames(&daemon, 2).unwrap();
    assert_eq!(frames[0].chan, 3);
    assert!(frames[0].fds.is_empty(), "terminal 3 took terminal 4's master");
    assert_eq!(frames[1].chan, 4);
    assert_eq!(frames[1].fds.len(), 1, "terminal 4 lost its master");
    let expected = marker.metadata().unwrap().ino();
    assert_eq!(inode(&frames[1].fds[0]), expected, "terminal 4 got another descriptor");
}

#[test]
fn a_frame_that_says_it_passes_a_descriptor_it_never_sent_ends_the_link() {
    let (holder, daemon) = UnixStream::pair().unwrap();
    // Terminal 3 says it passes its master but sends none.
    let first = frame(Kind::Listed, stated(1), 3, &listed_payload(30));
    wire::send_all(holder.as_raw_fd(), &first, &[]).unwrap();
    let mut reader = Reader::default();
    assert!(reader.fill(daemon.as_raw_fd()).unwrap());
    let error = reader.next_frame().expect_err("a frame without its descriptor was accepted");
    assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    // The same from a sender that does not state counts (an older build):
    // its kind says a LISTED passes the master.
    let (holder, daemon) = UnixStream::pair().unwrap();
    let first = frame(Kind::Listed, 0, 3, &listed_payload(30));
    wire::send_all(holder.as_raw_fd(), &first, &[]).unwrap();
    let mut reader = Reader::default();
    assert!(reader.fill(daemon.as_raw_fd()).unwrap());
    let error = reader.next_frame().expect_err("an older sender's LISTED without its master");
    assert_eq!(error.kind(), io::ErrorKind::InvalidData);
}

#[test]
fn a_frame_that_passes_more_descriptors_than_it_states_ends_the_link() {
    let (holder, daemon) = UnixStream::pair().unwrap();
    let marker = marker();
    // A PING says it passes nothing but carries a descriptor; the PING
    // after it must not inherit it.
    let ping = frame(Kind::Ping, stated(0), 0, &7u64.to_le_bytes());
    wire::send_all(holder.as_raw_fd(), &ping, &[marker.as_raw_fd()]).unwrap();
    let mut reader = Reader::default();
    assert!(reader.fill(daemon.as_raw_fd()).unwrap());
    let error = reader.next_frame().expect_err("a descriptor no frame states was kept");
    assert_eq!(error.kind(), io::ErrorKind::InvalidData);
}
