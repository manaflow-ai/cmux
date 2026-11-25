// cmux-web-test-timeout: 300
// l10n-allow-file: fixture records and assertions on the English catalog's words, not shipped UI.
// The composer holds still while the chat around it changes (Leo, 2026-11-22: "the composer just
// re-rendered/flickered as i was scrolling up and down my chat. your subagent finished and you were
// thinking maybe you started waiting maybe the flicker/re-render was before that and idk if the
// waiting for agent service bullshit has anything to do with it").
//
// One chat with a running turn, against the stand-in acpmux (support/papercutChat.ts), through each of
// his events in order: a wheel scroll up and back down, the turn's calls ending (the live line reads
// "Thinking"), a foreground subagent starting (the live line names it) beside a background one in the
// tray, each of them finishing, and acpmux going quiet while the pane reconnects,
// then answering again. Over each event: the composer's React renders (`cmuxAcpmuxDebug.renders()`,
// with `composer.prop:KEY` naming each prop whose identity changed), whether its editor is still the
// same DOM node, and every painted frame's composer box (place, size, opacity) and attribute changes on
// the composer's own elements, so a class toggle or a remount that draws no React render still shows.
// Real Chromium; CI fails the file when it cannot launch it (requireBrowserLane). Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/agent-pane-composer-still-on-churn.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";
import { COMPOSER_EDITOR, MAIN_DOCK } from "../src/agent-session/acpmux/composerSelectors";

type Watched = { looks: string[]; mutations: string[]; animations: number };

