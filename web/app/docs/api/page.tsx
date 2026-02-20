import type { Metadata } from "next";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";

export const metadata: Metadata = {
  title: "API Reference",
  description:
    "cmux CLI and Unix socket API reference. Workspace management, split panes, input control, notifications, environment variables, and detection methods.",
};

function Cmd({
  name,
  desc,
  cli,
  socket,
}: {
  name: string;
  desc: string;
  cli: string;
  socket: string;
}) {
  return (
    <div className="mb-6">
      <h4>{name}</h4>
      <p>{desc}</p>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
        <CodeBlock title="CLI" lang="bash">{cli}</CodeBlock>
        <CodeBlock title="Socket" lang="json">{socket}</CodeBlock>
      </div>
    </div>
  );
}

export default function ApiPage() {
  return (
    <>
      <h1>API Reference</h1>
      <p>
        cmux provides both a CLI tool and a Unix socket for programmatic
        control. Every command is available through both interfaces.
      </p>

      <h2>Socket</h2>
      <table>
        <thead>
          <tr>
            <th>Build</th>
            <th>Path</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Release</td>
            <td>
              <code>/tmp/cmux.sock</code>
            </td>
          </tr>
          <tr>
            <td>Debug</td>
            <td>
              <code>/tmp/cmux-debug.sock</code>
            </td>
          </tr>
          <tr>
            <td>Tagged debug build</td>
            <td>
              <code>/tmp/cmux-debug-&lt;tag&gt;.sock</code>
            </td>
          </tr>
        </tbody>
      </table>
      <p>
        Override with the <code>CMUX_SOCKET_PATH</code> environment variable.
        Send one newline-terminated JSON request per call:
      </p>
      <CodeBlock lang="json">{`{"id":"req-1","method":"workspace.list","params":{}}
// Response:
{"id":"req-1","ok":true,"result":{"workspaces":[...]}}`}</CodeBlock>
      <Callout>
        JSON socket requests must use <code>method</code> and{" "}
        <code>params</code>. Legacy v1 JSON payloads such as{" "}
        <code>{`{"command":"..."}`}</code> are not supported.
      </Callout>

      <h2>Access modes</h2>
      <table>
        <thead>
          <tr>
            <th>Mode</th>
            <th>Description</th>
            <th>How to enable</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>
              <strong>Off</strong>
            </td>
            <td>Socket disabled</td>
            <td>Settings UI or <code>CMUX_SOCKET_MODE=off</code></td>
          </tr>
          <tr>
            <td>
              <strong>cmux processes only</strong>
            </td>
            <td>
              Only processes spawned inside cmux terminals can connect.
            </td>
            <td>Default mode in Settings UI</td>
          </tr>
          <tr>
            <td>
              <strong>allowAll</strong>
            </td>
            <td>Allow any local process to connect (no ancestry check).</td>
            <td>
              Environment override only: <code>CMUX_SOCKET_MODE=allowAll</code>
            </td>
          </tr>
        </tbody>
      </table>
      <Callout type="warn">
        On shared machines, use <strong>Off</strong> or{" "}
        <strong>cmux processes only</strong>.
      </Callout>

      <h2>CLI options</h2>
      <table>
        <thead>
          <tr>
            <th>Flag</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>
              <code>--socket PATH</code>
            </td>
            <td>Custom socket path</td>
          </tr>
          <tr>
            <td>
              <code>--json</code>
            </td>
            <td>Output in JSON format</td>
          </tr>
          <tr>
            <td>
              <code>--window ID</code>
            </td>
            <td>Target a specific window</td>
          </tr>
          <tr>
            <td>
              <code>--workspace ID</code>
            </td>
            <td>Target a specific workspace</td>
          </tr>
          <tr>
            <td>
              <code>--surface ID</code>
            </td>
            <td>Target a specific surface</td>
          </tr>
          <tr>
            <td>
              <code>--id-format refs|uuids|both</code>
            </td>
            <td>Control identifier format in JSON output</td>
          </tr>
        </tbody>
      </table>

      <h2>Workspace commands</h2>

      <Cmd
        name="list-workspaces"
        desc="List all open workspaces."
        cli={`cmux list-workspaces
cmux list-workspaces --json`}
        socket={`{"id":"ws-list","method":"workspace.list","params":{}}`}
      />
      <Cmd
        name="new-workspace"
        desc="Create a new workspace."
        cli={`cmux new-workspace`}
        socket={`{"id":"ws-new","method":"workspace.create","params":{}}`}
      />
      <Cmd
        name="select-workspace"
        desc="Switch to a specific workspace."
        cli={`cmux select-workspace --workspace <id>`}
        socket={`{"id":"ws-select","method":"workspace.select","params":{"workspace_id":"<id>"}}`}
      />
      <Cmd
        name="current-workspace"
        desc="Get the currently active workspace."
        cli={`cmux current-workspace
cmux current-workspace --json`}
        socket={`{"id":"ws-current","method":"workspace.current","params":{}}`}
      />
      <Cmd
        name="close-workspace"
        desc="Close a workspace."
        cli={`cmux close-workspace --workspace <id>`}
        socket={`{"id":"ws-close","method":"workspace.close","params":{"workspace_id":"<id>"}}`}
      />

      <h2>Split commands</h2>

      <Cmd
        name="new-split"
        desc="Create a new split pane. Directions: left, right, up, down."
        cli={`cmux new-split right
cmux new-split down`}
        socket={`{"id":"split-new","method":"surface.split","params":{"direction":"right"}}`}
      />
      <Cmd
        name="list-surfaces"
        desc="List all surfaces in the current workspace."
        cli={`cmux list-surfaces
cmux list-surfaces --json`}
        socket={`{"id":"surface-list","method":"surface.list","params":{}}`}
      />
      <Cmd
        name="focus-surface"
        desc="Focus a specific surface."
        cli={`cmux focus-surface --surface <id>`}
        socket={`{"id":"surface-focus","method":"surface.focus","params":{"surface_id":"<id>"}}`}
      />

      <h2>Input commands</h2>

      <Cmd
        name="send"
        desc="Send text input to the focused terminal."
        cli={`cmux send "echo hello"
cmux send "ls -la\\n"`}
        socket={`{"id":"send-text","method":"surface.send_text","params":{"text":"echo hello\\n"}}`}
      />
      <Cmd
        name="send-key"
        desc="Send a key press. Keys: enter, tab, escape, backspace, delete, up, down, left, right."
        cli={`cmux send-key enter`}
        socket={`{"id":"send-key","method":"surface.send_key","params":{"key":"enter"}}`}
      />
      <Cmd
        name="send-surface"
        desc="Send text to a specific surface."
        cli={`cmux send-surface --surface <id> "command"`}
        socket={`{"id":"send-surface","method":"surface.send_text","params":{"surface_id":"<id>","text":"command"}}`}
      />
      <Cmd
        name="send-key-surface"
        desc="Send a key press to a specific surface."
        cli={`cmux send-key-surface --surface <id> enter`}
        socket={`{"id":"send-key-surface","method":"surface.send_key","params":{"surface_id":"<id>","key":"enter"}}`}
      />

      <h2>Notification commands</h2>

      <Cmd
        name="notify"
        desc="Send a notification."
        cli={`cmux notify --title "Title" --body "Body"
cmux notify --title "T" --subtitle "S" --body "B"`}
        socket={`{"id":"notify","method":"notification.create","params":{"title":"Title","subtitle":"S","body":"Body"}}`}
      />
      <Cmd
        name="list-notifications"
        desc="List all notifications."
        cli={`cmux list-notifications
cmux list-notifications --json`}
        socket={`{"id":"notif-list","method":"notification.list","params":{}}`}
      />
      <Cmd
        name="clear-notifications"
        desc="Clear all notifications."
        cli={`cmux clear-notifications`}
        socket={`{"id":"notif-clear","method":"notification.clear","params":{}}`}
      />

      <h2>Utility commands</h2>

      <Cmd
        name="ping"
        desc="Check if cmux is running and responsive."
        cli={`cmux ping`}
        socket={`{"id":"ping","method":"system.ping","params":{}}
// Response: {"id":"ping","ok":true,"result":{"pong":true}}`}
      />
      <Cmd
        name="capabilities"
        desc="List available socket methods and current access mode."
        cli={`cmux capabilities
cmux capabilities --json`}
        socket={`{"id":"caps","method":"system.capabilities","params":{}}`}
      />
      <Cmd
        name="identify"
        desc="Show focused window/workspace/pane/surface context."
        cli={`cmux identify
cmux identify --json`}
        socket={`{"id":"identify","method":"system.identify","params":{}}`}
      />

      <h2>Environment variables</h2>
      <table>
        <thead>
          <tr>
            <th>Variable</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>
              <code>CMUX_SOCKET_PATH</code>
            </td>
            <td>Override the socket path used by CLI and integrations</td>
          </tr>
          <tr>
            <td>
              <code>CMUX_SOCKET_ENABLE</code>
            </td>
            <td>
              Force-enable/disable socket (<code>1</code>/<code>0</code>,{" "}
              <code>true</code>/<code>false</code>, <code>on</code>/
              <code>off</code>)
            </td>
          </tr>
          <tr>
            <td>
              <code>CMUX_SOCKET_MODE</code>
            </td>
            <td>
              Override access mode (<code>cmuxOnly</code>,{" "}
              <code>allowAll</code>, <code>off</code>). Also accepts{" "}
              <code>cmux-only</code>/<code>cmux_only</code> and{" "}
              <code>allow-all</code>/<code>allow_all</code>
            </td>
          </tr>
          <tr>
            <td>
              <code>CMUX_WORKSPACE_ID</code>
            </td>
            <td>Auto-set: current workspace ID</td>
          </tr>
          <tr>
            <td>
              <code>CMUX_SURFACE_ID</code>
            </td>
            <td>Auto-set: current surface ID</td>
          </tr>
          <tr>
            <td>
              <code>TERM_PROGRAM</code>
            </td>
            <td>
              Set to <code>ghostty</code>
            </td>
          </tr>
          <tr>
            <td>
              <code>TERM</code>
            </td>
            <td>
              Set to <code>xterm-ghostty</code>
            </td>
          </tr>
        </tbody>
      </table>
      <Callout>
        Legacy <code>CMUX_SOCKET_MODE</code> values <code>full</code> and{" "}
        <code>notifications</code> are still accepted for compatibility.
      </Callout>

      <h2>Detecting cmux</h2>
      <CodeBlock title="bash" lang="bash">{`# Prefer explicit socket path if set
SOCK="\${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"
[ -S "$SOCK" ] && echo "Socket available"

# Check for the CLI
command -v cmux &>/dev/null && echo "cmux available"

# In cmux-managed terminals these are auto-set
[ -n "\${CMUX_WORKSPACE_ID:-}" ] && [ -n "\${CMUX_SURFACE_ID:-}" ] && echo "Inside cmux surface"

# Distinguish from regular Ghostty
[ "$TERM_PROGRAM" = "ghostty" ] && [ -n "\${CMUX_WORKSPACE_ID:-}" ] && echo "In cmux"`}</CodeBlock>

      <h2>Examples</h2>

      <h3>Python client</h3>
      <CodeBlock title="python" lang="python">{`import json
import os
import socket

SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux.sock")

def rpc(method, params=None, req_id=1):
    payload = {"id": req_id, "method": method, "params": params or {}}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(payload).encode("utf-8") + b"\\n")
        return json.loads(sock.recv(65536).decode("utf-8"))

# List workspaces
print(rpc("workspace.list", req_id="ws"))

# Send notification
print(rpc(
    "notification.create",
    {"title": "Hello", "body": "From Python!"},
    req_id="notify"
))`}</CodeBlock>

      <h3>Shell script</h3>
      <CodeBlock title="bash" lang="bash">{`#!/bin/bash
SOCK="\${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"

cmux_cmd() {
    printf "%s\\n" "$1" | nc -U "$SOCK"
}

cmux_cmd '{"id":"ws","method":"workspace.list","params":{}}'
cmux_cmd '{"id":"notify","method":"notification.create","params":{"title":"Done","body":"Task complete"}}'`}</CodeBlock>

      <h3>Build script with notification</h3>
      <CodeBlock title="bash" lang="bash">{`#!/bin/bash
npm run build
if [ $? -eq 0 ]; then
    cmux notify --title "✓ Build Success" --body "Ready to deploy"
else
    cmux notify --title "✗ Build Failed" --body "Check the logs"
fi`}</CodeBlock>
    </>
  );
}
