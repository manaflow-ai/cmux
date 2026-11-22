#!/usr/bin/env python3
"""The Mac Screen two-Mac rig's helper on each Mac (see live.py): talks to a tagged app's socket.

  mini.py TAG rpc METHOD [JSON]          one call; prints the result as JSON
  mini.py TAG frames DIR SECONDS FPS     window snapshots into DIR (frame-0000.png, ...)
  mini.py TAG clicks N GAP_MS X Y        N clicks at stream pixel X,Y through debug.mac_screen input;
                                         prints one sent_ms per click
  mini.py TAG relay-only on|off          writes macScreen.debug.relayOnly into the tag's cmux.json
"""
import json, os, socket, sys, time

tag, command = sys.argv[1], sys.argv[2]
SOCKET = f"/tmp/cmux-debug-{tag}.sock"
RIG = os.path.expanduser("~/rd-hub-rig")


def rpc(method, params=None, timeout=60):
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    conn.connect(SOCKET)
    conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = conn.recv(1 << 22)
        if not chunk:
            break
        buf += chunk
    conn.close()
    reply = json.loads(buf)
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


if command == "rpc":
    try:
        print(json.dumps(rpc(sys.argv[3], json.loads(sys.argv[4]) if len(sys.argv) > 4 else {})))
    except (OSError, ValueError) as error:
        print(json.dumps({"error": str(error)}))
elif command == "frames":
    out, seconds, fps = sys.argv[3], float(sys.argv[4]), float(sys.argv[5])
    os.makedirs(out, exist_ok=True)
    start, index = time.time(), 0
    while time.time() - start < seconds:
        due = start + index / fps
        if time.time() < due:
            time.sleep(due - time.time())  # paces the capture loop; not synchronization
        rpc("debug.window_snapshot", {"path": os.path.join(out, f"frame-{index:04d}.png")})
        index += 1
    print(json.dumps({"frames": index, "seconds": round(time.time() - start, 2)}))
elif command == "clicks":
    count, gap, x, y = int(sys.argv[3]), float(sys.argv[4]) / 1000, int(sys.argv[5]), int(sys.argv[6])
    for i in range(count):
        offset = (i % 5) * 12  # a fresh point each time, so every click is its own event
        rpc("debug.mac_screen", {"action": "input", "events": [{"t": "pointer", "x": x + offset, "y": y}]})
        reply = rpc("debug.mac_screen", {"action": "input", "events": [{"t": "button", "down": True}, {"t": "button", "down": False}]})
        print(json.dumps({"i": i, "sent_ms": reply.get("sent_ms"), "error": reply.get("error")}), flush=True)
        time.sleep(gap)  # spacing between test clicks
elif command == "relay-only":
    path = os.path.join(RIG, f"state-{tag}", "cmux.json")
    try:
        with open(path) as f:
            config = json.load(f)
    except (OSError, ValueError):
        config = {}
    config.setdefault("macScreen", {}).setdefault("debug", {})["relayOnly"] = sys.argv[3] == "on"
    with open(path + ".tmp", "w") as f:
        json.dump(config, f)
    os.replace(path + ".tmp", path)
    print(json.dumps(config))
else:
    sys.exit(f"unknown command {command}")
