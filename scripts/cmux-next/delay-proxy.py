#!/usr/bin/env python3
"""A local HTTPS (CONNECT) proxy that delays every byte by a fixed time each way.

The dependency bench's slow link (machine-join-e2e.yml, bench=deps-slow) when the kernel has no
netem: each chunk read from either side is written to the other DELAY_MS/2 later, in order, so a
round trip costs DELAY_MS more and throughput is not capped.

    delay-proxy.py PORT DELAY_MS HOSTS_LOG

Listens on 127.0.0.1 only. Each CONNECT host is appended to HOSTS_LOG (a host name per line), so the
bench can show which tools went through it.
"""
import asyncio
import sys
import time

PORT, DELAY_MS, HOSTS_LOG = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
ONE_WAY = DELAY_MS / 2000.0


async def pump(reader, writer):
    queue = asyncio.Queue()

    async def send():
        while True:
            due, chunk = await queue.get()
            wait = due - time.monotonic()
            if wait > 0:
                await asyncio.sleep(wait)
            if chunk is None:
                break
            writer.write(chunk)
            await writer.drain()
        try:
            writer.write_eof()
        except (OSError, RuntimeError):
            pass

    sender = asyncio.ensure_future(send())
    try:
        while True:
            chunk = await reader.read(65536)
            queue.put_nowait((time.monotonic() + ONE_WAY, chunk or None))
            if not chunk:
                break
    except OSError:
        queue.put_nowait((time.monotonic(), None))
    try:
        await sender
    except OSError:
        pass


async def handle(client_reader, client_writer):
    try:
        head = await client_reader.readuntil(b"\r\n\r\n")
        method, target = head.split(b" ", 2)[:2]
        if method != b"CONNECT":
            client_writer.write(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
            await client_writer.drain()
            return
        host, _, port = target.decode("ascii").rpartition(":")
        with open(HOSTS_LOG, "a") as log:
            log.write(host + "\n")
        await asyncio.sleep(ONE_WAY * 2)  # the TCP handshake's round trip
        up_reader, up_writer = await asyncio.open_connection(host, int(port))
        client_writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await client_writer.drain()
        await asyncio.gather(pump(client_reader, up_writer), pump(up_reader, client_writer))
    except (OSError, ValueError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
        pass
    finally:
        client_writer.close()


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", PORT)
    async with server:
        await server.serve_forever()


asyncio.run(main())
