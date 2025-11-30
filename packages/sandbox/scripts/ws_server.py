import asyncio
import struct
import hashlib
import base64
import sys

async def handle_client(reader, writer):
    try:
        # Handshake
        data = await reader.readuntil(b"\r\n\r\n")
        headers = data.decode().split("\r\n")
        key = None
        for h in headers:
            if h.lower().startswith("sec-websocket-key:"):
                key = h.split(":")[1].strip()
        
        if not key:
            writer.close()
            return

        accept_key = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        resp = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept_key}\r\n\r\n"
        )
        writer.write(resp.encode())
        await writer.drain()

        # Simple Echo Loop
        while True:
            byte1 = await reader.read(1)
            if not byte1: break
            b1 = byte1[0]
            opcode = b1 & 0x0f
            
            byte2 = await reader.read(1)
            b2 = byte2[0]
            mask = b2 & 0x80
            payload_len = b2 & 0x7f
            
            if payload_len == 126:
                data = await reader.read(2)
                payload_len = struct.unpack("!H", data)[0]
            elif payload_len == 127:
                data = await reader.read(8)
                payload_len = struct.unpack("!Q", data)[0]
            
            mask_key = None
            if mask:
                mask_key = await reader.read(4)
            
            payload = await reader.read(payload_len)
            if mask:
                payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
            
            if opcode == 8: # Close
                break
            
            if opcode == 1: # Text
                # Echo back (server to client usually not masked)
                resp_header = bytearray([0x81])
                if len(payload) < 126:
                    resp_header.append(len(payload))
                elif len(payload) < 65536:
                    resp_header.append(126)
                    resp_header.extend(struct.pack("!H", len(payload)))
                else:
                    resp_header.append(127)
                    resp_header.extend(struct.pack("!Q", len(payload)))
                
                writer.write(resp_header)
                writer.write(payload)
                await writer.drain()
    except Exception as e:
        pass
    finally:
        writer.close()

async def main():
    server = await asyncio.start_server(handle_client, '0.0.0.0', 8765)
    print("WS Server running on 8765", file=sys.stderr)
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass