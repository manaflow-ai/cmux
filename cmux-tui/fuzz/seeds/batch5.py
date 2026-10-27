#!/usr/bin/env python3
"""Writes the seed corpora of the batch 5 fuzz targets (p10-stability-021).

Run from anywhere: python3 cmux-tui/fuzz/seeds/batch5.py
Seeds go to cmux-tui/fuzz/corpus/<target>/seed-NN. Each seed follows its
target's input layout (see the doc comment of fuzz_targets/<target>.rs).
Keybinding seeds come from schemas/keybindings/keybinding-vectors.json and
settings seeds from schemas/settings/settings-schema.json.
"""

import base64
import hashlib
import json
import pathlib
import shutil

FUZZ = pathlib.Path(__file__).resolve().parent.parent
REPO = FUZZ.parent.parent
CORPUS = FUZZ / "corpus"
ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def write(target, seeds):
    folder = CORPUS / target
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    for index, seed in enumerate(seeds):
        data = seed.encode() if isinstance(seed, str) else bytes(seed)
        (folder / f"seed-{index:02}").write_bytes(data)


def row_index(index):
    """A schema row as the config targets read it: a little-endian u16."""
    return index.to_bytes(2, "little")


def crockford(data, symbols):
    bits = int.from_bytes(data, "big")
    width = len(data) * 8
    return "".join(ALPHABET[(bits >> (width - 5 * (i + 1))) & 0x1F] for i in range(symbols))


# tui_pty_input: op % 10. 0 input (surface, kind, len, flags[, reservation]),
# 1 burst (+copies), 2 mutation (variant, outcome, remote, surface[, extra]),
# 3 dequeue, 4 finish serial, 5 finish concurrent (index), 6 retire (surface),
# 7 cancel reservation (pick), 8 next generation, 9 old sender (generation).
def pty_input():
    ordered, press, motion, release = 0, 1, 2, 3
    local_ok = 0b0000_0010  # outcome Ok, local
    remote_timeout = 0b0000_0111  # outcome Timeout, remote
    remote_transport = 0b0000_1011
    seeds = [
        [0, 1, ordered, 3, 0, 0, 1, ordered, 4, 0, 3, 4, 3, 4],
        [0, 1, press, 6, local_ok, 0, 1, motion, 6, 0, 0, 1, motion, 6, 0,
         0, 1, release, 6, 0x80 | local_ok, 0, 3, 4, 3, 4, 3, 4],
        [1, 2, motion, 200, 0, 255, 1, 2, ordered, 255, 0, 255, 3, 4],
        [0, 1, press, 6, remote_timeout, 0, 1, release, 6, 0x80 | remote_timeout, 0,
         3, 4, 3, 4, 3, 4, 3, 4],
        [2, 2, 1, 1, 1, 3, 5, 0, 2, 3, 2, 1, 2, 3, 5, 0, 2, 0, 0, 0, 0, 3, 4],
        [2, 1, 2, 1, 0, 1, 2, 1, 2, 1, 0, 1, 3, 4, 3, 4],
        [0, 1, ordered, 8, remote_transport, 0, 2, ordered, 8, 2, 3, 4, 3, 4],
        [0, 1, press, 6, 0, 6, 1, 7, 0, 8, 0, 1, ordered, 1, 0, 9, 0, 0, 1, ordered, 1, 0, 3, 4],
        [2, 3, 0, 0, 2, 255, 2, 3, 0, 0, 2, 1, 3, 3, 5, 0, 5, 0],
    ]
    write("tui_pty_input", seeds)


