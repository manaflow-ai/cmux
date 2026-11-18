//! A NACK answer through a drop-tail bottleneck, sent by the real pacer and as it was
//! before (design D6, cmuxterm-hq docs/design/screen-share-under-100ms.md): resends
//! written straight to the socket, 64 datagrams in one burst. Prints the datagrams each
//! loses; run with `--nocapture` for the table.

use cmux_rd_core::pacer::Pacer;

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

fn datagrams(n: usize) -> Vec<Vec<u8>> {
    (0..n).map(|_| vec![0; MTU]).collect()
}

/// A NACK for [`REPAIRS`] datagrams at t=0, then a P-frame of the encoder's budget every
/// frame interval; `paced` sends the resends through the pacer, otherwise at once.
fn schedule(target_bps: u64, paced: bool) -> Vec<(u64, usize)> {
    let mut p = Pacer::new();
    let mut out = Vec::new();
    let p_frame = (target_bps / 8 / FPS) as usize / MTU;
    if paced {
        p.push_repair(datagrams(REPAIRS), target_bps, 0);
    } else {
        out.extend((0..REPAIRS).map(|_| (0, MTU)));
    }
    let mut now = 0;
    let mut next_frame = 0;
    let end = 3 * INTERVAL_US;
    loop {
        if next_frame <= now && next_frame < end {
            p.push_frame(datagrams(p_frame), target_bps, INTERVAL_US, now);
            next_frame += INTERVAL_US;
        }
        out.extend(p.due(now).into_iter().map(|d| (now, d.len())));
        let wake = p.next_deadline_us().unwrap_or(u64::MAX);
        let frame = if next_frame < end { next_frame } else { u64::MAX };
        if wake == u64::MAX && frame == u64::MAX {
            break;
        }
        now = wake.min(frame).max(now + 1);
    }
    out
}

#[test]
fn a_nack_answer_through_a_shallow_bottleneck_loses_less_paced() {
    // (capacity, drop-tail buffer): the target is below capacity, as the controller holds
    // it. A 64-datagram resend is 74 KB: more than a 5 ms buffer at 100 Mbps holds.
    let links = [(50e6, 5_000.0), (100e6, 5_000.0), (100e6, 2_000.0), (200e6, 2_000.0)];
    let targets = [8_000_000, 20_000_000];
    println!("target_mbps capacity_mbps buffer_ms | dropped before / paced");
    let mut total = (0, 0);
    for &target in &targets {
        let (old, new) = (schedule(target, false), schedule(target, true));
        assert_eq!(old.len(), new.len(), "same datagrams");
        for &(cap, buf) in &links {
            let mut b = Bottleneck::new(cap, buf);
            old.iter().for_each(|&(t, n)| b.offer(t, n));
            let d_old = b.dropped;
            let mut b = Bottleneck::new(cap, buf);
            new.iter().for_each(|&(t, n)| b.offer(t, n));
            let d_new = b.dropped;
            println!("{} {} {} | {d_old} / {d_new}", target / 1_000_000, cap / 1e6, buf / 1000.0);
            assert!(d_new <= d_old, "pacing lost more: {d_new} > {d_old}");
            total.0 += d_old;
            total.1 += d_new;
        }
    }
    println!("total dropped: before {} paced {}", total.0, total.1);
    assert!(total.0 > 0 && total.1 < total.0, "before {} paced {}", total.0, total.1);
}
