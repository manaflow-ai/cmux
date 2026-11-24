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
- **NACK**: from a leg's receiver to its sender. Bit `i` of `bitmap` asks for `base + i`. `highest` is the highest
  `hop_seq` seen; `loss_permille` the loss it measured on this leg (the sender sets its FEC rate from it).
- **PARITY**: XOR of `count` consecutive DATA datagrams starting at `first_seq`, each zero-padded to the longest;
  `len_xor` is the XOR of their lengths. Recovers any one of them. Sent only when the leg's loss is above zero; the
  rate (one PARITY per `count` DATA) is set from the reported loss. Never sent on the clean leg.
- **BIND / BIND_OK**: the ticket is the one `/v1/ice` mints for this session (as TURN credentials are). A rebind
  from a new address with the same ticket moves the allocation (roam keeps the relayed port).
- **PING / PONG**: leg RTT and keepalive, every 1 s when idle. `link_stat` reports both legs' RTT and loss.

## Sender and receiver rules (sans-IO, `cmux_transport::hop`)

- The sender keeps each DATA for repair until `max(2 x leg RTT, 50 ms)` past send, at most 256 KiB per leg; a
  NACKed seq past that, or whose records are all superseded class-1, is not resent.
- The receiver delivers records at once, out of order (WireGuard and the TCP inside it take reordering). On a gap it
  waits a reorder guard of `max(3 ms, RTT / 8)` then NACKs; it asks again after `1.5 x RTT`, at most 3 times.
  Duplicates are dropped by a 1024-seq window.
- **Latest-wins (R5)**: in a leg's egress queue, a class-1 record replaces any queued class-1 record with the same
  key and a lower `key_seq`. A queued record never jumps class 0 or reorders it; classes 2 and 3 are never dropped
  by R5 (the queue's byte bound still applies as in `class_queue.rs`). When the queue holds more than one record the
  sender packs them into one DATA up to the leg MTU.

## Lockstep

hop/1 is versioned by its first byte. Old phone (no hop/1): never binds the PoP, uses TURN. Old Mac: receives plain
WireGuard from the relayed port. New Mac to old PoP: never happens (the Mac only wraps toward a port whose BIND_OK it
saw advertised as `hop`). Golden vectors in `cmux-transport/tests/vectors/hop-frames.json` are checked by the Rust
codec, the PoP and the DO's TypeScript copy of the tagged record.
