/**
 * Terminal endpoints end to end in workerd. The fake provider answers the
 * WebSocket upgrade with one end of a Workers WebSocketPair; the test drives
 * the client end the Worker hands back.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;

const TENANT_A = "team_alpha";
const TENANT_B = "team_bravo";
const bearer = (token: string) => ({ authorization: `Bearer ${token}` });
const upgrade = { upgrade: "websocket" };

let h: Harness;
beforeEach(async () => {
  h = await makeHarness();
});
afterEach(async () => {
  await h.dispose();
});

type Frame = { readonly text: string } | { readonly bytes: ReadonlyArray<number> };

const frameOf = (data: unknown): Frame =>
  typeof data === "string"
    ? { text: data }
    : data instanceof ArrayBuffer
      ? { bytes: Array.from(new Uint8Array(data)) }
      : { text: `unexpected frame type ${Object.prototype.toString.call(data)}` };

/** Resolves with every frame the socket received, in order, once it closes. */
const collectUntilClose = (socket: WebSocket) =>
  new Promise<{ frames: Frame[]; code: number }>((resolve) => {
    const frames: Frame[] = [];
    socket.addEventListener("message", (event) => frames.push(frameOf(event.data)));
    socket.addEventListener("close", (event) => resolve({ frames, code: event.code }));
  });

const clientSocket = (response: Response): WebSocket => {
  const socket = response.webSocket;
  if (socket === null) throw new Error(`expected a WebSocket, got HTTP ${response.status}`);
  socket.binaryType = "arraybuffer";
  socket.accept();
  return socket;
};

describe("cross-tenant isolation", () => {
  it("returns 404 for every terminal endpoint on another tenant's VM, before any upstream request", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const keyB = await h.addKey(TENANT_B, ["vm:terminal"]);
    const calls: Array<[string, Record<string, string>, string]> = [
      [`/v1/vms/${vmId}/terminal`, upgrade, "GET"],
      [`/v1/vms/${vmId}/terminals/1`, upgrade, "GET"],
      [`/v1/vms/${vmId}/terminals`, {}, "GET"],
      [`/v1/vms/${vmId}/terminals/1`, {}, "DELETE"],
    ];
    for (const [path, extra, method] of calls) {
      const response = await h.request(path, { ...bearer(keyB), ...extra }, { method });
      expect(response.status, `${method} ${path}`).toBe(404);
      expect(response.webSocket).toBeNull();
      expect(await response.json()).toEqual({ _tag: "NotFound", message: "VM not found" });
    }
    expect(h.upstreamRequests).toHaveLength(0);
    expect(h.audit).toHaveLength(0);
  });

  it("returns 404 for a session in tenant B opening tenant A's VM", async () => {
    const { vmId } = h.addVm(TENANT_A);
    h.addMember(TENANT_B, "user_bob");
    const token = await h.sessionToken("user_bob");

    const response = await h.request(`/v1/vms/${vmId}/terminal`, { ...bearer(token), "x-cmux-team-id": TENANT_B, ...upgrade });

    expect(response.status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(0);
  });
});

describe("authorization before upgrade", () => {
  it("needs vm:terminal; vm:exec and vm:write are not enough", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["vm:read", "vm:write", "vm:exec"]);

    const response = await h.request(`/v1/vms/${vmId}/terminal`, { ...bearer(key), ...upgrade });

    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ missingScope: "vm:terminal" });
    expect(h.upstreamRequests).toHaveLength(0);
  });

  it("answers a plain GET with 426 and does not reach upstream", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["vm:terminal"]);

    const response = await h.request(`/v1/vms/${vmId}/terminal`, bearer(key));

    expect(response.status).toBe(426);
    expect(h.upstreamRequests).toHaveLength(0);
  });
});

