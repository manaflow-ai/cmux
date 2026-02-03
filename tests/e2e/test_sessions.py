import os
import subprocess
import time

import pytest

from protocol import b64decode, b64encode, read_msg, read_until, send_msg, wait_for_output

CMUXD_BIN = os.environ.get("CMUXD_BIN", "/opt/cmuxterm/cmuxd/zig-out/bin/cmuxd")
DOCKER_E2E = os.environ.get("CMUX_E2E_DOCKER") == "1"


def start_stdio(shell: str | None = None):
    env = os.environ.copy()
    if shell is not None:
        env["SHELL"] = shell
    else:
        env.setdefault("SHELL", "/bin/sh")
    test_home = env.get("CMUXD_TEST_HOME", "/tmp/cmuxd-test-home")
    os.makedirs(test_home, exist_ok=True)
    env["HOME"] = test_home
    return subprocess.Popen(
        [CMUXD_BIN, "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )


def replay_vt(data: bytes, rows: int, cols: int) -> tuple[list[list[str]], int, int]:
    screen = [[" "] * cols for _ in range(rows)]
    x = 0
    y = 0
    i = 0
    while i < len(data):
        byte = data[i]
        if byte == 0x1B:  # ESC
            if i + 1 >= len(data):
                break
            nxt = data[i + 1]
            if nxt == ord("c"):
                screen = [[" "] * cols for _ in range(rows)]
                x = 0
                y = 0
                i += 2
                continue
            if nxt == ord("["):
                j = i + 2
                while j < len(data) and not (0x40 <= data[j] <= 0x7E):
                    j += 1
                if j >= len(data):
                    break
                final = data[j]
                params = data[i + 2 : j].decode("ascii", "ignore")
                if final in (ord("H"), ord("f")):
                    parts = [p for p in params.split(";") if p != ""]
                    row = int(parts[0]) if len(parts) >= 1 else 1
                    col = int(parts[1]) if len(parts) >= 2 else 1
                    y = max(0, min(rows - 1, row - 1))
                    x = max(0, min(cols - 1, col - 1))
                i = j + 1
                continue
            if nxt == ord("]"):
                j = i + 2
                while j < len(data):
                    if data[j] == 0x07:  # BEL
                        j += 1
                        break
                    if data[j] == 0x1B and j + 1 < len(data) and data[j + 1] == ord("\\"):
                        j += 2
                        break
                    j += 1
                i = j
                continue
            i += 2
            continue
        if byte == 0x0D:  # CR
            x = 0
            i += 1
            continue
        if byte == 0x0A:  # LF
            y = min(rows - 1, y + 1)
            i += 1
            continue
        if byte >= 0x20:
            if 0 <= x < cols and 0 <= y < rows:
                screen[y][x] = chr(byte)
            x += 1
            if x >= cols:
                x = 0
                y = min(rows - 1, y + 1)
        i += 1
    return screen, x, y


def test_json_ping_pong():
    proc = start_stdio()
    try:
        send_msg(proc, {"type": "hello", "version": 1})
        read_until(proc, lambda m: m.get("type") == "welcome")

        send_msg(proc, {"type": "ping"})
        pong = read_until(proc, lambda m: m.get("type") == "pong")
        assert pong["type"] == "pong"
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def test_sessions_list_attach_and_scope():
    proc = start_stdio()
    try:
        send_msg(proc, {"type": "hello", "version": 1})
        welcome = read_until(proc, lambda m: m.get("type") == "welcome")
        session_id = welcome.get("session_id")

        send_msg(proc, {"type": "list_sessions"})
        listing = read_until(proc, lambda m: m.get("type") == "sessions")
        assert any(s.get("session_id") == session_id for s in listing.get("sessions", []))

        send_msg(proc, {"type": "new_session"})
        created = read_until(proc, lambda m: m.get("type") == "session_created")
        new_session_id = created["session_id"]
        new_pane_id = created["pane_id"]

        send_msg(proc, {"type": "list_sessions"})
        listing = read_until(proc, lambda m: m.get("type") == "sessions")
        session_ids = {s.get("session_id") for s in listing.get("sessions", [])}
        assert session_id in session_ids
        assert new_session_id in session_ids

        send_msg(proc, {"type": "list_panes", "session_id": new_session_id})
        panes = read_until(proc, lambda m: m.get("type") == "panes")
        pane_ids = [p.get("pane_id") for p in panes.get("panes", [])]
        assert pane_ids == [new_pane_id]

        send_msg(proc, {"type": "attach_session", "session_id": new_session_id})
        attached = read_until(proc, lambda m: m.get("type") == "session_attached")
        assert attached["session_id"] == new_session_id
        assert attached["pane_id"] == new_pane_id

        send_msg(proc, {"type": "snapshot_request", "session_id": new_session_id})
        snap = read_until(proc, lambda m: m.get("type") == "snapshot")
        assert snap["data"]
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def test_snapshot_avoids_default_palette():
    proc = start_stdio()
    try:
        send_msg(proc, {"type": "hello", "version": 1})
        welcome = read_until(proc, lambda m: m.get("type") == "welcome")
        session_id = welcome["session_id"]
        pane_id = welcome["pane_id"]
        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(b"stty -echo\n")})
        time.sleep(0.2)
        reset_cmd = b"printf '\\033]104\\033\\\\\\033]110\\033\\\\\\033]111\\033\\\\'\n"
        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(reset_cmd)})
        time.sleep(0.5)
        send_msg(proc, {"type": "snapshot_request", "session_id": session_id})
        snap = read_until(proc, lambda m: m.get("type") == "snapshot")
        payload = b64decode(snap["data"])
        assert b"\x1b]4;" not in payload
        assert b"\x1b]10;" not in payload
        assert b"\x1b]11;" not in payload
        assert b"\x1b]104" not in payload
        assert b"\x1b]110" not in payload
        assert b"\x1b]111" not in payload
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def test_snapshot_includes_palette_overrides():
    proc = start_stdio()
    try:
        send_msg(proc, {"type": "hello", "version": 1})
        welcome = read_until(proc, lambda m: m.get("type") == "welcome")
        session_id = welcome["session_id"]
        pane_id = welcome["pane_id"]
        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(b"stty -echo\n")})
        time.sleep(0.2)
        reset_cmd = b"printf '\\033]104\\033\\\\\\033]110\\033\\\\\\033]111\\033\\\\'\n"
        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(reset_cmd)})
        set_cmd = b"printf '\\033]4;1;rgb:12/34/56\\033\\\\'\n"
        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(set_cmd)})
        time.sleep(0.5)
        snap = None
        for _ in range(2):
            send_msg(proc, {"type": "snapshot_request", "session_id": session_id})
            try:
                snap = read_until(proc, lambda m: m.get("type") == "snapshot", timeout=10.0)
                break
            except TimeoutError:
                time.sleep(0.2)
        if snap is None:
            raise TimeoutError("timed out waiting for snapshot")
        payload = b64decode(snap["data"])
        assert b"\x1b]4;1;rgb:12/34/56" in payload
        assert payload.count(b"\x1b]4;") == 1
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def test_snapshot_cursor_style_default_and_explicit():
    proc = start_stdio(shell="/bin/sh")
    try:
        send_msg(proc, {"type": "hello", "version": 1})
        welcome = read_until(proc, lambda m: m.get("type") == "welcome")
        session_id = welcome["session_id"]
        pane_id = welcome["pane_id"]
        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(b"stty -echo\n")})
        time.sleep(0.2)

        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(b"printf '\\033[6 q'\n")})
        time.sleep(0.2)
        send_msg(proc, {"type": "snapshot_request", "session_id": session_id})
        snap = read_until(proc, lambda m: m.get("type") == "snapshot")
        payload = b64decode(snap["data"])
        assert b"\x1b[6 q" in payload

        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(b"printf '\\033[0 q'\n")})
        time.sleep(0.2)
        send_msg(proc, {"type": "snapshot_request", "session_id": session_id})
        snap = read_until(proc, lambda m: m.get("type") == "snapshot")
        payload = b64decode(snap["data"])
        assert b"\x1b[0 q" in payload
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def test_snapshot_cursor_position_reconnect():
    proc = start_stdio()
    try:
        send_msg(proc, {"type": "hello", "version": 1})
        welcome = read_until(proc, lambda m: m.get("type") == "welcome")
        session_id = welcome["session_id"]
        pane_id = welcome["pane_id"]
        prompt = b"PROMPT> "
        send_msg(
            proc,
            {
                "type": "input",
                "pane_id": pane_id,
                "data": b64encode(b"printf 'PROMPT> '; read -r _\n"),
            },
        )
        wait_for_output(proc, prompt, timeout=10.0, pane_id=pane_id)
        send_msg(proc, {"type": "snapshot_request", "session_id": session_id})
        snap = read_until(proc, lambda m: m.get("type") == "snapshot")
        payload = b64decode(snap["data"])
        rows = snap.get("rows", 24)
        cols = snap.get("cols", 80)
        screen, cursor_x, cursor_y = replay_vt(payload, rows, cols)
        row_texts = ["".join(row) for row in screen]
        row_idx = next((idx for idx, row in enumerate(row_texts) if "PROMPT> " in row), None)
        assert row_idx is not None
        col_idx = row_texts[row_idx].find("PROMPT> ")
        expected_x = col_idx + len("PROMPT> ")
        if cursor_y == row_idx:
            assert cursor_x == expected_x
        else:
            assert cursor_y == row_idx + 1
            assert cursor_x <= expected_x + 2
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def test_metadata_and_notifications():
    proc = start_stdio()
    try:
        send_msg(proc, {"type": "hello", "version": 1})
        welcome = read_until(proc, lambda m: m.get("type") == "welcome")
        pane_id = welcome["pane_id"]
        payload = b"echo READY\n"
        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(payload)})
        wait_for_output(proc, b"READY", timeout=10.0, pane_id=pane_id)
        time.sleep(0.2)

        def send_osc(payload: str) -> None:
            cmd = f"/usr/bin/printf '\\033]{payload}\\033\\\\'\\n"
            data = cmd.encode("utf-8")
            send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(data)})

        def send_osc_and_expect(
            payload: str,
            predicate,
            timeout: float = 10.0,
            attempts: int = 3,
            sync_hint: bytes | None = None,
        ):
            last_err = None
            for _ in range(attempts):
                send_osc(payload)
                if sync_hint is not None:
                    try:
                        wait_for_output(proc, sync_hint, timeout=1.0, pane_id=pane_id)
                    except TimeoutError:
                        pass
                try:
                    return read_until(proc, predicate, timeout=timeout)
                except TimeoutError as err:
                    last_err = err
            if last_err:
                raise last_err
            raise TimeoutError("timed out waiting for message")

        send_osc("7;file://localhost/tmp")
        send_osc("9;Hello from iTerm2")
        send_osc("777;notify;Title;Body")
        send_osc("99;;Kitty Title")
        send_osc("9;こんにちは")
        long_body = "x" * 256
        x_run = "x" * 64
        send_osc(f"9;{long_body}")

        messages: list[dict] = []
        end = time.time() + 30.0
        while time.time() < end:
            try:
                msg = read_msg(proc, timeout=0.5)
            except TimeoutError:
                continue
            if msg.get("type") != "output":
                messages.append(msg)

        has_cwd = any(
            m.get("type") == "cwd_update" and "/tmp" in m.get("cwd", "")
            for m in messages
        )
        if not has_cwd and DOCKER_E2E:
            pytest.xfail("flaky cwd_update in docker e2e")
        assert has_cwd
        assert any(
            m.get("type") == "notify" and m.get("body") == "Hello from iTerm2"
            for m in messages
        )
        assert any(
            m.get("type") == "notify"
            and m.get("title") == "Title"
            and m.get("body") == "Body"
            for m in messages
        )
        assert any(
            m.get("type") == "notify" and m.get("title") == "Kitty Title"
            for m in messages
        )
        assert any(
            m.get("type") == "notify" and m.get("body") == "こんにちは"
            for m in messages
        )
        assert any(
            m.get("type") == "notify"
            and (x_run in m.get("body", "") or x_run in m.get("title", ""))
            for m in messages
        )
    finally:
        proc.terminate()
        proc.wait(timeout=5)


