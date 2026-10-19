#!/usr/bin/env python3
"""Verify live Agent Chat over a paired Mac/iOS run.

This driver intentionally uses the production route only:
  provider CLI -> tagged Mac AgentChatSessionRegistry -> mobile.chat RPC ->
  paired iOS app's AgentChatModeView.
It does not enable UITestConfig fixtures or call the preview source.

The streamed validation workflow provisions a real Claude auth token and starts
recorded sessions for Claude/Codex/OpenCode/Pi. We select Claude here because
that workflow already provides a real ``CLAUDE_CODE_OAUTH_TOKEN``; the other
providers use resume-only fake credentials and must not be treated as a live
response proof.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
DEBUG_CLI = ROOT / "scripts" / "cmux-debug-cli.sh"
PROMPT_PREFIX = "CMUX_AGENT_CHAT_E2E_ANSWER"


class DriverError(RuntimeError):
    pass


def run(command: list[str], *, timeout: float = 30.0, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=timeout, check=check)


def host_rpc(tag: str, method: str, params: dict[str, Any]) -> Any:
    env = dict(os.environ)
    env["CMUX_TAG"] = tag
    result = subprocess.run(
        [str(DEBUG_CLI), "rpc", method, json.dumps(params, separators=(",", ":"))],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=30,
    )
    if result.returncode != 0:
        raise DriverError(f"{method} failed (exit {result.returncode}): {result.stderr.strip()}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        # The tagged CLI normally emits only the JSON-RPC response, but an
        # attached debug notice can precede it on a reused runner. Keep the
        # parser strict about the response while tolerating that notice.
        start = result.stdout.find("{")
        if start >= 0:
            try:
                return json.loads(result.stdout[start:])
            except json.JSONDecodeError:
                pass
        raise DriverError(f"{method} returned non-JSON output: {result.stdout[-500:]!r}")


def payload_value(value: Any, key: str) -> Any:
    """Find a wire payload through the CLI's optional JSON-RPC envelope."""
    if isinstance(value, dict):
        if key in value:
            return value[key]
        for nested_key in ("result", "payload", "data", "value"):
            if nested_key in value:
                found = payload_value(value[nested_key], key)
                if found is not None:
                    return found
    return None


def sessions_from(value: Any) -> list[dict[str, Any]]:
    sessions = payload_value(value, "sessions")
    if not isinstance(sessions, list):
        raise DriverError(f"mobile.chat.sessions had no sessions array: {value!r}")
    return [item for item in sessions if isinstance(item, dict)]


def text_fragments(value: Any) -> list[str]:
    """Extract user-visible text fields from wire/UI JSON without IDs."""
    out: list[str] = []
    if isinstance(value, str):
        out.append(value)
    elif isinstance(value, dict):
        for key, nested in value.items():
            key_lower = key.casefold()
            if (key_lower in {"text", "summary", "prompt", "subject", "title", "label", "display_name", "message"}
                    or key_lower.endswith(("label", "value"))) and isinstance(nested, str):
                out.append(nested)
            elif isinstance(nested, (dict, list)):
                out.extend(text_fragments(nested))
    elif isinstance(value, list):
        for nested in value:
            out.extend(text_fragments(nested))
    return out


def history_messages(value: Any) -> list[dict[str, Any]]:
    messages = payload_value(value, "messages")
    if not isinstance(messages, list):
        raise DriverError(f"mobile.chat.history had no messages array: {value!r}")
    return [item for item in messages if isinstance(item, dict)]


def message_role(message: dict[str, Any]) -> str:
    role = message.get("role")
    return role if isinstance(role, str) else ""


def message_text(message: dict[str, Any]) -> str:
    return " ".join(text_fragments(message.get("kind", message))).strip()


def ui_elements(sim_id: str) -> list[dict[str, Any]]:
    result = run(["idb", "ui", "describe-all", "--udid", sim_id], timeout=30)
    if result.returncode != 0:
        raise DriverError(f"idb accessibility dump failed: {result.stderr.strip()}")
    try:
        raw = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise DriverError(f"idb accessibility dump was not JSON: {result.stdout[-500:]!r}") from error
    if isinstance(raw, list):
        return [element for element in raw if isinstance(element, dict)]
    # fb-idb has emitted both a bare array and an object wrapper across client
    # releases. Accept the wrapper without weakening the element shape check.
    if isinstance(raw, dict):
        for key in ("elements", "AXElements", "children"):
            value = raw.get(key)
            if isinstance(value, list):
                return [element for element in value if isinstance(element, dict)]
    return []


