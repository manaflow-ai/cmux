//! The remote event stream (cmux-remote `mux_codec`, through
//! `cmux_remote::fuzz_seam`): each JSON line (a daemon event or reply) is cut
//! into `CMXL` packets, and the client's assembler joins them again. Packets
//! of many lines interleave; parts arrive in any order.
//!
//! Input (`Arbitrary`): up to 8 lines (a lane, a byte pattern and a length up
//! to two chunks and a bit, so lines of one, two and three parts), a line
//! limit, and up to 64 operations: deliver a part, deliver it again, deliver
//! it on the wrong lane, deliver it cut short, deliver it with one byte
//! changed, or deliver raw bytes. After the operations every part not yet
//! delivered is delivered in order.
//!
//! Oracle: no panic; a completed line keeps its first packet's lane and fits
//! the limit; the in-flight lines and bytes stay bounded (256 lines, the
//! limit per line); every line no operation tampered with (no wrong lane, cut,
//! change, or raw packet with its message id) completes exactly once, with
//! exactly its bytes, whatever the order and the duplicates, and a duplicate
//! part is refused. Tampering with one line never disturbs another.
#![no_main]

use std::collections::{BTreeMap, BTreeSet};

use arbitrary::Arbitrary;
use bytes::Bytes;
use cmux_remote::fuzz_seam::{Assembler, MAX_DOWNLOAD_LINE_BYTES, encode_line};
use cmux_remote_protocol::{Lane, MAX_FRAME_PAYLOAD};
use libfuzzer_sys::fuzz_target;

/// cmux-remote mux_codec CHUNK_BYTES: the payload of one packet.
const CHUNK: usize = MAX_FRAME_PAYLOAD - 20;
const MAX_IN_FLIGHT_LINES: usize = 256;

#[derive(Arbitrary, Debug)]
struct LineSpec {
    lane: u8,
    pattern: Vec<u8>,
    len: u32,
}

#[derive(Arbitrary, Debug)]
enum Op {
    Deliver { line: u8, part: u8 },
    WrongLane { line: u8, part: u8, lane: u8 },
    Cut { line: u8, part: u8, keep: u16 },
    Change { line: u8, part: u8, at: u16, byte: u8 },
    Raw { lane: u8, bytes: Vec<u8> },
}

#[derive(Arbitrary, Debug)]
struct Input {
    limit: u8,
    lines: Vec<LineSpec>,
    ops: Vec<Op>,
}

fn lane(pick: u8) -> Lane {
    Lane::ALL[usize::from(pick) % Lane::ALL.len()]
}

struct Sent {
    message: u64,
    lane: Lane,
    line: Vec<u8>,
    packets: Vec<Bytes>,
    delivered: Vec<bool>,
}

/// One packet into the assembler, with the bounds checked after it. True
/// when the assembler took the packet.
fn push(
    assembler: &mut Assembler,
    completed: &mut BTreeMap<u64, Vec<(Lane, Bytes)>>,
    maximum: usize,
    lane: Lane,
    packet: Bytes,
) -> bool {
    let message = packet.get(4..12).map(|id| u64::from_be_bytes(id.try_into().unwrap()));
    let result = assembler.push(lane, packet);
    let (lines, bytes) = assembler.in_flight();
    assert!(lines <= MAX_IN_FLIGHT_LINES, "{lines} lines in flight");
    assert!(bytes <= 2 * MAX_DOWNLOAD_LINE_BYTES, "{bytes} bytes in flight");
    match result {
        Ok(Some((line_lane, payload))) => {
            let payload_len = payload.strip_suffix(b"\n").map_or(payload.len(), <[u8]>::len);
            assert!(payload_len <= maximum.saturating_sub(1), "a line past the limit completed");
            completed.entry(message.unwrap_or(0)).or_default().push((line_lane, payload));
            true
        }
        Ok(None) => true,
        Err(_) => false,
    }
}

