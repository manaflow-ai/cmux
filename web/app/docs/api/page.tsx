import type { Metadata } from "next";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";

export const metadata: Metadata = {
  title: "API Reference",
  description:
    "cmux CLI and Unix socket API reference. Workspace/pane/surface control, notifications, browser automation, and socket security settings.",
};

export default function ApiPage() {
  return (
    <>
      <h1>API Reference</h1>
      <p>cmux exposes two automation interfaces:</p>
      <ul>
        <li>
          <strong>CLI</strong> (<code>cmux ...</code>) for scripts and
          day-to-day automation
        </li>
        <li>
          <strong>Unix socket API</strong> (JSON messages) for direct
          integrations
        </li>
      </ul>
      <p>
        The CLI is the easiest option and uses the socket API under the hood.
      </p>

      <h2>Socket</h2>
      <table>
        <thead>
          <tr>
            <th>Build</th>
            <th>Default path</th>
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
        </tbody>
      </table>
      <p>
        Override with <code>CMUX_SOCKET_PATH</code> or CLI flag{" "}
        <code>--socket</code>.
      </p>

      <h3>Protocol format (v2)</h3>
      <p>
        Send one JSON object per line using <code>method</code> and optional{" "}
        <code>params</code>. Responses are single-line JSON with <code>ok</code>
        , <code>result</code>, and <code>error</code> fields.
      </p>
      <CodeBlock lang="json">{`{"id": 1, "method": "system.ping", "params": {}}
{"id": 1, "ok": true, "result": {"pong": true}}`}</CodeBlock>
      <Callout>
        Legacy plain-text socket commands still exist, but new integrations
        should use v2 JSON methods.
      </Callout>

      <h2>Access Modes</h2>
      <table>
        <thead>
          <tr>
            <th>Mode</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>
              <strong>Off</strong>
            </td>
            <td>Socket disabled</td>
          </tr>
          <tr>
            <td>
              <strong>cmux processes only</strong>
            </td>
            <td>
              Only processes spawned inside cmux terminals can connect (default)
            </td>
          </tr>
          <tr>
            <td>
              <strong>allowAll (env only)</strong>
            </td>
            <td>Allow any same-user local process to connect</td>
          </tr>
        </tbody>
      </table>
      <p>
        Environment overrides: <code>CMUX_SOCKET_ENABLE</code>,{" "}
        <code>CMUX_SOCKET_MODE</code>, and <code>CMUX_SOCKET_PATH</code>.
      </p>
      <Callout type="warn">
        <code>allowAll</code> bypasses cmux ancestry checks and is intentionally
        hidden from the Settings UI.
      </Callout>

      <h2>CLI Global Options</h2>
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
            <td>Connect to a custom socket path</td>
          </tr>
          <tr>
            <td>
              <code>--window &lt;id|ref|index&gt;</code>
            </td>
            <td>Target a specific window context</td>
          </tr>
          <tr>
            <td>
              <code>--json</code>
            </td>
            <td>Machine-readable output</td>
          </tr>
          <tr>
            <td>
              <code>--id-format refs|uuids|both</code>
            </td>
            <td>Control ID format in responses</td>
          </tr>
        </tbody>
      </table>

      <h2>Common CLI Commands</h2>

      <h3>Workspace + window</h3>
      <CodeBlock lang="bash">{`cmux list-windows
cmux current-window
cmux new-window

cmux list-workspaces
cmux new-workspace
cmux select-workspace --workspace <id|ref|index>
cmux current-workspace
cmux close-workspace --workspace <id|ref|index>
cmux move-workspace-to-window --workspace <id|ref> --window <id|ref>`}</CodeBlock>

      <h3>Pane + surface</h3>
      <CodeBlock lang="bash">{`cmux new-split right
cmux list-panes [--workspace <id|ref>]
cmux list-pane-surfaces [--workspace <id|ref>] [--pane <id|ref>]
cmux focus-pane --pane <id|ref> [--workspace <id|ref>]

cmux new-pane [--type terminal|browser] [--direction left|right|up|down]
cmux new-surface [--type terminal|browser] [--pane <id|ref>] [--workspace <id|ref>]
cmux close-surface [--surface <id|ref>] [--workspace <id|ref>]
cmux move-surface --surface <id|ref|index> ...
cmux reorder-surface --surface <id|ref|index> ...`}</CodeBlock>

      <h3>Input + notifications</h3>
      <CodeBlock lang="bash">{`cmux send [--workspace <id|ref>] [--surface <id|ref>] "echo hello\\n"
cmux send-key [--workspace <id|ref>] [--surface <id|ref>] enter
cmux send-panel --panel <id|ref> [--workspace <id|ref>] "echo hello\\n"
cmux send-key-panel --panel <id|ref> [--workspace <id|ref>] enter

cmux notify --title "Done" --body "Task complete"
cmux notify --title "Done" --workspace <id|ref|index> --surface <id|ref|index>
cmux list-notifications
cmux clear-notifications`}</CodeBlock>

      <h3>Discovery + health</h3>
      <CodeBlock lang="bash">{`cmux ping
cmux capabilities
cmux identify
cmux identify --workspace <id|ref|index> --surface <id|ref|index>`}</CodeBlock>

      <h2>Socket Method Examples</h2>
      <CodeBlock lang="json">{`{"id": 1, "method": "system.capabilities", "params": {}}
{"id": 2, "method": "workspace.list", "params": {}}
{"id": 3, "method": "workspace.current", "params": {}}
{"id": 4, "method": "surface.send_text", "params": {"text": "echo hi\\n"}}
{"id": 5, "method": "notification.create", "params": {"title": "Done", "body": "Task complete"}}
{"id": 6, "method": "notification.list", "params": {}}
{"id": 7, "method": "notification.clear", "params": {}}`}</CodeBlock>

      <h2>Environment Variables</h2>
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
            <td>Override default socket path</td>
          </tr>
          <tr>
            <td>
              <code>CMUX_SOCKET_ENABLE</code>
            </td>
            <td>
              Force socket on/off (<code>1</code>/<code>0</code>; also accepts{" "}
              <code>true</code>/<code>false</code>)
            </td>
          </tr>
          <tr>
            <td>
              <code>CMUX_SOCKET_MODE</code>
            </td>
            <td>
              Override mode (<code>off</code>, <code>cmuxOnly</code>,{" "}
              <code>allowAll</code>; legacy <code>full</code>/<code>notifications</code>{" "}
              still accepted)
            </td>
          </tr>
          <tr>
            <td>
              <code>CMUX_WORKSPACE_ID</code>
            </td>
            <td>Auto-set current workspace ID in cmux terminals</td>
          </tr>
          <tr>
            <td>
              <code>CMUX_SURFACE_ID</code>
            </td>
            <td>Auto-set current surface ID in cmux terminals</td>
          </tr>
          <tr>
            <td>
              <code>CMUX_TAB_ID</code>, <code>CMUX_PANEL_ID</code>
            </td>
            <td>Backward-compatible aliases for workspace/surface IDs</td>
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

      <h2>Detecting cmux</h2>
      <CodeBlock title="bash" lang="bash">{`# Check socket availability
[ -S "\${CMUX_SOCKET_PATH:-/tmp/cmux.sock}" ] && echo "In cmux"

# Check injected environment
[ -n "$CMUX_WORKSPACE_ID" ] && [ -n "$CMUX_SURFACE_ID" ] && echo "In cmux"

# Check CLI presence
command -v cmux >/dev/null && echo "cmux available"`}</CodeBlock>

      <h2>Socket Client Example (Python)</h2>
      <CodeBlock title="python" lang="python">{`import json
import os
import socket

SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux.sock")

def call(method, params=None, id=1):
    req = {"id": id, "method": method, "params": params or {}}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(SOCKET_PATH)
        sock.sendall((json.dumps(req) + "\\n").encode("utf-8"))
        response = sock.recv(65536).decode("utf-8").strip()
    return json.loads(response)

print(call("system.ping"))
print(call("workspace.current"))
print(call("notification.create", {"title": "Done", "body": "From Python"}))`}</CodeBlock>
    </>
  );
}
