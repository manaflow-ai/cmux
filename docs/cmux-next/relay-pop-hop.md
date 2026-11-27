# hop/1: per-leg repair and latest-wins at our UDP relay PoP (RFD 0142 R4, R5)

Leo, 2026-11-24 08:31Z: "i wonder about not only fallback transports, but hybrid protocols. not only to be able to
access degraded or shut-off networks, but also to potentially achieve best-of-both-worlds type stuff. ..."

RFD 0142 (cmuxterm-hq `docs/rfd/0142-strip-mining-infra-relays-overlay.md`) R4 and R5, built on a relay we own.

## Why a UDP PoP, not the DO or TURN

- The link's relay path today is a Cloudflare TURN allocation (`cmux-mobile-link/src/dial/turn.rs`). We cannot add
  a sequence number, a NACK or a drop policy to Cloudflare's TURN servers.
- `LinkRelay` (the DO) carries datagrams over a WebSocket, so each of its legs is already a TCP connection that
  repairs loss at that leg's RTT. R4 on a TCP leg would be a second repair layer under TCP's. What a TCP leg cannot
  avoid is head-of-line blocking; that is only removed by a UDP leg. The DO keeps forwarding relay frames as before;
  it learns the tagged record (below) so R5's header means the same thing on every relay kind.
- So R4 and R5 run on a Rust UDP PoP (`cmux-hop-relay`), RFD 0142 Phase 2. It is a third relay candidate beside TURN
  and the DO: the dialer races it like a TURN allocation.

## Shape

```
phone ==hop/1 (lossy leg: seq, NACK, FEC, latest-wins)==> PoP --plain WireGuard UDP (or hop/1)--> Mac
```

The phone binds an allocation on the PoP (like TURN). The PoP gives it a relayed `ip:port`; the phone advertises it
as a candidate, as it does a TURN relayed address. The Mac needs no change: it sends WireGuard to the relayed
address and receives WireGuard from it. A Mac that speaks hop/1 wraps its datagrams to the relayed port in hop/1
DATA so it can tag class-1 records (R5) and the PoP repairs the Mac leg too. Plain WireGuard and hop/1 are told apart
by the first byte (WireGuard's is 1-4, STUN's top two bits are 00, hop/1's is `0xC1`).

The relay sees: WireGuard ciphertext (unchanged), the hop sequence numbers of each leg (counts and timing it could
infer anyway) and, for class-1 records only, `(stream key id, key seq)`: an opaque per-session id and a counter. It
holds no key. A receiver ignores a tag that disagrees with the authenticated inner one (the tag only steers
dropping; WireGuard's replay window rejects a replay).

## Wire format (all integers big-endian)

Every hop/1 datagram starts `[u8 0xC1][u8 type]`.

| type | name | body |
|---|---|---|
| 1 | DATA | `[u32 hop_seq][records...]` |
| 2 | NACK | `[u32 base][u64 bitmap][u32 highest][u16 loss_permille]` |
| 3 | PARITY | `[u32 first_seq][u8 count][u16 len_xor][xor bytes]` |
| 4 | BIND | `[u16 ticket_len][ticket]` |
| 5 | BIND_OK | `[u8 family 4/6][addr][u16 port][u32 lifetime_s]` |
| 6 | PING | `[u32 nonce][u32 sent_ms]` |
| 7 | PONG | `[u32 nonce][u32 sent_ms][u16 loss_permille]` |
| 8 | ERROR | `[u16 code]` |

- **DATA**: one or more records, `[u8 class][u8 flags][tag if flags & 1: u32 key, u32 key_seq][u16 len][bytes]`.
  Several records in one DATA are R5's coalescing. `hop_seq` is per leg and per direction, starts at a random value
  and increments by one per DATA; it is the unit of repair.
  - class: 0 control (handshakes, keepalives), 1 interactive state (latest-wins, tagged), 2 input, 3 bulk, 4 media.
  - Decoders refuse, in this order: a record cut short before its flags (`record_truncated`), a class above 4
    (`class`), a flag bit other than bit 0 (`flags`), a tag on a class other than 1 (`tag_class`), a tag or length cut
    short (`record_truncated`), length 0 (`empty_record`), a body past the datagram (`record_truncated`). A DATA with
    no records is `no_records`. `cmux_transport::hop::decode_records` parses a DATA body (and the relay frame's
    tagged-datagrams payload, which is the same record layout).
- **NACK**: from a leg's receiver to its sender. Bit `i` of `bitmap` asks for `base + i`. `highest` is the highest
  `hop_seq` seen; `loss_permille` the loss it measured on this leg (the sender sets its FEC rate from it).
- **PARITY**: XOR of `count` consecutive whole DATA datagrams (header included) starting at `first_seq`, each
  zero-padded to the longest; `len_xor` is the XOR of their lengths. Recovers any one of them. Sent only when the
  peer reports loss above zero (in NACK or PONG); the group size is 4 at 5% or more, 8 at 2% or more, else 16. A
  group also closes `max(5 ms, RTT / 8)` after its last DATA (the tail of a burst) and `max(5 ms, RTT / 2)` after its
  first (so its parity still beats a NACK round trip); a group of one is a copy. Never sent on the clean leg. The
  receiver keeps raw DATA for recovery (128 seqs) only while its own measured loss is above zero or for 5 s after a
  PARITY.
- **BIND / BIND_OK**: the ticket is the one `/v1/ice` mints for this session (as TURN credentials are). A rebind
  from a new address with the same ticket moves the allocation (roam keeps the relayed port).
- **PING / PONG**: leg RTT and keepalive, every 1 s whether or not DATA flows (PONG carries the loss the peer
  measured, so the sender's FEC rate follows it without a NACK). `link_stat` reports both legs' RTT and loss.

## Sender and receiver rules (sans-IO, `cmux_transport::hop`)

- The sender keeps each DATA for repair until `4 x leg RTT + 50 ms` past send (at most 2 s, so all three asks are
  covered), at most 256 KiB per leg; a NACKed seq past that, or whose records are all class-1 with a newer `key_seq`
  of their key already sent, is not resent (R5 on).
- Tail loss: a lost last DATA opens no gap the receiver sees, so the sender resends its last DATA once, `RTT +
  reorder guard` after sending it, if no DATA followed (a tail-loss probe; a duplicate when nothing was lost). Head
  loss (DATA before the first the receiver ever sees) is not repaired; the end-to-end layer (WireGuard's handshake
  retry) covers it.
- The receiver delivers records at once, out of order (WireGuard and the TCP inside it take reordering). On a gap it
  waits a reorder guard of `max(3 ms, RTT / 8)` then NACKs; it asks again after `1.5 x RTT`, at most 3 times.
  Duplicates are dropped by a 1024-seq window.
- **Latest-wins (R5)**: in a leg's egress queue, a class-1 record replaces any queued class-1 record with the same
  key and a lower `key_seq`, in the older one's place; a class-1 record whose `key_seq` is at or below one queued or
  already sent for its key is dropped. A queued record never jumps class 0 or reorders it; classes 2 to 4 are never
  dropped by R5 (each class's byte bound, 16/64/64/256/256 KiB, drops its oldest; media also expires after 250 ms).
  Classes 0, 1 and 2 go in strict order, then bulk and media share by bytes. When the queue holds more than one
  record the sender packs them into one DATA up to the leg MTU (1200).
- A leg in plain mode (toward an old Mac) sends each record as its bytes alone and classes what it receives by
  shape; the first hop/1 datagram it receives switches it to hop/1.

## Measured (deterministic sim, `cargo test -p cmux-transport --test hop_sim -- --nocapture`)

Scenario 1, phone leg 70 ms RTT + 0-10 ms jitter and 3% loss each way, Mac leg 10 ms RTT clean, 60 s, phone input
64 B / 20 ms and Mac bulk 1000 B / 5 ms, both with a 200 ms end-to-end resend (a TCP inside the tunnel):

| | input p50 / p95 / p99 | bulk p99 | end-to-end resends | phone-leg bytes |
|---|---|---|---|---|
| plain forwarder | 47 / 51 / 249 ms | 248 ms | 456 | 12.6 MB |
| hop/1 NACK only | 47 / 51 / 164 ms | 147 ms | 28 | 12.8 MB |
| hop/1 NACK + FEC | 47 / 51 / 60 ms | 61 ms | 2 | 15.7 MB |

Scenario 2, phone leg 150 ms RTT and 1% loss, the PoP's egress to the phone paced at 125 KB/s, 4 streams x 60 fps x
600 B class-1 frames (144 KB/s) plus 100 KB/s bulk, 30 s: frame delay p50 / p95 is 535 / 538 ms with R5 off and 92 /
99 ms with R5 on.

## Lockstep

hop/1 is versioned by its first byte. Old phone (no hop/1): never binds the PoP, uses TURN. Old Mac: receives plain
WireGuard from the relayed port. New Mac to old PoP: never happens (the Mac only wraps toward a port whose BIND_OK it
saw advertised as `hop`). Golden vectors in `cmux-transport/tests/vectors/hop-frames.json` are checked by the Rust
codec, the PoP and the DO's TypeScript copy of the tagged record. One case per line: `valid` yes or no, `type`, `hex`,
the decoded fields as decimal strings (`records` as `class:key:key_seq:hex`, `-` when untagged), or `error` for a
refused case; the file's `format` line gives the decode order.
