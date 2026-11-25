#!/usr/bin/env python3
"""A UDP forwarder on the viewer VM for a host behind a NAT that maps per destination.

The Mac host's NAT gives it one port toward STUN (its srflx) and another toward this VM, and the
link's responder punches do not authenticate, so the viewer never learns the port that works.
This binds PUBLIC_PORT on every address (the Mac host is told `srflx PUBLIC_IP:PUBLIC_PORT`) and
127.0.0.1:LOCAL_PORT (the viewer is told `host 127.0.0.1:LOCAL_PORT`), and passes datagrams
between the last source heard on each. Every packet is still the link's own sealed packet.

  punchfwd.py PUBLIC_PORT LOCAL_PORT SECONDS
"""
import select, socket, sys, time

pub_port, loc_port, secs = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
pub = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
pub.bind(("0.0.0.0", pub_port))
loc = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
loc.bind(("127.0.0.1", loc_port))
mac = viewer = None
counts = {"to_viewer": 0, "to_mac": 0, "dropped": 0}
end = time.time() + secs
while time.time() < end:
    r, _, _ = select.select([pub, loc], [], [], 0.5)
    for s in r:
        data, addr = s.recvfrom(65535)
        if s is pub:
            if mac != addr:
                print("mac at", addr, file=sys.stderr, flush=True)
            mac = addr
            if viewer:
                loc.sendto(data, viewer); counts["to_viewer"] += 1
            else:
                counts["dropped"] += 1
        else:
            viewer = addr
            if mac:
                pub.sendto(data, mac); counts["to_mac"] += 1
            else:
                counts["dropped"] += 1
print(counts, file=sys.stderr, flush=True)
