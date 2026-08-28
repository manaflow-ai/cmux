# Analyze a CMUX_TUI_INPUT_AUDIT file produced by repro-10431-paste.py.
#
# For each paste iteration it reconstructs the byte stream seen at each tap
# (t1 = crossterm ingress, t2 = app enqueue toward the surface, t3 = bytes
# written to the child pty) and diffs them against the known 818-byte paste,
# printing the exact runs that vanished and the layer they vanished in.

import difflib
import sys

AUDIT = sys.argv[1] if len(sys.argv) > 1 else "audit.log"

inner_osc_query = """python3 - <<'PY'
import os, select, termios, time, tty
fd = os.open('/dev/tty', os.O_RDWR)
old = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    os.write(fd, b'\\x1b]11;?\\x1b\\\\')
    data = b''
    # Generous deadline: the shell may still be consuming the pasted
    # heredoc and the TUI coalesces frames (this raced at 2s, and 8s
    # still fails on saturated CI runners).
    end = time.monotonic() + 30
    while time.monotonic() < end and not (data.endswith(b'\\x1b\\\\') or data.endswith(b'\\x07')):
        r, _, _ = select.select([fd], [], [], max(0, end - time.monotonic()))
        if not r:
            break
        data += os.read(fd, 128)
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    os.close(fd)
print(data.decode('ascii', 'ignore').replace('\\x1b', '<ESC>').replace('\\x07', '<BEL>'))
PY
"""
EXPECTED = inner_osc_query.replace("\n", "\r").encode()
# For capture-mode audits, REPRO_CAPTURE holds the capture file path the
# repro printed at startup (the path is embedded in the pasted bytes).
CAPTURE = os.environ.get("REPRO_CAPTURE") if (os := __import__("os")) else None
if CAPTURE:
    body = inner_osc_query.split("\n", 1)[1]
    body = body[: body.rindex("PY\n") + len("PY\n")]
    tail = "printf 'CAPTURE-%s\\n' done\n"
    EXPECTED = (f"cat > {CAPTURE} <<'PY'\n" + body + tail).replace("\n", "\r").encode()


def parse(path):
    iterations = []
    current = None
    for raw in open(path, "r", encoding="utf-8", errors="replace"):
        parts = raw.rstrip("\n").split(" ")
        if len(parts) < 3:
            continue
        tag = parts[1]
        if tag == "harness":
            marker = parts[2]
            if marker.endswith("-begin"):
                current = {"name": marker[:-6].rstrip("-"), "lines": []}
            elif current is not None:
                current["result"] = marker.rsplit("-", 1)[-1]
                iterations.append(current)
                current = None
            continue
        if current is not None:
            current["lines"].append(parts)
    return iterations


def stream(lines, tag, predicate=lambda parts: True):
    out = bytearray()
    for parts in lines:
        if parts[1] != tag or not predicate(parts):
            continue
        hexpart = parts[-1]
        if hexpart and hexpart != "-":
            try:
                out.extend(bytes.fromhex(hexpart))
            except ValueError:
                pass
    return bytes(out)


def diff_report(name, got, expected):
    if got == expected:
        print(f"  {name}: {len(got)} bytes, exact match")
        return True
    print(f"  {name}: {len(got)} bytes (expected {len(expected)})")
    matcher = difflib.SequenceMatcher(a=expected, b=got, autojunk=False)
    for op, a0, a1, b0, b1 in matcher.get_opcodes():
        if op == "equal":
            continue
        lost = expected[a0:a1]
        added = got[b0:b1]
        print(
            f"    {op} expected[{a0}:{a1}]={lost!r} got[{b0}:{b1}]={added!r}"
        )
    return False


def only_paste_window(data, expected):
    # The tap stream may contain unrelated bytes (probe replies, earlier
    # commands). Trim to the region from the first byte of the paste prefix.
    prefix = expected[:16]
    index = data.find(prefix[:8])
    return data[index:] if index >= 0 else data


def audit_losses(lines):
    """Audit-writer losses within one iteration: (dropped lines, shed payloads).

    The audit sink drops whole lines under queue pressure (`audit-dropped N`)
    and sheds large payloads under byte pressure (`payload-bytes=N` in the
    detail). Either way the tap streams are incomplete, so byte loss must not
    be attributed to the pipeline from this iteration.
    """
    dropped = 0
    shed = 0
    for parts in lines:
        if parts[1] == "audit-dropped":
            try:
                dropped += int(parts[2])
            except (IndexError, ValueError):
                dropped += 1
        elif any(part.startswith("payload-bytes=") for part in parts[2:]):
            shed += 1
    return dropped, shed


iterations = parse(AUDIT)
print(f"{len(iterations)} iterations in {AUDIT}")
for iteration in iterations:
    result = iteration.get("result", "?")
    print(f"{iteration['name']}: {result}")
    if result == "ok":
        continue
    lines = iteration["lines"]
    dropped, shed = audit_losses(lines)
    if dropped or shed:
        print(
            f"  INCONCLUSIVE: the audit writer lost data in this iteration"
            f" ({dropped} dropped lines, {shed} shed payloads); tap streams"
            " are incomplete, so byte loss cannot be attributed to the"
            " pipeline. Rerun with less load or a faster audit target."
        )
        continue
    t1 = only_paste_window(stream(lines, "t1-key"), EXPECTED)
    t2 = only_paste_window(
        stream(lines, "t2-enqueue", lambda parts: "kind=Ordered" in " ".join(parts)),
        EXPECTED,
    )
    t3 = only_paste_window(
        stream(lines, "t3-write", lambda parts: "result=ok" in " ".join(parts)),
        EXPECTED,
    )
    ok1 = diff_report("t1 crossterm ingress", t1[: len(EXPECTED)], EXPECTED)
    ok2 = diff_report("t2 app enqueue     ", t2[: len(EXPECTED)], EXPECTED)
    ok3 = diff_report("t3 child pty write ", t3[: len(EXPECTED)], EXPECTED)
    for parts in lines:
        if parts[1] in ("t2-dropped", "t2-rejected", "t3-canceled", "t3-rejected-exited"):
            print("    note:", " ".join(parts[1:]))
    if ok1 and ok2 and ok3:
        print(
            "    all taps intact: loss is below the TUI's child-pty write"
            " (kernel pty input path or the inner shell)"
        )