describe("terminal proxy", () => {
  it("passes frames through in order both ways, rewrites control frames and drops unknown ones", async () => {
    const { vmId, upstreamId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["vm:terminal"]);
    const OUTPUT_FRAMES = 64;
    const receivedUpstream: Frame[] = [];
    h.s3a.onTerminal((socket) => {
      socket.addEventListener("message", (event) => {
        const frame = frameOf(event.data);
        receivedUpstream.push(frame);
        // The last valid client frame starts the scripted output.
        if (!("text" in frame) || !frame.text.includes("resize")) return;
        socket.send(JSON.stringify({ type: "sessionInfo", sessionId: 7, slug: "main", created: true, host: "upstream-only" }));
        for (let index = 0; index < OUTPUT_FRAMES; index += 1) socket.send(new Uint8Array([index, 255 - index]));
        socket.send(JSON.stringify({ type: "error", message: `vm ${upstreamId} on freestyle host lagged` }));
        socket.send(JSON.stringify({ type: "upstreamDebug", secret: "x" }));
        socket.send(JSON.stringify({ type: "exited", exitCode: 3 }));
        socket.close(1000, `bye from ${upstreamId}`);
      });
    });

    const response = await h.request(`/v1/vms/${vmId}/terminal?cols=120&rows=40&name=main`, { ...bearer(key), ...upgrade });
    expect(response.status).toBe(101);
    const socket = clientSocket(response);
    const done = collectUntilClose(socket);
    socket.send(new TextEncoder().encode("echo hi\n"));
    socket.send("not json");
    socket.send(JSON.stringify({ type: "exec", command: "rm -rf /" }));
    socket.send(JSON.stringify({ type: "resize", cols: 100, rows: 30, extra: true }));
    const { frames, code } = await done;

    expect(code).toBe(1000);
    expect(frames).toEqual([
      { text: JSON.stringify({ type: "sessionInfo", sessionId: 7, name: "main", created: true }) },
      ...Array.from({ length: OUTPUT_FRAMES }, (_, index) => ({ bytes: [index, 255 - index] })),
      { text: JSON.stringify({ type: "error", message: "The terminal reported an error" }) },
      { text: JSON.stringify({ type: "exited", exitCode: 3 }) },
    ]);
    expect(receivedUpstream).toEqual([
      { bytes: Array.from(new TextEncoder().encode("echo hi\n")) },
      { text: JSON.stringify({ type: "resize", cols: 100, rows: 30 }) },
    ]);

    const [upstreamRequest] = h.s3a.requests;
    const url = new URL(String(upstreamRequest?.url));
    expect(url.pathname).toBe(`/v5/vms/${upstreamId}/pty`);
    expect(Object.fromEntries(url.searchParams)).toEqual({ cols: "120", rows: "40", slug: "main" });
    expect(upstreamRequest?.headers.get("authorization")).toBe("Bearer upstream-test-key");
    expect(h.audit).toMatchObject([{ action: "terminal.open", cmuxId: vmId, outcome: "ok" }]);
  });

  it("closes the upstream socket when the client disconnects", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["vm:terminal"]);
    const upstreamClosed = new Promise<number>((resolve) => {
      h.s3a.onTerminal((socket) => socket.addEventListener("close", (event) => resolve(event.code)));
    });

    const socket = clientSocket(await h.request(`/v1/vms/${vmId}/terminal`, { ...bearer(key), ...upgrade }));
    socket.close(1000, "done");

    expect(await upstreamClosed).toBe(1000);
  });

  it("reattaches to a session by name", async () => {
    const { vmId, upstreamId } = h.addVm(TENANT_A);
    h.s3a.setPtySessions(upstreamId, [{ sessionId: 3, state: "running", slug: "main", linuxUser: "dev" }]);
    const key = await h.addKey(TENANT_A, ["vm:terminal"]);
    h.s3a.onTerminal((socket) => {
      socket.send(new Uint8Array([42]));
      socket.close(1000, "");
    });

    const response = await h.request(`/v1/vms/${vmId}/terminals/main?user=dev`, { ...bearer(key), ...upgrade });

    expect(response.status).toBe(101);
    const { frames } = await collectUntilClose(clientSocket(response));
    expect(frames).toEqual([{ bytes: [42] }]);
    const url = new URL(String(h.s3a.requests.at(0)?.url));
    expect(url.pathname).toBe(`/v5/vms/${upstreamId}/pty/sessions/main`);
    expect(url.searchParams.get("linuxUser")).toBe("dev");
  });

  it("returns 404 for an unknown session and for a selector that is not a session name", async () => {
    const { vmId } = h.addVm(TENANT_A);
    const key = await h.addKey(TENANT_A, ["vm:terminal"]);

    const unknown = await h.request(`/v1/vms/${vmId}/terminals/nope`, { ...bearer(key), ...upgrade });
    expect(unknown.status).toBe(404);
    expect(await unknown.json()).toEqual({ _tag: "NotFound", message: "Terminal session not found" });

    const before = h.upstreamRequests.length;
    const malformed = await h.request(`/v1/vms/${vmId}/terminals/Bad_Name`, { ...bearer(key), ...upgrade });
    expect(malformed.status).toBe(404);
    expect(h.upstreamRequests).toHaveLength(before);
  });
});

describe("sessions over REST", () => {
  it("lists and closes the VM's sessions without leaking upstream fields", async () => {
    const { vmId, upstreamId } = h.addVm(TENANT_A);
    h.s3a.setPtySessions(upstreamId, [
      { sessionId: 3, state: "running", slug: "main", linuxUser: "dev" },
      { sessionId: 4, state: "exited", slug: null, linuxUser: null },
    ]);
    const key = await h.addKey(TENANT_A, ["vm:terminal"]);

    const listed = await h.request(`/v1/vms/${vmId}/terminals`, bearer(key));
    expect(listed.status).toBe(200);
    expect(await listed.json()).toEqual({
      items: [
        { sessionId: 3, name: "main", state: "running", user: "dev", cols: 80, rows: 24, exitCode: null, createdAt: "2026-09-21T14:13:20.000Z" },
        { sessionId: 4, name: null, state: "exited", user: null, cols: 80, rows: 24, exitCode: 0, createdAt: "2026-09-21T14:13:20.000Z" },
      ],
    });

    const closed = await h.request(`/v1/vms/${vmId}/terminals/3`, bearer(key), { method: "DELETE" });
    expect(closed.status).toBe(200);
    expect(await closed.json()).toEqual({ sessionId: 3, exitCode: null });
    expect(h.audit).toMatchObject([{ action: "terminal.close", cmuxId: vmId, outcome: "ok" }]);

    const again = await h.request(`/v1/vms/${vmId}/terminals/3`, bearer(key), { method: "DELETE" });
    expect(again.status).toBe(404);
    expect(await again.text()).not.toContain(upstreamId);
  });
});
