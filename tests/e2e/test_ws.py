import asyncio
import json
import subprocess
import time

import pytest
import websockets

from protocol import b64encode, b64decode

WS_ADDR = "ws://127.0.0.1:4010"


def start_ws_server():
    return subprocess.Popen([
        "/opt/cmuxterm/cmuxd/zig-out/bin/cmuxd",
        "--ws",
        "0.0.0.0:4010",
    ])


async def recv_until(ws, predicate, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        msg = await asyncio.wait_for(ws.recv(), timeout=timeout)
        data = json.loads(msg)
        if predicate(data):
            return data
    raise TimeoutError("timeout waiting for ws message")


@pytest.mark.asyncio
async def test_ws_handshake_snapshot():
    proc = start_ws_server()
    await asyncio.sleep(0.2)
    try:
        async with websockets.connect(WS_ADDR) as ws:
            await ws.send(json.dumps({"type": "hello", "version": 1}))
            welcome = await recv_until(ws, lambda m: m.get("type") == "welcome")
            pane_id = welcome["pane_id"]

            await ws.send(json.dumps({"type": "snapshot_request", "pane_id": pane_id}))
            snap = await recv_until(ws, lambda m: m.get("type") == "snapshot")
            assert snap["cols"] == 80
            assert snap["rows"] == 24
            assert snap["data"]
    finally:
        proc.terminate()
        proc.wait(timeout=5)


@pytest.mark.asyncio
async def test_ws_ping_pong():
    proc = start_ws_server()
    await asyncio.sleep(0.2)
    try:
        async with websockets.connect(WS_ADDR) as ws:
            await ws.send(json.dumps({"type": "hello", "version": 1}))
            await recv_until(ws, lambda m: m.get("type") == "welcome")

            pong_waiter = await ws.ping()
            await asyncio.wait_for(pong_waiter, timeout=2.0)
    finally:
        proc.terminate()
        proc.wait(timeout=5)


@pytest.mark.asyncio
async def test_ws_input_output():
    proc = start_ws_server()
    await asyncio.sleep(0.2)
    try:
        async with websockets.connect(WS_ADDR) as ws:
            await ws.send(json.dumps({"type": "hello", "version": 1}))
            welcome = await recv_until(ws, lambda m: m.get("type") == "welcome")
            pane_id = welcome["pane_id"]

            payload = b"echo CMUXE2E_WS\n"
            await ws.send(json.dumps({"type": "input", "pane_id": pane_id, "data": b64encode(payload)}))

            def has_output(m):
                if m.get("type") != "output":
                    return False
                data = b64decode(m.get("data", ""))
                return b"CMUXE2E_WS" in data

            await recv_until(ws, has_output, timeout=8.0)
    finally:
        proc.terminate()
        proc.wait(timeout=5)


@pytest.mark.asyncio
async def test_ws_resize_snapshot():
    proc = start_ws_server()
    await asyncio.sleep(0.2)
    try:
        async with websockets.connect(WS_ADDR) as ws:
            await ws.send(json.dumps({"type": "hello", "version": 1}))
            welcome = await recv_until(ws, lambda m: m.get("type") == "welcome")
            pane_id = welcome["pane_id"]

            await ws.send(json.dumps({"type": "resize", "pane_id": pane_id, "cols": 120, "rows": 40}))
            await ws.send(json.dumps({"type": "snapshot_request", "pane_id": pane_id}))
            snap = await recv_until(ws, lambda m: m.get("type") == "snapshot")
            assert snap["cols"] == 120
            assert snap["rows"] == 40
    finally:
        proc.terminate()
        proc.wait(timeout=5)


@pytest.mark.asyncio
async def test_ws_new_pane_snapshot_output():
    proc = start_ws_server()
    await asyncio.sleep(0.2)
    try:
        async with websockets.connect(WS_ADDR) as ws:
            await ws.send(json.dumps({"type": "hello", "version": 1}))
            await recv_until(ws, lambda m: m.get("type") == "welcome")

            await ws.send(json.dumps({"type": "new_pane"}))
            created = await recv_until(ws, lambda m: m.get("type") == "pane_created")
            pane_id = created["pane_id"]

            await ws.send(json.dumps({"type": "snapshot_request", "pane_id": pane_id}))
            snap = await recv_until(ws, lambda m: m.get("type") == "snapshot")
            assert snap["data"]

            payload = b"echo CMUXE2E_WS_PANE\n"
            await ws.send(json.dumps({"type": "input", "pane_id": pane_id, "data": b64encode(payload)}))

            def has_output(m):
                if m.get("type") != "output":
                    return False
                data = b64decode(m.get("data", ""))
                return b"CMUXE2E_WS_PANE" in data

            await recv_until(ws, has_output, timeout=8.0)
    finally:
        proc.terminate()
        proc.wait(timeout=5)


@pytest.mark.asyncio
async def test_ws_new_pane_cwd():
    proc = start_ws_server()
    await asyncio.sleep(0.2)
    try:
        async with websockets.connect(WS_ADDR) as ws:
            await ws.send(json.dumps({"type": "hello", "version": 1}))
            await recv_until(ws, lambda m: m.get("type") == "welcome")

            await ws.send(json.dumps({"type": "new_pane", "cwd": "/tmp"}))
            created = await recv_until(ws, lambda m: m.get("type") == "pane_created")
            pane_id = created["pane_id"]

            payload = b"pwd\n"
            await ws.send(json.dumps({"type": "input", "pane_id": pane_id, "data": b64encode(payload)}))

            def has_pwd(m):
                if m.get("type") != "output":
                    return False
                data = b64decode(m.get("data", ""))
                return b"/tmp" in data

            await recv_until(ws, has_pwd, timeout=8.0)
    finally:
        proc.terminate()
        proc.wait(timeout=5)


@pytest.mark.asyncio
async def test_ws_pane_exit_event():
    proc = start_ws_server()
    await asyncio.sleep(0.2)
    try:
        async with websockets.connect(WS_ADDR) as ws:
            await ws.send(json.dumps({"type": "hello", "version": 1}))
            await recv_until(ws, lambda m: m.get("type") == "welcome")

            await ws.send(json.dumps({"type": "new_pane"}))
            created = await recv_until(ws, lambda m: m.get("type") == "pane_created")
            pane_id = created["pane_id"]

            payload = b"exit\n"
            await ws.send(json.dumps({"type": "input", "pane_id": pane_id, "data": b64encode(payload)}))

            def exited(m):
                return m.get("type") == "pane_exited" and m.get("pane_id") == pane_id

            msg = await recv_until(ws, exited, timeout=8.0)
            assert "exit_code" in msg
    finally:
        proc.terminate()
        proc.wait(timeout=5)


@pytest.mark.asyncio
async def test_ws_multiple_clients():
    proc = start_ws_server()
    await asyncio.sleep(0.2)
    try:
        async with websockets.connect(WS_ADDR) as ws1, websockets.connect(WS_ADDR) as ws2:
            await ws1.send(json.dumps({"type": "hello", "version": 1}))
            await ws2.send(json.dumps({"type": "hello", "version": 1}))

            welcome1 = await recv_until(ws1, lambda m: m.get("type") == "welcome")
            welcome2 = await recv_until(ws2, lambda m: m.get("type") == "welcome")

            await ws1.send(json.dumps({"type": "snapshot_request", "pane_id": welcome1["pane_id"]}))
            await ws2.send(json.dumps({"type": "snapshot_request", "pane_id": welcome2["pane_id"]}))

            snap1 = await recv_until(ws1, lambda m: m.get("type") == "snapshot")
            snap2 = await recv_until(ws2, lambda m: m.get("type") == "snapshot")

            assert snap1["data"]
            assert snap2["data"]
    finally:
        proc.terminate()
        proc.wait(timeout=5)
