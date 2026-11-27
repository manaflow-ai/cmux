//! The link model: one pipe per direction and a discrete-event loop.

use super::Res;
use cmux_tab_snapshots::{Applied, Mirror, Producer, Session};
use std::collections::BTreeMap;

pub const LINK_PAYLOAD_PER_WRITE: usize = 16 * 1024;
pub const LINK_HEADER_PER_WRITE: usize = 9;
/// Cards in the first screenful.
pub const FIRST_SCREENFUL: usize = 6;

pub struct Link {
    pub name: &'static str,
    pub rtt_ms: f64,
    pub down_bps: f64,
    pub up_bps: f64,
}

pub const LINKS: [Link; 2] = [
    Link { name: "wifi", rtt_ms: 8.0, down_bps: 100e6, up_bps: 40e6 },
    Link { name: "lte", rtt_ms: 70.0, down_bps: 12e6, up_bps: 5e6 },
];

/// Bytes a frame of `len` payload bytes costs on the link.
pub fn on_link(len: usize) -> (usize, usize) {
    let writes = len.div_ceil(LINK_PAYLOAD_PER_WRITE).max(1);
    (len + writes * LINK_HEADER_PER_WRITE, writes)
}

/// One direction of the link: writes leave one after another.
pub struct Pipe {
    pub free_at_us: f64,
    pub bps: f64,
    pub half_rtt_us: f64,
    pub bytes: usize,
    pub frames: usize,
    pub writes: usize,
}

impl Pipe {
    pub fn new(bps: f64, rtt_ms: f64) -> Self {
        Self { free_at_us: 0.0, bps, half_rtt_us: rtt_ms * 500.0, bytes: 0, frames: 0, writes: 0 }
    }

    /// Sends a frame at `now`; returns (time it has left the sender, time it
    /// arrives), in microseconds.
    pub fn send(&mut self, now: f64, len: usize) -> (f64, f64) {
        let (bytes, writes) = on_link(len);
        self.bytes += bytes;
        self.frames += 1;
        self.writes += writes;
        let start = now.max(self.free_at_us);
        let done = start + bytes as f64 * 8.0 / self.bps * 1e6;
        self.free_at_us = done;
        (done, done + self.half_rtt_us)
    }
}

pub enum Ev {
    ToMac(Vec<u8>),
    ToPhone(Vec<u8>),
    MacPoll,
}

#[derive(Default)]
pub struct Marks {
    pub rows: Option<f64>,
    pub first_card: Option<f64>,
    pub first_screen: Option<f64>,
    pub all: Option<f64>,
}

pub struct Outcome {
    pub marks: Marks,
    pub down: Pipe,
    pub up: Pipe,
    pub blob_bytes: usize,
    /// Blob bytes of blobs the phone already held when they arrived.
    pub resent_blob_bytes: usize,
}

/// When the link drops.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Drop {
    /// Never: run until both sides are idle.
    Never,
    /// The moment the first screenful of cards is filled. Every frame
    /// still in flight is lost.
    AfterFirstScreen,
}

/// Runs one link from link-up (t = 0) until both sides are idle.
pub fn simulate(
    link: &Link,
    producer: &Producer,
    session: &mut Session,
    mirror: &mut Mirror,
    phone_first: Vec<Vec<u8>>,
) -> Res<Outcome> {
    simulate_until(link, producer, session, mirror, phone_first, Drop::Never)
}

/// [`simulate`], ending early when `drop` says the link drops.
pub fn simulate_until(
    link: &Link,
    producer: &Producer,
    session: &mut Session,
    mirror: &mut Mirror,
    phone_first: Vec<Vec<u8>>,
    drop: Drop,
) -> Res<Outcome> {
    let mut queue: BTreeMap<(u64, u64), Ev> = BTreeMap::new();
    let mut seq = 0u64;
    let mut push = |queue: &mut BTreeMap<(u64, u64), Ev>, at_us: f64, ev: Ev| {
        seq += 1;
        queue.insert(((at_us * 1000.0).round() as u64, seq), ev);
    };
    let mut down = Pipe::new(link.down_bps, link.rtt_ms);
    let mut up = Pipe::new(link.up_bps, link.rtt_ms);
    let mut marks = Marks::default();
    let mut blob_bytes = 0;
    let mut resent_blob_bytes = 0;
    for frame in phone_first {
        let (_, at) = up.send(0.0, frame.len());
        push(&mut queue, at, Ev::ToMac(frame));
    }
    push(&mut queue, 0.0, Ev::MacPoll);
    while let Some(((at_ns, _), ev)) = queue.pop_first() {
        let now = at_ns as f64 / 1000.0;
        match ev {
            Ev::ToMac(frame) => {
                session.on_frame(&frame)?;
                push(&mut queue, now, Ev::MacPoll);
            }
            Ev::MacPoll => {
                // Event times are rounded to 1 ns, so compare with a 0.01 us slack.
                if down.free_at_us > now + 0.01 {
                    continue;
                }
                if let Some(frame) = session.next_frame(producer) {
                    let (done, at) = down.send(now, frame.len());
                    push(&mut queue, at, Ev::ToPhone(frame));
                    push(&mut queue, done, Ev::MacPoll);
                }
            }
            Ev::ToPhone(frame) => {
                let reply = match mirror.apply_frame(&frame)? {
                    Applied::Manifest { .. } | Applied::Delta { .. } => {
                        marks.rows.get_or_insert(now);
                        // A pushing Mac sends every card blob unasked.
                        if session.pushes() { None } else { mirror.want_frame() }
                    }
                    Applied::Gap { .. } => mirror.resume_frame(),
                    Applied::Blob { len, fresh, .. } => {
                        blob_bytes += len;
                        if !fresh {
                            resent_blob_bytes += len;
                        }
                        None
                    }
                };
                if let Some(reply) = reply {
                    let (_, at) = up.send(now, reply.len());
                    push(&mut queue, at, Ev::ToMac(reply));
                }
                check_marks(&mut marks, mirror, now);
                if drop == Drop::AfterFirstScreen && marks.first_screen.is_some() {
                    break;
                }
            }
        }
    }
    Ok(Outcome { marks, down, up, blob_bytes, resent_blob_bytes })
}

pub fn check_marks(marks: &mut Marks, mirror: &Mirror, now: f64) {
    if marks.rows.is_none() {
        return;
    }
    let n = mirror.rows().len();
    if marks.first_card.is_none() && (n == 0 || mirror.card_filled(0)) {
        marks.first_card = Some(now);
    }
    if marks.first_screen.is_none() && (0..n.min(FIRST_SCREENFUL)).all(|i| mirror.card_filled(i)) {
        marks.first_screen = Some(now);
    }
    if marks.all.is_none() && mirror.missing().is_empty() {
        marks.all = Some(now);
    }
}