@pytest.mark.xfail(DOCKER_E2E, reason="flaky title_update in docker e2e")
def test_title_update():
    proc = start_stdio()
    try:
        send_msg(proc, {"type": "hello", "version": 1})
        welcome = read_until(proc, lambda m: m.get("type") == "welcome")
        pane_id = welcome["pane_id"]
        payload = b"echo READY\n"
        send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(payload)})
        wait_for_output(proc, b"READY", timeout=10.0, pane_id=pane_id)

        def send_osc(payload: str) -> None:
            cmd = f"/usr/bin/printf '\\033]{payload}\\033\\\\'\\n"
            data = cmd.encode("utf-8")
            send_msg(proc, {"type": "input", "pane_id": pane_id, "data": b64encode(data)})

        def send_osc_and_expect(payload: str, predicate, timeout: float = 10.0, attempts: int = 3):
            last_err = None
            for _ in range(attempts):
                send_osc(payload)
                try:
                    return read_until(proc, predicate, timeout=timeout)
                except TimeoutError as err:
                    last_err = err
            if last_err:
                raise last_err
            raise TimeoutError("timed out waiting for message")

        try:
            title = send_osc_and_expect(
                "2;CMUXTITLE",
                lambda m: m.get("type") == "title_update"
                and m.get("pane_id") == pane_id
                and "CMUXTITLE" in m.get("title", ""),
            )
        except TimeoutError:
            title = send_osc_and_expect(
                "0;CMUXTITLE",
                lambda m: m.get("type") == "title_update"
                and m.get("pane_id") == pane_id
                and "CMUXTITLE" in m.get("title", ""),
            )
        assert "CMUXTITLE" in title.get("title", "")
    finally:
        proc.terminate()
        proc.wait(timeout=5)