fuzz_target!(|input: Input| {
    let maximum = match input.limit % 4 {
        0 => MAX_DOWNLOAD_LINE_BYTES,
        1 => 1,
        2 => CHUNK + 1,
        _ => 2 * CHUNK + 1,
    };
    let mut sent = Vec::new();
    for (index, spec) in input.lines.iter().take(8).enumerate() {
        let pattern: &[u8] = if spec.pattern.is_empty() { b"x" } else { &spec.pattern };
        let len = spec.len as usize % (2 * CHUNK + 100);
        let line: Vec<u8> = pattern.iter().copied().cycle().take(len).collect();
        // The sender refuses an over-limit line; nothing of it goes out.
        let Ok(packets) = encode_line(index as u64 + 1, &line, maximum) else { continue };
        let delivered = vec![false; packets.len()];
        sent.push(Sent {
            message: index as u64 + 1,
            lane: lane(spec.lane),
            line,
            packets,
            delivered,
        });
    }
    let mut assembler = Assembler::new(maximum);
    let mut tainted = BTreeSet::new();
    let mut completed: BTreeMap<u64, Vec<(Lane, Bytes)>> = BTreeMap::new();

    for op in input.ops.iter().take(64) {
        let pick = |line: u8, part: u8| -> Option<(usize, usize)> {
            if sent.is_empty() {
                return None;
            }
            let line = usize::from(line) % sent.len();
            Some((line, usize::from(part) % sent[line].packets.len()))
        };
        match *op {
            Op::Deliver { line, part } => {
                let Some((line, part)) = pick(line, part) else { continue };
                let message = sent[line].message;
                let again = sent[line].delivered[part];
                // A replay after the line completed starts a new line with that
                // id: replay protection is the session's (sequence numbers),
                // not the assembler's.
                if again && completed.contains_key(&message) {
                    tainted.insert(message);
                }
                let packet = sent[line].packets[part].clone();
                let accepted =
                    push(&mut assembler, &mut completed, maximum, sent[line].lane, packet);
                if again && !tainted.contains(&message) {
                    assert!(!accepted, "a duplicate part of a pending line was accepted");
                }
                sent[line].delivered[part] = true;
            }
            Op::WrongLane { line, part, lane: pick_lane } => {
                let Some((line, part)) = pick(line, part) else { continue };
                let wrong = lane(pick_lane);
                if wrong == sent[line].lane {
                    continue;
                }
                tainted.insert(sent[line].message);
                push(
                    &mut assembler,
                    &mut completed,
                    maximum,
                    wrong,
                    sent[line].packets[part].clone(),
                );
            }
            Op::Cut { line, part, keep } => {
                let Some((line, part)) = pick(line, part) else { continue };
                let packet = &sent[line].packets[part];
                let keep = usize::from(keep) % (packet.len() + 1);
                tainted.insert(sent[line].message);
                push(
                    &mut assembler,
                    &mut completed,
                    maximum,
                    sent[line].lane,
                    packet.slice(..keep),
                );
            }
            Op::Change { line, part, at, byte } => {
                let Some((line, part)) = pick(line, part) else { continue };
                let mut packet = sent[line].packets[part].to_vec();
                if packet.is_empty() {
                    continue;
                }
                let at = usize::from(at) % packet.len();
                if packet[at] == byte {
                    continue;
                }
                packet[at] = byte;
                tainted.insert(sent[line].message);
                // A changed id byte reaches another message id.
                if let Some(id) = packet.get(4..12) {
                    tainted.insert(u64::from_be_bytes(id.try_into().unwrap()));
                }
                push(&mut assembler, &mut completed, maximum, sent[line].lane, Bytes::from(packet));
            }
            Op::Raw { lane: pick_lane, ref bytes } => {
                if let Some(id) = bytes.get(4..12) {
                    tainted.insert(u64::from_be_bytes(id.try_into().unwrap()));
                }
                push(
                    &mut assembler,
                    &mut completed,
                    maximum,
                    lane(pick_lane),
                    Bytes::from(bytes.clone()),
                );
            }
        }
    }
    for line in 0..sent.len() {
        for part in 0..sent[line].packets.len() {
            if !sent[line].delivered[part] {
                sent[line].delivered[part] = true;
                push(
                    &mut assembler,
                    &mut completed,
                    maximum,
                    sent[line].lane,
                    sent[line].packets[part].clone(),
                );
            }
        }
    }

    for line in &sent {
        let message = line.message;
        if tainted.contains(&message) {
            continue;
        }
        let got = completed.get(&message).map(Vec::as_slice).unwrap_or_default();
        assert_eq!(got.len(), 1, "untouched line {message} completed {} times", got.len());
        assert_eq!(got[0].0, line.lane, "untouched line {message} changed lane");
        assert!(got[0].1 == line.line.as_slice(), "untouched line {message} changed bytes");
    }
});
