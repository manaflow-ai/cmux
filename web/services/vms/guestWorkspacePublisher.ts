import { shellQuote } from "./drivers/cmuxTuiDaemon";
import { vmEdgeAliasDomain, VM_PLACEHOLDER_API_KEY } from "../coderouter/vmGuestEnv";

const PUBLISHER_PATH = "/usr/local/lib/cmux/workspace-publisher.py";
const UNIT_PATH = "/etc/systemd/system/cmux-workspace-publisher.service";

/** Event-driven VM publisher. cmux-tui owns the authoritative tree and revision. */
export function guestWorkspacePublisherScript(): string {
  return `import json, os, select, subprocess, sys, urllib.request, ssl

def daemon_layout():
    try:
        layout = open("/etc/cmux/daemon-layout").read().strip()
    except OSError:
        layout = ""
    if layout == "user" and os.path.exists("/home/cmux/.cmux/bin/cmux-tui"):
        return "cmux", "/home/cmux", "/home/cmux/.cmux/bin/cmux-tui"
    return "root", "/root", os.environ.get("CMUX_TUI_BIN", "/usr/local/bin/cmux-tui")

DAEMON_USER, DAEMON_HOME, BIN = daemon_layout()
SESSION = os.environ.get("CMUX_TUI_SESSION", "cloud")
VM_ID = os.environ.get("CMUX_VM_ID", "")
if not VM_ID:
    for env_path in ("/home/cmux/.config/cmux/model-plane.env", "/etc/cmux/model-plane.env"):
        try:
            for line in open(env_path):
                if line.startswith("CMUX_VM_ID="):
                    VM_ID = line.split("=", 1)[1].strip().strip("\\\"'")
                    break
        except OSError:
            pass
        if VM_ID:
            break
PUBLISH_URL = os.environ.get("CMUX_WORKSPACE_PUBLISH_URL", ${JSON.stringify(`https://${vmEdgeAliasDomain()}/api/vm/workspace-snapshot`)})
AUTH = ${JSON.stringify(`Bearer ${VM_PLACEHOLDER_API_KEY}`)}
CA = "/usr/local/share/ca-certificates/freestyle-tls.crt"
EVENTS = {"workspace-added", "workspace-closed", "workspace-renamed", "workspace-moved", "tab-added", "tab-closed", "tab-renamed", "tree-changed"}

def call(*args):
    command = [BIN, "--session", SESSION, "--json", *args]
    if DAEMON_USER != "root":
        command = ["setpriv", "--reuid=cmux", "--regid=cmux", "--init-groups", "env", "HOME=" + DAEMON_HOME, "USER=cmux", "LOGNAME=cmux", *command]
    return subprocess.run(command, check=False, capture_output=True, text=True, timeout=20)

def payload(stdout):
    value = json.loads(stdout)
    if isinstance(value, dict) and value.get("ok") is True and isinstance(value.get("data"), dict):
        return value["data"]
    return value

def snapshot():
    result = call("session", "current", "snapshot")
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "cmux-tui snapshot failed")
    data = payload(result.stdout)
    if not isinstance(data, dict):
        raise RuntimeError("cmux-tui returned an invalid snapshot")
    generation = data.get("generation") or data.get("session", {}).get("generation")
    if not isinstance(generation, str) or not generation:
        try:
            generation = open("/etc/cmux/daemon-instance-id").read().strip()
        except OSError:
            generation = "cloud"
    revision = data.get("workspace_revision")
    if not isinstance(revision, int) or revision < 0:
        revision = data.get("workspaceRevision", 0)
    workspaces, terminals = [], []
    for index, workspace in enumerate(data.get("workspaces", [])):
        if not isinstance(workspace, dict):
            continue
        workspace_id = workspace.get("id") or workspace.get("workspace_id")
        if not isinstance(workspace_id, str) or not workspace_id:
            continue
        workspaces.append({"id": workspace_id, "name": str(workspace.get("name") or workspace_id), "index": int(workspace.get("index", index)), "focused": bool(workspace.get("focused") or workspace.get("active"))})
        for screen in workspace.get("screens", []):
            for pane in (screen.get("panes", []) if isinstance(screen, dict) else []):
                for tab in (pane.get("tabs", []) if isinstance(pane, dict) else []):
                    if not isinstance(tab, dict) or tab.get("kind") not in (None, "pty"):
                        continue
                    terminal_id = tab.get("terminal_resource_id") or tab.get("content_id") or tab.get("id")
                    if isinstance(terminal_id, str) and terminal_id:
                        terminals.append({"id": terminal_id, "title": str(tab.get("title") or tab.get("name") or ""), "workspaceId": workspace_id, "cwd": tab.get("cwd") if isinstance(tab.get("cwd"), str) else None, "agent": None})
    return {"generation": generation, "revision": int(revision), "snapshot": {"workspaces": workspaces, "terminals": terminals}}

