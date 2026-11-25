//! Scoreboard sim for the three-way hub (RFD 0142 R6): a deterministic,
//! in-process model of one agent turn whose events reach the phone from two
//! sources, the Mac and the AutoCloud VM, and the Mac sleeping mid-turn.
//!
//! Every frame is really sealed (`hub::seal_frame`), routed by the relay's rule
//! (`HubRelayRule`, the same rule `HubRelay` in the backend runs) and opened and
//! ordered by the phone's `TruthTracker`. Only the clock and the links are
//! modelled: a seeded PRNG gives each frame its link delay, and every socket is
//! ordered (a frame never overtakes an earlier one on the same socket).
//!
//! Rows (printed, and asserted):
//! - "Mac sleeps mid-turn: visible stream gap". Before (one link to the Mac,
//!   fall back to the VM once the link is declared dead): the gap is the
//!   reconnect machine's detection plus a cold dial, from
//!   `cmux-mobile-link/src/reconnect/timings.rs` (HEARTBEAT 2.5 s, then
//!   PROBE_TIMEOUT 2 s, then PROBE_GRACE 0.5 s) and the scoreboard's measured
//!   lte cold first content (0.6 s). After: no event missing, and the longest
//!   wait between two delivered events is no longer than in the steady state
//!   before the sleep (at most one event interval plus link jitter).
//! - "phone bytes during dual-source session". Before (A2 download-both, the
//!   phone takes both sources' streams to pick the truthful copy): 2x. After:
//!   1x, each event once plus the hub frame's fixed overhead.
//!
//! `cargo test -p cmux-transport --test hub_scoreboard -- --nocapture` prints
//! the numbers.

use cmux_transport::RelayFrame;
use cmux_transport::hub::{
    HUB_FRAME_OVERHEAD, HubHeader, HubKey, HubPos, HubRelayRule, HubRole, HubRoute, HubTo,
    seal_frame,
};
use cmux_transport::hub_truth::{TruthConfig, TruthEvent, TruthTracker};

const SESSION: [u8; 16] = [0x5e; 16];
const SECRET: [u8; 32] = [7; 32];

/// One streamed event every 50 ms (a fast token stream).
const INTERVAL_MS: u64 = 50;
const EVENTS: u64 = 200;
/// The Mac sleeps after its copy of this event (mid-turn: 5 s in).
const SLEEP_AFTER: u64 = 100;

/// Mac to relay over lte: 35 ms one way (link-profiles.json lte, rtt 70 ms)
/// plus up to 30 ms of jitter.
const MAC_BASE_MS: u64 = 35;
const MAC_JITTER_MS: u64 = 30;
/// The VM runs the turn and sits in a datacenter: its copy leaves after the
/// Mac's would (it mirrors through its own log), 30 ms plus up to 10 ms.
const VM_BASE_MS: u64 = 30;
const VM_JITTER_MS: u64 = 10;
/// Relay to phone over lte, one way.
const PHONE_DOWN_MS: u64 = 35;

/// The reconnect machine's detection of a dead link and the lte cold dial.
const HEARTBEAT_MS: u64 = 2500;
const PROBE_TIMEOUT_MS: u64 = 2000;
const PROBE_GRACE_MS: u64 = 500;
const LTE_COLD_DIAL_MS: u64 = 600;

/// xorshift64*: deterministic, no dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }

    fn below(&mut self, n: u64) -> u64 {
        if n == 0 { 0 } else { self.next() % n }
    }
}

struct Sent {
    at_relay: u64,
    source: HubRole,
    bytes: Vec<u8>,
}

/// The event payload sizes of the turn (20..420 bytes: deltas, tool output).
fn events(rng: &mut Rng) -> Vec<Vec<u8>> {
    (0..EVENTS)
        .map(|i| {
            let len = 20 + rng.below(400) as usize;
            (0..len).map(|j| (i as usize + j) as u8).collect()
        })
        .collect()
}

/// One source's frames, in order, each at its arrival time at the relay.
fn upload(
    rng: &mut Rng,
    key: &HubKey,
    payloads: &[Vec<u8>],
    source: HubRole,
    upto: u64,
) -> Vec<Sent> {
    let (base, jitter) = match source {
        HubRole::Mac => (MAC_BASE_MS, MAC_JITTER_MS),
        HubRole::Vm => (VM_BASE_MS, VM_JITTER_MS),
    };
    let mut last = 0;
    (0..upto)
        .map(|seq| {
            let header = HubHeader {
                session: SESSION,
                pos: HubPos::new(1, seq),
                source,
                to: HubTo::Viewers,
            };
            let frame = seal_frame(key, &header, &payloads[seq as usize]).expect("fits");
            // An ordered socket: never before the previous frame.
            last = (seq * INTERVAL_MS + base + rng.below(jitter + 1)).max(last);
            Sent { at_relay: last, source, bytes: frame.encode().expect("encodes") }
        })
        .collect()
}

struct After {
    delivered: u64,
    missing: u64,
    duplicates: u64,
    gaps_flagged: u64,
    max_gap_ms: u64,
    steady_max_gap_ms: u64,
    sleep_gap_ms: u64,
    phone_bytes: u64,
    one_stream_bytes: u64,
    from_vm_after_sleep: u64,
}

fn run_hub(seed: u64) -> After {
    let mut rng = Rng(seed);
    let key = HubKey::derive(&SECRET, &SESSION);
    let payloads = events(&mut rng);
    let mut sent = upload(&mut rng, &key, &payloads, HubRole::Mac, SLEEP_AFTER + 1);
    sent.extend(upload(&mut rng, &key, &payloads, HubRole::Vm, EVENTS));
    // The relay sees frames in arrival order (ties: the Mac's socket first).
    sent.sort_by_key(|s| (s.at_relay, s.source as u8));

    let mut rule = HubRelayRule::default();
    let mut phone = TruthTracker::new(SESSION, TruthConfig::default());
    let mut phone_bytes = 0u64;
    let mut last_down = 0u64;
    let mut deliveries: Vec<(u64, u64)> = Vec::new();
    let mut from_vm_after_sleep = 0;
    for s in &sent {
        let frame = RelayFrame::decode(&s.bytes).expect("valid frame");
        let header = HubHeader::decode(&frame.payload).expect("header");
        if rule.route(&header) != HubRoute::Viewers {
            continue;
        }
        phone_bytes += s.bytes.len() as u64;
        last_down = (s.at_relay + PHONE_DOWN_MS).max(last_down);
        for event in phone.on_payload(&key, &frame.payload).expect("the phone takes it") {
            if let TruthEvent::Deliver { source, pos, .. } = event {
                deliveries.push((pos.seq, last_down));
                if pos.seq > SLEEP_AFTER && source == HubRole::Vm {
                    from_vm_after_sleep += 1;
                }
            }
        }
    }
    let one_stream_bytes: u64 =
        payloads.iter().map(|p| (p.len() + HUB_FRAME_OVERHEAD) as u64).sum();
    let gap = |w: &[(u64, u64)]| w[1].1 - w[0].1;
    let steady_max_gap_ms =
        deliveries.windows(2).filter(|w| w[1].0 <= SLEEP_AFTER).map(gap).max().unwrap_or(0);
    let sleep_gap_ms =
        deliveries.windows(2).find(|w| w[0].0 == SLEEP_AFTER).map(gap).unwrap_or(u64::MAX);
    let seqs: Vec<u64> = deliveries.iter().map(|d| d.0).collect();
    let delivered = seqs.len() as u64;
    assert_eq!(seqs, (0..EVENTS).collect::<Vec<_>>(), "in order, each once");
    After {
        delivered,
        missing: EVENTS - delivered,
        duplicates: phone.stats.duplicates,
        gaps_flagged: phone.stats.gaps,
        max_gap_ms: deliveries.windows(2).map(gap).max().unwrap_or(0),
        steady_max_gap_ms,
        sleep_gap_ms,
        phone_bytes,
        one_stream_bytes,
        from_vm_after_sleep,
    }
}

