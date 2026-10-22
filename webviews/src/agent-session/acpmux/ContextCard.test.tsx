// The context ring's hover card (Leo 2026-10-21, after Claude's and Codex's): resting on the ring,
// or focusing it from the keyboard, shows a glass card with no click. It reads "23% used · 111k /
// 475k", draws the window as a thin stacked bar (setup, then conversation, over the free track,
// in the Inspector Context meter's colors) and ends on "Details ›", which opens the Inspector at
// its Context section. The ring itself never takes a hover pill.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ContextRing } from "./ComposerPickers";
import { translate } from "./i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
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

test("keyboard focus opens the card at once, with the context line and a stacked bar", async () => {
  const ring = await mount({ used: 111_000, size: 475_000, setup: 20_000 });
  await act(async () => ring.focus());
  await wait();
  const shown = card();
  expect(shown).not.toBeNull();
  expect(shown!.textContent).toContain(translate("context.title"));
  const line = shown!.querySelector(".acpmux-context-card-line")!.textContent;
  expect(line).toContain("23%");
  expect(line).toMatch(/111K/i);
  expect(line).toMatch(/475K/i);
  const segments = [...shown!.querySelectorAll<HTMLElement>(".acpmux-context-card-bar [data-segment]")];
  expect(segments.map((segment) => segment.dataset.segment)).toEqual(["setup", "conversation"]);
  // 20k and 91k of 475k.
  expect(parseFloat(segments[0].style.width)).toBeCloseTo(4.2, 1);
  expect(parseFloat(segments[1].style.width)).toBeCloseTo(19.2, 1);
});

test("without a setup split the bar is one used segment", async () => {
  const ring = await mount({ used: 60_000, size: 200_000 });
  await act(async () => ring.focus());
  await wait();
  const segments = [...card()!.querySelectorAll<HTMLElement>(".acpmux-context-card-bar [data-segment]")];
  expect(segments.map((segment) => segment.dataset.segment)).toEqual(["used"]);
  expect(parseFloat(segments[0].style.width)).toBeCloseTo(30, 1);
});

test("the card shows no plan-limits section when the harness reports none", async () => {
  const ring = await mount({ used: 60_000, size: 200_000 });
  await act(async () => ring.focus());
  await wait();
  expect(card()!.querySelector(".acpmux-context-card-limits")).toBeNull();
});

