/**
 * The baked daemon's full `identify` answer (version, build commit, every capability), read on the
 * guest over the daemon socket that the bake records in /etc/cmux/daemon-socket. The bake stores it
 * in its result (and the channel history records it), so scripts/cmux-next/release/image-staleness.ts
 * compares an image with the tip's capability list without a VM. The smoke reads it again on a
 * fresh clone. `cmux host cloud daemon-info` is not enough: it keeps only the Cloud role's subset.
 */
import { DEVBOX_WORK_USER } from "../../services/vms/images/workUser";

/** Sent as the work user (the daemon's owner); prints one `IDENTIFY_JSON {...}` line. */
const PROBE = `
import json, socket, sys
path = open("/etc/cmux/daemon-socket").read().strip()
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(15)
sock.connect(path)
sock.sendall(b'{"id":1,"cmd":"identify"}\\n')
buffer = b""
while True:
    while b"\\n" not in buffer:
        chunk = sock.recv(1 << 20)
        if not chunk:
            sys.exit("socket closed before the identify reply")
        buffer += chunk
    line, buffer = buffer.split(b"\\n", 1)
    message = json.loads(line)
    if message.get("id") == 1:
        break
if not message.get("ok"):
    sys.exit("identify failed: %s" % message.get("error"))
data = message.get("data") or {}
print("IDENTIFY_JSON " + json.dumps({"socket": path, "version": data.get("version"), "build_commit": data.get("build_commit"), "capabilities": sorted(set(data.get("capabilities") or []))}))
`;

export function daemonIdentifyCommand(): string {
  const b64 = Buffer.from(PROBE).toString("base64");
  return `test -s /etc/cmux/daemon-socket && printf '%s' ${b64} | base64 -d > /tmp/cmux-identify.py && chmod 0644 /tmp/cmux-identify.py && sudo -n -u ${DEVBOX_WORK_USER} python3 /tmp/cmux-identify.py; rc=$?; rm -f /tmp/cmux-identify.py; exit $rc`;
}

export type DaemonIdentify = { socket: string; version: string | null; build_commit: string | null; capabilities: string[] };

export function parseDaemonIdentify(stdout: string): DaemonIdentify {
  const line = stdout.split("\n").find((l) => l.startsWith("IDENTIFY_JSON "));
  if (!line) throw new Error(`no IDENTIFY_JSON line: ${stdout.trim().slice(-300)}`);
  const parsed = JSON.parse(line.slice("IDENTIFY_JSON ".length)) as DaemonIdentify;
  if (!Array.isArray(parsed.capabilities) || parsed.capabilities.length === 0) throw new Error(`identify answered no capabilities: ${line.slice(0, 300)}`);
  return parsed;
}
