#!/usr/bin/env python3
import base64
import json
import os
import random
import re
import shutil
import signal
import socket
import struct
import subprocess
import time
import fcntl
from contextlib import contextmanager
from pathlib import Path

tag = os.environ.get("CMUX_TAG", "swmob")
repo = Path(os.environ.get("CMUX_REPO", Path(__file__).resolve().parents[2]))
simulator_id = os.environ["SIMULATOR_ID"]
client_id = os.environ.get("CLIENT_ID", "mobile-soak-cli")
duration_seconds = int(os.environ.get("SOAK_SECONDS", str(12 * 60 * 60)))
soak_root = Path(os.environ.get("SOAK_ROOT", f"/tmp/cmux-mobile-soak-{tag}"))
log_path = Path(os.environ.get("SOAK_LOG", soak_root / "mobile-soak.log"))
status_path = Path(os.environ.get("SOAK_STATUS", soak_root / "mobile-soak.status"))
color_probe_interval = int(os.environ.get("COLOR_PROBE_INTERVAL", "120"))
color_verify_script = Path(os.environ.get("COLOR_VERIFY_SCRIPT", Path(__file__).with_name("verify-colors.swift")))
socket_timeout_seconds = float(os.environ.get("SOCKET_TIMEOUT_SECONDS", "30"))
attach_settle_seconds = float(os.environ.get("ATTACH_SETTLE_SECONDS", "4"))
color_settle_seconds = float(os.environ.get("COLOR_SETTLE_SECONDS", "2"))
color_failure_is_fatal = os.environ.get("COLOR_FAILURE_IS_FATAL", "1").lower() not in {"0", "false", "no"}
loop_sleep_seconds = float(os.environ.get("LOOP_SLEEP_SECONDS", "5"))
failure_sleep_seconds = float(os.environ.get("FAILURE_SLEEP_SECONDS", str(loop_sleep_seconds)))
ticket_ttl_seconds = int(os.environ.get("MOBILE_TICKET_TTL_SECONDS", "3600"))
attach_route_id = os.environ.get("MOBILE_ATTACH_ROUTE_ID", "debug_loopback").strip()
attach_route_kind = os.environ.get("MOBILE_ATTACH_ROUTE_KIND", "").strip()
external_ticket_path = os.environ.get("MOBILE_ATTACH_TICKET_JSON", "").strip()
reattach_interval_seconds = float(os.environ.get("MOBILE_REATTACH_INTERVAL_SECONDS", str(45 * 60)))
reattach_mode = os.environ.get("MOBILE_REATTACH_MODE", "openurl").strip().lower()
input_interval = int(os.environ.get("MOBILE_INPUT_INTERVAL", "20"))
input_burst_commands = int(os.environ.get("MOBILE_INPUT_BURST_COMMANDS", "1"))
screenshot_interval = int(os.environ.get("MOBILE_SCREENSHOT_INTERVAL", "120"))
max_scrollback_rows = int(os.environ.get("MOBILE_MAX_SCROLLBACK_ROWS", "80"))
profile = os.environ.get("SOAK_PROFILE", "steady")
dev_origin = os.environ.get("CMUX_DEV_ORIGIN", "").strip().rstrip("/")
dev_stack_auth_token = os.environ.get("CMUX_MOBILE_DEV_STACK_AUTH_TOKEN", "").strip()
expected_min_workspaces = int(os.environ.get("MOBILE_EXPECT_MIN_WORKSPACES", "1"))
full_workspace_list_interval = int(os.environ.get("MOBILE_FULL_WORKSPACE_LIST_INTERVAL", str(input_interval)))
color_verify_attempts = int(os.environ.get("COLOR_VERIFY_ATTEMPTS", "5"))
color_verify_retry_seconds = float(os.environ.get("COLOR_VERIFY_RETRY_SECONDS", "0.75"))
terminal_output_attempts = int(os.environ.get("TERMINAL_OUTPUT_ATTEMPTS", "8"))
terminal_output_retry_seconds = float(os.environ.get("TERMINAL_OUTPUT_RETRY_SECONDS", "0.75"))
failure_limit = int(os.environ.get("MOBILE_FAILURE_LIMIT", "1"))
command_timeout_seconds = float(os.environ.get("MOBILE_COMMAND_TIMEOUT_SECONDS", "45"))
diagnostics_dir = Path(os.environ.get("SOAK_DIAGNOSTICS_DIR", soak_root / "diagnostics"))
cmux_log_path = Path(os.environ.get("CMUX_DEBUG_LOG", f"/tmp/cmux-debug-{tag}.log"))
cmux_log_tail_lines = int(os.environ.get("CMUX_DEBUG_LOG_TAIL_LINES", "500"))
terminal_mutation_lock_path = Path(os.environ.get("MOBILE_TERMINAL_MUTATION_LOCK", soak_root / "mobile-terminal-mutation.lock"))

COLOR_PROBE_LABELS = [
    "RED_E2E",
    "GREEN_E2E",
    "BLUE_E2E",
    "YELLOW_E2E",
]


def run(args, *, cwd=repo, input_text=None, check=True, extra_env=None, timeout=None):
    env = os.environ.copy()
    env["CMUX_TAG"] = tag
    if extra_env:
        env.update(extra_env)
    timeout = command_timeout_seconds if timeout is None else timeout
    proc = subprocess.Popen(
        args,
        cwd=str(cwd),
        text=True,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        stdin=subprocess.PIPE if input_text is not None else None,
        start_new_session=True,
    )
    try:
        stdout, _ = proc.communicate(input=input_text, timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
            stdout, _ = proc.communicate(timeout=2)
        except Exception:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except Exception:
                pass
            stdout, _ = proc.communicate()
        raise RuntimeError(f"{' '.join(args)} timed out after {timeout:g}s: {stdout[-1200:]}")
    if check and proc.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed ({proc.returncode}): {stdout[-1200:]}")
    return stdout


@contextmanager
def terminal_mutation_lock(reason):
    terminal_mutation_lock_path.parent.mkdir(parents=True, exist_ok=True)
    with terminal_mutation_lock_path.open("a+") as lock_file:
        started = time.monotonic()
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        waited = time.monotonic() - started
        if waited > 1:
            log(f"terminal_lock_wait reason={reason} waited={waited:.2f}s")
        try:
            yield
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def run_json_file(args, path):
    output = run(args, cwd=Path("/"), check=False)
    path.write_text(output)
    return output


def cmux_rpc(method, params):
    return json.loads(run(["scripts/cmux-debug-cli.sh", "rpc", method, json.dumps(params)]))


def selected_route(routes):
    if attach_route_id:
        for route in routes:
            if route.get("id") == attach_route_id:
                return route
    if attach_route_kind:
        for route in routes:
            if route.get("kind") == attach_route_kind:
                return route
    if routes:
        return routes[0]
    raise RuntimeError("attach ticket has no routes")


# The soak drives the dev simulator build, which (since the pairing scheme went
# channel-specific in CmxPairingURLScheme) registers `cmux-ios-dev` in its
# CFBundleURLSchemes rather than the release `cmux-ios`. `simctl openurl` routes
# by the registered scheme, so an attach link minted here must use the dev
# scheme to reach the tagged dev app instead of failing or opening an installed
# release/beta build. Override only when soaking a release build.
ATTACH_URL_SCHEME = os.environ.get("MOBILE_ATTACH_URL_SCHEME", "cmux-ios-dev").strip()


def attach_url_for_ticket(ticket):
    encoded = base64.urlsafe_b64encode(
        json.dumps(ticket, separators=(",", ":")).encode("utf-8")
    ).decode("ascii").rstrip("=")
    return f"{ATTACH_URL_SCHEME}://attach?v={ticket.get('version', 1)}&payload={encoded}"


def ticket_from_payload(payload, attach_url):
    ticket = payload["ticket"]
    route = selected_route(ticket["routes"])
    filtered_ticket = dict(ticket)
    filtered_ticket["routes"] = [route]
    return {
        "token": ticket["auth_token"],
        "workspace_id": ticket["workspaceID"],
        "host": route["endpoint"]["host"],
        "port": int(route["endpoint"]["port"]),
        "attach_url": attach_url_for_ticket(filtered_ticket),
        "created_at": time.monotonic(),
    }


def create_ticket(workspace_id=None):
    if external_ticket_path:
        payload = json.loads(Path(external_ticket_path).read_text())
        if "ticket" in payload:
            attach_url = payload.get("attach_url") or payload.get("attachURL")
            if not attach_url:
                raise RuntimeError("external attach ticket payload is missing attach_url")
            return ticket_from_payload(payload, attach_url)
        required = ("token", "workspace_id", "host", "port", "attach_url")
        missing = [key for key in required if key not in payload]
        if missing:
            raise RuntimeError(f"external attach ticket is missing fields: {missing}")
        return {
            "token": payload["token"],
            "workspace_id": payload["workspace_id"],
            "host": payload["host"],
            "port": int(payload["port"]),
            "attach_url": payload["attach_url"],
            "created_at": time.monotonic(),
        }

    params = {
        "ttl_seconds": ticket_ttl_seconds,
        "target": "simulator_injection",
    }
    if workspace_id:
        params["workspace_id"] = workspace_id
    payload = cmux_rpc("mobile.attach_ticket.create", params)
    return ticket_from_payload(payload, payload["attach_url"])


def launch_app_with_attach_ticket(ticket):
    bundle_id = f"dev.cmux.ios.{tag}"
    run(["xcrun", "simctl", "terminate", simulator_id, bundle_id], cwd=Path("/"), check=False)
    launch_output = run(
        ["xcrun", "simctl", "launch", "--terminate-running-process", simulator_id, bundle_id],
        cwd=Path("/"),
        extra_env={
            "SIMCTL_CHILD_CMUX_UITEST_MOCK_DATA": "1",
            "SIMCTL_CHILD_CMUX_UITEST_ATTACH_URL": ticket["attach_url"],
            "SIMCTL_CHILD_CMUX_MOBILE_DEV_STACK_AUTH_TOKEN": dev_stack_auth_token,
            "SIMCTL_CHILD_CMUX_MOBILE_SOAK_OPEN_SELECTED_WORKSPACE": "1",
            "SIMCTL_CHILD_AppleLanguages": "(en)",
            "SIMCTL_CHILD_AppleLocale": "en_US",
        },
    ).strip()
    log(f"app_launch ticket_workspace={ticket['workspace_id'][:8]} output={launch_output}")
    time.sleep(attach_settle_seconds)
    assert_attached_ui(ticket)


def reattach_app_with_attach_ticket(ticket):
    if reattach_mode == "relaunch":
        launch_app_with_attach_ticket(ticket)
        return
    if reattach_mode != "openurl":
        raise RuntimeError(f"unsupported MOBILE_REATTACH_MODE={reattach_mode!r}")

    output = run(
        ["xcrun", "simctl", "openurl", simulator_id, ticket["attach_url"]],
        cwd=Path("/"),
    ).strip()
    log(f"app_openurl ticket_workspace={ticket['workspace_id'][:8]} output={output}")
    time.sleep(attach_settle_seconds)
    assert_attached_ui(ticket)


def simulator_accessibility_snapshot():
    if shutil.which("xcodebuildmcp") is None:
        return "xcodebuildmcp unavailable"
    output = run(
        ["xcodebuildmcp", "ui-automation", "snapshot-ui", "--simulator-id", simulator_id, "--output", "json"],
        cwd=Path("/"),
        check=False,
    )
    return output


def accessibility_snapshot_unavailable(snapshot):
    lowered = snapshot.lower()
    return (
        "failed to get accessibility hierarchy" in lowered
        or "no translation object returned" in lowered
        or "axe command 'describe-ui' failed" in lowered
        or "xcodebuildmcp unavailable" in lowered
    )


def capture_attachment_fallback_screenshot():
    fallback_root = soak_root / "attachment-fallbacks"
    fallback_root.mkdir(parents=True, exist_ok=True)
    screenshot_command_path = fallback_root / f"{client_id}-{int(time.time())}-screenshot-command.json"
    copied = fallback_root / f"{client_id}-{int(time.time())}.png"
    if shutil.which("xcodebuildmcp") is None:
        run(["xcrun", "simctl", "io", simulator_id, "screenshot", "--type=png", str(copied)], cwd=Path("/"))
    else:
        screenshot_output = run_json_file(
            [
                "xcodebuildmcp",
                "ui-automation",
                "screenshot",
                "--simulator-id",
                simulator_id,
                "--return-format",
                "path",
                "--output",
                "json",
            ],
            screenshot_command_path,
        )
        parsed = json.loads(screenshot_output)
        screenshot_path = parsed.get("path") or parsed.get("screenshotPath")
        if not screenshot_path:
            text_chunks = [
                item.get("text", "")
                for item in parsed.get("content", [])
                if isinstance(item, dict)
            ]
            match = re.search(r"(/[^\n]+?\.(?:png|jpg|jpeg))", "\n".join(text_chunks))
            if match:
                screenshot_path = match.group(1)
        if not screenshot_path or not Path(screenshot_path).exists():
            raise RuntimeError(f"attachment fallback screenshot missing path output={screenshot_output[:800]}")
        shutil.copyfile(screenshot_path, copied)
    return copied


def assert_attached_ui(ticket):
    blockers = [
        "Open in “cmux DEV",
        "Sign in with Apple",
        "Sign in with Google",
        "Email address",
        "Email me a code",
        "signin.apple",
        "signin.google",
    ]
    deadline = time.monotonic() + 15
    last_snapshot = ""
    saw_snapshot_unavailable = False
    while time.monotonic() < deadline:
        snapshot = simulator_accessibility_snapshot()
        last_snapshot = snapshot
        if accessibility_snapshot_unavailable(snapshot):
            saw_snapshot_unavailable = True
            time.sleep(0.5)
            continue
        visible_blockers = [blocker for blocker in blockers if blocker in snapshot]
        if visible_blockers:
            raise RuntimeError(f"simulator UI is not attached to terminal; visible blockers={visible_blockers}")

        if (
            "MobileTerminalSurface" in snapshot
            or "MobileWorkspaceShell" in snapshot
            or "MobileWorkspaceList" in snapshot
        ):
            return
        time.sleep(0.5)

    if saw_snapshot_unavailable:
        screenshot_path = capture_attachment_fallback_screenshot()
        workspaces = framed_rpc(ticket, "mobile.workspace.list", {})
        workspace_count = len(workspaces.get("workspaces", []))
        terminal_count = sum(len(workspace.get("terminals", [])) for workspace in workspaces.get("workspaces", []))
        if workspace_count >= expected_min_workspaces and terminal_count > 0:
            log(
                "attached_ui_snapshot_unavailable "
                f"screenshot={screenshot_path} workspaces={workspace_count} terminals={terminal_count}"
            )
            return

    raise RuntimeError(
        "simulator UI is not showing a mobile workspace or terminal surface; "
        f"snapshot_prefix={last_snapshot[:800]}"
    )


def framed_rpc(ticket, method, params, *, use_stack_auth=False):
    auth = {"attach_token": ticket["token"]}
    if use_stack_auth and dev_stack_auth_token:
        auth["stack_access_token"] = dev_stack_auth_token
    request = {
        "id": f"{method}-{int(time.time() * 1000)}",
        "method": method,
        "params": params,
        "auth": auth,
    }
    data = json.dumps(request, separators=(",", ":")).encode()
    started = time.monotonic()
    try:
        with socket.create_connection((ticket["host"], ticket["port"]), timeout=socket_timeout_seconds) as conn:
            conn.settimeout(socket_timeout_seconds)
            conn.sendall(struct.pack(">I", len(data)) + data)
            header = conn.recv(4)
            if len(header) != 4:
                raise RuntimeError(f"{method} short framed response header")
            length = struct.unpack(">I", header)[0]
            body = bytearray()
            while len(body) < length:
                chunk = conn.recv(length - len(body))
                if not chunk:
                    raise RuntimeError(f"{method} short framed response body")
                body.extend(chunk)
    except socket.timeout as exc:
        elapsed = time.monotonic() - started
        raise TimeoutError(f"{method} timed out after {elapsed:.1f}s") from exc
    response = json.loads(body)
    if not response.get("ok"):
        raise RuntimeError(f"{method} failed: {response}")
    return response["result"]


def assert_full_workspace_list(ticket, iteration):
    workspaces = framed_rpc(ticket, "mobile.workspace.list", {})
    full_count = len(workspaces.get("workspaces", []))
    if full_count < expected_min_workspaces:
        raise RuntimeError(
            f"full workspace list too small: count={full_count} expected>={expected_min_workspaces}"
        )
    log(f"full_workspace_list_ok iteration={iteration} count={full_count}")
    return workspaces


def visible_lines(snapshot):
    rows = snapshot["snapshot"].get("scrollbackRows", []) + snapshot["snapshot"].get("visibleRows", [])
    return ["".join(cell.get("text", "") for cell in row.get("cells", [])) for row in rows]


def snapshot_summary(snapshot):
    payload = snapshot.get("snapshot", {})
    grid = payload.get("gridSize", {})
    visible_rows = payload.get("visibleRows", [])
    scrollback_rows = payload.get("scrollbackRows", [])
    return {
        "grid": grid,
        "visible_row_count": len(visible_rows),
        "scrollback_row_count": len(scrollback_rows),
        "fidelity": snapshot.get("fidelity", "unknown"),
        "tail": visible_lines(snapshot)[-40:],
    }


def log(message):
    log_path.parent.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    line = f"{stamp} {message}"
    print(line, flush=True)
    with log_path.open("a") as f:
        f.write(line + "\n")


def write_status(status, iterations, failures, **extra):
    payload = {
        "status": status,
        "iterations": iterations,
        "failures": failures,
        "elapsed_seconds": round(time.monotonic() - STARTED, 1),
        "profile": profile,
    }
    payload.update(extra)
    status_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = status_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=2))
    tmp.replace(status_path)


def write_failure_diagnostics(ticket, terminal_id, iteration, error):
    diagnostic_root = diagnostics_dir / f"{client_id}-iteration-{iteration}-{int(time.time())}"
    diagnostic_root.mkdir(parents=True, exist_ok=True)

    manifest = {
        "client_id": client_id,
        "iteration": iteration,
        "error": str(error),
        "workspace_id": ticket.get("workspace_id"),
        "terminal_id": terminal_id,
        "simulator_id": simulator_id,
        "tag": tag,
        "profile": profile,
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }

    if terminal_id:
        try:
            snapshot = framed_rpc(ticket, "mobile.terminal.snapshot", {
                "workspace_id": ticket["workspace_id"],
                "terminal_id": terminal_id,
                "client_id": client_id,
                "viewport_columns": 54,
                "viewport_rows": 42,
                "max_scrollback_rows": max(max_scrollback_rows, 500),
            })
            (diagnostic_root / "terminal-snapshot.json").write_text(json.dumps(snapshot, indent=2))
            (diagnostic_root / "terminal-text.txt").write_text("\n".join(visible_lines(snapshot)))
            manifest["terminal_snapshot"] = snapshot_summary(snapshot)
        except Exception as snapshot_error:
            manifest["terminal_snapshot_error"] = str(snapshot_error)

    try:
        host_status = framed_rpc(ticket, "mobile.host.status", {}) if external_ticket_path else cmux_rpc("mobile.host.status", {})
        (diagnostic_root / "mobile-host-status.json").write_text(json.dumps(host_status, indent=2))
    except Exception as host_error:
        manifest["host_status_error"] = str(host_error)

    try:
        workspaces = framed_rpc(ticket, "mobile.workspace.list", {"workspace_id": ticket["workspace_id"]})
        (diagnostic_root / "workspace-list.json").write_text(json.dumps(workspaces, indent=2))
    except Exception as workspace_error:
        manifest["workspace_list_error"] = str(workspace_error)

    if shutil.which("xcodebuildmcp") is not None:
        try:
            ui_output = run_json_file(
                ["xcodebuildmcp", "ui-automation", "snapshot-ui", "--simulator-id", simulator_id, "--output", "json"],
                diagnostic_root / "ui-snapshot.json",
            )
            manifest["ui_snapshot_prefix"] = ui_output[:1000]
        except Exception as ui_error:
            manifest["ui_snapshot_error"] = str(ui_error)
        try:
            screenshot_output = run_json_file(
                ["xcodebuildmcp", "ui-automation", "screenshot", "--simulator-id", simulator_id, "--return-format", "path", "--output", "json"],
                diagnostic_root / "screenshot-command.json",
            )
            try:
                parsed = json.loads(screenshot_output)
                screenshot_path = parsed.get("path") or parsed.get("screenshotPath")
                if not screenshot_path:
                    text_chunks = [
                        item.get("text", "")
                        for item in parsed.get("content", [])
                        if isinstance(item, dict)
                    ]
                    match = re.search(r"(/[^\n]+?\\.(?:png|jpg|jpeg))", "\n".join(text_chunks))
                    if match:
                        screenshot_path = match.group(1)
                if screenshot_path and Path(screenshot_path).exists():
                    copied = diagnostic_root / "screenshot.png"
                    shutil.copyfile(screenshot_path, copied)
                    manifest["screenshot"] = str(copied)
            except Exception as parse_error:
                manifest["screenshot_parse_error"] = str(parse_error)
        except Exception as screenshot_error:
            manifest["screenshot_error"] = str(screenshot_error)

    try:
        ps_output = run(["ps", "-axo", "pid,ppid,%cpu,rss,comm,args"], cwd=Path("/"), check=False)
        (diagnostic_root / "processes.txt").write_text(ps_output)
    except Exception as ps_error:
        manifest["process_error"] = str(ps_error)

    if cmux_log_path.exists():
        try:
            lines = cmux_log_path.read_text(errors="replace").splitlines()
            (diagnostic_root / "cmux-debug-tail.log").write_text("\n".join(lines[-cmux_log_tail_lines:]) + "\n")
        except Exception as log_error:
            manifest["cmux_log_error"] = str(log_error)

    (diagnostic_root / "manifest.json").write_text(json.dumps(manifest, indent=2))
    log(f"diagnostics iteration={iteration} path={diagnostic_root}")
    return diagnostic_root


