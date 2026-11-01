// The context ring's hover card keeps the shared glass material compact: one left-aligned
// "used / window · percent" line, a thin usage bar, short category rows when reported, and a
// Details row when Session Info can open.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ContextRing } from "./ComposerPickers";
import { contextSegments } from "./ContextCard";
import { translate } from "./i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    pretendToBeVisual: true,
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (callback: FrameRequestCallback) =>
      setTimeout(() => callback(Date.now()), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function wait(ms = 0) {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, ms));
  });
}

async function mount(props: Parameters<typeof ContextRing>[0]) {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<ContextRing {...props} />);
  });
  return container.querySelector<HTMLButtonElement>(".acpmux-context-ring")!;
}

const card = () => document.querySelector<HTMLElement>(".acpmux-context-card");

/// Lets React and the hover timers run, one macrotask at a time, until `done` or `capMs` passes.
async function until(done: () => boolean, capMs = 3000) {
  const deadline = Date.now() + capMs;
  while (!done() && Date.now() < deadline) await wait();
}

test("resting the pointer on the ring shows the card without a click", async () => {
  const ring = await mount({ used: 111_000, size: 475_000 });
  expect(card()).toBeNull();
  await act(async () => {
    ring.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true }));
  });
  await until(() => card() !== null);
  expect(card()).not.toBeNull();
});

test("keyboard focus opens the compact tooltip at once", async () => {
  const ring = await mount({ used: 111_000, size: 475_000, setup: 20_000 });
  await act(async () => ring.focus());
  await wait();
  const shown = card();
  expect(shown).not.toBeNull();
  expect(shown!.textContent).toContain(translate("context.title"));
  const line = shown!.querySelector(".acpmux-context-card-line")!.textContent!;
  expect(line).toContain("111K");
  expect(line).toContain("475K");
  expect(line).toContain("23%");
  expect(shown!.querySelector(".acpmux-context-card-bar")).not.toBeNull();
  expect(shown!.querySelector<HTMLProgressElement>(".acpmux-context-card-bar")!.value).toBe(23);
});

test("the compact card does not expose an inferred setup split", async () => {
  const ring = await mount({ used: 60_000, size: 200_000 });
  await act(async () => ring.focus());
  await wait();
  expect(card()!.querySelector(".acpmux-context-card-parts")).toBeNull();
});

test("reported breakdowns stay to Messages, Tools and System rows", async () => {
  const ring = await mount({
    used: 131_400,
    size: 1_000_000,
    breakdown: {
      maxTokens: 1_000_000,
      categories: [
        { name: "Messages", kind: "used", tokens: 92_000 },
        { name: "MCP tools", kind: "used", tokens: 21_400 },
        { name: "System tools", kind: "used", tokens: 8_000 },
        { name: "System prompt", kind: "used", tokens: 10_000 },
        { name: "Free space", kind: "free", tokens: 868_600 },
      ],
    },
  });
  await act(async () => ring.focus());
  await wait();
  const line = card()!.querySelector(".acpmux-context-card-line")!.textContent!;
  expect(line).toContain("131.4K");
  expect(line).toContain("1M");
  expect(line).toContain("13%");
  const rows = [...card()!.querySelectorAll(".acpmux-context-card-part")].map((row) =>
    row.textContent?.replace(/\s+/g, " ").trim(),
  );
  expect(rows).toEqual(
    expect.arrayContaining([
      expect.stringMatching(/^Messages\s*92K$/),
      expect.stringMatching(/MCP tools\s*29\.4K$/),
      expect.stringMatching(/Agent setup\s*10K$/),
    ]),
  );
  expect(rows).toHaveLength(3);
});

test("the Details action is a full-width row beneath the summary", async () => {
  const ring = await mount({ used: 131_400, size: 1_000_000, onOpenDetails: () => {} });
  await act(async () => ring.focus());
  await wait();
  const details = card()!.querySelector<HTMLButtonElement>(".acpmux-context-card-details")!;
  expect(details.textContent).toContain(translate("context.details"));
  expect(details.textContent).toContain("›");
  expect(details.closest(".acpmux-context-card-foot")).not.toBeNull();
});

test("the card shows no plan-limits section when the harness reports none", async () => {
  const ring = await mount({ used: 60_000, size: 200_000 });
  await act(async () => ring.focus());
  await wait();
  expect(card()!.querySelector(".acpmux-context-card-limits")).toBeNull();
});

test("Details › opens Session Info's Context section", async () => {
  let opened = 0;
  const ring = await mount({ used: 60_000, size: 200_000, onOpenDetails: () => opened++ });
  await act(async () => ring.focus());
  await wait();
  const details = card()!.querySelector<HTMLButtonElement>(".acpmux-context-card-details")!;
  expect(details.textContent).toContain(translate("context.details"));
  expect(details.textContent).toContain("›");
  await act(async () => details.click());
  expect(opened).toBe(1);
});

test("with nowhere to open, the card has no Details link", async () => {
  const ring = await mount({ used: 60_000, size: 200_000 });
  await act(async () => ring.focus());
  await wait();
  expect(card()!.querySelector(".acpmux-context-card-details")).toBeNull();
});

