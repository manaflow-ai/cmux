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

`Socket::path_changed()` is for a tunnel whose route under the connection
changed (cmux-wg calls it when its multipath underlay leaves the path that
carried the session, or the peer roams). With data unacknowledged, the socket
resends from the oldest unacknowledged byte at its next poll, as an RTO would,
slow start included, but its RTO returns to the RTT estimate's value instead of
doubling: the losses were the old route's. With nothing in flight it does
nothing.

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