def send_color_probe(ticket, terminal_id, iteration):
    bars = {
        "RED_E2E": "\\033[48;2;220;40;40;38;2;255;255;255mRED_E2E_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX\\033[0m\\n",
        "GREEN_E2E": "\\033[48;2;40;180;80;38;2;0;0;0mGREEN_E2E_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX\\033[0m\\n",
        "BLUE_E2E": "\\033[48;2;50;120;240;38;2;255;255;255mBLUE_E2E_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX\\033[0m\\n",
        "YELLOW_E2E": "\\033[48;2;230;210;50;38;2;0;0;0mYELLOW_E2E_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX\\033[0m\\n",
    }
    command = "printf '\\033[2J\\033[H" + "".join(bars.values()) + "'\n"
    with terminal_mutation_lock(f"color-{iteration}"):
        framed_rpc(ticket, "mobile.terminal.input", {
            "workspace_id": ticket["workspace_id"],
            "terminal_id": terminal_id,
            "text": command,
        })
        time.sleep(color_settle_seconds)
        shot = soak_root / f"{client_id}-color-{iteration}.png"
        last_error = None
        counts = ""
        attempts = max(1, color_verify_attempts)
        for attempt in range(1, attempts + 1):
            run(["xcrun", "simctl", "io", simulator_id, "screenshot", "--type=png", str(shot)], cwd=Path("/"))
            try:
                counts = run(["swift", str(color_verify_script), str(shot)], cwd=Path("/")).strip()
                break
            except Exception as exc:
                last_error = exc
                if attempt < attempts:
                    time.sleep(color_verify_retry_seconds)
        else:
            diagnostic = framed_rpc(ticket, "mobile.terminal.snapshot", {
                "workspace_id": ticket["workspace_id"],
                "terminal_id": terminal_id,
                "client_id": client_id,
                "viewport_columns": 54,
                "viewport_rows": 42,
                "max_scrollback_rows": 120,
            })
            text = "\n".join(visible_lines(diagnostic))
            missing = [label for label in COLOR_PROBE_LABELS if label not in text]
            styled_cells = 0
            for row in diagnostic["snapshot"].get("visibleRows", []):
                for cell in row.get("cells", []):
                    style = cell.get("style", {})
                    if style.get("foreground") or style.get("background") or style.get("inverse"):
                        styled_cells += 1
            fidelity = diagnostic.get("fidelity", "unknown")
            raise RuntimeError(
                "color probe screenshot failed "
                f"screenshot={shot} attempts={attempts} backend_fidelity={fidelity} "
                f"styled_cells={styled_cells} missing_labels={missing}: {last_error}"
            ) from last_error
        log(f"color_ok iteration={iteration} screenshot={shot} counts={counts}")


