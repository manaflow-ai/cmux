#!/usr/bin/env python3
"""Send one request to a tagged cmux-next app's debug socket and print its result.

    app-rpc.py SOCKET METHOD [PARAMS_JSON]

The socket speaks JSON lines: {"id":1,"method":...,"params":...} in, one
{"id":1,"result":...} line out (scripts/cmux-debug-cli.sh's `rpc` does the
same). The bench needs this because the bundled bin/cmux is the cmux-tui
binary, which has no command for the app's debug methods. Prints the result
as JSON; prints the whole reply and exits 1 when the app answers with an error
or the socket does not answer.
"""

from __future__ import annotations

import json
import socket
import sys


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    path, method = argv[1], argv[2]
    params = json.loads(argv[3]) if len(argv) == 4 else {}
    request = {"id": 1, "method": method, "params": params}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(60)
            client.connect(path)
            client.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode())
            reply = bytearray()
            while not reply.endswith(b"\n"):
                chunk = client.recv(65536)
                if not chunk:
                    break
                reply.extend(chunk)
    except OSError as error:
        print(json.dumps({"error": f"{path}: {error}"}))
        return 1
    try:
        response = json.loads(reply)
    except ValueError:
        print(json.dumps({"error": "not JSON", "reply": reply.decode(errors="replace").strip()}))
        return 1
    if isinstance(response, dict) and (response.get("ok") is False or "result" not in response):
        # ControlWire's failure reply: {"id":..,"ok":false,"error":{code,message}}.
        print(json.dumps(response, separators=(",", ":")))
        return 1
    print(json.dumps(response["result"] if isinstance(response, dict) else response, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