test("Escape closes a card that keyboard focus opened", async () => {
  const ring = await mount({ used: 60_000, size: 200_000 });
  await act(async () => ring.focus());
  await wait();
  expect(card()).not.toBeNull();
  await act(async () => {
    document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  await until(() => card() === null);
  expect(card()).toBeNull();
});

test("Escape closes a card that the pointer opened", async () => {
  const ring = await mount({ used: 60_000, size: 200_000 });
  await act(async () => {
    ring.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true }));
  });
  await until(() => card() !== null);
  await act(async () => {
    document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  await until(() => card() === null);
  expect(card()).toBeNull();
});

test("the card's padding counts as inside the card", async () => {
  const ring = await mount({ used: 60_000, size: 200_000 });
  await act(async () => {
    ring.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true }));
  });
  await until(() => card() !== null);
  const outer = card()!;
  // The pointer leaves the ring for the card's padding (its outer element, not its content).
  await act(async () => {
    ring.dispatchEvent(new window.MouseEvent("pointerout", { bubbles: true, relatedTarget: outer }));
    outer.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true, relatedTarget: ring }));
  });
  // fixed-wait: proving the card stays means outwaiting the close grace (200 ms) once.
  await wait(400);
  expect(card()).not.toBeNull();
  // Pinned by a click, a press on the padding keeps it, and a press outside closes it.
  await act(async () => ring.click());
  await act(async () => {
    outer.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true }));
  });
  await wait();
  expect(card()).not.toBeNull();
  await act(async () => {
    outer.dispatchEvent(new window.MouseEvent("pointerout", { bubbles: true, relatedTarget: document.body }));
    document.body.dispatchEvent(new window.MouseEvent("pointerdown", { bubbles: true }));
  });
  await until(() => card() === null);
  expect(card()).toBeNull();
});

test("the split never passes the whole bar, even with more used than the window", () => {
  const total = (segments: ReturnType<typeof contextSegments>) =>
    segments.reduce((sum, segment) => sum + segment.percent, 0);
  expect(total(contextSegments(520_000, 475_000, 20_000))).toBeCloseTo(100, 5);
  expect(total(contextSegments(520_000, 475_000))).toBeCloseTo(100, 5);
  const [setup, conversation] = contextSegments(520_000, 475_000, 20_000);
  expect(setup.percent).toBeCloseTo(4.2, 1);
  expect(conversation.percent).toBeCloseTo(95.8, 1);
});

test("Tab from the ring reaches Details ›, and Tab past it leaves the card", async () => {
  let opened = 0;
  const ring = await mount({ used: 60_000, size: 200_000, onOpenDetails: () => opened++ });
  const after = document.createElement("button");
  after.textContent = "after";
  document.body.append(after);
  await act(async () => ring.focus());
  await wait();
  const tab = (target: Element, shiftKey = false) =>
    act(async () => {
      target.dispatchEvent(
        new window.KeyboardEvent("keydown", {
          key: "Tab",
          shiftKey,
          bubbles: true,
          cancelable: true,
        }),
      );
    });
  await tab(ring);
  const details = card()!.querySelector<HTMLButtonElement>(".acpmux-context-card-details")!;
  expect(document.activeElement).toBe(details);
  // Return on the focused link opens Session Info, as a click does.
  await act(async () => details.click());
  expect(opened).toBe(1);
  await act(async () => ring.focus());
  await wait();
  await tab(ring);
  // Shift-Tab goes back to the ring; Tab past the last button goes on past the ring.
  await tab(document.activeElement!, true);
  expect(document.activeElement).toBe(ring);
  await tab(ring);
  await tab(document.activeElement!);
  expect(document.activeElement).toBe(after);
  await until(() => card() === null);
  expect(card()).toBeNull();
});

test("before the first usage report the ring is inert and shows no card", async () => {
  const ring = await mount({});
  await act(async () => ring.dispatchEvent(new window.MouseEvent("pointerover", { bubbles: true })));
  // fixed-wait: proving no card shows means outwaiting the hover delay (450 ms) once.
  await wait(600);
  expect(card()).toBeNull();
});

test("the ring takes no hover or open pill in any stylesheet", () => {
  const dir = import.meta.dir;
  const css = ["styles.css", "composerLocation.css", "composerControls.css", "contextCard.css"]
    .map((file) => {
      try {
        return readFileSync(join(dir, file), "utf8");
      } catch {
        return "";
      }
    })
    .join("\n")
    .replace(/\/\*[\s\S]*?\*\//g, "");
  const offenders: string[] = [];
  for (const match of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const selectors = match[1].split(",").map((selector) => selector.trim());
    const ringStates = selectors.filter(
      (selector) => /\.acpmux-context-ring(?![\w-])/.test(selector) && /:hover|\[aria-expanded/.test(selector),
    );
    if (ringStates.length === 0) continue;
    const fill = /(?:^|;)\s*background(?:-color)?\s*:\s*([^;]+)/.exec(match[2]);
    if (fill && !/^(none|transparent)\s*$/.test(fill[1].trim()))
      offenders.push(`${ringStates.join(", ")} -> ${fill[1]}`);
  }
  expect(offenders).toEqual([]);
});
