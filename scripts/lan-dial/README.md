# lan-dial: background jobs reach the LAN on macOS

macOS Local Network privacy refuses a LAN connection (`EHOSTUNREACH`, or a timeout) from any program that launchd,
a CI runner or a fleet worker started, unless that program holds a grant, and on the fleet Macs no grant can be
given ahead of time (no user-approved MDM, ad hoc signed builds, a new worker binary each release). Until now each
tool worked around it on its own: a socket-activated `/usr/bin/nc` per fixed destination, glaeda's lan-fetch
broker with one verb, or Apple's `/usr/bin/python3`, which macOS 27 no longer lets through (macOS 27.0.1,
measured 2026-11-23). Under a runner even Apple's `nc` and `ssh` are refused: the runner is the responsible program for
its whole process tree.

lan-dial is one protocol for all of them. A launchd job rooted on Apple's `/bin/sh`, socket-activated on an
owner-only Unix socket, makes each connection with Apple's `/usr/bin/nc`; it is launchd's child, not the caller's,
so who started the caller does not matter, and a Unix socket is not a Local Network connection.

## The protocol

1. Connect to the relay's socket (`~/.local/state/cmux/lan-dial/relay.sock`, mode 0600).
2. Send one line: `CONNECT HOST PORT\n` (`\r\n` is fine).
3. Read one line: `OK`, or `ERR <why>` and the relay closes.
4. After `OK` the socket is the TCP stream to HOST:PORT, both ways, until either side closes. A peer that is down
   or refuses shows as end of stream right after `OK`.

Anything that speaks a Unix socket can use it: any Python, Rust, Go, `nc -U`. The relay (`relay.sh`) checks only
that HOST is a name or address and PORT a port; the job runs as the socket's owner and only the owner can connect,
so it gives a caller nothing it could not do by loading its own launchd job.

## Use

```sh
python3 scripts/lan-dial/lan_dial.py probe 192.168.1.20 8080 --send 'GET /stats HTTP/1.0\r\n\r\n'
python3 scripts/lan-dial/lan_dial.py http http://192.168.1.20:8080/stats
ssh -o ProxyCommand='python3 scripts/lan-dial/lan_dial.py connect %h %p' me@192.168.1.30
```

```python
sys.path.insert(0, "scripts/lan-dial")
import lan_dial
sock = lan_dial.dial("192.168.1.20", 8080)   # direct first; the relay when privacy refuses it
```

Nothing needs installing first: the first dial that is refused runs `lan_dial.py up`, which writes the relay's
script and plist under `~/.local/state/cmux/lan-dial/` and bootstraps it into `system` (root), else `gui/UID`,
else `user/UID`. `up` again refreshes a changed relay; `down` unloads it and removes its files; `status` reads it.
`--via direct|relay` (or `LAN_DIAL_VIA`) picks a route outright.

## Evidence

- `tests/test_lan_dial.py`: the protocol end to end on Linux under both `dash` and `bash` (macOS's `/bin/sh`),
  with a stand-in for launchd's socket activation: the stream after `OK` both ways (a greeting the peer sends
  first is not eaten), bad request lines refused, a down peer, the auto fallback after `EHOSTUNREACH`, HTTP.
- `demo.sh`: on a fleet Mac, from a fleet step, `--via direct` then `--via relay` against an office-LAN HTTP
  service with a Python that is not Apple's; `demo.json` holds both sides.