def check_color_probe(ticket, terminal_id, iteration):
    try:
        send_color_probe(ticket, terminal_id, iteration)
    except Exception as exc:
        if color_failure_is_fatal:
            raise
        log(f"color_warn iteration={iteration} error={exc}")


def wait_for_terminal_text(ticket, terminal_id, expected):
    started_at = time.monotonic()
    attempts = max(1, terminal_output_attempts)
    last_snapshot = None
    last_text = ""
    compact_expected = re.sub(r"\s+", "", expected)
    for attempt in range(1, attempts + 1):
        refreshed = framed_rpc(ticket, "mobile.terminal.snapshot", {
            "workspace_id": ticket["workspace_id"],
            "terminal_id": terminal_id,
            "client_id": client_id,
            "viewport_columns": 54,
            "viewport_rows": 42,
            "max_scrollback_rows": max_scrollback_rows,
        })
        last_snapshot = refreshed
        text = "\n".join(visible_lines(refreshed))
        last_text = text
        compact_text = re.sub(r"\s+", "", text)
        if expected in text or compact_expected in compact_text:
            return {
                "attempts": attempt,
                "latency_ms": round((time.monotonic() - started_at) * 1000, 1),
                "fidelity": refreshed.get("fidelity", "unknown"),
                "summary": snapshot_summary(refreshed),
            }
        if attempt < attempts:
            time.sleep(terminal_output_retry_seconds)
    detail = ""
    if last_snapshot is not None:
        detail = f" snapshot={snapshot_summary(last_snapshot)}"
    tail = "\\n".join(last_text.splitlines()[-8:])
    raise RuntimeError(f"missing terminal round-trip output: {expected}{detail} tail={tail!r}")


