# wan-pair: one cmux.rd link session between a lane VM and a fleet Mac

Measures Linux to Mac and Mac to Linux over the WAN: key to glass, first frame and bandwidth, on
the product's secure link (STUN, direct path). The device hub's signaling is played by `pair.py`
and carried over `udprel.py`, a small reliable UDP channel to the VM's public address, because a
lane VM and a fleet Mac share no reachable tailnet port.

Both ends need a `cmux-rd` bench build from the same SHA (NIGHTLY's bundled `cmux rd` has only
the `link` feature). From `cmux-tui/crates/cmux-rd-host`:

    cargo build --release --bin cmux-rd --no-default-features --features bench,openh264,link

## Run

On the Mac (lease it first; it forks and logs to `~/ssl3/agent.log`):

    python3 mac_agent.py VM_PUBLIC_IP:4104 TOKEN /path/to/cmux-rd [MINUTES]

On the VM, with Xvfb on `:99` and `cmux-rd testapp --display :99 --workload marker` (or
`--workload motion` for bandwidth):

    PAIR_TOKEN=TOKEN python3 pair.py l2m --out results.jsonl -- --input key --samples 100
    PAIR_TOKEN=TOKEN python3 pair.py m2l --fwd --fwd-only --mac-source synthetic-still \
        --serve-arg=--profile --serve-arg=baseline --out results.jsonl -- --input key --samples 100

Bandwidth: `-- --input none --duration-s 20`, with `--workload motion` on the Linux host or
`--mac-source synthetic-tick --serve-arg=--synthetic-scene --serve-arg=churn` on the Mac;
Mbit/s is `bytes * 8 / duration`.

## Two things Mac to Linux needs today

- `--fwd`: a Mac behind a NAT that maps per destination (a fleet Mac's site NAT) gives its socket one
  port toward STUN and another toward the VM. The Mac host is the link's responder, and its punches
  do not authenticate, so the Linux viewer never learns the port that works (`secure handshake
  timed out ... heard 0`). `punchfwd.py` binds a public port on the VM, tells the Mac host
  `srflx VM_PUBLIC_IP:4105`, and passes the link's sealed packets to the viewer on 127.0.0.1.
  Linux to Mac needs nothing: the Mac is the initiator there.
- `--profile baseline` on the Mac host: an OpenH264 viewer decodes the default VideoToolbox
  profile's IDR and then gets every P-frame wrong with `decode_errors 0` (39 of 40 keys lost).

Results from 2026-11-22: cmuxterm-hq#14231.
