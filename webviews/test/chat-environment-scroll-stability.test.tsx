// The started-chat EnvironmentLine is header chrome, not transcript content. A long-chat scroll that
// publishes a new snapshot with the same machine/folder/branch must leave that chip mounted and
// unrendered in either placement. This is an app-wiring test: it drives AcpmuxPane's real bridge and
// instruments the actual EnvironmentLine source rather than rendering a projected chip harness.
//
// A Vite pre-transform injects counters into the real EnvironmentLine function before Vite compiles
// it. `renders` is the exact function-body invocation count; `mounts` and `unmounts` are the exact
// useEffect lifecycle counts. A snapshot with changed cwd is then required to update once.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import type { Plugin } from "vite";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-environment-scroll-stability.test.tsx", async () => {
  setDefaultTimeout(180_000);
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch({ headless: true });
  } catch {
    describe.skip("environment chip scroll stability", () => test("chromium", () => {}));
    return;
  }

  // papercutPane.open owns navigation. Wrapping newPage lets us install the probe before the entry
  // module imports EnvironmentLine, while the Vite pre-transform below instruments exact TS source.
  const probeScript = () => {
    const target = globalThis as typeof globalThis & {
      __cmuxEnvProbe?: { renders: number; mounts: number; unmounts: number; reset(): void; snapshot(): unknown };
    };
    const state = { renders: 0, mounts: 0, unmounts: 0 };
    const reset = () => {
      state.renders = 0;
      state.mounts = 0;
      state.unmounts = 0;
    };
    target.__cmuxEnvProbe = {
      get renders() {
        return state.renders;
      },
      set renders(value: number) {
        state.renders = value;
      },
      get mounts() {
        return state.mounts;
      },
      set mounts(value: number) {
        state.mounts = value;
      },
      get unmounts() {
        return state.unmounts;
      },
      set unmounts(value: number) {
        state.unmounts = value;
      },
      reset,
      snapshot: () => ({ ...state }),
    };
  };

  const wrappedBrowser = () =>
    new Proxy(browser!, {
      get(target, property, receiver) {
        if (property !== "newPage") return Reflect.get(target, property, receiver);
        return async (options?: Parameters<Browser["newPage"]>[0]) => {
          const page = await target.newPage(options);
          await page.addInitScript(probeScript);
          return page;
        };
      },
    });

  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    const probe: Plugin = {
      name: "chat-environment-scroll-probe",
      enforce: "pre",
      transform(source, id) {
        if (!id.includes("/agent-session/acpmux/header/EnvironmentLine.tsx")) return;
        // This is a controlled source-unmemoized comparator discriminator, not a base-ref build.
        const baseline = process.env.CMUX_ENV_SCROLL_BASELINE === "1";
        let next = source;
        if (baseline)
          next = next
            .replace('import { memo } from "react";', 'import { useEffect } from "react";')
            .replace(
              "export const EnvironmentLine = memo(function EnvironmentLine(",
              "export function EnvironmentLine(",
            )
            .replace("}, sameEnvironmentLine);", "}");
        // Vite may revisit a pre-transformed module while warming the graph; an injected source is
        // already instrumented and must remain idempotent across that second pass.
        if (next.includes("globalThis.__cmuxEnvProbe.renders += 1")) return { code: next, map: null };
        next = next.replace('import { memo } from "react";', 'import { memo, useEffect } from "react"');
        const functionStart = next.indexOf("function EnvironmentLine(");
        if (functionStart < 0)
          throw new Error(`EnvironmentLine probe missed function; source=${next.slice(0, 260).replace(/\s+/g, " ")}`);
        const paramsOpen = next.indexOf("(", functionStart);
        let depth = 0;
        let paramsClose = -1;
        for (let index = paramsOpen; index < next.length; index += 1) {
          if (next[index] === "(") depth += 1;
          else if (next[index] === ")" && --depth === 0) {
            paramsClose = index;
            break;
          }
        }
        const bodyOpen = paramsClose < 0 ? -1 : next.indexOf("{", paramsClose);
        if (bodyOpen < 0)
          throw new Error(
            `EnvironmentLine probe missed body; source=${next.slice(functionStart, functionStart + 320).replace(/\s+/g, " ")}`,
          );
        const probe = `\n  globalThis.__cmuxEnvProbe.renders += 1;\n  useEffect(() => { globalThis.__cmuxEnvProbe.mounts += 1; return () => { globalThis.__cmuxEnvProbe.unmounts += 1; }; }, []);`;
        next = `${next.slice(0, bodyOpen + 1)}${probe}${next.slice(bodyOpen + 1)}`;
        return { code: next, map: null };
      },
    };
    // Keep enough rows to exercise both scroll extremes and history publication without making
    // the browser lane spend its whole timeout laying out a synthetic 42-turn transcript.
    pane = await papercutPane(wrappedBrowser, { turns: 24, running: false, vitePlugins: [probe] });
    // Warm Vite and Chromium before the actual cases; this closes only the warm page and leaves
    // the daemon/page fixture alive for the cases below.
    const warm = await pane.open({ width: 980, height: 720 });
    await warm.close();
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  const settle = async (page: Page) => {
    await page.evaluate(async () => {
      const finite = () =>
        document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
      await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
      await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
    });
  };

  const publishSnapshot = async (page: Page, cwd: string) => {
    // App.saveSnapshot coalesces writes for 250 ms; wait on the storage state instead of racing
    // that debounce after the fixture has painted its last turn.
    // The fixture page remains open, so exercise the same pagehide flush the host uses before
    // reading its current snapshot.
    await page.evaluate(() => window.dispatchEvent(new Event("pagehide")));
    await page.waitForFunction(() => Boolean(sessionStorage.getItem("cmux.acpmux.snapshot")), undefined, {
      timeout: 20_000,
    });
    return page.evaluate((cwd) => {
      const raw = sessionStorage.getItem("cmux.acpmux.snapshot");
      if (!raw) throw new Error("started chat did not persist an Acpmux snapshot");
      const current = JSON.parse(raw) as Record<string, any>;
      const summary = { ...current.summary, cwd };
      const next = { ...current, summary, rows: [...(current.rows ?? [])] };
      const bridge = (window as any).cmuxAcpmuxBridge;
      if (!bridge?.receive) throw new Error("Acpmux bridge receive is unavailable");
      bridge.receive(next);
    }, cwd);
  };

  const runPlacement = async (placement: "left" | "right") => {
    const page = await pane!.open({ width: 980, height: 720 });
    try {
      await page.evaluate(async (placement) => {
        // @ts-expect-error Vite's agent-pane root resolves this test-only runtime import.
        const module = (await import(/* @vite-ignore */ "/chatDisplay.ts")) as { setChatDisplay(value: unknown): void };
        module.setChatDisplay({ "agentPane.display.environment.placement": placement });
      }, placement);
      await page.locator(".acpmux-env-line").waitFor({ timeout: 20_000 });
      const identity = await page.locator(".acpmux-env-line").elementHandle();
      if (!identity) throw new Error("environment chip identity is missing");
      await page.evaluate(() => (window as any).__cmuxEnvProbe.reset());

      // Move the real transcript to both ends across painted frames. Its scroll handler stays local
      // to VirtualTranscript; each following snapshot publication exercises the App/header boundary.
      const moveScroll = async (top: "start" | "end") =>
        page.evaluate(async (top) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
          if (!scroller) throw new Error("chat transcript scroller is missing");
          scroller.scrollTop = top === "start" ? 0 : scroller.scrollHeight;
          scroller.dispatchEvent(new Event("scroll", { bubbles: true }));
          await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
        }, top);
      await moveScroll("start");
      if (process.env.CMUX_ENV_SCROLL_SHOTS)
        await page.screenshot({ path: `${process.env.CMUX_ENV_SCROLL_SHOTS}/${placement}-scroll-start.png` });
      await publishSnapshot(page, "/home/dev/cmux");
      await settle(page);
      await moveScroll("end");
      if (process.env.CMUX_ENV_SCROLL_SHOTS)
        await page.screenshot({ path: `${process.env.CMUX_ENV_SCROLL_SHOTS}/${placement}-scroll-end.png` });
      await publishSnapshot(page, "/home/dev/cmux");
      await settle(page);
      const unchanged = await page.evaluate(() => (window as any).__cmuxEnvProbe.snapshot());
      const sameNode = await page.locator(".acpmux-env-line").evaluate((node, previous) => node === previous, identity);

      await page.evaluate(() => (window as any).__cmuxEnvProbe.reset());
      await publishSnapshot(page, "/home/dev/another-project");
      await settle(page);
      const changed = await page.evaluate(() => (window as any).__cmuxEnvProbe.snapshot());
      console.log(
        JSON.stringify({
          kind: "chat-environment-scroll-receipt",
          mode: process.env.CMUX_ENV_SCROLL_BASELINE === "1" ? "source-unmemoized-baseline" : "final",
          placement,
          unchanged,
          changed,
          sameNode,
          frames: process.env.CMUX_ENV_SCROLL_SHOTS || null,
        }),
      );
      return { placement, unchanged, changed, sameNode };
    } finally {
      await page.close();
    }
  };

  test("the actual App owns Left, Right, Off, and covered surfaces", async () => {
    const page = await pane!.open({ width: 980, height: 720 });
    try {
      const display = async (placement: "left" | "right" | "off") =>
        page.evaluate(async (placement) => {
          // @ts-expect-error Vite's agent-pane root resolves this test-only runtime import.
          const module = (await import(/* @vite-ignore */ "/chatDisplay.ts")) as {
            setChatDisplay(value: unknown): void;
          };
          module.setChatDisplay({ "agentPane.display.environment.placement": placement });
        }, placement);
      await display("left");
      await page.locator(".acpmux-environment-row").waitFor({ timeout: 20_000 });
      expect(await page.locator(".acpmux-environment-row").count()).toBe(1);
      expect(await page.locator(".acpmux-environment-row .acpmux-env-line").count()).toBe(1);

      // Session Info is the normal chat inspector: it stays beside the row, with its top inset
      // below the header. The separate event Inspector covers the chat surface and removes the
      // chip rather than leaving it clickable through the glass.
      await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }));
      await page.locator("aside.acpmux-chat-inspector").waitFor({ timeout: 20_000 });
      expect(await page.locator(".acpmux-environment-row .acpmux-env-line").count()).toBe(1);
      const normalInset = await page.locator("aside.acpmux-chat-inspector").evaluate((panel) => {
        const row = document.querySelector<HTMLElement>(".acpmux-environment-row")!;
        return { panelTop: panel.getBoundingClientRect().top, rowBottom: row.getBoundingClientRect().bottom };
      });
      expect(Math.abs(normalInset.panelTop - normalInset.rowBottom)).toBeLessThan(2);
      await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyHeaderState({ inspector: false, version: 3 }));
      await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyTabRow({ height: 32, trailingInset: 0 }));
      await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 4 }));
      await page.locator("aside.acpmux-chat-inspector").waitFor({ timeout: 20_000 });
      expect(await page.locator(".acpmux-environment-row .acpmux-env-line").count()).toBe(1);
      const tabRowInset = await page.locator("aside.acpmux-chat-inspector").evaluate((panel) => {
        const row = document.querySelector<HTMLElement>(".acpmux-environment-row")!;
        return { panelTop: panel.getBoundingClientRect().top, rowBottom: row.getBoundingClientRect().bottom };
      });
      expect(Math.abs(tabRowInset.panelTop - tabRowInset.rowBottom)).toBeLessThan(2);
      await page.evaluate(() => {
        (window as any).cmuxAcpmuxBridge.applyHeaderState({ inspector: false, version: 5 });
        (window as any).cmuxAcpmuxBridge.toggleInspector(true);
      });
      await page.locator("section.acpmux-inspector").waitFor({ timeout: 20_000 });
      await page.locator(".acpmux-env-line").waitFor({ state: "detached", timeout: 20_000 });
      await page.evaluate(() => (window as any).cmuxAcpmuxBridge.toggleInspector(false));
      await page.locator(".acpmux-environment-row").waitFor({ timeout: 20_000 });

      await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyTabRow({ height: 0, trailingInset: 0 }));
      await display("right");
      await page.locator(".acpmux-header-status-slot .acpmux-env-line").waitFor({ timeout: 20_000 });
      expect(await page.locator(".acpmux-environment-row").count()).toBe(0);
      expect(await page.locator(".acpmux-header-status-slot .acpmux-env-line").count()).toBe(1);

      await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyTabRow({ height: 32, trailingInset: 0 }));
      await page.locator(".acpmux-env-line--compact").waitFor({ timeout: 20_000 });
      expect(await page.locator(".acpmux-header .acpmux-env-line--compact").count()).toBe(1);

      await display("off");
      await page.locator(".acpmux-env-line").waitFor({ state: "detached", timeout: 20_000 });
    } finally {
      await page.close();
    }
  });

  test("long-chat scroll leaves the Left chip mounted and stable, while own cwd changes update it", async () => {
    const result = await runPlacement("left");
    expect(result.sameNode).toBe(true);
    expect(result.unchanged.renders).toBe(0);
    expect(result.unchanged.mounts).toBe(0);
    expect(result.unchanged.unmounts).toBe(0);
    expect(result.changed.renders).toBeGreaterThan(0);
    expect(result.changed.mounts).toBe(0);
    expect(result.changed.unmounts).toBe(0);
  });

  test("long-chat scroll leaves the Right chip mounted and stable, while own cwd changes update it", async () => {
    const result = await runPlacement("right");
    expect(result.sameNode).toBe(true);
    expect(result.unchanged.renders).toBe(0);
    expect(result.unchanged.mounts).toBe(0);
    expect(result.unchanged.unmounts).toBe(0);
    expect(result.changed.renders).toBeGreaterThan(0);
    expect(result.changed.mounts).toBe(0);
    expect(result.changed.unmounts).toBe(0);
  });
});
