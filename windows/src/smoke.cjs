const net = require("node:net");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { createCmuxWindowsRuntime } = require("./server.cjs");

const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), `cmux-windows-smoke-${process.pid}-`));
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
    dataDir,
    pipeName
  });
  const info = await runtime.listen();

  const stateResponse = await fetch(`${info.url}api/state`);
  assert(stateResponse.ok, "state endpoint failed");
  const state = await stateResponse.json();
  assert(state.workspaces.length === 1, "expected one initial workspace");

  const workspaceCwd = fs.mkdtempSync(path.join(os.tmpdir(), `cmux-windows-cwd-${process.pid}-`));
  const workspaceResponse = await fetch(`${info.url}api/workspaces`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ title: "Smoke", cwd: workspaceCwd })
  });
  assert(workspaceResponse.ok, "workspace create failed");
  const workspace = await workspaceResponse.json();
  assert(workspace.cwd === workspaceCwd, "workspace cwd should use requested folder");
  assert(workspace.panels[0]?.cwd === workspaceCwd, "initial workspace panel should inherit requested folder");

  const terminalResponse = await fetch(`${info.url}api/panels`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ workspaceId: workspace.id, type: "terminal", direction: "right" })
  });
  assert(terminalResponse.ok, "terminal create failed");
  const terminal = await terminalResponse.json();
  assert(terminal.cwd === workspaceCwd, "new terminal should inherit workspace folder");

  const defaultBrowserResponse = await fetch(`${info.url}api/panels`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ workspaceId: workspace.id, type: "browser" })
  });
  assert(defaultBrowserResponse.ok, "default browser create failed");
  const defaultBrowser = await defaultBrowserResponse.json();
  assert(defaultBrowser.url === "https://www.google.com", "default browser should open Google");

  const restartResponse = await fetch(`${info.url}api/panels/${terminal.id}/restart`, {
    method: "POST"
  });
  assert(restartResponse.ok, "terminal restart failed");

  const browserResponse = await fetch(`${info.url}api/panels`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ workspaceId: workspace.id, type: "browser", title: "Smoke Browser", color: "#336699", url: "https://example.com" })
  });
  assert(browserResponse.ok, "browser create failed");
  const browser = await browserResponse.json();
  assert(browser.title === "Smoke Browser", "browser title should be preserved on create");
  assert(browser.color === "#336699", "browser color should be preserved on create");

  const browserUpdateResponse = await fetch(`${info.url}api/panels/${browser.id}`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ url: "https://example.org" })
  });
  assert(browserUpdateResponse.ok, "browser update failed");

  const reorderWorkspaceResponse = await fetch(`${info.url}api/workspaces`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ title: "Reorder Target" })
  });
  assert(reorderWorkspaceResponse.ok, "workspace reorder target create failed");
  const reorderWorkspace = await reorderWorkspaceResponse.json();
  const reorderResponse = await fetch(`${info.url}api/workspaces/${reorderWorkspace.id}`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ beforeWorkspaceId: workspace.id })
  });
  assert(reorderResponse.ok, "workspace reorder failed");
  const reorderedStateResponse = await fetch(`${info.url}api/state`);
  const reorderedState = await reorderedStateResponse.json();
  const smokeIndex = reorderedState.workspaces.findIndex((candidate) => candidate.id === workspace.id);
  const movedIndex = reorderedState.workspaces.findIndex((candidate) => candidate.id === reorderWorkspace.id);
  assert(movedIndex >= 0 && smokeIndex >= 0 && movedIndex < smokeIndex, "workspace reorder should move before target");

  const pngPath = path.join(dataDir, "background.png");
  fs.writeFileSync(pngPath, Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=",
    "base64"
  ));
  const imageResponse = await fetch(`${info.url}_cmux/local-image?url=${encodeURIComponent(pathToFileURL(pngPath).href)}`);
  assert(imageResponse.ok, "local background image endpoint failed");
  assert((imageResponse.headers.get("content-type") || "").startsWith("image/png"), "local image endpoint should serve png content type");
  assert((await imageResponse.arrayBuffer()).byteLength > 0, "local image endpoint should return bytes");

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
