#!/usr/bin/env python3
"""Writes the seed corpora of the batch 6 byte-layout fuzz targets
(p10-stability-181): the app host script session in cmux-tui/fuzz, the
mobile host's frame decoders in cmux-next-ios/rust/fuzz and the OptChat
Chief's request and transcript parsers in Native/OptChat/fuzz.

Run from anywhere: python3 cmux-tui/fuzz/seeds/batch6.py
Seeds go to <fuzz dir>/corpus/<target>/seed-NN. Each seed follows its
target's input layout (see the doc comment of fuzz_targets/<target>.rs).
The two browser host targets take structured (`arbitrary`) input; their
seeds are a minimized corpus of a short run, not written here.
"""

import json
import pathlib
import shutil
import struct

REPO = pathlib.Path(__file__).resolve().parents[3]
TUI_FUZZ = REPO / "cmux-tui/fuzz"
MOBILE_FUZZ = REPO / "cmux-next-ios/rust/fuzz"
OPTCHAT_FUZZ = REPO / "Native/OptChat/fuzz"

# cmux-rd-proto stream.rs: u8 type, u32 LE length, payload.
STREAM_CONTROL, STREAM_DATAGRAM, STREAM_BULK = 1, 2, 3
RB = "rb/1"


def write(fuzz_dir, target, seeds):
    folder = fuzz_dir / "corpus" / target
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    for index, seed in enumerate(seeds):
        data = seed.encode() if isinstance(seed, str) else bytes(seed)
        (folder / f"seed-{index:02}").write_bytes(data)


def lines(*values):
    return "".join(json.dumps(value, separators=(",", ":")) + "\n" for value in values)


def app_host_script_session():
    return [
        lines({"t": "ready", "runtime": "1.0.0"}),
        lines({"t": "init-failed", "error": "SyntaxError: unexpected token"}),
        lines(
            {"t": "ready", "runtime": "1.0.0"},
            {"t": "call", "cb": 1, "name": "workspace.list", "params": {}, "options": {}},
            {"t": "call", "cb": 2, "name": "pane.split", "params": {"pane": "p1"}, "options": {"gesture": None}},
            {"t": "log", "level": "info", "message": "hello"},
            {"t": "done", "cb": 1, "ok": True, "body": {"value": 3}},
        ),
        lines(
            {"t": "subscribe", "sub": 1, "stream": "resource.changed", "filter": {}},
            {"t": "subscribe", "sub": 2, "stream": "resource.changed", "filter": None},
            {"t": "unsubscribe", "sub": 1},
            {"t": "scene", "mount": "m", "ops": []},
            {"t": "mounted", "mount": "m"},
        ),
        lines({"t": "done", "cb": 7, "ok": False, "body": {"code": "script.error", "message": "boom"}},
              {"t": "fatal", "reason": "memory", "entry": "eval"}),
        lines({"t": "fatal", "reason": "interrupt", "entry": "run"}),
        # A cut-off last line, and a line that is not a message.
        lines({"t": "ready", "runtime": "1"}) + '{"t":"call","cb":3',
        '{"t":"nope"}\n',
        "".join(
            json.dumps({"t": "call", "cb": n, "name": "op", "params": n, "options": {}}) + "\n"
            for n in range(80)
        ),
    ]


def stream_frame(kind, payload):
    if isinstance(payload, (dict, list)):
        payload = json.dumps(payload, separators=(",", ":")).encode()
    return struct.pack("<BI", kind, len(payload)) + payload


def rb(body):
    return stream_frame(STREAM_CONTROL, {"t": "service", "service": RB, "body": body})


def phone_and_host(phone, host):
    # mobile_host_phone_stream: u16 LE length of the phone's bytes, the
    # phone's bytes, the host's; each side in chunks (a length byte, then that
    # many bytes; a length of 0 takes the rest of the side).
    phone = b"\x00" + phone if phone else b""
    host = b"\x00" + host if host else b""
    return struct.pack("<H", len(phone)) + phone + host