/// Before: the phone's one link to the Mac. When the Mac sleeps the phone
/// hears nothing more; its reconnect machine notices at the next heartbeat,
/// probes, waits out the grace, and dials the VM cold. The events the VM made
/// in the meantime arrive in one burst after the dial.
fn before_gap_ms(seed: u64) -> (u64, u64) {
    let mut rng = Rng(seed);
    let key = HubKey::derive(&SECRET, &SESSION);
    let payloads = events(&mut rng);
    let mac = upload(&mut rng, &key, &payloads, HubRole::Mac, SLEEP_AFTER + 1);
    let last_heard = mac.last().map(|s| s.at_relay + PHONE_DOWN_MS).unwrap_or(0);
    let resumed = last_heard + HEARTBEAT_MS + PROBE_TIMEOUT_MS + PROBE_GRACE_MS + LTE_COLD_DIAL_MS;
    // Events the phone should have seen during the outage but did not.
    let late = (SLEEP_AFTER + 1..EVENTS)
        .filter(|seq| seq * INTERVAL_MS + VM_BASE_MS + PHONE_DOWN_MS < resumed)
        .count() as u64;
    (resumed - last_heard, late)
}

#[test]
fn scoreboard_mac_sleeps_mid_turn() {
    let mut worst: Option<After> = None;
    for seed in [0x5eed_0001u64, 0x5eed_0002, 0x5eed_0003, 0xdead_beef, 0x0142_0006] {
        let after = run_hub(seed);
        assert_eq!(after.missing, 0, "seed {seed:#x}: no event missing");
        assert_eq!(after.gaps_flagged, 0, "seed {seed:#x}: the phone saw no hole");
        assert_eq!(after.duplicates, 0, "seed {seed:#x}: the relay forwarded each position once");
        assert!(after.from_vm_after_sleep > 0, "seed {seed:#x}: the VM carried the rest");
        // The sleep costs nothing over the steady state's jitter.
        assert!(
            after.sleep_gap_ms <= INTERVAL_MS + MAC_JITTER_MS,
            "seed {seed:#x}: gap at the sleep {} ms",
            after.sleep_gap_ms
        );
        assert!(after.max_gap_ms <= INTERVAL_MS + MAC_JITTER_MS);
        // 1x: every byte the phone downloads is one copy of one event.
        assert_eq!(after.phone_bytes, after.one_stream_bytes, "seed {seed:#x}: one copy");
        if worst.as_ref().is_none_or(|w| after.sleep_gap_ms > w.sleep_gap_ms) {
            worst = Some(after);
        }
    }
    let after = worst.expect("ran");
    let (before_gap, before_late) = before_gap_ms(0x5eed_0001);
    assert!(before_gap >= 5_000);
    let raw: u64 = {
        let mut rng = Rng(0x5eed_0001);
        events(&mut rng).iter().map(|p| p.len() as u64).sum()
    };
    println!(
        "hub scoreboard ({EVENTS} events every {INTERVAL_MS} ms, Mac sleeps after {SLEEP_AFTER}, 5 seeds, worst shown)"
    );
    println!(
        "  Mac sleeps mid-turn: visible stream gap   before {before_gap} ms ({before_late} events late)   after {} ms at the sleep (steady state max {} ms, interval {INTERVAL_MS} ms), {} missing, {} delivered",
        after.sleep_gap_ms, after.steady_max_gap_ms, after.missing, after.delivered
    );
    println!(
        "  phone bytes during dual-source session    before 2.00x ({} B, both streams)   after {:.2}x ({} B; {} B of events + {HUB_FRAME_OVERHEAD} B frame per event)",
        2 * after.one_stream_bytes,
        after.phone_bytes as f64 / after.one_stream_bytes as f64,
        after.phone_bytes,
        raw
    );
}
