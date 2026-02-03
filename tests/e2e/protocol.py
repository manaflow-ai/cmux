import base64
import json
import select
import time


class _ProcState:
    def __init__(self) -> None:
        self.queue = []
        self.output_buffers = {}


def _get_state(proc) -> _ProcState:
    state = getattr(proc, "_cmux_state", None)
    if state is None:
        state = _ProcState()
        proc._cmux_state = state
    return state


def _read_next(proc, timeout: float = 0.1) -> dict | None:
    rlist, _, _ = select.select([proc.stdout], [], [], timeout)
    if not rlist:
        return None
    chunk = proc.stdout.readline()
    if not chunk:
        return None
    buf = chunk.strip()
    if not buf:
        return None
    try:
        return json.loads(buf.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid json from cmuxd: {buf!r}") from exc


def _update_output_buffer(state: _ProcState, msg: dict) -> None:
    pid = msg.get("pane_id")
    data = b64decode(msg.get("data", ""))
    buf = state.output_buffers.get(pid, b"") + data
    if len(buf) > 8192:
        buf = buf[-8192:]
    state.output_buffers[pid] = buf


def b64encode(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def b64decode(data: str) -> bytes:
    return base64.b64decode(data.encode("ascii"))


def send_msg(proc, msg: dict) -> None:
    line = json.dumps(msg) + "\n"
    proc.stdin.write(line.encode("utf-8"))
    proc.stdin.flush()


def read_msg(proc, timeout: float = 5.0) -> dict:
    state = _get_state(proc)
    if state.queue:
        return state.queue.pop(0)
    end = time.time() + timeout
    while time.time() < end:
        msg = _read_next(proc, timeout=0.1)
        if msg is None:
            continue
        return msg
    raise TimeoutError("timed out waiting for message")


def read_until(proc, predicate, timeout: float = 5.0) -> dict:
    state = _get_state(proc)
    end = time.time() + timeout
    while time.time() < end:
        idx = 0
        while idx < len(state.queue):
            msg = state.queue[idx]
            if predicate(msg):
                return state.queue.pop(idx)
            if msg.get("type") == "output":
                state.queue.pop(idx)
                _update_output_buffer(state, msg)
                continue
            idx += 1

        msg = _read_next(proc, timeout=0.1)
        if msg is None:
            continue
        batch = [msg]
        while True:
            msg = _read_next(proc, timeout=0)
            if msg is None:
                break
            batch.append(msg)
        for msg in batch:
            if predicate(msg):
                return msg
            if msg.get("type") == "output":
                _update_output_buffer(state, msg)
                continue
            state.queue.append(msg)
    raise TimeoutError("timed out waiting for message")


def wait_for_output(proc, needle: bytes, timeout: float = 5.0, pane_id: str | None = None) -> None:
    state = _get_state(proc)
    end = time.time() + timeout

    def has_match() -> bool:
        if pane_id is None:
            return any(needle in buf for buf in state.output_buffers.values())
        return needle in state.output_buffers.get(pane_id, b"")

    if has_match():
        return

    while time.time() < end:
        idx = 0
        while idx < len(state.queue):
            msg = state.queue[idx]
            if msg.get("type") == "output":
                state.queue.pop(idx)
                _update_output_buffer(state, msg)
                if has_match():
                    return
                continue
            idx += 1

        msg = _read_next(proc, timeout=0.1)
        if msg is None:
            continue
        if msg.get("type") == "output":
            _update_output_buffer(state, msg)
            if has_match():
                return
        else:
            state.queue.append(msg)
    raise TimeoutError(f"did not see output: {needle!r}")