await requireBrowserLane("agent-pane-composer-still-on-churn.test.ts", async () => {
  setDefaultTimeout(290_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 40, running: true });
  });
  afterAll(async () => {
    pane?.stall([]);
    await pane?.close();
    await browser?.close();
  });

  const update = (data: Record<string, unknown>, acpmux?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: data, ...(acpmux ? { _meta: { acpmux } } : {}) },
  });
  const agent = (id: string, call: string, background: boolean, state = "running") => ({
    id,
    parent: null,
    name: background ? "Auditor" : "Reviewer",
    kind: "general-purpose",
    task: background ? "Audit the bottom stack" : "Review the diff",
    state,
    toolCallId: call,
    background,
  });
  /// A subagent's start as acpmux records it: `subagent_spawned`, then its Agent call.
  const spawn = (id: string, call: string, background: boolean) => {
    pane.record(
      "subagent_spawned",
      update(
        { sessionUpdate: "subagent_spawned", subagentSessionId: id, background },
        { subagents: [agent(id, call, background)] },
      ),
      "in",
    );
    pane.record(
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: call,
        title: `Agent: ${background ? "Audit the bottom stack" : "Review the diff"}`,
        kind: "think",
        status: "in_progress",
        rawInput: {
          description: background ? "Audit the bottom stack" : "Review the diff",
          prompt: "Look.",
          subagent_type: "general-purpose",
          ...(background ? { run_in_background: true } : {}),
        },
      }),
      "in",
    );
  };
  /// Its end: its state, then its Agent call's result.
  const finish = (id: string, call: string, background: boolean) => {
    pane.record(
      "subagent_state_update",
      update({ sessionUpdate: "subagent_state_update" }, { subagents: [agent(id, call, background, "completed")] }),
      "in",
    );
    pane.record(
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: call,
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: `Done.\nagentId: ${id}` } }],
      }),
      "in",
    );
  };

  /// The composer's renders since the last read, and the props that changed identity among them.
  const renders = async (page: Page) => {
    const all = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())) as Record<string, number>;
    const props = Object.keys(all)
      .filter((key) => key.startsWith("composer.prop:"))
      .map((key) => `${key.slice("composer.prop:".length)}×${all[key]}`)
      .sort();
    return { renders: all.composer ?? 0, props };
  };
  const editorNode = (page: Page) =>
    page.evaluate((selector) => {
      const w = window as any;
      const node = document.querySelector(selector);
      if (!node) throw new Error("Composer editor is missing");
      w.__editorNodes ??= [];
      if (!w.__editorNodes.includes(node)) w.__editorNodes.push(node);
      return w.__editorNodes.indexOf(node) as number;
    }, `${MAIN_DOCK} ${COMPOSER_EDITOR}`);
  /// Starts reading every painted frame's composer box and every attribute or child change on the
  /// composer's own elements (its form, box, field and foot; not the menus or chips that draw inside).
  const watch = (page: Page) =>
    page.evaluate((dockSelector) => {
      const w = window as any;
      const looks: string[] = [];
      const mutations = new Set<string>();
      const dock = document.querySelector<HTMLElement>(dockSelector)!;
      const form = () => dock.querySelector<HTMLElement>(".acpmux-composer");
      const box = () => dock.querySelector<HTMLElement>(".acpmux-composer-box");
      const name = (node: Node) => {
        const element = node instanceof Element ? node : node.parentElement;
        return element ? `${element.tagName.toLowerCase()}.${[...element.classList].slice(0, 2).join(".")}` : "?";
      };
      const observer = new MutationObserver((records) => {
        for (const record of records) {
          const target = record.target instanceof Element ? record.target : record.target.parentElement;
          if (!target || !form()?.contains(target)) continue;
          // Text the composer itself draws that may change (the context ring's figure) is not a flicker.
          if (record.type === "characterData") continue;
          mutations.add(
            record.type === "attributes" ? `${name(target)}[${record.attributeName}]` : `${name(target)} children`,
          );
        }
      });
      observer.observe(dock, { subtree: true, attributes: true, childList: true });
      const startAnimations = new Set(dock.getAnimations({ subtree: true }));
      let animations = 0;
      const stop = w.cmuxAfterPaint(() => {
        const b = box();
        const rect = b?.getBoundingClientRect();
        looks.push(
          rect
            ? `${Math.round(rect.left)},${Math.round(rect.top)},${Math.round(rect.width)}x${Math.round(rect.height)},${getComputedStyle(b!).opacity}`
            : "none",
        );
        for (const animation of form()?.getAnimations({ subtree: true }) ?? [])
          if (!startAnimations.has(animation)) {
            startAnimations.add(animation);
            animations += 1;
          }
        return true;
      });
      w.__composerWatch = () => {
        stop();
        observer.disconnect();
        return { looks: [...new Set(looks)], mutations: [...mutations].sort(), animations };
      };
    }, MAIN_DOCK);
  const watched = (page: Page) => page.evaluate(() => (window as any).__composerWatch()) as Promise<Watched>;
  /// Two painted frames, so a commit the event started has drawn.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          let frames = 0;
          window.cmuxAfterPaint(() => {
            frames += 1;
            if (frames < 3) return true;
            resolve();
            return false;
          });
        }),
    );

  test("a scroll, a subagent's start and end, the live line's change and a wait for acpmux leave the composer still", async () => {
    const page = await pane.open({ width: 1100, height: 760 });
    const results: Record<string, { renders: number; props: string[]; node: number } & Watched> = {};
    try {
      // The tray's background subagent first, before any event under test: the tray's arrival above
      // the composer is a real change (it sits on the tray).
      spawn("sub-bg", "agent-bg", true);
      await page.getByText("Audit the bottom stack").first().waitFor({ timeout: 20_000 });
      await settle(page);
      const node = await editorNode(page);
      await renders(page);

      const step = async (label: string, event: () => Promise<void>) => {
        await watch(page);
        await event();
        await settle(page);
        const seen = await watched(page);
        results[label] = { ...(await renders(page)), node: await editorNode(page), ...seen };
      };

      await step("scroll", async () => {
        const scroller = await page.locator(".acpmux-scroll").boundingBox();
        await page.mouse.move(scroller!.x + scroller!.width / 2, scroller!.y + scroller!.height / 2);
        for (let n = 0; n < 12; n++) {
          await page.mouse.wheel(0, -100);
          await settle(page);
        }
        for (let n = 0; n < 14; n++) {
          await page.mouse.wheel(0, 100);
          await settle(page);
        }
      });
      await step("calls end: Thinking", async () => {
        for (const id of ["r1", "r2"])
          pane.record(
            "tool_call_update",
            update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" }),
            "in",
          );
        await page.getByText("Thinking", { exact: false }).first().waitFor({ timeout: 20_000 });
      });
      const waitingOnAgent = page.getByText(/^Waiting on (?:1 subagent|subagent .+)/).first();
      await step("subagent starts", async () => {
        spawn("sub-fg", "agent-fg", false);
        await waitingOnAgent.waitFor({ timeout: 20_000 });
      });
      await step("subagent finishes: Thinking", async () => {
        finish("sub-fg", "agent-fg", false);
        await waitingOnAgent.waitFor({ state: "hidden", timeout: 20_000 });
      });
      await step("background subagent finishes", async () => {
        finish("sub-bg", "agent-bg", true);
        // fixed-wait: the tray card's own end (its line and count) draws over the next second.
        await page.waitForTimeout(1_200);
      });
      await step("scroll again", async () => {
        for (let n = 0; n < 8; n++) {
          await page.mouse.wheel(0, -120);
          await settle(page);
        }
        for (let n = 0; n < 10; n++) {
          await page.mouse.wheel(0, 120);
          await settle(page);
        }
      });
      const connects = await page.evaluate(
        () => (window as any).cmuxAcpmuxDebug.acpLog({ limit: 1 }).stats.connects as number,
      );
      await step("acpmux quiet during reconnect", async () => {
        const watches = pane.methods.filter((method) => method === "_acpmux/watch").length;
        pane.stall(["_acpmux/watch", "_acpmux/attach"]);
        pane.drop();
        await pane.sent("_acpmux/watch", watches);
        // fixed-wait: sample the composer across a sustained wait for the service.
        await page.waitForTimeout(3_000);
      });
      await step("acpmux answers again", async () => {
        pane.stall([]);
        await page.waitForFunction(
          (before) => (window as any).cmuxAcpmuxDebug.acpLog({ limit: 1 }).stats.connects > before,
          connects,
          { timeout: 30_000 },
        );
      });
      for (const [label, result] of Object.entries(results))
        console.log(`COMPOSER-CHURN ${JSON.stringify({ event: label, ...result, editorNodeBefore: node })}`);
      for (const [label, result] of Object.entries(results)) {
        expect({ label, renders: result.renders, props: result.props }).toEqual({ label, renders: 0, props: [] });
        expect({ label, node: result.node }).toEqual({ label, node });
        expect({ label, looks: result.looks.length }).toEqual({ label, looks: 1 });
        expect({ label, mutations: result.mutations }).toEqual({ label, mutations: [] });
        expect({ label, animations: result.animations }).toEqual({ label, animations: 0 });
      }
    } finally {
      pane.stall([]);
      await page.close();
    }
  });
});
