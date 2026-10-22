#!/usr/bin/env python3
"""Expose a direct dev-backend stack's MCP server to ChatGPT through a public tunnel.

ChatGPT calls the MCP server and OAuth token endpoint from its own servers, so
it needs a public HTTPS origin. The dev-backend gateway routes by its tailnet
host, so this proxy sits between `cloudflared` and the stack: it sends the
stack's own Host and names the tunnel in `x-cmux-public-origin`, which a dev
stack (only) uses as the OAuth issuer. The browser still signs in on the
tailnet host.

    cloudflared tunnel --no-autoupdate --url http://127.0.0.1:8790   # prints https://NAME.trycloudflare.com
    python3 scripts/mcp-dev-tunnel.py --stack https://cmux-dev-backend-1.tail137216.ts.net:4569 \\
        --public https://NAME.trycloudflare.com --port 8790

Then add https://NAME.trycloudflare.com/api/mcp in ChatGPT Developer mode.
"""

import argparse
import http.client
import http.server
import re
import ssl
import urllib.parse

HOP_BY_HOP = {"connection", "keep-alive", "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade", "host"}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stack", required=True, help="the stack's tailnet URL, https://HOST.ts.net:PORT")
    parser.add_argument("--public", required=True, help="the tunnel origin, https://NAME.trycloudflare.com")
    parser.add_argument("--port", type=int, default=8790)
    args = parser.parse_args()
    stack = urllib.parse.urlsplit(args.stack)
    if stack.scheme != "https" or not stack.hostname or not stack.hostname.endswith(".ts.net"):
        parser.error("--stack must be the stack's https tailnet URL")
    public = args.public.rstrip("/")
    if not re.fullmatch(r"https://[a-z0-9-]+\.trycloudflare\.com", public):
        parser.error("--public must be https://NAME.trycloudflare.com")
    stack_host = stack.netloc
    context = ssl.create_default_context()

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def forward(self) -> None:
            length = int(self.headers.get("content-length") or 0)
            body = self.rfile.read(length) if length else None
            headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
            headers["Host"] = stack_host
            headers["x-cmux-public-origin"] = public
            upstream = http.client.HTTPSConnection(stack.hostname, stack.port or 443, context=context, timeout=300)
            try:
                upstream.request(self.command, self.path, body=body, headers=headers)
                response = upstream.getresponse()
                self.send_response(response.status, response.reason)
                for key, value in response.getheaders():
                    if key.lower() not in HOP_BY_HOP and key.lower() != "content-length":
                        self.send_header(key, value)
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                # Stream: MCP responses may be server-sent events.
                while chunk := response.read1(65536):
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
            except (OSError, http.client.HTTPException) as error:
                self.log_error("upstream failed: %s", error)
                self.close_connection = True
            finally:
                upstream.close()

        do_GET = do_POST = do_DELETE = do_OPTIONS = do_HEAD = forward

    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"{public} -> {args.stack} on 127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
