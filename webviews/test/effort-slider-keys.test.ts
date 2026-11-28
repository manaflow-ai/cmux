// l10n-allow-file: test fixture prompts, replies and level names, not shipped UI.
// The reasoning slider in a real browser (Debug Settings agent.reasoningSlider, opt-in; effort-picker-slider.test.tsx
// covers its rules in JSDOM with synthetic events). Here real key presses go through the pane's dev
// entry to a stand-in acpmux daemon: the slider's stops are the levels the agent reports (an unknown
// agent level included), Right, End and Home step the native range input, each step sends
// `session/set_config_option` as a list pick does, and the menu stays open until Escape. Off (the
// default), the menu is the list. The host's `composer` event turns the option on.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("effort-slider-keys.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("effort-slider-keys: skipping (run `bunx playwright install chromium`)");
    describe.skip("reasoning slider", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000e7";
  const START = Date.UTC(2026, 9, 14, 9, 0, 0);
  const say = (text: string) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const steps: Step[] = [
    ["mux", "user_message", { text: "Tune the uploader" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("Uploader tuned.")],
    ["mux", "turn_result", { status: "completed" }],
  ];
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  // The agent's levels, in its order: the pane names the ones it knows, and "deep" is one only this
  // agent reports, so the slider cannot be a hard-coded Low…Max.
  const LEVELS = ["low", "medium", "high", "deep", "xhigh", "max"];
  const NAMES = ["Low", "Medium", "High", "Deep", "Extra High", "Max"];
  const configOptions = () => [
    {
      id: "effort",
      name: "Effort",
      category: "thought_level",
      currentValue: effort,
      options: LEVELS.map((value) => ({ value, name: value === "deep" ? "Deep" : value })),
    },
    {
      id: "fast-mode",
      name: "Fast mode",
      currentValue: "off",
      options: [
        { value: "off", name: "Off" },
        { value: "on", name: "On" },
      ],
    },
  ];
  let effort = "high";
  let configDelay = 0;
  const session = () => ({
    sessionId: CHAT,
    cwd: "/home/dev/uploader",
    title: "Uploader tuning",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
    configOptions: configOptions(),
  });
  const calls: { method: string; params: Record<string, any> }[] = [];

  function answer(method: string, params: Record<string, any>): unknown {
    calls.push({ method, params });
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session()] };
      case "_acpmux/attach":
        return { session: session(), lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      case "session/set_config_option":
        if (params.configId === "effort") effort = String(params.value);
        return { configOptions: configOptions() };
      default:
        return null;
    }
  }
  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (session: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
  };
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          const reply = () =>
            ws.send(
              JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }),
            );
          // A slow agent answers a level change late (the last test), so keys can outrun it.
          if (message.method === "session/set_config_option" && configDelay > 0) setTimeout(reply, configDelay);
          else reply();
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
    // A cold dev server's first load can stall in CI (agent-pane-replay.test.ts): load it here,
    // again if it stalls, so the test times only the menu.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(CHAT));
        await warm.getByText("Uploader tuned.").waitFor({ timeout: 25_000 });
        await warm.close();
        break;
      } catch (error) {
        await warm.close();
        if (attempt === 3) throw error;
      }
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  const TRIGGER = ".acpmux-effort .acpmux-picker-button";
  const MENU = ".acpmux-effort-menu";
  const sent = () =>
    calls
      .filter((call) => call.method === "session/set_config_option" && call.params.configId === "effort")
      .map((call) => call.params.value);
  const radioLabels = (page: Page) =>
    page
      .locator(`${MENU} [role="menuitemradio"]`)
      .evaluateAll((items) => items.map((item) => item.querySelector(".acpmux-menu-label")?.textContent));
  const open = async (slider: boolean) => {
    effort = "high";
    configDelay = 0;
    calls.length = 0;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(CHAT));
    await page.getByText("Uploader tuned.").waitFor();
    // The host's `composer` event (AgentPaneComposerSetting), as the app pushes it.
    if (slider) await page.evaluate(() => window.cmuxAcpmuxComposer?.({ reasoningSlider: true }));
    await page.locator(TRIGGER).click();
    await page.locator(MENU).waitFor();
    return page;
  };

  test("off (the default), the reasoning menu is the list of the agent's levels", async () => {
    const page = await open(false);
    expect(await page.locator(MENU).getByRole("slider").count()).toBe(0);
    expect(await radioLabels(page)).toEqual([...NAMES, "On", "Off"]);
    await page.close();
  });

  test("on, the menu shows a slider whose stops are the agent's levels; real keys step it and each step sends the level", async () => {
    const page = await open(true);
    // A native range input: role slider, arrow keys and Home/End, its value named by aria-valuetext.
    const slider = page.locator(MENU).getByRole("slider", { name: "Effort" });
    await slider.waitFor();
    // No level rows: the slider replaces them. Fast mode stays its own radio section.
    expect(await radioLabels(page)).toEqual(["On", "Off"]);
    // One stop per level the agent reports, the current one named on the slider and in the menu.
    expect(await slider.evaluate((input: HTMLInputElement) => [input.min, input.max, input.step])).toEqual([
      "0",
      String(LEVELS.length - 1),
      "1",
    ]);
    expect(await slider.getAttribute("aria-valuetext")).toBe("High");
    expect(await page.locator(`${MENU} .acpmux-effort-slider-level`).textContent()).toBe("High");
    // The menu opens with the slider focused, so the keys reach it at once.
    await page.waitForFunction(
      () => document.activeElement?.matches(".acpmux-effort-menu input[type=range]"),
      undefined,
      {
        timeout: 5_000,
      },
    );
    const valuetext = () => slider.getAttribute("aria-valuetext");
    const settle = async (name: string, value: string) => {
      await page.waitForFunction(
        (name) =>
          document.querySelector(".acpmux-effort-menu input[type=range]")?.getAttribute("aria-valuetext") === name &&
          document.querySelector(".acpmux-effort-menu .acpmux-effort-slider-level")?.textContent === name &&
          document.activeElement?.matches(".acpmux-effort-menu input[type=range]"),
        name,
        { timeout: 5_000 },
      );
      // The pick reaches the agent as a list pick does.
      for (let wait = 0; sent().at(-1) !== value && wait < 50; wait++) await Bun.sleep(100);
      expect(sent().at(-1)).toBe(value);
    };
    await page.keyboard.press("ArrowRight");
    await settle("Deep", "deep");
    await page.keyboard.press("ArrowRight");
    await settle("Extra High", "xhigh");
    await page.keyboard.press("End");
    await settle("Max", "max");
    await page.keyboard.press("Home");
    await settle("Low", "low");
    // Walking every stop names every level the agent reports, in its order.
    const walked = [await valuetext()];
    for (let step = 1; step < LEVELS.length; step++) {
      await page.keyboard.press("ArrowRight");
      await settle(NAMES[step]!, LEVELS[step]!);
      walked.push(await valuetext());
    }
    expect(walked).toEqual(NAMES);
    expect(sent()).toEqual(["deep", "xhigh", "max", "low", ...LEVELS.slice(1)]);
    // The keys stay on the slider: the menu is still open, and the chip names the level.
    expect(await page.locator(MENU).isVisible()).toBe(true);
    await page.keyboard.press("Escape");
    await page.waitForFunction(() => document.querySelector(".acpmux-effort-menu") === null, undefined, {
      timeout: 5_000,
    });
    expect(await page.locator(TRIGGER).textContent()).toContain("Max");
    await page.close();
  });

  test("on, keys pressed faster than the agent answers still walk the levels", async () => {
    const page = await open(true);
    configDelay = 800;
    const slider = page.locator(MENU).getByRole("slider", { name: "Effort" });
    await slider.waitFor();
    await page.waitForFunction(() => document.activeElement?.matches(".acpmux-effort-menu input[type=range]"));
    // Three steps before the first answer: each sends its own level, none is swallowed.
    for (let step = 0; step < 3; step++) await page.keyboard.press("ArrowRight");
    await page.waitForFunction(
      () => document.querySelector(".acpmux-effort-menu input[type=range]")?.getAttribute("aria-valuetext") === "Max",
      undefined,
      { timeout: 5_000 },
    );
    for (let wait = 0; sent().length < 3 && wait < 50; wait++) await Bun.sleep(100);
    expect(sent()).toEqual(["deep", "xhigh", "max"]);
    // The late answers do not pull the thumb back to an earlier level.
    await Bun.sleep(3 * configDelay);
    expect(await slider.getAttribute("aria-valuetext")).toBe("Max");
    expect(await page.locator(`${MENU} .acpmux-effort-slider-level`).textContent()).toBe("Max");
    await page.close();
  });
});
