//! A keyframe and a NACK repair through a drop-tail bottleneck, sent by the real pacer
//! and by the schedule the pacer had before (design D3/D6, cmuxterm-hq
//! docs/design/screen-share-under-100ms.md): a frame's size raised the rate to fit it
//! into half a frame interval, and resends were written straight to the socket.
//! Prints the datagrams each loses; run with `--nocapture` for the table.

use cmux_rd_core::pacer::{BURST_US, PACING_FACTOR, Pacer};

const MTU: usize = 1152;
const FPS: u64 = 60;
const INTERVAL_US: u64 = 1_000_000 / FPS;
/// The one-datagram budget the controller's NACK answer may resend at once.
const REPAIRS: usize = 64;

/// A link of `capacity_bps` with a drop-tail queue of `buffer_us` at that rate.
struct Bottleneck {
    bytes_per_us: f64,
    buffer_bytes: f64,
    /// When the queue drains, in µs.
    free_at: f64,
    dropped: usize,
    last_out: f64,
}

impl Bottleneck {
    fn new(capacity_bps: f64, buffer_us: f64) -> Self {
        let bytes_per_us = capacity_bps / 8.0 / 1e6;
        Self {
            bytes_per_us,
            buffer_bytes: bytes_per_us * buffer_us,
            free_at: 0.0,
            dropped: 0,
            last_out: 0.0,
        }
    }

    fn offer(&mut self, at_us: u64, bytes: usize) {
        let at = at_us as f64;
        let queued = (self.free_at - at).max(0.0) * self.bytes_per_us;
        if queued + bytes as f64 > self.buffer_bytes {
            self.dropped += 1;
            return;
        }
        self.free_at = self.free_at.max(at) + bytes as f64 / self.bytes_per_us;
        self.last_out = self.free_at;
    }
}

/// What one scenario sends: a keyframe of `keyframe_bytes` at t=0, then at 20 ms (a
/// NACK for its tail) [`REPAIRS`] resends and the next P-frame of the encoder's budget.
struct Scenario {
    target_bps: u64,
    keyframe_bytes: usize,
}

fn datagrams(bytes: usize) -> Vec<Vec<u8>> {
    (0..bytes.div_ceil(MTU)).map(|_| vec![0; MTU]).collect()
}

/// The real pacer: returns (send time, bytes) of every datagram.
fn paced(s: &Scenario) -> Vec<(u64, usize)> {
    let mut p = Pacer::new();
    let mut out = Vec::new();
    p.push_frame(datagrams(s.keyframe_bytes), s.target_bps, INTERVAL_US, 0);
    let p_frame = (s.target_bps / 8 / FPS) as usize;
    let mut now = 0;
    let mut pushed = false;
    for _ in 0..1_000_000 {
        if !pushed && now >= 20_000 {
            p.push_repair(datagrams(REPAIRS * MTU), s.target_bps, now);
            p.push_frame(datagrams(p_frame), s.target_bps, INTERVAL_US, now);
            pushed = true;
        }
        out.extend(p.due(now).into_iter().map(|d| (now, d.len())));
        now = match p.next_deadline_us() {
            Some(t) if !pushed => t.min(20_000).max(now + 1),
            Some(t) => t.max(now + 1),
            None if !pushed => 20_000,
            None => break,
        };
    }
    out
}

/// The schedule before: rate = max(2.5 x target, queued / half a frame interval), with
/// the burst allowance; resends written at once.
fn before(s: &Scenario) -> Vec<(u64, usize)> {
    let floor = s.target_bps as f64 * PACING_FACTOR / 8.0 / 1e6;
    let window = INTERVAL_US as f64 * 0.5;
    let mut out = Vec::new();
    let spread = |from: u64, bytes: usize, out: &mut Vec<(u64, usize)>| {
        let rate = floor.max(bytes as f64 / window);
        let burst = rate * BURST_US as f64;
        let mut sent = 0.0;
        for _ in 0..bytes.div_ceil(MTU) {
            let at = from + ((sent - burst).max(0.0) / rate) as u64;
            out.push((at, MTU));
            sent += MTU as f64;
        }
    };
    spread(0, s.keyframe_bytes, &mut out);
    out.extend((0..REPAIRS).map(|_| (20_000, MTU)));
    spread(20_000, (s.target_bps / 8 / FPS) as usize, &mut out);
    out.sort_by_key(|&(t, _)| t);
    out
}

fn run(schedule: &[(u64, usize)], capacity_bps: f64, buffer_us: f64) -> (usize, f64) {
    let mut b = Bottleneck::new(capacity_bps, buffer_us);
    for &(t, bytes) in schedule {
        b.offer(t, bytes);
    }
    (b.dropped, b.last_out / 1000.0)
}

#[test]
fn a_keyframe_and_its_repairs_through_a_shallow_bottleneck_lose_less_paced() {
    // Linux host keyframe (525 KB, cmux#44486's measurement) and a 1080p desktop one.
    let scenarios = [
        Scenario { target_bps: 50_000_000, keyframe_bytes: 525_000 },
        Scenario { target_bps: 30_000_000, keyframe_bytes: 300_000 },
    ];
    // (capacity, drop-tail buffer): the target is below capacity, as the controller holds it.
    let links = [(100e6, 5_000.0), (100e6, 10_000.0), (200e6, 5_000.0), (200e6, 10_000.0)];
    println!(
        "target_mbps keyframe_kb capacity_mbps buffer_ms | dropped before / paced | last delivered ms before / paced"
    );
    // Drops on links the pacing rate fits (2.5 x target at most the capacity).
    let mut fits = (0, 0);
    for s in &scenarios {
        let (old, new) = (before(s), paced(s));
        assert_eq!(old.len(), new.len(), "same datagrams");
        for &(cap, buf) in &links {
            let (d_old, t_old) = run(&old, cap, buf);
            let (d_new, t_new) = run(&new, cap, buf);
            println!(
                "{} {} {} {} | {d_old} / {d_new} | {t_old:.1} / {t_new:.1}",
                s.target_bps / 1_000_000,
                s.keyframe_bytes / 1000,
                cap / 1e6,
                buf / 1000.0,
            );
            assert!(d_new <= d_old, "pacing lost more: {d_new} > {d_old}");
            if s.target_bps as f64 * PACING_FACTOR <= cap {
                fits.0 += d_old;
                fits.1 += d_new;
            }
        }
    }
    println!("dropped where the pacing rate fits: before {} paced {}", fits.0, fits.1);
    // Where 2.5 x the target fits the link, nothing paced is lost; before, the keyframe
    // burst overflowed those links. (A 50 Mbps target on a 100 Mbps link paces above
    // the capacity: there pacing only has to lose no more than before.)
    assert_eq!(fits.1, 0, "paced keyframe or repairs were dropped");
    assert!(fits.0 > 0);
}