def publish():
    current = snapshot()
    body_value = {"vmId": VM_ID, **current} if VM_ID else current
    body = json.dumps(body_value).encode()
    context = ssl.create_default_context()
    if os.path.isfile(CA):
        context.load_verify_locations(CA)
    request = urllib.request.Request(PUBLISH_URL, data=body, method="POST", headers={"Content-Type": "application/json", "Authorization": AUTH})
    with urllib.request.urlopen(request, timeout=30, context=context) as response:
        response.read(4096)

def subscribe():
    command = [BIN, "--session", SESSION, "--jsonl", "session", "current", "events"]
    if DAEMON_USER != "root":
        command = ["setpriv", "--reuid=cmux", "--regid=cmux", "--init-groups", "env", "HOME=" + DAEMON_HOME, "USER=cmux", "LOGNAME=cmux", *command]
    return subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)

def relevant(event):
    if event.get("event") in EVENTS:
        return True
    if event.get("kind") == "snapshot":
        return True
    if event.get("kind") == "delta":
        changes = json.dumps(event.get("changes", []), separators=(",", ":"))
        return any(marker in changes for marker in ("workspace", "tab", "terminal"))
    return False

publish()
while True:
    process = subscribe()
    try:
        for line in process.stdout:
            try:
                event = json.loads(line)
            except (TypeError, ValueError):
                continue
            if not relevant(event):
                continue
            # Drain already queued deltas before taking one authoritative snapshot.
            while select.select([process.stdout], [], [], 0)[0]:
                if not process.stdout.readline():
                    break
            try:
                publish()
            except Exception as error:
                print("workspace publish failed:", error, file=sys.stderr, flush=True)
    finally:
        process.kill()
        process.wait()
`;
}

/** Idempotently installs the event subscriber; systemd handles process restart. */
export function guestWorkspacePublisherInstallCommand(): string {
  const script = guestWorkspacePublisherScript();
  const unit = `[Unit]
Description=cmux workspace state publisher
After=network-online.target cmux-tui-daemon.service
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 ${PUBLISHER_PATH}
Restart=always
RestartSec=1
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
[Install]
WantedBy=multi-user.target
`;
  return `set -eu
install -d -m 0755 /usr/local/lib/cmux
cmux_workspace_tmp=$(mktemp -d)
trap 'rm -rf "$cmux_workspace_tmp"' EXIT
printf %s ${shellQuote(script)} > "$cmux_workspace_tmp/script"
printf %s ${shellQuote(unit)} > "$cmux_workspace_tmp/unit"
if ! cmp -s "$cmux_workspace_tmp/script" ${shellQuote(PUBLISHER_PATH)} || ! cmp -s "$cmux_workspace_tmp/unit" ${shellQuote(UNIT_PATH)}; then
  install -m 0644 "$cmux_workspace_tmp/script" ${shellQuote(PUBLISHER_PATH)}
  install -m 0644 "$cmux_workspace_tmp/unit" ${shellQuote(UNIT_PATH)}
  systemctl daemon-reload
  systemctl enable --now cmux-workspace-publisher.service >/dev/null 2>&1
else
  systemctl enable --now cmux-workspace-publisher.service >/dev/null 2>&1
fi`;
}