# tui_browser_input: op % 8. 0/1 event (surface, selector, 6 params),
# 2 burst (+copies), 3 spread (u16 base, count, event), 4 turns (count),
# 5 forget (wide flag, surface), 6 clear resize failures, 7 visibility mask.
def browser_input():
    def event(selector, *params):
        params = list(params) + [0] * (6 - len(params))
        return [selector, *params]

    press = event(0, 0, 10, 10, 0, 1, 1)
    release = event(0, 1, 10, 10, 0, 1, 1)
    move = event(0, 2, 11, 12, 2, 0, 2)
    resize = event(7, 2, 3, 0, 3, 0, 0)
    seeds = [
        [0, 1, *press, 0, 1, *move, 0, 1, *release, 4, 7],
        [2, 1, *move, 255, 4, 7, 4, 7],
        [2, 1, *event(6, 255), 255, 2, 1, *event(6, 255), 255, 4, 7],
        [3, 0, 0, 255, *event(4, 0, 65, 65)],
        [3, 0, 0, 255, *event(5, 1, 1)] + [3, 0, 1, 255, *event(5, 1, 1)] + [4, 7] * 4,
        [0, 2, *resize, 0, 2, *resize, 4, 7, 7, 0b100, 6, 0, 2, *resize, 4, 7],
        [0, 3, *press, 5, 0, 3, 0, 3, *release, 4, 7],
        [0, 4, *event(8, 1), 0, 4, *event(9), 0, 4, *event(10), 0, 4, *event(11), 4, 7],
        [0, 5, *event(12, 1, 0, 0, 0, 0, 9), 0, 5, *event(12, 1, 0, 0, 0, 0, 10), 4, 7],
        [2, 6, *release, 255, 0, 6, *press, 2, 6, *release, 255, 4, 7],
    ]
    write("tui_browser_input", seeds)


# tui_keys: mode byte, source byte (even: host bytes, odd: built events).
def keys():
    host = [
        b"abc\r\x7f\t",
        b"\x1b[A\x1b[B\x1bOH\x1b[1;5C\x1b[3~\x1b[5~",
        b"\x1b[97u\x1b[97;5u\x1b[97;3u\x1b[13;2u",
        b"\x1b[1095:1063:59;6u\x1b[233:201:101;2;201u",
        b"\x1b[97;1:3u\x1b[57441u\x1b[57399;129u",
        "é中\U0001f600".encode(),
        b"\x1b[200~paste\x1b[201~\x1b[I\x1b[O",
        b"\x1b[<0;10;5M\x1b[<0;10;5m\x1bOP\x1b[15~\x1b[24~",
        b"\x1b\x1bx\x1b",
    ]
    seeds = []
    for index, data in enumerate(host):
        mode = [0, 1, 29, 31, 0x20, 0x40, 0x80, 0x9f, 0x3f][index]
        seeds.append(bytes([mode, 0b10 * (index & 1)]) + data)
    # Built: selector (0x80 = enhanced), code bytes, modifiers, kind, state,
    # then for enhanced: present (1 shifted, 2 base, >>2 text length), chars.
    built = [
        [0x80 | 0, ord("a"), 0b0100, 0, 0, 0b0101, ord("A"), ord("a")],
        [0x80 | 1, 0xC0, 0x47, 0x04, 0x00, 0b0110, 0, 0, 0b1111, 0xC0, 0x27, 0x04, 0x00, ord(";"),
         0xC0, 0x27, 0x04, 0x00, 0xC0, 0x27, 0x04, 0x00, 0xC0, 0x27, 0x04, 0x00],
        [13, 0, 0, 0, 14, 0b0010, 1, 0, 26, 5, 0, 0, 0, 28, 0, 0, 1],
        [0x80 | 2, ord("e"), 0b0100, 0, 0b1000, 0b0100, ord("´") & 0x7F],
        [30, 0b0001, 0, 0, 31, 0, 0, 0, 23, 0b0001, 2, 0],
    ]
    for index, data in enumerate(built):
        seeds.append(bytes([[0, 29, 31, 1, 0x20][index], 1 | (0b10 * (index & 1))] + data))
    write("tui_keys", seeds)


