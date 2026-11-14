#!/bin/bash
# The Cloud late-attach harness (cmux-server attach_harness_request).
# Usage: unshare -rn scripts/cloud-attach-harness.sh TEST_BINARY ATTACH_SECONDS
# (or sudo -n unshare -n). Runs inside a fresh network namespace. A dummy link (it drops every packet)
# carries 10.9.9.0/24, so a connect to 10.9.9.1 hangs, as one sent before a
# fresh machine's network attach. At ATTACH seconds 10.9.9.1 goes onto lo,
# where a server answers 200; the next SYN connects.
set -euo pipefail
bin=$1; attach=$2
ip link set lo up
ip link add d0 type dummy; ip link set d0 up; ip addr add 10.9.9.2/24 dev d0
python3 -c '
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n=int(self.headers.get("content-length",0)); self.rfile.read(n)
        b=b"{\"ok\":true}"; self.send_response(200); self.send_header("content-length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
http.server.HTTPServer(("0.0.0.0",8080),H).serve_forever()' &
srv=$!
( sleep "$attach"; ip addr add 10.9.9.1/32 dev lo ) &
CMUX_ATTACH_URL=http://10.9.9.1:8080/bind "$bin" --ignored --exact cloud_http::tests::attach_harness_request --nocapture 2>&1 | grep attach-harness
kill $srv
