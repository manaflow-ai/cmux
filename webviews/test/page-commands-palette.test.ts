// The native palette's chat header toggles (AgentPaneView+Commands.swift, AgentPageCommand) in the
// real chat pane: the page lists the ones its header offers, and runs each the way its button does.
// CMUX_BROWSER_TESTS=1 bun test test/page-commands-palette.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { PAPERCUT_CHAT, papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

type NativeCall = { method: string; params: Record<string, unknown> };

await requireBrowserLane("page-commands-palette.test.ts", async () => {
  setDefaultTimeout(180_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, {
      turns: 2,
      running: false,
      otherSessions: [{ sessionId: "replacement-chat", cwd: "/home/dev/replacement" }],
    });
  });
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
  });

  // The App's side of `pane.commandAvailability` and `pane.action`: recorded, in every actions map
  // the page sets, a reconnect's too.
  const record = async (page: Page) => {
    await page.addInitScript(() => {
      const calls: { method: string; params: Record<string, unknown> }[] = [];
      (window as unknown as { nativeCalls: typeof calls }).nativeCalls = calls;
      const stand = Object.fromEntries(
        ["pane.commandAvailability", "pane.action"].map((method) => [
          method,
          async (params: Record<string, unknown>) => {
            calls.push({ method, params });
            return method === "pane.action" ? { shown: true } : null;
          },
        ]),
      );
      let actions: Record<string, unknown> = { ...stand };
      // On the prototype: a lost connection deletes the page's own `cmuxAcpmuxActions` (App.tsx
      // connectHost), which would take an accessor on `window` with it, and the reconnect's with it.
      Object.defineProperty(Window.prototype, "cmuxAcpmuxActions", {
        configurable: true,
        get: () => actions,
        set: (next: Record<string, unknown> | undefined) => {
          actions = { ...next, ...stand };
        },
      });
    });
  };
  const calls = (page: Page, method: string) =>
    page.evaluate(
      (method) =>
        (window as unknown as { nativeCalls: NativeCall[] }).nativeCalls.filter((call) => call.method === method),
      method,
    );
  // Until the page made `count` calls of `method`.
  const made = (page: Page, method: string, count: number) =>
    page.waitForFunction(
      ([method, count]) =>
        (window as unknown as { nativeCalls: NativeCall[] }).nativeCalls.filter((call) => call.method === method)
          .length >= count,
      [method, count] as const,
      { timeout: 10_000 },
    );

  test("the page offers the header's toggles its chat has, and runs each like its button", async () => {
    const page = await pane.open({ width: 1200, height: 760 }, record);
    try {
      // A local chat with no page to preview: Files and the tabs beside it, not Preview.
      await page.waitForFunction(
        () =>
          (window as unknown as { nativeCalls: NativeCall[] }).nativeCalls
            .filter((call) => call.method === "pane.commandAvailability")
            .at(-1)
            ?.params.commands?.toString() === "toggleFiles,toggleSideTabs",
        undefined,
        { timeout: 10_000 },
      );

      await page.evaluate(
        (session) => window.cmuxAcpmuxBridge!.command!(`header:toggleFiles|${session}`),
        PAPERCUT_CHAT,
      );
      await made(page, "pane.action", 1);
      // Not offered here: the command changes nothing, so the next call is the side tabs' own.
      await page.evaluate(
        (session) => window.cmuxAcpmuxBridge!.command!(`header:togglePreview|${session}`),
        PAPERCUT_CHAT,
      );
      await page.evaluate(
        (session) => window.cmuxAcpmuxBridge!.command!(`header:toggleSideTabs|${session}`),
        PAPERCUT_CHAT,
      );
      await made(page, "pane.action", 2);
      expect((await calls(page, "pane.action")).map((call) => call.params)).toEqual([
        { id: "files", cwd: "/home/dev/cmux", mode: "toggle" },
        { id: "sideTabs" },
      ]);
    } finally {
      await page.close();
    }
  });

  test("a delayed header command cannot affect a replacement chat", async () => {
    const page = await pane.open({ width: 1200, height: 760 }, record);
    try {
      await made(page, "pane.commandAvailability", 1);
      await page.evaluate((session) => {
        // Delivery after a replacement: a captured old session and an unscoped legacy command
        // must not use this chat's current Files callback. A current command proves it is live.
        window.cmuxAcpmuxBridge!.command!("header:toggleFiles|replaced-chat");
        window.cmuxAcpmuxBridge!.command!("toggleFiles");
        window.cmuxAcpmuxBridge!.command!(`header:toggleFiles|${session}`);
      }, PAPERCUT_CHAT);
      await made(page, "pane.action", 1);
      expect((await calls(page, "pane.action")).map((call) => call.params)).toEqual([
        { id: "files", cwd: "/home/dev/cmux", mode: "toggle" },
      ]);
    } finally {
      await page.close();
    }
  });

  test("a new chat's command waits for callbacks owned by its render", async () => {
    const page = await pane.open({ width: 1200, height: 760 }, record);
    try {
      await made(page, "pane.commandAvailability", 1);
      await page.evaluate(async () => {
        const path = "/direct.ts";
        const { AcpmuxDirectClient } = await import(/* @vite-ignore */ path);
        const prototype = AcpmuxDirectClient.prototype;
        const original = prototype.emitNow;
        prototype.emitNow = function (this: { selectedSession?: string; snapshotHold?: unknown }, connection: string) {
          original.call(this, connection);
          // The real client has emitted B (snapshotRef now holds B), but React has not rendered
          // B's callbacks yet. Deliver B's command in this exact same stack before yielding.
          if (this.selectedSession === "replacement-chat" && !this.snapshotHold) {
            prototype.emitNow = original;
            (window as unknown as { transitionCommandDelivered: boolean }).transitionCommandDelivered = true;
            window.cmuxAcpmuxBridge!.command!("header:toggleFiles|replacement-chat");
          }
        };
        window.cmuxAcpmuxDebug!.selectSession("replacement-chat");
      });
      await page.waitForFunction(
        () =>
          (window as unknown as { transitionCommandDelivered?: boolean }).transitionCommandDelivered &&
          window.cmuxAcpmuxDebug!.chatState().sessionId === "replacement-chat",
      );
      expect(await calls(page, "pane.action")).toEqual([]);
      await page.evaluate(() => window.cmuxAcpmuxBridge!.command!("header:toggleFiles|replacement-chat"));
      await made(page, "pane.action", 1);
      expect((await calls(page, "pane.action")).map((call) => call.params)).toEqual([
        { id: "files", cwd: "/home/dev/replacement", mode: "toggle" },
      ]);
    } finally {
      await page.close();
    }
  });

  test("the page lists its commands again after a reconnect, whose handshake forgot them", async () => {
    const page = await pane.open({ width: 1200, height: 760 }, record);
    try {
      await made(page, "pane.commandAvailability", 1);
      const before = (await calls(page, "pane.commandAvailability")).length;
      pane.drop();
      await made(page, "pane.commandAvailability", before + 1);
      expect((await calls(page, "pane.commandAvailability")).at(-1)?.params).toEqual({
        commands: ["toggleFiles", "toggleSideTabs"],
      });
    } finally {
      await page.close();
    }
  });
});
