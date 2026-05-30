const net = require("node:net");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { WebSocket } = require("ws");
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

function waitForWebSocketOpen(socket) {
  return new Promise((resolve, reject) => {
    if (socket.readyState === WebSocket.OPEN) {
      resolve();
      return;
    }
    socket.once("open", resolve);
    socket.once("error", reject);
  });
}

async function waitForCondition(label, probe, timeoutMs = 3000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (probe()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`${label} timed out`);
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

  const autoWorkspaceOneResponse = await fetch(`${info.url}api/workspaces`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({})
  });
  assert(autoWorkspaceOneResponse.ok, "first default workspace create failed");
  const autoWorkspaceOne = await autoWorkspaceOneResponse.json();
  assert(autoWorkspaceOne.title === "Workspace 2", "first default workspace should use the next free title");

  const autoWorkspaceTwoResponse = await fetch(`${info.url}api/workspaces`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({})
  });
  assert(autoWorkspaceTwoResponse.ok, "second default workspace create failed");
  const autoWorkspaceTwo = await autoWorkspaceTwoResponse.json();
  assert(autoWorkspaceTwo.title === "Workspace 3", "second default workspace should avoid duplicate titles");

  const workspaceCwd = fs.mkdtempSync(path.join(os.tmpdir(), `cmux-windows-cwd-${process.pid}-`));
  const folderWorkspaceOneResponse = await fetch(`${info.url}api/workspaces`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ cwd: workspaceCwd })
  });
  assert(folderWorkspaceOneResponse.ok, "first folder workspace create failed");
  const folderWorkspaceOne = await folderWorkspaceOneResponse.json();
  assert(folderWorkspaceOne.title === path.basename(workspaceCwd), "folder workspace should use the folder name");

  const folderWorkspaceTwoResponse = await fetch(`${info.url}api/workspaces`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ cwd: workspaceCwd })
  });
  assert(folderWorkspaceTwoResponse.ok, "second folder workspace create failed");
  const folderWorkspaceTwo = await folderWorkspaceTwoResponse.json();
  assert(folderWorkspaceTwo.title === `${path.basename(workspaceCwd)} 2`, "duplicate folder workspace should get a suffix");

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

  const initialTerminal = workspace.panels[0];
  assert(initialTerminal?.type === "terminal", "workspace should start with a terminal panel");
  const firstFontResponse = await fetch(`${info.url}api/panels/${initialTerminal.id}`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ terminalFontSize: 18 })
  });
  assert(firstFontResponse.ok, "first terminal font size update failed");
  const isolatedFontStateResponse = await fetch(`${info.url}api/state`);
  const isolatedFontState = await isolatedFontStateResponse.json();
  const isolatedFontWorkspace = isolatedFontState.workspaces.find((candidate) => candidate.id === workspace.id);
  const isolatedInitialTerminal = isolatedFontWorkspace.panels.find((panel) => panel.id === initialTerminal.id);
  const isolatedSecondTerminal = isolatedFontWorkspace.panels.find((panel) => panel.id === terminal.id);
  assert(isolatedInitialTerminal.terminalFontSize === 18, "target terminal should keep its font size override");
  assert(isolatedSecondTerminal.terminalFontSize === 0, "other terminals should not inherit a pane font size override");

  const secondFontResponse = await fetch(`${info.url}api/panels/${terminal.id}`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ terminalFontSize: 11 })
  });
  assert(secondFontResponse.ok, "second terminal font size update failed");
  const dualFontStateResponse = await fetch(`${info.url}api/state`);
  const dualFontState = await dualFontStateResponse.json();
  const dualFontWorkspace = dualFontState.workspaces.find((candidate) => candidate.id === workspace.id);
  const dualInitialTerminal = dualFontWorkspace.panels.find((panel) => panel.id === initialTerminal.id);
  const dualSecondTerminal = dualFontWorkspace.panels.find((panel) => panel.id === terminal.id);
  assert(dualInitialTerminal.terminalFontSize === 18, "first terminal font size override should remain separate");
  assert(dualSecondTerminal.terminalFontSize === 11, "second terminal font size override should remain separate");

  const defaultBrowserResponse = await fetch(`${info.url}api/panels`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ workspaceId: workspace.id, type: "browser" })
  });
  assert(defaultBrowserResponse.ok, "default browser create failed");
  const defaultBrowser = await defaultBrowserResponse.json();
  assert(defaultBrowser.url === "https://www.google.com", "default browser should open Google");

  const eventSocket = new WebSocket(`${info.url.replace(/^http/, "ws")}events`);
  await waitForWebSocketOpen(eventSocket);
  const originalEnsureTerminalProcess = runtime.ensureTerminalProcess.bind(runtime);
  const prewarmedPanelIds = new Set();
  runtime.ensureTerminalProcess = (panel) => {
    prewarmedPanelIds.add(panel.id);
    return { closed: false, close() {} };
  };
  try {
    const prewarmWorkspaceResponse = await fetch(`${info.url}api/workspaces`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ title: "Prewarm Smoke" })
    });
    assert(prewarmWorkspaceResponse.ok, "prewarm workspace create failed");
    const prewarmWorkspace = await prewarmWorkspaceResponse.json();
    const prewarmInitialTerminal = prewarmWorkspace.panels[0];
    assert(prewarmInitialTerminal?.type === "terminal", "prewarm workspace should start with a terminal");
    await waitForCondition("initial workspace terminal prewarm", () => prewarmedPanelIds.has(prewarmInitialTerminal.id));

    const prewarmTerminalResponse = await fetch(`${info.url}api/panels`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ workspaceId: prewarmWorkspace.id, type: "terminal", direction: "right" })
    });
    assert(prewarmTerminalResponse.ok, "prewarm terminal create failed");
    const prewarmTerminal = await prewarmTerminalResponse.json();
    await waitForCondition("created terminal prewarm", () => prewarmedPanelIds.has(prewarmTerminal.id));
  } finally {
    runtime.ensureTerminalProcess = originalEnsureTerminalProcess;
    eventSocket.close();
  }

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
