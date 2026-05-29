const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { createCmuxWindowsRuntime } = require("./server.cjs");

const pipeName = process.platform === "win32"
  ? `\\\\.\\pipe\\cmux-windows-smoke-${process.pid}`
  : path.join(os.tmpdir(), `cmux-windows-smoke-${process.pid}.sock`);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function pipeRoundTrip(command) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(pipeName);
    let output = "";
    socket.on("connect", () => socket.write(command + "\n"));
    socket.on("data", (chunk) => {
      output += chunk.toString("utf8");
      if (output.includes("\n")) {
        socket.end();
        resolve(output.trim());
      }
    });
    socket.on("error", reject);
  });
}

(async () => {
  const runtime = createCmuxWindowsRuntime({
    dataDir: path.join(os.tmpdir(), `cmux-windows-smoke-${process.pid}`),
    pipeName
  });
  const info = await runtime.listen();

  const stateResponse = await fetch(`${info.url}api/state`);
  assert(stateResponse.ok, "state endpoint failed");
  const state = await stateResponse.json();
  assert(state.workspaces.length === 1, "expected one initial workspace");

  const workspaceResponse = await fetch(`${info.url}api/workspaces`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ title: "Smoke" })
  });
  assert(workspaceResponse.ok, "workspace create failed");
  const workspace = await workspaceResponse.json();

  const terminalResponse = await fetch(`${info.url}api/panels`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ workspaceId: workspace.id, type: "terminal", direction: "right" })
  });
  assert(terminalResponse.ok, "terminal create failed");
  const terminal = await terminalResponse.json();

  const restartResponse = await fetch(`${info.url}api/panels/${terminal.id}/restart`, {
    method: "POST"
  });
  assert(restartResponse.ok, "terminal restart failed");

  const browserResponse = await fetch(`${info.url}api/panels`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ workspaceId: workspace.id, type: "browser", url: "https://example.com" })
  });
  assert(browserResponse.ok, "browser create failed");
  const browser = await browserResponse.json();

  const browserUpdateResponse = await fetch(`${info.url}api/panels/${browser.id}`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ url: "https://example.org" })
  });
  assert(browserUpdateResponse.ok, "browser update failed");

  const missingFocusResponse = await fetch(`${info.url}api/panels/missing/focus`, {
    method: "POST"
  });
  assert(missingFocusResponse.status === 404, "missing panel focus should return 404");
  const missingFocus = await missingFocusResponse.json();
  assert(missingFocus.ok === false, "missing panel focus should report ok=false");

  const latestStateResponse = await fetch(`${info.url}api/state`);
  const latestState = await latestStateResponse.json();
  const activeWorkspace = latestState.workspaces.find((candidate) => candidate.id === latestState.activeWorkspaceId);
  assert(activeWorkspace.panels.length >= 1, "expected panels before close check");
  for (const panel of [...activeWorkspace.panels]) {
    const closeResponse = await fetch(`${info.url}api/panels/${panel.id}`, { method: "DELETE" });
    assert(closeResponse.ok, "panel close failed");
  }
  const emptyStateResponse = await fetch(`${info.url}api/state`);
  const emptyState = await emptyStateResponse.json();
  const emptyWorkspace = emptyState.workspaces.find((candidate) => candidate.id === emptyState.activeWorkspaceId);
  assert(emptyWorkspace.panels.length === 0, "workspace should allow zero open panels");

  const ping = await pipeRoundTrip("ping");
  assert(ping === "OK", `pipe ping failed: ${ping}`);

  runtime.close();
  process.stdout.write("cmux Windows smoke passed\n");
})().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exit(1);
});
