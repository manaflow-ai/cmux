import { CmuxClient, CmuxCommandError, CmuxTimeoutError, Tree } from "../src/index.js";

async function main(): Promise<void> {
  const socketPath = process.env.CMUX_MUX_SOCKET;
  if (!socketPath) throw new Error("CMUX_MUX_SOCKET is required");

  const marker = `CMUX_TS_E2E_${process.pid}_${Date.now()}`;
  const later = `${marker}_ATTACH`;
  const client = new CmuxClient({ socketPath, timeoutMs: 5000 });
  try {
    const identify = await client.identify();
    assert(identify.app === "cmux-mux", `unexpected app ${identify.app}`);
    assert(identify.protocol >= 5 && identify.protocol <= 6, `unsupported protocol ${identify.protocol}`);

    const created = await client.newWorkspace({ name: marker, cols: 80, rows: 24 });
    await client.send(created.surface, { text: `printf '${marker}\\n'\r` });
    await waitForMarker(client, created.surface, marker);
    const screen = await client.readScreen(created.surface);
    assert(screen.text.includes(marker), "marker missing from read-screen");

    const tree = await client.listWorkspaces();
    const workspaceId = findWorkspaceForSurface(tree, created.surface);
    assert(workspaceId !== undefined, "new workspace not found");

    await client.renameSurface(created.surface, `${marker}-renamed`);
    const events = await client.subscribe();
    await client.resizeSurface(created.surface, 100, 31);
    const resized = await nextSurfaceResized(events, created.surface, 1000);
    assert(resized.cols === 100 && resized.rows === 31, `bad resize event ${JSON.stringify(resized)}`);
    await client.resizeSurface(created.surface, 100, 31);
    const duplicate = await nextSurfaceResized(events, created.surface, 500).catch((err) => {
      if (err instanceof CmuxTimeoutError) return null;
      throw err;
    });
    assert(duplicate === null, "same-size resize emitted surface-resized");
    events.close();

    const attach = await client.attachSurface(created.surface);
    const first = await attach.next(1000);
    assert(first.event === "vt-state", `first attach event was ${first.event}`);
    await client.send(created.surface, { text: `printf '${later}\\n'\r` });
    const output = await nextAttachOutput(attach, 3000);
    assert(output.event === "output" || output.event === "resized", "attach did not produce output/resized after vt-state");
    attach.close();

    await client.closeWorkspace(workspaceId!);
    const afterClose = await client.listWorkspaces();
    assert(findWorkspaceForSurface(afterClose, created.surface) === undefined, "closed workspace still present");
    try {
      await client.readScreen(created.surface);
      throw new Error("read-screen on closed surface unexpectedly succeeded");
    } catch (err) {
      assert(err instanceof CmuxCommandError, `closed surface error was not command error: ${err}`);
      assert(String(err.message).length > 0, "command error did not preserve server message");
    }
  } finally {
    await client.close().catch(() => undefined);
  }
}

async function waitForMarker(client: CmuxClient, surface: number, marker: string): Promise<void> {
  const deadline = Date.now() + 5000;
  let last = "";
  while (Date.now() < deadline) {
    last = (await client.readScreen(surface)).text;
    if (last.includes(marker)) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`marker not found; last screen: ${JSON.stringify(last)}`);
}

async function nextSurfaceResized(events: Awaited<ReturnType<CmuxClient["subscribe"]>>, surface: number, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new CmuxTimeoutError("surface-resized not observed");
    const event = await events.next(remaining);
    if (event.event === "surface-resized" && event.surface === surface) return event;
  }
}

async function nextAttachOutput(attach: Awaited<ReturnType<CmuxClient["attachSurface"]>>, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new CmuxTimeoutError("attach output not observed");
    const event = await attach.next(remaining);
    if (event.event === "output" || event.event === "resized") return event;
  }
}

function findWorkspaceForSurface(tree: Tree, surface: number): number | undefined {
  for (const workspace of tree.workspaces) {
    for (const screen of workspace.screens) {
      for (const pane of screen.panes) {
        if ("tabs" in pane && pane.tabs?.some((tab) => tab.surface === surface)) return workspace.id;
      }
    }
  }
  return undefined;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