STARTED = time.monotonic()


def main():
    deadline = STARTED + duration_seconds
    iterations = 0
    failures = 0
    ticket = create_ticket()
    launch_app_with_attach_ticket(ticket)
    terminal_id = None

    while time.monotonic() < deadline:
        iterations += 1
        try:
            if time.monotonic() - ticket["created_at"] > reattach_interval_seconds:
                ticket = create_ticket(ticket["workspace_id"])
                reattach_app_with_attach_ticket(ticket)

            if dev_origin:
                run(["curl", "-fsS", dev_origin], cwd=Path("/"))
            host_status = framed_rpc(ticket, "mobile.host.status", {}) if external_ticket_path else cmux_rpc("mobile.host.status", {})
            if not host_status["host_service"]["is_running"]:
                raise RuntimeError(f"host not running: {host_status}")

            if iterations == 1 or (
                full_workspace_list_interval > 0
                and iterations % full_workspace_list_interval == 0
            ):
                assert_full_workspace_list(ticket, iterations)

            workspaces = framed_rpc(ticket, "mobile.workspace.list", {"workspace_id": ticket["workspace_id"]})
            workspace = workspaces["workspaces"][0]
            if dev_stack_auth_token and (iterations == 1 or iterations % max(1, input_interval) == 0):
                full_list = framed_rpc(ticket, "mobile.workspace.list", {}, use_stack_auth=True)
                full_count = len(full_list.get("workspaces", []))
                if full_count < 1:
                    raise RuntimeError("dev stack auth workspace list returned no workspaces")
                log(f"dev_auth_workspace_list_ok iteration={iterations} count={full_count}")
            terminals = workspace.get("terminals", [])
            if not terminals:
                raise RuntimeError("workspace has no terminals")
            terminal_id = terminals[0]["id"]

            if profile == "crash-finder":
                cols = random.choice([32, 40, 54, 64, 84, 96, 120, 132])
                rows = random.choice([8, 12, 18, 24, 42, 48, 60])
            else:
                cols = random.choice([54, 64, 84, 96])
                rows = random.choice([18, 24, 42, 48])
            snapshot = framed_rpc(ticket, "mobile.terminal.snapshot", {
                "workspace_id": ticket["workspace_id"],
                "terminal_id": terminal_id,
                "client_id": client_id,
                "viewport_columns": cols,
                "viewport_rows": rows,
                "max_scrollback_rows": max_scrollback_rows,
            })
            grid = snapshot["snapshot"]["gridSize"]
            if grid["columns"] < 20 or grid["rows"] < 5:
                raise RuntimeError(f"bad grid size: {grid}")

            if input_interval > 0 and iterations % input_interval == 0:
                client_token = re.sub(r"[^a-z0-9]", "", client_id.lower())[-3:] or "mob"
                left = random.randint(100_000, 900_000)
                right = iterations
                unique = f"ms{client_token}{left + right}"
                args = " ".join(f"$(({left + (offset * 997)}+{right}))" for offset in range(input_burst_commands))
                command = f"printf 'ms{client_token}%s\\n' {args}\n"
                with terminal_mutation_lock(f"input-{iterations}"):
                    input_result = framed_rpc(ticket, "mobile.terminal.input", {
                        "workspace_id": ticket["workspace_id"],
                        "terminal_id": terminal_id,
                        "text": command,
                    })
                    log(
                        "input_sent "
                        f"iteration={iterations} queued={1 if input_result.get('queued') else 0} "
                        f"marker={unique} chars={len(command)}"
                    )
                    output_result = wait_for_terminal_text(ticket, terminal_id, unique)
                    log(
                        "input_visible "
                        f"iteration={iterations} marker={unique} "
                        f"latency_ms={output_result['latency_ms']} "
                        f"attempts={output_result['attempts']} "
                        f"fidelity={output_result['fidelity']} "
                        f"grid={output_result['summary']['grid']['columns']}x{output_result['summary']['grid']['rows']}"
                    )

            if iterations == 1 or (color_probe_interval > 0 and iterations % color_probe_interval == 0):
                check_color_probe(ticket, terminal_id, iterations)
            elif screenshot_interval > 0 and iterations % screenshot_interval == 0:
                shot = soak_root / f"{client_id}-{iterations}.png"
                run(["xcrun", "simctl", "io", simulator_id, "screenshot", "--type=png", str(shot)], cwd=Path("/"))

            log(
                "ok "
                f"iteration={iterations} failures={failures} "
                f"workspace={ticket['workspace_id'][:8]} terminal={(terminal_id or '')[:8]} "
                f"grid={grid['columns']}x{grid['rows']} requested={cols}x{rows}"
            )
            write_status("running", iterations, failures, last_terminal_id=terminal_id)
            time.sleep(loop_sleep_seconds)
        except Exception as exc:
            failures += 1
            diagnostic_path = None
            try:
                diagnostic_path = write_failure_diagnostics(ticket, terminal_id, iterations, exc)
            except Exception as diagnostic_error:
                log(f"diagnostics_failed iteration={iterations} error={diagnostic_error}")
            log(f"fail iteration={iterations} failures={failures} error={exc} diagnostics={diagnostic_path}")
            if failures >= failure_limit:
                write_status("failed", iterations, failures, error=str(exc), diagnostics=str(diagnostic_path or ""))
                raise
            time.sleep(failure_sleep_seconds)

    write_status("passed", iterations, failures)
    log(f"passed iterations={iterations} failures={failures} elapsed={round(time.monotonic() - STARTED, 1)}")


if __name__ == "__main__":
    main()
