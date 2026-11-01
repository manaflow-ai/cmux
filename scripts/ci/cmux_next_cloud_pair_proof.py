"""Optional real Cloud leg of the paired iPhone rig; no provisioning or fake data.

CMUX_IOS_CLOUD_PROOF_FILE names a probe-owned, current-user 0600 JSON file.
The existing provisioner supplies the machine/session and a known assistant
history reply. prompt and expected_reply are synthetic templates containing
{nonce}; the joined expected reply must not occur in the submitted prompt.
Only UI actions send the prompt and copy the assistant's resulting answer.
Simulator push injection proves routing only, never APNs delivery.
"""
import json
import os
import re
import secrets
import stat
import subprocess
import time
from pathlib import Path


class ProofFailure(RuntimeError):
    """Messages name the failed check, never runner inputs or credentials."""


FIELDS = frozenset(("owner_user_id", "stack_project_id", "machine_id", "team_id",
                    "machine_name", "session_id", "session_name", "history_reply",
                    "prompt", "expected_reply"))


def read_proof(path, *, artifact_root=None):
    if artifact_root is not None and Path(path).resolve().is_relative_to(Path(artifact_root).resolve()):
        raise ProofFailure("Cloud proof input must stay outside the artifact directory")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "r") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid():
            raise ProofFailure("Cloud proof input must be a current-user 0600 regular file")
        if info.st_size > 65536:
            raise ProofFailure("Cloud proof input is not a bounded manifest")
        try:
            proof = json.load(source)
        except (ValueError, UnicodeError) as from_error:
            raise ProofFailure("Cloud proof input is not JSON") from from_error
    if not isinstance(proof, dict) or set(proof) != FIELDS:
        raise ProofFailure("Cloud proof input has missing or unknown fields")
    if any(not isinstance(v, str) or not v.strip() or len(v) > 8192 for v in proof.values()):
        raise ProofFailure("Cloud proof input fields must be nonempty bounded strings")
    if any("{nonce}" not in proof[k] for k in ("prompt", "expected_reply")):
        raise ProofFailure("Cloud prompt and reply must each include the fresh {nonce} template")
    return proof


def challenge(proof, nonce):
    prompt = proof["prompt"].replace("{nonce}", nonce)
    expected = proof["expected_reply"].replace("{nonce}", nonce)
    if expected in prompt or expected in proof["history_reply"]:
        raise ProofFailure("Expected assistant reply must differ from prompt and existing history")
    return prompt, expected


def nodes(tree):
    pending = list(tree) if isinstance(tree, list) else [tree]
    while pending:
        node = pending.pop()
        if isinstance(node, dict):
            yield node
            pending.extend(node.get("children") or [])


def label(node):
    return str(node.get("AXLabel") or "")


def visible(node, bounds=None):
    frame = node.get("frame") or {}
    if frame.get("width", 0) <= 0 or frame.get("height", 0) <= 0:
        return False
    if bounds is None:
        return frame.get("y", -1) >= 0
    return (frame.get("x", 0) < bounds["x"] + bounds["width"] and
            frame.get("x", 0) + frame["width"] > bounds["x"] and
            frame.get("y", 0) < bounds["y"] + bounds["height"] and
            frame.get("y", 0) + frame["height"] > bounds["y"])


def unique(matches, what):
    if len(matches) > 1:
        raise ProofFailure(f"Ambiguous UI control: {what}")
    return matches[0] if matches else None


