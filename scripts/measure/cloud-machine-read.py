#!/usr/bin/env python3
"""Compare two built cmux binaries through the same fake-provider file-read route.

Run on the test fleet with GNU time, after building each revision:
  python3 scripts/measure/cloud-machine-read.py --before /tmp/cmux-before --after /tmp/cmux-after

The provider produces bounded ranges; only the measured CLI process's peak RSS is
reported. This measures local transport/encoding work, not real network latency.
"""

import argparse
import base64
import json
import os
import pathlib
import shlex
import signal
import statistics
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True, type=pathlib.Path)
    parser.add_argument("--after", required=True, type=pathlib.Path)
    parser.add_argument("--bytes", type=int, default=64 * 1024 * 1024 + 17)
    parser.add_argument("--samples", type=int, default=3)
    args = parser.parse_args()
    if args.bytes < 0 or args.samples < 1:
        parser.error("bytes must be nonnegative and samples must be positive")
    block = bytes(range(251)) * ((4 * 1024 * 1024) // 251 + 1)

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if self.path.endswith("/client-session"):
                body = {"ok": True, "value": {
                    "machine": "vm_abcdefghij0123456789", "vm_id": "benchmark-vm",
                    "linux_user": "cmux", "token": "benchmark-token",
                    "expires_at": int(time.time() * 1000) + 900_000,
                    "api_base_url": f"http://127.0.0.1:{self.server.server_port}",
                    "ssh": None,
                }}
            else:
                command = shlex.split(request["command"])
                if command[3] != "read":
                    raise ValueError("the benchmark only serves ranged reads")
                offset, length = map(int, command[-2:])
                if not 0 <= offset <= args.bytes or not 0 < length <= 4 * 1024 * 1024:
                    raise ValueError("unexpected read range")
                payload = block[:min(length, args.bytes - offset)]
                body = {"statusCode": 0, "stderr": "", "stdout": json.dumps({
                    "path": "/benchmark.bin", "size": len(payload),
                    "total": args.bytes, "version": "benchmark-v1",
                    "dataBase64": base64.b64encode(payload).decode("ascii"),
                })}
            encoded = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    server = HTTPServer(("127.0.0.1", 0), Provider)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    measurements = {"before": [], "after": []}
    try:
        with tempfile.TemporaryDirectory(prefix="cmux-read-benchmark-") as scratch:
            for sample in range(args.samples):
                for name in ("before", "after"):
                    binary = getattr(args, name).resolve()
                    receipt = pathlib.Path(scratch) / f"{name}-{sample}.time"
                    request = json.dumps({
                        "api": f"http://127.0.0.1:{server.server_port}",
                        "credential": "benchmark-credential", "team": "team_benchmark",
                        "machine": "vm_abcdefghij0123456789", "op": "read",
                        "path": "/benchmark.bin",
                        "cache_dir": f"{scratch}/{name}-{sample}-cache",
                    }).encode()
                    command = (
                        ["/usr/bin/time", "-f", "%e\t%M", "-o", str(receipt),
                         str(binary), "cloud", "machine-io"]
                    )
                    with subprocess.Popen(command, stdin=subprocess.PIPE,
                                          stdout=subprocess.DEVNULL, start_new_session=True) as child:
                        try:
                            child.communicate(input=request, timeout=180)
                        except subprocess.TimeoutExpired:
                            os.killpg(child.pid, signal.SIGKILL)
                            child.communicate()
                            raise
                        if child.returncode:
                            raise subprocess.CalledProcessError(child.returncode, command)
                    elapsed, rss = receipt.read_text().strip().split("\t")
                    measurements[name].append({"seconds": float(elapsed), "peak_rss_kib": int(rss)})
    finally:
        server.shutdown()
        worker.join(timeout=5)
        server.server_close()
    result = {"payload_bytes": args.bytes, "samples": measurements}
    for metric in ("seconds", "peak_rss_kib"):
        before = statistics.median(row[metric] for row in measurements["before"])
        after = statistics.median(row[metric] for row in measurements["after"])
        result[metric] = {"before": before, "after": after, "delta": after - before}
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