# config_keybindings: "key<TAB>command<TAB>when" line, then keybindings.json.
def config_keybindings():
    vectors = json.loads((REPO / "schemas/keybindings/keybinding-vectors.json").read_text())
    seeds = []
    for vector in vectors["vectors"]:
        entries = list(vector.get("bindings") or [])
        entries += [{"key": r.get("key"), "command": "-" + r["command"]} if isinstance(r, dict)
                    else {"command": "-" + r} for r in vector.get("removals") or []]
        if not entries:
            continue
        first = entries[0]
        params = f"{first.get('key') or ''}\t{first['command'].lstrip('-')}\t{first.get('when') or ''}"
        body = "// keybindings.json\n" + json.dumps(entries, indent=2)
        seeds.append(params + "\n" + body)
    seeds += [
        "cmd+shift+p\tcommandPalette\t\n[]",
        "j\tnextHunk\tdiffViewerFocused && !textInputFocus\n[\n  // bare\n  {\"key\": \"j\", \"command\": \"nextHunk\", \"when\": \"diffViewerFocused\"},\n]",
        "cmd++\tzoomIn\t\n[{\"key\":\"cmd++\",\"command\":\"zoomIn\",\"args\":{\"step\":1}}, {\"command\":\"-zoomOut\"}]",
        "ctrl+a b c d e\tx\t\n[,]",
        "⌘⇧k\tx\t\n{\"not\":\"an array\"}",
        "f20\tx\t\n[/* c */ 1, \"two\", {\"key\": 3}]",
    ]
    write("config_keybindings", seeds)


# config_schema: selector byte (even: schema document; odd: a little-endian
# u16 row index of the embedded schema, then a value for that row), then JSON text.
def config_schema():
    schema = json.loads((REPO / "schemas/settings/settings-schema.json").read_text())
    rows = schema["rows"]
    seeds = []
    by_kind = {}
    for index, row in enumerate(rows):
        by_kind.setdefault(row["kind"], (index, row))
    for kind, (index, row) in sorted(by_kind.items()):
        document = {"version": schema["version"], "sections": schema["sections"][:1], "rows": [row]}
        seeds.append(bytes([0]) + json.dumps(document).encode())
        for sample in (row.get("accepts") or [])[:1] + (row.get("refuses") or [])[:1]:
            seeds.append(bytes([1]) + row_index(index) + json.dumps(sample).encode())
    # An hour past i64 / 60 overflowed `quiet_hours_minutes` (tests/quiet_hours.rs).
    index, _ = by_kind["time_range"]
    seeds.append(bytes([1]) + row_index(index) + b'{"start": "-40000000001064563953:22", "end": "00:00"}')
    write("config_schema", seeds)