class PhoneUI:
    def __init__(self, simctl, udid, bundle, env):
        self.simctl, self.udid, self.bundle, self.env = simctl, udid, bundle, env
        self.bounds = None

    def run(self, argv, *, input=None, env=None, check=True):
        result = subprocess.run(argv, input=input, env=env, capture_output=True, text=True, timeout=45)
        if check and result.returncode:
            # stderr/argv may contain runner input. Never echo them into artifacts.
            raise ProofFailure(f"Cloud UI command failed: {Path(argv[0]).name}")
        return result.stdout

    def tree(self):
        try:
            tree = json.loads(self.run(["axe", "describe-ui", "--udid", self.udid]))
            roots = tree if isinstance(tree, list) else [tree]
            frame = next((n.get("frame") for n in roots if isinstance(n, dict) and n.get("frame")), None)
            if frame and frame.get("width", 0) > 0 and frame.get("height", 0) > 0:
                self.bounds = frame
            return tree
        except ValueError as error:
            raise ProofFailure("Cloud UI accessibility tree was not JSON") from error

    def wait(self, check, what, seconds=60):
        # A bounded UI observation, not a GitHub/fleet polling loop.
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            found = check()
            if found:
                return found
            time.sleep(1)
        raise ProofFailure(f"Cloud UI did not show {what} before its deadline")

    def find(self, predicate):
        tree = self.tree()
        return [n for n in nodes(tree) if visible(n, self.bounds) and predicate(n)]

    def control(self, predicate, what):
        return self.wait(lambda: unique(self.find(predicate), what), what)

    def tap(self, node, *, press=False):
        f = node["frame"]
        if not visible(node, self.bounds):
            raise ProofFailure("Cloud UI control is outside the visible screen")
        left, top, right, bottom = f["x"], f["y"], f["x"] + f["width"], f["y"] + f["height"]
        if self.bounds:
            b = self.bounds
            left, top = max(left, b["x"]), max(top, b["y"])
            right, bottom = min(right, b["x"] + b["width"]), min(bottom, b["y"] + b["height"])
        self.run(["axe", "touch" if press else "tap", "--udid", self.udid,
                  "-x", str((left + right) / 2), "-y", str((top + bottom) / 2)] +
                 (["--down", "--up", "--delay", "0.08"] if press else ["--tap-style", "simulator"]))

    def named(self, text):
        self.tap(self.control(lambda n: n.get("type") == "Button" and label(n) == text, text))

    def launch(self, args):
        self.run(self.simctl + ["terminate", self.udid, self.bundle], check=False)
        self.run(self.simctl + ["launch", self.udid, self.bundle] + args, env=self.env)

    def copy(self, button):
        sentinel = "not-copied-" + secrets.token_hex(12)
        self.run(self.simctl + ["pbcopy", self.udid], input=sentinel)
        self.tap(button)
        value = self.wait(lambda: (lambda s: s if s != sentinel else None)(
            self.run(self.simctl + ["pbpaste", self.udid])), "fresh clipboard data", seconds=10)
        return value

    def verify_session(self, proof):
        title = self.control(lambda n: n.get("type") == "Button"
                             and label(n).endswith(" in " + proof["machine_name"]), "Cloud chat title")
        self.tap(title, press=True)
        copied = self.copy(self.control(lambda n: n.get("type") == "Button"
                                       and label(n) == "Copy Session ID", "Copy Session ID"))
        if copied.strip() != proof["session_id"]:
            raise ProofFailure("UI opened a different Cloud session")

    def reply(self, expected):
        def copied_answer():
            tree = list(nodes(self.tree()))
            jump = unique([n for n in tree if visible(n, self.bounds) and n.get("type") == "Button"
                           and label(n) == "Jump to bottom"], "Jump to bottom")
            if jump:
                self.tap(jump)
                return False
            if not any(expected in str(n.get("AXLabel") or "") or expected in str(n.get("AXValue") or "") for n in tree):
                return False
            # Only completed assistant turns have the exact Copy action. Code
            # fences say Copy code. Reading the clipboard forbids prompt echoes.
            buttons = [n for n in tree if visible(n, self.bounds) and n.get("type") == "Button" and label(n) == "Copy"]
            if not buttons:
                return False
            button = max(buttons, key=lambda n: n["frame"]["y"])
            return self.copy(button).strip() == expected.strip()
        self.wait(copied_answer, "completed assistant reply", seconds=180)

    def select_mac(self, rig_name):
        self.tap(self.control(self.is_mac_picker, "relay Mac picker"), press=True)
        self.named(rig_name)

    @staticmethod
    def is_mac_picker(node):
        return node.get("type") in ("Button", "PopUpButton") and (label(node) == "Mac" or label(node).startswith("Mac,"))

    def await_cloud_destination(self, rig_name):
        selected = False
        def arrived():
            nonlocal selected
            if self.find(lambda n: n.get("AXUniqueId") == "chat.composer.field"):
                return True
            picker = unique(self.find(self.is_mac_picker), "relay Mac picker")
            if picker and not selected:
                selected = True
                text = " ".join(label(n) for n in nodes(picker)) + " " + str(picker.get("AXValue") or "")
                if rig_name not in text:
                    self.tap(picker, press=True)
                    self.named(rig_name)
            return False
        self.wait(arrived, "Cloud chat after notification tap", seconds=120)