def mobile_host_phone_stream():
    phone = [
        rb({"t": "rb.open", "url": "https://cmux.dev"}),
        rb({"t": "rb.navigate", "url": "https://example.com/"}),
        rb({"t": "rb.navigate"}),
        rb({"t": "rb.visibility", "visible": False}),
        rb({"t": "rb.screen", "w": 390, "h": 844, "scale": 3}),
        rb({"t": "rb.page", "url": "file:///etc/passwd"}),
        stream_frame(STREAM_CONTROL, {"t": "hello", "token": "00", "service": RB}),
        stream_frame(STREAM_CONTROL, {"t": "stop"}),
        stream_frame(STREAM_CONTROL, {"e": "pointer", "kind": "down", "x": 0.5, "y": 2.0}),
        stream_frame(STREAM_CONTROL, {"e": "ime_commit", "text": "héllo\n"}),
        stream_frame(STREAM_CONTROL, {"e": "key", "code": "Enter", "down": True}),
        stream_frame(STREAM_DATAGRAM, bytes([0x10, 4, 0, 0, 0, 0, 0, 0])),
        stream_frame(STREAM_BULK, b"bulk"),
    ]
    host = [
        rb({"t": "rb.page", "url": "https://example.com/", "can_go_back": True}),
        rb({"t": "rb.page", "url": "file:///Users/me/secret.txt"}),
        stream_frame(STREAM_DATAGRAM, bytes(16)),
    ]
    return [
        phone_and_host(b"".join(phone), b"".join(host)),
        phone_and_host(phone[1], host[0]),
        phone_and_host(phone[6] + phone[3], b""),
        # Trickled one byte per read.
        struct.pack("<H", 2 * len(phone[0])) + b"".join(b"\x01" + bytes([b]) for b in phone[0]),
        # An unknown frame type: the stream is broken from there.
        phone_and_host(stream_frame(STREAM_CONTROL, {"t": "stop"}) + b"\x09\x00\x00\x00\x00", b""),
        # A length past the frame limit.
        phone_and_host(b"\x01\xff\xff\xff\x7f", b""),
    ]


def source_frame(kind, payload):
    return struct.pack(">BI", kind, len(payload)) + payload


def chunked(data, size):
    return b"".join(bytes([len(data[i:i + size])]) + data[i:i + size] for i in range(0, len(data), size))


def mobile_host_source_frames():
    size = source_frame(1, b'{"t":"size","width":1179,"height":2556}')
    unit = source_frame(2, b"\x01" + struct.pack(">Q", 123456) + b"\x00\x00\x00\x01\x65\x88")
    error = source_frame(1, b'{"t":"error","message":"no booted simulator"}')
    return [
        b"\x00" + size + unit,
        b"\x00" + error,
        chunked(size + unit + unit, 3),
        b"\x00" + source_frame(2, b"\x00\x01"),
        b"\x00" + source_frame(3, b""),
        b"\x00" + b"\x01\x7f\xff\xff\xff",
        b"\x00" + source_frame(1, b"not json"),
    ]


def mobile_host_control_line():
    return [
        lines({"type": "token", "token": "eyJhbGciOi"}),
        lines({"type": "mac_identity", "private_key": "aa" * 32, "public_key": "04" + "bb" * 64}),
        lines({"type": "acpmux", "url": "unix:///tmp/acpmux.sock", "token": None}),
        lines({"type": "browser", "request": 3, "addr": "127.0.0.1:4100", "secret": "s" * 64}),
        lines({"type": "browser_failed", "request": 3, "reason": "no engine"}),
        lines({"type": "surface", "request": 4, "addr": "127.0.0.1:4200", "secret": "t" * 64},
              {"type": "surface_gone", "tab": "tab-1"}),
        lines({"type": "devices", "devices": [{"id": "phone-1", "identity_key": "04aa", "approval_key": ""}],
               "denied": [{"id": "phone-2", "identity_key": "04bb"}]}),
        lines({"type": "drop_phone", "phone_device_id": "PHONE-1"}),
        lines({"type": "phone_credentials", "credentials": {"phone-1": "cred-" + "c" * 40}}),
        "not json\n{\"type\":\"unknown\"}\n",
    ]