def element_match(elements: list[dict[str, Any]], needle: str) -> dict[str, Any] | None:
    needle = needle.casefold()
    candidates: list[dict[str, Any]] = []
    for element in elements:
        fields: list[str] = []
        for key, value in element.items():
            key_lower = key.casefold()
            if any(token in key_lower for token in ("label", "value", "identifier", "id", "title")):
                if isinstance(value, (str, int, float)):
                    fields.append(str(value))
        if any(needle == value.casefold() for value in fields):
            return element
        if any(needle in value.casefold() for value in fields):
            candidates.append(element)
    return candidates[0] if candidates else None


def element_frame(element: dict[str, Any]) -> tuple[float, float] | None:
    frame = element.get("frame") or element.get("AXFrame") or element.get("rect")
    if isinstance(frame, dict):
        try:
            values = {str(key).casefold(): value for key, value in frame.items()}
            return (
                float(values.get("x", 0)) + float(values.get("width", 0)) / 2,
                float(values.get("y", 0)) + float(values.get("height", 0)) / 2,
            )
        except (TypeError, ValueError):
            return None
    # Legacy fb-idb clients encode AXFrame as "{{x, y}, {width, height}}".
    # Keep the current dict form above, but parse the legacy wire form too so
    # the driver remains usable with the pinned and fallback client versions.
    if isinstance(frame, str):
        values = re.findall(r"-?\d+(?:\.\d+)?", frame)
        if len(values) >= 4:
            try:
                x, y, width, height = (float(value) for value in values[:4])
                return x + width / 2, y + height / 2
            except ValueError:
                return None
    return None


