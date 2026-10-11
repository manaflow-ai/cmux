#!/usr/bin/env python3
"""TCP proxy that adds a one-way delay per direction (ordered). delayproxy.py <listen_port> <host> <port> <one_way_ms>"""
import asyncio, sys

LP, H, P, D = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), float(sys.argv[4]) / 1000

async def pump(reader, writer):
    q = asyncio.Queue(); loop = asyncio.get_running_loop()
    async def rd():
        while True:
            b = await reader.read(65536)
            await q.put((loop.time() + D, b))
            if not b: return
    async def wr():
        while True:
            due, b = await q.get()
            dt = due - loop.time()
            if dt > 0: await asyncio.sleep(dt)
            if not b: writer.close(); return
            writer.write(b); await writer.drain()
    await asyncio.gather(rd(), wr(), return_exceptions=True)

async def handle(cr, cw):
    sr, sw = await asyncio.open_connection(H, P)
    await asyncio.gather(pump(cr, sw), pump(sr, cw), return_exceptions=True)

async def main():
    s = await asyncio.start_server(handle, "127.0.0.1", LP)
    async with s: await s.serve_forever()

asyncio.run(main())