def optchat_mcp_request():
    def rpc(id_, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if id_ is not None:
            message["id"] = id_
        if params is not None:
            message["params"] = params
        return message

    def call(id_, name, arguments):
        return rpc(id_, "tools/call", {"name": name, "arguments": arguments})

    chief = b"\x00"
    subagent = b"\x01"
    return [
        chief + lines(rpc(1, "initialize", {"protocolVersion": "2025-06-18"}),
                      rpc(None, "notifications/initialized"), rpc(2, "tools/list"), rpc(3, "ping")).encode(),
        chief + lines(call(4, "zoom", {"id": 12, "n": 3}), call(5, "date", {"id": "7"}),
                      call(6, "send", {"text": "hi"}), call(7, "reply", {"to": "m1", "text": "ok"})).encode(),
        chief + lines(call(8, "spawn", {"task": "build", "harness": "claude"}),
                      call(9, "tell", {"id": "sub-1", "text": "go"}), call(10, "transcript", {"n": 5}),
                      call(11, "sleep", {"minutes": 1}), call(12, "control", {"op": "status"})).encode(),
        subagent + lines(call("a", "spawn", {"task": "x"}), call("b", "zoom", {"id": 1, "n": 1}),
                         call("c", "send", {"text": "y"}), call("d", "stop", {})).encode(),
        subagent + lines(call(1, "version", {}), call(2, "move", {"to": "/tmp"}),
                         rpc(3, "resources/list")).encode(),
        chief + lines(call(None, "zoom", {}), {"id": None, "method": 5}, [1, 2]).encode(),
    ]


def optchat_claude_import():
    session = lines(
        {"type": "user", "uuid": "u1", "timestamp": "2026-10-01T10:00:00Z", "cwd": "/repo",
         "message": {"content": "Fix the build"}},
        {"type": "assistant", "uuid": "a1", "timestamp": "2026-10-01T10:00:05Z",
         "message": {"content": [{"type": "text", "text": "Looking."},
                                 {"type": "tool_use", "name": "Read", "input": {"file_path": "/repo/a.rs"}},
                                 {"type": "tool_use", "name": "Bash", "input": {"command": "make"}}]}},
        {"type": "user", "uuid": "u2", "message": {"content": [{"type": "tool_result", "content": "ok"}]}},
        {"type": "assistant", "uuid": "a2", "timestamp": "2026-10-01T10:01:00Z",
         "message": {"content": [{"type": "text", "text": "Fixed."}]}},
        {"type": "user", "uuid": "u3", "isMeta": True, "message": {"content": "<command-name>/clear"}},
        {"type": "user", "uuid": "u4", "isSidechain": True, "message": {"content": "side"}},
    )
    resumed = lines(
        {"type": "user", "uuid": "u1", "timestamp": "2026-10-01T10:00:00Z", "message": {"content": "Fix the build"}},
        {"type": "user", "uuid": "u9", "timestamp": "not a date", "message": {"content": "x" * 600}},
        {"type": "user", "uuid": "u10", "timestamp": "2026-10-02T09:00:00+02:00", "message": {"content": "x" * 600}},
    )
    return [
        session,
        session.encode() + b"\x00" + resumed.encode(),
        "not json\n[1,2]\n\n" + session,
        b"\xff\xfe" + session.encode(),
    ]


def optchat_chief_turn_stream():
    def event(e):
        return {"type": "stream_event", "event": e}

    turn = lines(
        {"type": "system", "subtype": "init"},
        event({"type": "message_start", "message": {"id": "m1"}}),
        event({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
        event({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hel"}}),
        event({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "lo"}}),
        event({"type": "content_block_stop", "index": 0}),
        event({"type": "content_block_start", "index": 1,
               "content_block": {"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}}),
        event({"type": "content_block_delta", "index": 1,
               "delta": {"type": "input_json_delta", "partial_json": "{\"command\":\"ls\"}"}}),
        event({"type": "content_block_stop", "index": 1}),
        event({"type": "message_stop"}),
        {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "is_error": True}]}},
        {"type": "assistant", "parent_tool_use_id": "t1", "message": {"content": []}},
        {"type": "result", "subtype": "success", "is_error": False, "result": "Hello",
         "usage": {"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 2}},
    )
    thinking = lines(
        event({"type": "message_start"}),
        event({"type": "content_block_start", "index": 0, "content_block": {"type": "thinking"}}),
        event({"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "hm"}}),
        event({"type": "content_block_start", "index": 1, "content_block": {"type": "text"}}),
        event({"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "partial"}}),
    )
    return [
        b"\x00" + turn.encode(),
        b"\x02" + thinking.encode(),
        b"\x01" + lines({"type": "result", "is_error": True, "subtype": "error_max_turns"}).encode(),
        b"\x04" + b"garbage\n{}\n",
    ]


def main():
    write(TUI_FUZZ, "app_host_script_session", app_host_script_session())
    write(MOBILE_FUZZ, "mobile_host_phone_stream", mobile_host_phone_stream())
    write(MOBILE_FUZZ, "mobile_host_source_frames", mobile_host_source_frames())
    write(MOBILE_FUZZ, "mobile_host_control_line", mobile_host_control_line())
    write(OPTCHAT_FUZZ, "optchat_mcp_request", optchat_mcp_request())
    write(OPTCHAT_FUZZ, "optchat_claude_import", optchat_claude_import())
    write(OPTCHAT_FUZZ, "optchat_chief_turn_stream", optchat_chief_turn_stream())


if __name__ == "__main__":
    main()