# config_store: a length byte (initial file is 4x that), the file, then ops:
# selector % 8 (0/1/6 set, 2 reset, 3 reset all, 4 domains, 5 team policy,
# 7 reload). Rows are little-endian u16 indexes.
def config_store():
    schema = json.loads((REPO / "schemas/settings/settings-schema.json").read_text())
    rows = schema["rows"]

    def initial(text):
        text = text.encode()
        padded = text + b" " * (-len(text) % 4)
        return bytes([len(padded) // 4]) + padded

    def string(text):
        data = text.encode()
        return [len(data), *data]

    row = row_index(3)
    toggle = row_index(next(i for i, r in enumerate(rows) if r["kind"] == "toggle"))
    choice = row_index(next(i for i, r in enumerate(rows) if r["kind"] == "choice"))
    keyed = 0x10  # idempotency key, origin user
    seeds = [
        initial("{}") + bytes([0, 0, *toggle, 0, 1, 0]),
        initial('{"appearance": {"density": "compact"}} // c') + bytes([0, 0, *choice, 5, *choice, 0, keyed, 3]),
        initial("{}") + bytes([0, 0, *toggle, 0, 1, keyed, 1, 0, 0, *toggle, 0, 1, keyed, 1]),
        initial("{}") + bytes([0, 0, *toggle, 0, 1, 0x20, 0, 0, *toggle, 0, 0, 0x60]),
        initial('{"a": 1,}') + bytes([2, 1, *toggle, 0, 3, 2, 7, 0, *string('{"b": true}'), 0]),
        initial("{}") + bytes([4, 1, *string("Dark"), 1, *string("Menlo"), 0]),
        initial("{}") + bytes([5, *string("Team"), 1, 0, *toggle, 0, 1, 1, 0, *choice, 3, *string("x"), 0, 5]),
        initial("[1, 2]") + bytes([7, 1, 0, 0, 0, *toggle, 0, 1, 2]),
        initial("{}") + bytes([0, 3, *row, *string("not.a.row"), 6, *string('{"x": [1, 2]}'), 0x02]),
    ]
    write("config_store", seeds)


# server_core_pairing: selector % 4 (0 normalize, 1 key[32] + payload,
# 2 random[5] + key, 3 encode_bits with symbols = selector >> 2), then data.
def server_core_pairing():
    key = hashlib.sha256(b"install key").digest()
    code = crockford(bytes([1, 2, 3, 4, 5]), 8)
    fp = crockford(hashlib.sha256(key).digest(), 16)
    payload = f"https://cmux.com/pair?c={code}#fp={fp}"
    seeds = [
        b"\x007KQ4-M2XD",
        b"\x00 7kq4 m2xd ",
        b"\x00OIL0-1234",
        b"\x00U0000000",
        b"\x00\xe2\x80\x937KQ4M2XD",
        b"\x01" + key + payload.encode(),
        b"\x01" + key + payload.lower().encode(),
        b"\x01" + key + payload.replace("#fp=", "&fp=").encode(),
        b"\x02" + bytes([1, 2, 3, 4, 5]) + key,
        b"\x02" + bytes([0xFF] * 5),
        bytes([3 | (16 << 2)]) + hashlib.sha256(b"x").digest(),
    ]
    write("server_core_pairing", seeds)


# server_core_enrollment: selector % 4 (0 read_frame, 1 Begun::parse at
# NOW_MS, 2 jwk_thumbprint + begin_request, 3 valid_collect_secret), then text.
def server_core_enrollment():
    now_ms = 1_800_000_000_000
    b64 = lambda data: base64.urlsafe_b64encode(data).rstrip(b"=").decode()
    jwk = {"kty": "EC", "crv": "P-256", "x": b64(bytes(range(32))), "y": b64(bytes(range(32, 64)))}
    canonical = json.dumps({"crv": "P-256", "kty": "EC", "x": jwk["x"], "y": jwk["y"]},
                           separators=(",", ":"))
    thumbprint = b64(hashlib.sha256(canonical.encode()).digest())
    secret = b64(bytes(range(16))) + "." + "ab" * 32
    paired = {"t": "paired", "host": "host_" + "a" * 20, "team": "team_" + "b" * 20,
              "user": "user_" + "c" * 20, "install": "inst_" + "d" * 20}
    begun = {"code": "7KQ4M2XD", "thumbprint": thumbprint, "collect_secret": secret,
             "expires_at": now_ms + 60_000}
    request = dict(jwk, wg=base64.b64encode(bytes(32)).decode(), env="production",
                   info={"name": "mini", "platform": "macos", "os_version": "26.1",
                         "arch": "aarch64", "cmux_version": "1.0.0", "capabilities": ["chief"]})
    text = lambda selector, value: bytes([selector]) + (
        value if isinstance(value, str) else json.dumps(value)).encode()
    seeds = [
        text(0, paired),
        text(0, dict(paired, host="host_short")),
        text(0, {"t": "refused"}),
        text(0, {"t": "pending"}),
        text(0, {"x": 1}),
        text(1, begun),
        text(1, dict(begun, code="7kq4-m2xd")),
        text(1, dict(begun, expires_at=now_ms + 3_600_000)),
        text(2, jwk),
        text(2, request),
        text(2, dict(request, info=dict(request["info"], platform="beos"))),
        text(3, secret),
        text(3, secret.upper()),
    ]
    write("server_core_enrollment", seeds)


if __name__ == "__main__":
    pty_input()
    browser_input()
    keys()
    config_keybindings()
    config_schema()
    config_store()
    server_core_pairing()
    server_core_enrollment()
