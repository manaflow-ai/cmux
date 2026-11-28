// The native composer-status-dot tour caught a missing projection: the daemon sent statuses,
// but the direct client's published summary discarded them. Exercise the wire-to-view path,
// including updates and clearing, rather than handing a prebuilt summary to the dot.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import type { AcpmuxSnapshot } from "./model";
import { composerView, sameComposerView } from "./composer/composerView";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
  dom.window.close();
});

test("daemon statuses and facts reach the composer on attach, update and clear", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const view: { shown?: AcpmuxSnapshot } = {};
  const wakes: Array<() => void> = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => wakes.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      view.shown = snapshot;
      for (const wake of wakes.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    await until(() => view.shown?.summary !== undefined);
    expect(view.shown!.summary?.composerStatus?.items.map((item) => item.kind)).toEqual(["stuck", "rateLimited"]);
    const attached = composerView(view.shown!);
    const paused = {
      items: [{ kind: "queuePaused", level: "attention", words: "status.queuePaused.paused", action: "resumeQueue" }],
      facts: [{ kind: "queued", count: 2, live: true }],
    };
    socket.changeSession(mockHost.sessionId!, { title: "status update", composerStatus: paused });
    await until(() => view.shown?.summary?.title === "status update");
    expect(view.shown!.summary?.composerStatus).toEqual(paused as never);
    const changed = composerView(view.shown!);
    // Isolate the status field: the composer's memoization must notice it even without a title change.
    expect(
      sameComposerView(attached, {
        ...attached,
        summary: { ...attached.summary!, composerStatus: changed.summary!.composerStatus },
      }),
    ).toBe(false);
    for (const [title, status] of [
      ["empty", { items: [], facts: [] }],
      ["old daemon", undefined],
      ["null", null],
      ["malformed", { items: "not a list", facts: [] }],
    ] as const) {
      socket.changeSession(mockHost.sessionId!, { title, composerStatus: status });
      await until(() => view.shown?.summary?.title === title);
      expect(view.shown!.summary?.composerStatus).toEqual((title === "empty" ? status : undefined) as never);
    }
  } finally {
    client.close();
  }
});
