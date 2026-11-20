#!/usr/bin/env bash
# Serves the email code AutoFill live-check page over https on 127.0.0.1:8443 with a throwaway
# self-signed certificate. The dev build maps login.otp-check.test to 127.0.0.1 and accepts the
# certificate through CMUX_NEXT_CEF_EXTRA_SWITCHES (debug builds only):
#   CMUX_NEXT_CEF_EXTRA_SWITCHES="host-resolver-rules=MAP *.otp-check.test 127.0.0.1:ignore-certificate-errors"
# and reads mail.json as its mailbox (CMUX_NEXT_VERIFICATION_FIXTURE_MAIL); opt in you@example.com in
# Settings > Browser > Passwords, then open https://login.otp-check.test:8443/ as a person does
# (`open -a <app> URL`, or the omnibar): a tab opened over the socket (`cmux open`) is agent-driven
# and never gets an offer.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=login.otp-check.test" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1
cd "$HERE"
exec python3 -I -c '
import http.server, ssl, sys
server = http.server.ThreadingHTTPServer(("127.0.0.1", 8443), http.server.SimpleHTTPRequestHandler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
' "$WORK/cert.pem" "$WORK/key.pem"
