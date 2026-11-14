"""Drive the owner-local Full-access path on the paired iPhone simulator.

This is intentionally a real UI proof.  The Mac chat is created through the
tagged app's own CLI socket, while every send and approval is made through the
phone accessibility surface.  The exported receipt contains hashes and
booleans only; screenshots are deterministic proof states and never include
pairing URLs, credentials, or runner logs.
"""
import hashlib
import json
import os
import subprocess
import time
from pathlib import Path

from cmux_next_cloud_pair_proof import PhoneUI, ProofFailure, label, nodes, unique


REFUSAL = "Not sent: Full access is off for this iPhone."
CHAT_NAME = "Owner local access proof"
REPLY = "OWNER_ACCESS_PROOF_REPLY"


def _hash(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _value(value, *keys):
    if isinstance(value, dict):
        for key in keys:
            if isinstance(value.get(key), str) and value[key]:
                return value[key]
            found = _value(value.get(key), *keys)
            if found:
                return found
    return None


def _cli(exe, env, args, namespace="agents"):
    try:
        result = subprocess.run([exe, "--json", namespace, *args], env=env,
                                capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ProofFailure(f"owner chat CLI failed: {type(error).__name__}") from None
    if result.returncode:
        raise ProofFailure("owner chat CLI refused the local session")
    # acpmux emits pretty JSON; the app CLI may also emit a final JSON line.
    for candidate in [result.stdout, *reversed(result.stdout.splitlines())]:
        try:
            value = json.loads(candidate)
        except ValueError:
            continue
        if isinstance(value, dict):
            return value
    raise ProofFailure("owner chat CLI returned no JSON receipt")


def _start_with_full_access_off(exe, env):
    """Use the supported off command in the proof's fresh daemon, then read back."""
    if not env.get("ACPMUX_HOME") or env.get("ACPMUX_SOCKET"):
        raise ProofFailure("owner proof needs its isolated daemon home")
    def phone():
        listed = _cli(exe, env, ["ticket", "ls"], namespace="host")
        devices = [device for device in listed.get("devices", [])
                   if device.get("role") == "phone" and device.get("revoked_at") is None]
        if len(devices) != 1 or not devices[0].get("id"):
            raise ProofFailure("owner proof needs exactly one paired phone")
        return devices[0]
    device = phone()
    changed = _cli(exe, env, ["ticket", "full-access", device["id"], "off"], namespace="host")
    observed = phone()
    if (changed.get("device", {}).get("full_access") is not False
            or observed["id"] != device["id"] or observed.get("full_access") is not False):
        raise ProofFailure("owner proof could not read back Full access off")


def _button(ui, predicate, what):
    return ui.control(lambda n: n.get("type") == "Button" and predicate(n), what)


def _assistant_reply(ui, expected):
    def copied():
        tree = list(nodes(ui.tree()))
        jumps = [n for n in tree if n.get("type") == "Button" and label(n) == "Jump to bottom"]
        if jumps:
            ui.tap(unique(jumps, "Jump to bottom"))
            return False
        buttons = [n for n in tree if n.get("type") == "Button" and label(n) == "Copy"]
        if not buttons:
            return False
        sentinel = "owner-proof-not-copied"
        ui.run(ui.simctl + ["pbcopy", ui.udid], input=sentinel)
        ui.tap(max(buttons, key=lambda n: n["frame"]["y"]))
        value = ui.wait(lambda: (lambda s: s if s != sentinel else None)(
            ui.run(ui.simctl + ["pbpaste", ui.udid])), "assistant transcript clipboard", seconds=10)
        return value.strip() == expected
    ui.wait(copied, "the owner chat assistant reply", seconds=180)


def _open_chat(ui, workspace_name, session_id):
    ui.launch(["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"])
    row = ui.control(lambda n: workspace_name in label(n), "owner proof workspace")
    ui.tap(row)
    # TabsKit's page title/menu capsule is the only bottom button before the
    # workspace page is open; its exact accessibility id is framework-owned.
    def menu():
        candidates = [n for n in ui.find(lambda n: n.get("type") == "Button")
                      if n.get("frame", {}).get("y", 0) > (ui.bounds or {}).get("height", 0) * 0.70]
        return max(candidates, key=lambda n: n["frame"]["y"]) if candidates else None
    ui.tap(ui.wait(menu, "workspace page menu"))
    ui.named("Search Agent Chats", "Search Agent Chats")
    row = ui.control(lambda n: n.get("AXUniqueId") == f"agentChats.row.{session_id}"
                      or CHAT_NAME in label(n), "owner proof chat")
    ui.tap(row)
    ui.control(lambda n: n.get("AXUniqueId") == "chat.composer.field", "owner chat composer")


def run_owner_access_proof(*, mac_app, sock, env, simctl, udid, bundle, phone_env,
                           work, out, shot, note):
    """Create and drive one owner-local chat; returns only after transcript read-back."""
    root = Path(work, "owner-local")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    cwd = root / "cwd"
    cwd.mkdir(mode=0o700, exist_ok=True)
    cli = Path(mac_app, "Contents", "Resources", "bin", "cmux")
    if not cli.is_file():
        raise ProofFailure("tagged app has no bundled cmux CLI")
    cli_env = dict(env, CMUX_SOCKET_PATH=sock)
    receipt = {
        "schema": "cmux-owner-access-proof-v1",
        "local_owner_chat": True,

        "pairing_prompt_captured": (Path(out, "screens", "pairing-dialog.png").is_file()),
        "refusal": REFUSAL,
        "refusal_is_one_sentence": True,
        "one_tap_control": "agentChat.fullAccess.enable",
    }
    created = _cli(str(cli), cli_env, ["chat", "new", "--top", "--harness", "claude",
                                       "--mode", "bypassPermissions", "--cwd", str(cwd),
                                       "--name", CHAT_NAME])
    session_id = _value(created, "chat", "sessionId")
    if not session_id:
        raise ProofFailure("owner chat CLI receipt had no session id")
    acpmux = Path(mac_app, "Contents", "Resources", "bin", "acpmux")
    if not acpmux.is_file():
        raise ProofFailure("tagged app has no bundled agent CLI")
    _start_with_full_access_off(str(acpmux), cli_env)
    receipt["full_access_started_off"] = True
    ui = PhoneUI(simctl, udid, bundle, phone_env)
    _open_chat(ui, CHAT_NAME, session_id)
    ui.tap(ui.control(lambda n: n.get("AXUniqueId") == "chat.composer.field", "owner composer"))
    prompt = f"Reply with exactly {REPLY} and no other words."
    ui.run(["axe", "type", prompt, "--udid", udid])
    ui.named("Send", "owner chat Send")
    ui.control(lambda n: REFUSAL in label(n), "Full-access refusal")
    receipt["refusal_visible"] = True
    receipt["refusal_sha256"] = _hash(REFUSAL)
    shot("owner-refusal")
    enable = ui.control(lambda n: n.get("AXUniqueId") == "agentChat.fullAccess.enable",
                        "one-tap Full access control")
    ui.tap(enable)
    receipt["approval_tapped"] = True
    shot("owner-approval")
    _assistant_reply(ui, REPLY)
    receipt["held_prompt_retried"] = True
    receipt["assistant_reply_read_back"] = True
    receipt["assistant_reply_sha256"] = _hash(REPLY)
    shot("owner-transcript")
    Path(out, "owner-access-proof.json").write_text(json.dumps(receipt, indent=2) + "\n")
    note("- owner-local: Full access off refusal, one-tap approval, held prompt retry, and transcript read-back passed")

