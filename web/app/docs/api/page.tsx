import type { Metadata } from "next";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";

export const metadata: Metadata = {
  title: "API Reference",
  description: "CLI and socket API reference for cmux",
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
        </tbody>
      </table>
      <p>
        Override with the <code>CMUX_SOCKET_PATH</code> environment variable.
        Commands are newline-terminated JSON:
      </p>
      <CodeBlock lang="json">{`{"command": "command-name", "arg1": "value1"}
// Response:
{"success": true, "data": {...}}`}</CodeBlock>

      <h2>Access modes</h2>
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
              <strong>Notifications only</strong>
            </td>
            <td>Only notification commands allowed</td>
          </tr>
          <tr>
            <td>
              <strong>Full control</strong>
            </td>
            <td>All commands enabled</td>
          </tr>
        </tbody>
      </table>
      <Callout type="warn">
        On shared machines, use &ldquo;Notifications only&rdquo; mode to prevent
        other users from controlling your terminals.
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
        </tbody>
      </table>

      <h2>Workspace commands</h2>

      <Cmd
        name="list-workspaces"
        desc="List all open workspaces."
        cli={`cmux list-workspaces
cmux list-workspaces --json`}
        socket={`{"command": "list-workspaces"}`}
      />
      <Cmd
        name="new-workspace"
        desc="Create a new workspace."
        cli={`cmux new-workspace`}
        socket={`{"command": "new-workspace"}`}
      />
      <Cmd
        name="select-workspace"
        desc="Switch to a specific workspace."
        cli={`cmux select-workspace --workspace <id>`}
        socket={`{"command": "select-workspace", "id": "<id>"}`}
      />
      <Cmd
        name="current-workspace"
        desc="Get the currently active workspace."
        cli={`cmux current-workspace
cmux current-workspace --json`}
        socket={`{"command": "current-workspace"}`}
      />
      <Cmd
        name="close-workspace"
        desc="Close a workspace."
        cli={`cmux close-workspace --workspace <id>`}
        socket={`{"command": "close-workspace", "id": "<id>"}`}
      />

      <h2>Split commands</h2>

      <Cmd
        name="new-split"
        desc="Create a new split pane. Directions: left, right, up, down."
        cli={`cmux new-split right
cmux new-split down`}
        socket={`{"command": "new-split", "direction": "right"}`}
      />
      <Cmd
        name="list-surfaces"
        desc="List all surfaces in the current workspace."
        cli={`cmux list-surfaces
cmux list-surfaces --json`}
        socket={`{"command": "list-surfaces"}`}
      />
      <Cmd
        name="focus-surface"
        desc="Focus a specific surface."
        cli={`cmux focus-surface --surface <id>`}
        socket={`{"command": "focus-surface", "id": "<id>"}`}
      />

      <h2>Input commands</h2>

      <Cmd
        name="send"
        desc="Send text input to the focused terminal."
        cli={`cmux send "echo hello"
cmux send "ls -la\\n"`}
        socket={`{"command": "send", "text": "echo hello\\n"}`}
      />
      <Cmd
        name="send-key"
        desc="Send a key press. Keys: enter, tab, escape, backspace, delete, up, down, left, right."
        cli={`cmux send-key enter`}
        socket={`{"command": "send-key", "key": "enter"}`}
      />
      <Cmd
        name="send-surface"
        desc="Send text to a specific surface."
        cli={`cmux send-surface --surface <id> "command"`}
        socket={`{"command": "send-surface", "id": "<id>", "text": "command"}`}
      />
      <Cmd
        name="send-key-surface"
        desc="Send a key press to a specific surface."
        cli={`cmux send-key-surface --surface <id> enter`}
        socket={`{"command": "send-key-surface", "id": "<id>", "key": "enter"}`}
      />

      <h2>Notification commands</h2>

      <Cmd
        name="notify"
        desc="Send a notification."
        cli={`cmux notify --title "Title" --body "Body"
cmux notify --title "T" --subtitle "S" --body "B"`}
        socket={`{"command": "notify", "title": "Title",
 "subtitle": "S", "body": "Body"}`}
      />
      <Cmd
        name="list-notifications"
        desc="List all notifications."
        cli={`cmux list-notifications
cmux list-notifications --json`}
        socket={`{"command": "list-notifications"}`}
      />
      <Cmd
        name="clear-notifications"
        desc="Clear all notifications."
        cli={`cmux clear-notifications`}
        socket={`{"command": "clear-notifications"}`}
      />

      <h2>Utility commands</h2>

      <Cmd
        name="ping"
        desc="Check if cmux is running and responsive."
        cli={`cmux ping`}
        socket={`{"command": "ping"}
// Response: {"success": true, "pong": true}`}
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
            <td>Override the default socket path</td>
          </tr>
          <tr>
            <td>
              <code>CMUX_SOCKET_ENABLE</code>
            </td>
            <td>
              Enable/disable socket (<code>1</code>/<code>0</code>)
            </td>
          </tr>
          <tr>
            <td>
              <code>CMUX_SOCKET_MODE</code>
            </td>
            <td>
              Override access mode (<code>full</code>,{" "}
              <code>notifications</code>, <code>off</code>)
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
        Environment variables override app settings. Use the socket check to
        distinguish cmux from regular Ghostty.
      </Callout>

      <h2>Detecting cmux</h2>
      <CodeBlock title="bash" lang="bash">{`# Check for the socket
[ -S /tmp/cmux.sock ] && echo "In cmux"

# Check for the CLI
command -v cmux &>/dev/null && echo "cmux available"

# Distinguish from regular Ghostty
[ "$TERM_PROGRAM" = "ghostty" ] && [ -S /tmp/cmux.sock ] && echo "In cmux"`}</CodeBlock>

      <h2>Examples</h2>

      <h3>Python client</h3>
      <CodeBlock title="python" lang="python">{`import socket, json

def send_command(cmd):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect('/tmp/cmux.sock')
    sock.send(json.dumps(cmd).encode() + b'\\n')
    response = sock.recv(4096).decode()
    sock.close()
    return json.loads(response)

# List workspaces
print(send_command({"command": "list-workspaces"}))

# Send notification
send_command({
    "command": "notify",
    "title": "Hello",
    "body": "From Python!"
})`}</CodeBlock>

      <h3>Shell script</h3>
      <CodeBlock title="bash" lang="bash">{`#!/bin/bash
cmux_cmd() {
    echo "$1" | nc -U /tmp/cmux.sock
}

cmux_cmd '{"command": "list-workspaces"}'
cmux_cmd '{"command": "notify", "title": "Done", "body": "Task complete"}'`}</CodeBlock>

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