test("Details › opens the Inspector's Context section", async () => {
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

// The richer card (Leo 2026-10-21: "we should have richer metadata on the context circle"): a row
// per part of the window as Claude Code's /context counts it, the model's window, the time since
// the last compaction and Compact now. Each row shows only with real data behind it.
const BREAKDOWN = {
  categories: [
    { id: "system_prompt", name: "System prompt", tokens: 6_000 },
    { id: "system_tools", name: "System tools", tokens: 14_000 },
    { id: "memory_files", name: "Memory files", tokens: 5_000 },
    { id: "messages", name: "Messages", tokens: 80_000 },
  ],
  attachmentTokens: 3_000,
};
const NOW = Date.UTC(2026, 9, 21, 12, 0, 0);
const parts = () =>
  [...card()!.querySelectorAll<HTMLElement>(".acpmux-context-card-part")].map((row) => ({
    kind: row.dataset.segment,
    name: row.querySelector(".acpmux-context-card-part-name")!.textContent,
    tokens: row.querySelector(".acpmux-context-card-part-tokens")!.textContent,
  }));
const fact = (name: string) => card()!.querySelector<HTMLElement>(`[data-fact="${name}"]`);

test("Claude Code's breakdown shows a row each for system, tools, files and messages", async () => {
  const ring = await mount({ used: 111_000, size: 475_000, setup: 20_000, breakdown: BREAKDOWN });
  await act(async () => ring.focus());
  await wait();
  expect(parts()).toEqual([
    { kind: "system", name: translate("context.system"), tokens: "6K" },
    { kind: "tools", name: translate("context.tools"), tokens: "14K" },
    // Memory files and the attachments.
    { kind: "files", name: translate("context.files"), tokens: "8K" },
    // The rest of what is used now: 111K - 6K - 14K - 8K.
    { kind: "messages", name: translate("context.messages"), tokens: "83K" },
  ]);
  const segments = [...card()!.querySelectorAll<HTMLElement>(".acpmux-context-card-bar [data-segment]")];
  expect(segments.map((segment) => segment.dataset.segment)).toEqual(["system", "tools", "files", "messages"]);
});

test("without a breakdown the card shows no system, tools, files or messages row", async () => {
  const ring = await mount({ used: 111_000, size: 475_000 });
  await act(async () => ring.focus());
  await wait();
  expect(parts()).toEqual([]);
  expect(card()!.querySelector('[data-segment="system"], [data-segment="messages"]')).toBeNull();
});

test("the model's window shows with the model's name, and not without it", async () => {
  const ring = await mount({ used: 111_000, size: 475_000, model: "Opus 5.5" });
  await act(async () => ring.focus());
  await wait();
  expect(fact("model")?.textContent).toBe(translate("context.modelWindow", { model: "Opus 5.5", size: "475K" }));
  await act(async () => root!.render(<ContextRing used={111_000} size={475_000} />));
  await wait();
  expect(fact("model")).toBeNull();
});

test("the time since the last compaction shows only after one", async () => {
  const ring = await mount({ used: 30_000, size: 200_000, compactedAt: NOW - 12 * 60_000, now: NOW });
  await act(async () => ring.focus());
  await wait();
  expect(fact("compacted")?.textContent).toBe(
    translate("context.compacted", { ago: translate("home.ago", { time: translate("age.minutes", { n: 12 }) }) }),
  );
  await act(async () => root!.render(<ContextRing used={30_000} size={200_000} now={NOW} />));
  await wait();
  expect(fact("compacted")).toBeNull();
});

test("Compact now fires the compact action and closes the card", async () => {
  let compacted = 0;
  const ring = await mount({ used: 111_000, size: 475_000, onCompact: () => compacted++ });
  await act(async () => ring.focus());
  await wait();
  const button = card()!.querySelector<HTMLButtonElement>(".acpmux-context-card-compact")!;
  expect(button.textContent).toBe(translate("context.compactNow"));
  await act(async () => button.click());
  expect(compacted).toBe(1);
  await until(() => card() === null);
  expect(card()).toBeNull();
});

test("without a compact action there is no Compact now, and a running turn disables it", async () => {
  const ring = await mount({ used: 111_000, size: 475_000 });
  await act(async () => ring.focus());
  await wait();
  expect(card()!.querySelector(".acpmux-context-card-compact")).toBeNull();
  await act(async () => root!.render(<ContextRing used={111_000} size={475_000} working onCompact={() => {}} />));
  await wait();
  expect(card()!.querySelector<HTMLButtonElement>(".acpmux-context-card-compact")!.disabled).toBe(true);
});

/// The ring between two other controls, as the composer's footer has it.
async function mountBetween(props: Parameters<typeof ContextRing>[0]) {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <>
        <button type="button" id="before">
          before
        </button>
        <ContextRing {...props} />
        <button type="button" id="after">
          after
        </button>
      </>,
    );
  });
  return container.querySelector<HTMLButtonElement>(".acpmux-context-ring")!;
}
/// A Tab press: the page's keydown first, then, unless the page took it, the browser's own move to
/// the next (or previous) button in document order, which jsdom does not do.
const tab = async (shift = false) => {
  await act(async () => {
    const from = document.activeElement as HTMLElement;
    const press = new window.KeyboardEvent("keydown", { key: "Tab", shiftKey: shift, bubbles: true, cancelable: true });
    if (!from.dispatchEvent(press)) return;
    const order = [...document.querySelectorAll<HTMLButtonElement>("button:not(:disabled)")];
    order[order.indexOf(from as HTMLButtonElement) + (shift ? -1 : 1)]?.focus();
  });
  await wait();
};
const focused = () => document.activeElement as HTMLElement | null;

test("Tab from the ring reaches Compact now and Details in the card, then moves on past the ring", async () => {
  let compacted = 0;
  const ring = await mountBetween({
    used: 111_000,
    size: 475_000,
    onCompact: () => compacted++,
    onOpenDetails: () => {},
  });
  await act(async () => ring.focus());
  await wait();
  expect(card()).not.toBeNull();
  await tab();
  expect(focused()?.className).toBe("acpmux-context-card-compact");
  expect(card()!.contains(focused())).toBe(true);
  await tab();
  expect(focused()?.className).toBe("acpmux-context-card-details");
  // Shift+Tab steps back, and from the first action back to the ring.
  await tab(true);
  expect(focused()?.className).toBe("acpmux-context-card-compact");
  await tab(true);
  expect(focused()).toBe(ring);
  // Into the card again, and Enter on Compact now (a button's Enter is its click).
  await tab();
  await act(async () => focused()!.click());
  expect(compacted).toBe(1);
  await act(async () => ring.focus());
  await wait();
  await tab();
  await tab();
  // Tab past the card's last action goes to what follows the ring, and the card closes.
  await tab();
  expect(focused()?.id).toBe("after");
  await until(() => card() === null);
  expect(card()).toBeNull();
});

test("Escape inside the card closes it and puts focus back on the ring", async () => {
  const ring = await mountBetween({ used: 111_000, size: 475_000, onOpenDetails: () => {} });
  await act(async () => ring.focus());
  await wait();
  await tab();
  expect(focused()?.className).toBe("acpmux-context-card-details");
  await act(async () => {
    focused()!.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  await until(() => card() === null);
  expect(card()).toBeNull();
  expect(focused()).toBe(ring);
});