def tap_element(sim_id: str, needle: str, *, timeout: float = 30.0) -> dict[str, Any]:
    """Tap an accessibility element, retrying bounded external UI snapshots.

    There is no event callback from the simulator accessibility server. The
    one-second retry is therefore a bounded command retry, rather than a
    synchronization delay; every loop performs a fresh accessibility query.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        elements = ui_elements(sim_id)
        hit = element_match(elements, needle)
        if hit:
            center = element_frame(hit)
            if center:
                result = run(["idb", "ui", "tap", "--udid", sim_id, str(int(center[0])), str(int(center[1]))], timeout=30)
                if result.returncode != 0:
                    raise DriverError(f"tap {needle!r} failed: {result.stderr.strip()}")
                return hit
        time.sleep(1)
    raise DriverError(f"accessibility element {needle!r} did not appear within {timeout:.0f}s")


def wait_for_ui(sim_id: str, needle: str, *, timeout: float = 30.0) -> list[dict[str, Any]]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        elements = ui_elements(sim_id)
        if element_match(elements, needle):
            return elements
        time.sleep(1)
    raise DriverError(f"accessibility element {needle!r} did not appear within {timeout:.0f}s")


def ui_text(sim_id: str, text: str) -> None:
    result = run(["idb", "ui", "text", "--udid", sim_id, text], timeout=30)
    if result.returncode != 0:
        raise DriverError(f"typing Agent Chat prompt failed: {result.stderr.strip()}")


def choose_session(sessions: list[dict[str, Any]], provider: str, requested_id: str | None) -> dict[str, Any]:
    if requested_id:
        candidates = [item for item in sessions if item.get("id") == requested_id or item.get("session_id") == requested_id]
    else:
        candidates = [item for item in sessions if str(item.get("agent") or item.get("agent_kind") or "").casefold() == provider.casefold()]
    if not candidates:
        raise DriverError(
            f"no live {provider} Agent Chat session was published by mobile.chat.sessions; "
            "provider setup or hook discovery is missing (fixtures are not a fallback)"
        )
    live_candidates = [item for item in candidates if str(item.get("state") or "").casefold() != "ended"]
    if live_candidates:
        candidates = live_candidates
    candidates.sort(key=lambda item: str(item.get("last_activity_at") or item.get("last_activity") or ""), reverse=True)
    selected = candidates[0]
    session_id = selected.get("id") or selected.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        raise DriverError(f"session descriptor has no id: {selected!r}")
    return selected


def wait_for_session(tag: str, provider: str, requested_id: str | None, timeout: float = 90.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last_error = ""
    while time.monotonic() < deadline:
        try:
            selected = choose_session(sessions_from(host_rpc(tag, "mobile.chat.sessions", {})), provider, requested_id)
            session_id = selected.get("id") or selected.get("session_id")
            history_messages(host_rpc(tag, "mobile.chat.history", {"session_id": session_id, "limit": 200}))
            return selected
        except (DriverError, subprocess.TimeoutExpired) as error:
            last_error = str(error)
            time.sleep(2)
    raise DriverError(f"live provider session never became history-readable: {last_error}")


def wait_for_idle(tag: str, provider: str, session_id: str, timeout: float = 90.0) -> dict[str, Any]:
    """Wait until the selected live session can accept a normal Send action."""
    deadline = time.monotonic() + timeout
    last_state = ""
    while time.monotonic() < deadline:
        sessions = sessions_from(host_rpc(tag, "mobile.chat.sessions", {}))
        selected = next(
            (item for item in sessions if (item.get("id") or item.get("session_id")) == session_id),
            None,
        )
        if selected is not None:
            last_state = str(selected.get("state") or "")
            if last_state.casefold() in {"idle", "needs_input", "failed"}:
                return selected
            if last_state.casefold() == "ended":
                raise DriverError(f"{provider} session {session_id} ended before the live prompt")
        time.sleep(2)
    raise DriverError(f"{provider} session {session_id} stayed {last_state or 'unknown'}; cannot send a normal prompt")


def wait_for_response(
    tag: str,
    session_id: str,
    prompt: str,
    baseline_ids: set[str],
    baseline_max_seq: int,
    timeout: float = 180.0,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    deadline = time.monotonic() + timeout
    last_messages: list[dict[str, Any]] = []
    last_payload: Any = None
    while time.monotonic() < deadline:
        last_payload = host_rpc(tag, "mobile.chat.history", {"session_id": session_id, "limit": 200})
        last_messages = history_messages(last_payload)
        prompt_index = max(
            (index for index, message in enumerate(last_messages)
             if message_role(message) == "user" and prompt in message_text(message)),
            default=None,
        )
        if prompt_index is not None:
            later = last_messages[prompt_index + 1 :]
            assistant = [
                message for message in later
                if message_role(message) == "agent"
                and message_text(message)
                and (
                    str(message.get("id") or "") not in baseline_ids
                    or int(message.get("seq") or -1) > baseline_max_seq
                )
            ]
            if assistant:
                return last_messages, {"prompt_index": prompt_index, "assistant_message": assistant[-1]}
        time.sleep(2)
    raise DriverError(
        f"provider did not append a non-empty assistant response after mobile.chat.send; "
        f"observed {len(last_messages)} messages, last payload={last_payload!r}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--sim-id", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--provider", default="claude")
    parser.add_argument("--session-id")
    parser.add_argument(
        "--prompt",
        help="Prompt to send; defaults to a unique no-file-edit Claude request.",
    )
    args = parser.parse_args()
    if not args.prompt:
        args.prompt = (
            f"{PROMPT_PREFIX}_{uuid.uuid4().hex[:10]}: reply with one short sentence "
            "confirming you received this mobile Agent Chat prompt. Do not edit files."
        )

    output = Path(args.out)
    output.mkdir(parents=True, exist_ok=True)
    started = time.time()
    evidence: dict[str, Any] = {"provider": args.provider, "prompt": args.prompt, "tag": args.tag, "sim_id": args.sim_id}
    try:
        if args.provider.casefold() != "claude":
            raise DriverError("live verification currently supports Claude only; other workflow providers use resume-only fake credentials")
        if not os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
            raise DriverError("CLAUDE_CODE_OAUTH_TOKEN is missing; refusing to claim live provider verification")
        # Live production app must show the workspace shell button. Preview mode
        # exposes OpenAgentMode instead and is deliberately rejected before and
        # after opening the mode, so fixture UI cannot accidentally pass.
        if element_match(ui_elements(args.sim_id), "OpenAgentMode"):
            raise DriverError("Agent Chat preview fixture detected; live verification refuses fixture mode")
        tap_element(args.sim_id, "MobileAgentsModeButton", timeout=90)
        if element_match(ui_elements(args.sim_id), "OpenAgentMode"):
            raise DriverError("Agent Chat preview fixture detected; live verification refuses fixture mode")
        wait_for_ui(args.sim_id, "MobileAgentChatMode", timeout=30)

        selected = wait_for_session(args.tag, args.provider, args.session_id)
        session_id = selected.get("id") or selected.get("session_id")
        assert isinstance(session_id, str)
        selected = wait_for_idle(args.tag, args.provider, session_id)
        baseline = history_messages(host_rpc(args.tag, "mobile.chat.history", {"session_id": session_id, "limit": 200}))
        if not baseline:
            raise DriverError(f"live session {session_id} has an empty transcript")
        baseline_ids = {str(message.get("id")) for message in baseline if message.get("id") is not None}
        baseline_max_seq = max((int(message.get("seq") or -1) for message in baseline), default=-1)
        evidence["session_id"] = session_id
        evidence["inbound_history_count"] = len(baseline)
        evidence["session_state_before_send"] = selected.get("state")

        title = str(selected.get("title") or "")
        row_needle = title if title else str(selected.get("agent") or args.provider)
        tap_element(args.sim_id, row_needle, timeout=60)
        wait_for_ui(args.sim_id, "MobileAgentTranscript", timeout=30)
        transcript_ui = " ".join(text_fragments(ui_elements(args.sim_id)))
        visible_history_text = [message_text(message) for message in baseline if message_text(message)]
        if not any(text and text in transcript_ui for text in visible_history_text):
            raise DriverError("iOS Agent Chat transcript did not render the host history")
        evidence["inbound_transcript_rendered"] = True
        screenshot = run(["xcrun", "simctl", "io", args.sim_id, "screenshot", str(output / "agent-chat-before-send.png")], timeout=30)
        if screenshot.returncode != 0:
            raise DriverError(f"before-send screenshot failed: {screenshot.stderr.strip()}")

        tap_element(args.sim_id, "Message your agent", timeout=30)
        ui_text(args.sim_id, args.prompt)
        # An idle session exposes Send. Keep a clear failure if the UI regresses
        # to the working-session menu rather than silently choosing Queue/Steer.
        tap_element(args.sim_id, "Send", timeout=30)
        after, response = wait_for_response(
            args.tag,
            session_id,
            args.prompt,
            baseline_ids,
            baseline_max_seq,
        )
        response_text = message_text(response["assistant_message"])
        if not response_text:
            raise DriverError("host history contained an empty assistant response")
        evidence.update({
            "outbound_prompt_reached_host": True,
            "response_text": response_text[:4000],
            "history_count_after_send": len(after),
        })
        ui_wait = time.monotonic() + 30
        while time.monotonic() < ui_wait:
            labels = " ".join(text_fragments(ui_elements(args.sim_id)))
            # Match the response prose itself, rather than a message id or a
            # generic transcript marker. Whitespace is normalized because idb
            # may expose wrapped SwiftUI text as separate labels.
            normalized_labels = " ".join(labels.split())
            response_probe = " ".join(response_text.split())[:120]
            if args.prompt in normalized_labels and response_probe and response_probe in normalized_labels:
                evidence["response_rendered_on_ios"] = True
                break
            time.sleep(1)
        else:
            raise DriverError("host response arrived but iOS Agent Chat did not render the new response")
        screenshot = run(["xcrun", "simctl", "io", args.sim_id, "screenshot", str(output / "agent-chat-after-send.png")], timeout=30)
        if screenshot.returncode != 0:
            raise DriverError(f"after-send screenshot failed: {screenshot.stderr.strip()}")
        evidence["status"] = "pass"
        return 0
    except (DriverError, subprocess.TimeoutExpired, OSError, AssertionError) as error:
        evidence["status"] = "fail"
        evidence["error"] = str(error)
        return 1
    finally:
        evidence["duration_seconds"] = round(time.time() - started, 3)
        (output / "agent-chat.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except DriverError as error:
        print(f"LIVE AGENT CHAT FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