def run_cloud_leg(proof, *, root, mac_env, email, rpc, phone_log, simctl, udid, bundle,
                  phone_env, rig_name, work, out, shot, note):
    """Runs only after real QR pairing succeeded, before the rig's teardown."""
    nonce = secrets.token_hex(16)
    prompt, expected = challenge(proof, nonce)
    auth = rpc("auth.status")
    if not auth.get("signed_in") or auth.get("user_id") != proof["owner_user_id"] or auth.get("email", "").lower() != email.lower():
        raise ProofFailure("Provisioned machine owner does not match the Mac/phone test account")
    config = Path(root, "Packages/macOS/CmuxNext/Sources/CmuxNextCloud/Config/CloudConfiguration.swift").read_text()
    default = re.search(r'static let developmentProjectID = "([^"]+)"', config)
    project = mac_env.get("CMUX_STACK_PROJECT_ID") or (default.group(1) if default else None)
    if mac_env.get("CMUX_AUTH_ENVIRONMENT", "").lower() == "production" or project != proof["stack_project_id"]:
        raise ProofFailure("Provisioned machine project does not match the tagged Mac")
    if not phone_log.wait(re.compile(r"Stack project " + re.escape(project) + r"\b"), 30):
        raise ProofFailure("Phone did not sign into the provisioned machine's Stack project")
    ui = PhoneUI(simctl, udid, bundle, phone_env)
    machine = ui.wait(lambda: next((m for m in rpc("cloud.machines").get("machines", [])
                                   if m.get("id") == proof["machine_id"]), None), "real Cloud machine in the signed-in Mac", 180)
    if machine.get("title") != proof["machine_name"]:
        raise ProofFailure("Provisioned Cloud machine name does not match the Mac's directory")
    opened = rpc("action.run", {"action": "cloudOpenMachine", "target": "machine:" + proof["machine_id"], "focus": True})
    if "error" in opened:
        raise ProofFailure("Mac refused to open the provisioned Cloud machine")
    ui.wait(lambda: any(m.get("id") == proof["machine_id"] and m.get("daemon") == "connected"
                       for m in rpc("cloud.machines").get("machines", [])), "Cloud daemon connection", 180)

    # This is the real Settings authorization request; never a permissions seed.
    ui.launch(["-cmux-mobile-settings-page", "notifications"])
    def permission():
        row = unique(ui.find(lambda n: n.get("AXUniqueId") == "settings.notifications.allow"), "notification settings")
        if row:
            texts = [label(n) for n in nodes(row)] + [str(row.get("AXValue") or "")]
            for state in ("On", "Off", "Not set"):
                if any(text == state or text.endswith(", " + state) for text in texts):
                    return row, state
        return None
    row, state = ui.wait(permission, "notification permission state")
    if state == "Off":
        raise ProofFailure("Simulator notification permission is denied; no permission bypass is used")
    if state == "Not set":
        ui.tap(row)
        ui.named("Allow")
        ui.wait(lambda: (permission() or (None, None))[1] == "On", "notification authorization")
    ui.launch(["-cmux-mobile-tab", "home"])
    ui.named("Cloud chats")
    ui.select_mac(rig_name)
    ui.named(proof["machine_name"])
    ui.tap(ui.control(lambda n: n.get("type") == "Button" and
                      (label(n) == proof["session_name"] or label(n).startswith(proof["session_name"] + ",")
                       or label(n).startswith(proof["session_name"] + "\n")), "Cloud session"))
    ui.verify_session(proof)
    ui.reply(proof["history_reply"])
    shot("phone-cloud-history")
    ui.tap(ui.control(lambda n: n.get("AXUniqueId") == "chat.composer.field", "Cloud composer"))
    ui.run(["axe", "type", prompt, "--udid", udid])
    ui.named("Send")
    ui.reply(expected)
    shot("phone-cloud-reply")

    title = "Cloud routing proof " + nonce
    payload = {"aps": {"alert": {"title": title, "body": "Tap to open the Cloud chat"}, "sound": "default"},
               "cmux": {"cloud": {"kind": "done", "event_id": nonce, "machine_id": proof["machine_id"],
                                    "team_id": proof["team_id"], "session_id": proof["session_id"]}}}
    push_file = Path(work, "cloud-routing-push.json")
    try:
        with open(push_file, "x", opener=lambda p, f: os.open(p, f, 0o600)) as file:
            json.dump(payload, file)
        # Cold tap: the prior chat view cannot make this check pass accidentally.
        ui.run(simctl + ["terminate", udid, bundle])
        ui.run(["axe", "button", "home", "--udid", udid])
        ui.run(simctl + ["push", udid, bundle, str(push_file)])
        ui.run(["axe", "swipe", "--udid", udid, "--start-x", "100", "--start-y", "5",
                "--end-x", "100", "--end-y", "600", "--duration", "0.4"])
        def notification():
            matching = ui.find(lambda n: title in label(n))
            for identifier in ("NotificationShortLookView", "ListCell"):
                found = unique([n for n in matching if n.get("AXUniqueId") == identifier], "injected notification banner")
                if found:
                    return found
            return unique([n for n in matching if n.get("type") == "Button"], "injected notification banner")
        banner = ui.wait(notification, "injected notification banner")
        ui.tap(banner)
        # The notification preserves Cloud identity; choosing its paired relay
        # Mac is allowed, but no local chat or supplied transcript can stand in.
        ui.await_cloud_destination(rig_name)
        ui.verify_session(proof)
        ui.reply(expected)
        shot("phone-cloud-notification-tap")
    finally:
        push_file.unlink(missing_ok=True)
    evidence = {"machine_id": proof["machine_id"], "team_id": proof["team_id"], "session_id": proof["session_id"],
                "owner_and_project_match": True, "history_copied_from_assistant": True,
                "reply_copied_from_assistant": expected.strip(), "notification_tap": True,
                "notification_transport": "simulator injection; routing proof only", "apns_delivery_proven": False}
    Path(out, "cloud-ui-proof.json").write_text(json.dumps(evidence, indent=2) + "\n")
    note("- Cloud: real paired history, unique UI send and assistant reply readback passed; cold notification tap passed (simulator routing only, no APNs receipt)")
