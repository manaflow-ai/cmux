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
As a receiver, an ACK now carries up to three SACK blocks, not one: the block of
the segment that triggered it, then the lowest others. cmux-wg turns recovery
on, and builds smoltcp with a 32-range assembler
(`assembler-max-segment-count-32`): with the default 4, a receiver dropped every
out-of-order segment past its fourth hole.

CUBIC tells random loss from congestion. Before a fast retransmit or a SACK
episode cuts, the socket asks `Controller::loss_is_congestion`. Out of slow
start, CUBIC answers no when two things hold. No queue: neither the smoothed
RTT nor the newest sample is past min RTT / β (one segment is timed per round
trip and srtt moves 1/8 a sample, so a queue slow start built shows in the
newest sample about eight round trips before srtt). Sparse: segments delivered
per segment lost are at least 50, the 2% loss BBRv2 tolerates: the average loss
interval (RFC 5348's loss event rate, smoothed 3/4 old, 1/4 new) over the
average segments a SACK episode lost (`Controller::on_recovery_end`, the most
bytes the episode had lost at once). Random loss takes about one segment an
event; a shallow buffer, whose queue is too short to show in the RTT, drops a
run of them, and the next losses cut. A loss in slow start always ends it
(left doubling, slow start overshoots any buffer), and an RTO resets the loss
history, so the losses after it cut until they are sparse again. A random loss
is resent and cuts nothing. RTOs still cut. Every cut, an RTO's included, has
a floor (Westwood+, Mascolo et al. 2001; Linux `tcp_westwood`): ssthresh is
`max(β × flight, rate × min RTT)`, capped at the window, where `rate` is the
delivery rate (bytes ACKed per smoothed round trip, smoothed 7/8 old, 1/8
new). On a full bottleneck the RTT has grown past its minimum, so the floor is
under the flight and the usual β cut drains the queue.

Without it, a 60 fps screen stream at 50 ms and 2% loss, or 150 ms and 1%, was
cut every two or three round trips to below its own rate and ran seconds
behind. The before/after numbers, and the bottleneck rows that keep it honest
(a 20 Mbit/s, 50 ms bottleneck with a one-RTT and a quarter-RTT queue), are in
the PR that added it (cmux#45105). `path_changed()` forgets the minimum RTT, so
the old route's round trip is no floor for the new one. The detectors are
`random_loss_keeps_the_delivered_window`, `queue_loss_still_cuts`,
`slow_start_overshoot_cuts_before_srtt_catches_up`,
`slow_start_loss_is_congestion`, `rto_resets_the_loss_history`,
`burst_losses_are_congestion` and `sparse_random_loss_is_not_congestion`.

`Socket::path_changed()` is for a tunnel whose route under the connection
changed (cmux-wg calls it when its multipath underlay leaves the path that
carried the session, or the peer roams). With data unacknowledged, the socket
resends from the oldest unacknowledged byte at its next poll, as an RTO would,
slow start included, but its RTO returns to the RTT estimate's value instead of
doubling: the losses were the old route's. With nothing in flight it does
nothing.

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

The changes are in `src/socket/tcp/congestion/cubic.rs` and `src/socket/tcp.rs`,
each marked `cmux patch`, with tests next to them. Reno's own start is unchanged;
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
