# cmux smoltcp patch

This directory vendors smoltcp 0.14.0 from crates.io. cmux-wg runs it as the
userspace TCP inside its WireGuard tunnels, with CUBIC.

Upstream CUBIC starts every connection at a 2 × 1024 byte congestion window. The
cmux patch starts it at RFC 6928's initial window, `min(10 * MSS, max(2 * MSS,
14600))` bytes: 10 KiB before the handshake, then 11,600 bytes once the tunnel's
1160 byte MSS is known. The window follows an MSS learned from the handshake
only until the first ACK of new data or the first loss. Linux and the other
common stacks have started at 10 segments since 2013. A 200 KB first message
needs about 4 round trips instead of about 7.

The window counts the segments the socket actually sends: on every SYN the
socket hands the controller `min(local, remote)` MSS, also when the peer sent no
MSS option (536 bytes). `Socket::reset()` starts the next connection on a fresh
controller of the same kind, so a reused socket gets the initial window again.
A listening socket that an RST sends from SYN-RECEIVED back to LISTEN drops
that peer's MSS and window the same way.

In congestion avoidance, both the Reno-friendly estimate and the cubic target
credit every newly acknowledged byte (RFC 9438 sections 4.2 and 4.3). Capping
that credit at one MSS made delayed ACKs and cumulative ACKs after a repaired
hole recover the window more slowly despite delivering the same bytes. The
one-MSS growth cap still applies in slow start. The detector is
`congestion_avoidance_credits_bytes_in_delayed_acks`, which compares equal
delivery with individual and delayed ACKs after a loss.

The patch also adds tail-loss probes (RFC 8985 section 7), off by default:
`Socket::set_tail_loss_probe(Some(max_ack_delay))`. With no selective ACKs, a
segment lost at the end of a burst draws no duplicate ACKs, so only the RTO
resends it, and the RTO then collapses the congestion window and resends
everything in flight. A probe resends the oldest unacknowledged segment once
`max(2 * SRTT, 10 ms) + max_ack_delay` passes with no ACK of new data,
keeps the congestion window, and leaves the RTO's deadline as it was. It runs
only in ESTABLISHED and CLOSE-WAIT, only after an RTT measurement, only when it
would fire before the RTO, and at most once per ACK of new data. cmux-wg turns
it on with a 25 ms allowance.

The patch also adds SACK loss recovery (RFC 6675), off by default:
`Socket::set_sack_recovery(true)`. smoltcp already offers SACK in its SYN and
sends SACK blocks, but as a sender it read only the cumulative ACK, so under
repeated loss it found one hole per round trip and cut the window again at each
one. With recovery on, and only when the peer permitted SACK, the socket keeps a
scoreboard of up to 16 SACKed ranges and, in one recovery episode, resends only
the holes it deems lost (three segments' worth, in the segments this socket sends, min(local, remote)
MSS, or three ranges SACKed above a hole, or everything sent after it SACKed with fewer than four
segments outstanding from the hole on, or three duplicate ACKs for the head),
several per round trip when the window has room. An episode cuts the window
once, to ssthresh with no inflation for the duplicate ACKs (the pipe already
leaves the SACKed segments out), and only when a hole is lost by the duplicate threshold: a hole lost only
because everything after it arrived (a short frame's loss) is resent with no
cut, as the tail-loss probe it replaces did, one round trip sooner. SACKed and
lost bytes count out of the data in flight (RFC 6675's pipe), so new data keeps
flowing while holes are repaired. A retransmission timeout drops the scoreboard
(RFC 2018 section 8), and resending the head restarts the RTO, as the
duplicate-ACK fast retransmit does. Blocks count only when both edges fall
inside the flight. A peer that did not permit SACK gets the plain behavior.
RACK time-based loss detection (RFC 8985) rides on the same scoreboard: the socket
remembers when each run of new data was first sent (32 records), and a hole is
lost once it was sent more than srtt + a reorder window ago while data sent
LATER was SACKed, without waiting for three duplicate ACKs or three segments'
worth of SACKed bytes (which tiny keystroke segments never reach in time). The
reorder window is srtt/4, times a multiplier (up to 4) that grows each time a
DSACK block shows a retransmission was spurious. Send order is (send time, end
sequence), so segments sent in the same poll are ordered by sequence (RFC 8985's
RACK.end_seq). Only the expired records' bytes are lost, not the whole hole they
sit in. A timer in `poll_at` and `dispatch` re-evaluates at the earliest expiry.
A retransmission restarts the clock of the records it overlaps (splitting one
it only partly covers) and makes them in flight again; when RACK declares that
retransmission lost too, its bytes are due again even below `sack_high_rxt`. A
retransmission pause (tunnel hold) also stops SACK and RACK resends. An RTO
forgets the records. Upstreaming: this
is RACK without min-RTT filtering (srtt stands in) and without RACK's own
reorder-window decay; smoltcp's tail-loss probe is the TLP half already.
As a receiver, an ACK now carries up to three SACK blocks, not one: the block of
the segment that triggered it, then the lowest others. cmux-wg turns recovery
on, and builds smoltcp with a 32-range assembler
(`assembler-max-segment-count-32`): with the default 4, a receiver dropped every
out-of-order segment past its fourth hole.

`Socket::path_changed()` is for a tunnel whose route under the connection
changed (cmux-wg calls it when its multipath underlay leaves the path that
carried the session, or the peer roams). With data unacknowledged, the socket
resends from the oldest unacknowledged byte at its next poll, as an RTO would,
slow start included, but its RTO returns to the RTT estimate's value instead of
doubling: the losses were the old route's. With nothing in flight it resends
nothing.

`Socket::set_retransmit_paused(true)` is for a peer that went silent on purpose
(cmux-wg's `WgNet::hold`, a phone the OS suspended in the background). Data in
flight is not resent while paused: no RTO, tail-loss probe or zero-window probe,
and `poll_at` waits for ingress instead of their deadlines. New data is still
sent once, and arriving segments are answered. `set_retransmit_paused(false)`
with data in flight resends at the next poll as `path_changed()` does. The
detector is `test_retransmit_paused_resends_nothing_until_resumed`, and in
cmux-wg `a_held_tunnel_does_not_retransmit_unacknowledged_output`.

`Socket::link_repairs_losses()` is for a tunnel that starts repairing its own
losses below TCP (cmux-wg's ultra mode, which "Auto" turns on at the first
loss). The losses that turned it on, and any other loss of data already in
flight at the call, were the unrepaired link's: they are still resent, but they
cut no congestion window, and a cut one of them already made (SACK recovery,
fast retransmit or RTO) is undone by restoring the controller saved just before
it, as long as that cut's episode is still open. Data sent after the call cuts
the window as usual. Without it, a loss early in slow start at a 300 ms round
trip cut the window of a stream that needed it, and the stream ran seconds
behind for the rest of the session; a tunnel that had repair on from the start
never saw the loss at all. The controllers derive `Clone` for the saved copy.

`Socket::unsent_queue()` returns the octets in the transmit buffer that were
never sent (`send_queue()` also counts those in flight), and
`Socket::smoothed_rtt()` the RFC 6298 SRTT. cmux-wg reads both to keep at most
about one bandwidth-delay product of unsent bytes in a socket, as Linux's
`TCP_NOTSENT_LOWAT` does: bytes in a socket can no longer be reordered, so a
latency-bound frame queued behind them waits for all of them. The detector is
`test_unsent_queue_and_smoothed_rtt`.

A pure ACK carries the highest sequence number sent (SND.MAX), as Linux's do,
not the send point a retransmission timeout rewound. After an RTO smoltcp
resends from the oldest unacknowledged byte, and it numbered its ACKs from
there too; a peer that already held data past that point (its ACK was lost)
saw those ACKs as old segments and dropped them with the acknowledgment they
carried (RFC 9293 3.10.7.4). With data flowing both ways through loss, both
ends rewound, each dropped the other's ACKs, and the connection stalled until
its user timeout. The tunnel TCP model test found it once a gate held writes
back (seed 13 of `tunnel_tcp_delivers_every_byte_once_in_order_over_a_lossy_link`,
12% loss). The detector is `test_pure_ack_after_rto_carries_send_max`.

The patch also adds black-hole fallback (RFC 4821 section 7.7, Linux's
`tcp_mtu_probing=1`), off by default: `Socket::set_black_hole_fallback(true)`.
smoltcp sends with DF clear and does no path MTU discovery, so an underlay path
smaller than the tunnel MTU that drops oversized packets silently carries the
handshake, ACKs and keystrokes and loses every full segment: a bulk transfer
stalls for good. With fallback on, after two retransmission timeouts in a row of
a head segment larger than a 1280 byte IP packet's (an MSS of 1240 over IPv4,
1220 over IPv6), with no ACK of new data between them, the connection sends
segments that size from then on, starting with the resend at hand.
`path_changed()` lifts the limit, also with nothing in flight, since a new
route may carry full segments. Nothing changes on the wire but the segment
size, so any peer works. cmux-wg turns it on; its detector is
`cmux-wg/tests/path_mtu.rs`, a 4 MiB transfer at tunnel MTU 1420 over a
1400 byte IPv6 path that drops longer packets.

The patch adds a BBR-style controller, `CongestionControl::Bbr`, behind the
`socket-tcp-bbr` feature (RFD 0142 O1), and cmux-wg makes it the tunnel default
(`CMUX_WG_ULTRA_CC=cubic` goes back). Its window is twice the bandwidth-delay
product: the highest delivery rate of the last 10 rounds that were not
app-limited, times the minimum RTT of the last 10 s. Startup grows the window
by every acknowledged byte, up to 2.885 times the BDP measured so far, until
the rate grows under 25 % for 3 rounds or a loss comes. A loss episode bounds
the window to 0.7 of the flight at the loss but never under the BDP, so a random
loss costs no throughput, and the bound grows one segment a round (BBRv2's
inflight_hi): a queue shallower than the BDP is not overfilled every few rounds.
A round counts at most the window it began with as delivered, so a repaired
hole, whose cumulative ACK covers data SACKed rounds ago, does not read as a
burst of bandwidth. An RTO saves the window and resends one segment
(packet conservation); the next ACK of new data brings the window back. Two RTOs
in a row, with nothing acknowledged between them, restart the model. cmux-wg paces its
datagrams itself, so the controller has no pacing gain cycle and no PROBE_RTT.
`RttEstimator` keeps its latest raw sample for the controller's minimum. Its
tests are in `congestion/bbr.rs`.

A SACK resend of the head that is lost too goes again once the peer SACKed three
segments of data sent after it (Linux's `tcp_mark_lost_retrans`). Before, it
waited for the RTO, which Karn's backoff stretched past the user timeout under
heavy loss; with a window that loss does not shrink, that failed 2 of the first 48
seeds of cmux-wg's tunnel TCP model at 12% loss. The detector is
`test_sack_lost_resend_of_the_head_goes_again_once_later_data_is_sacked`.

A keep-alive probe from the remote (one octet or none, just below the receive
window) counts as hearing from it for the user timeout. On the passive side
(the socket listened) it also pushes the socket's own next probe to 1.25
keep-alive intervals out. Upstream answered the probe but refreshed neither the
timeout nor the idle timer, so both ends of an idle connection probed on their
own clocks: two probes and two ACKs per interval. Now the active end keeps
probing, the passive end only answers, and its timeout is fed by those probes
as it was by the ACKs of its own. When the remote goes quiet the deferred probe
goes out as before. Only one side defers: probes that crossed would defer both
alike, and both would still fire together. The idle refresh that any segment
triggers never moves a deferred probe earlier: the ACK to a probe of ours that
crossed the remote's would undo the deferral. Nothing changes on the wire, so
any peer works. The detectors are
`test_remote_keep_alive_defers_ours_and_counts_as_heard`,
`test_remote_keep_alive_deferral_survives_a_crossing_ack` and
`test_remote_keep_alive_leaves_the_active_sides_beat`.

The changes are in `src/socket/tcp/congestion/cubic.rs`,
`src/socket/tcp/congestion/bbr.rs` and `src/socket/tcp.rs`, each marked
`cmux patch`, with tests next to them. Reno's own start is unchanged;
cmux does not enable it.

## Taken from upstream main

These commits are on smoltcp main but in no release yet; they are applied
unchanged:

- smoltcp-rs/smoltcp#1211 (c7595c577fed, 7d961a1af84e, 51c662c23e2b):
  per-socket `set_min_rto` and `set_initial_rto`. cmux-wg sets a 200 ms floor.
- smoltcp-rs/smoltcp#1216 (bd424c843f51): retry a fast retransmit whose
  emit failed, instead of waiting for the RTO.
- smoltcp-rs/smoltcp#1219 (bfe5f95404c0): the RTO and zero-window-probe
  timers no longer cancel each other.
- 336a1dd1aaf0: clamp a scaled receive window at the edge already
  advertised. With cmux-wg's 256 KiB buffers (window shift 3) a peer could
  otherwise send past the buffer and hit `assert!(count <= self.window())`
  (smoltcp-rs/smoltcp#1227).
- e707719e03e2: clear the keep-alive timer when keep-alive is turned off.

Remove this vendor copy when the smoltcp version used by cmux starts at the
RFC 6928 window and has these commits.
