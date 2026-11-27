// l10n-allow-file: test fixtures.
// The memory inbox card (MemoryOfferCard.tsx): its diff lines, one key per action with focus inside,
// the daemon's error shown with the facts still actionable, and the one-line note once settled.
import { afterEach, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { MemoryOfferCard } from "./MemoryOfferCard";
import { memoryOfferFromRecord, memoryRequestFailed, settleMemoryOffer } from "./memoryInbox";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

const FACTS = ["Use bun, never npm.", "Run webview tests from webviews/."];
const OFFER = memoryOfferFromRecord({
  offerId: "o1",
  file: "CLAUDE.md",
  facts: FACTS,
  heading: "## Learned in chats",
  created: false,
})!;

const press = async (target: Element, key: string) =>
  act(async () => {
    target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
  });

test("the card draws the file, the heading and a + line per fact, and takes no focus", async () => {
  const container = await render(<MemoryOfferCard offer={OFFER} onResolve={() => {}} />);
  expect(container.querySelector(".cv-memory__file")?.textContent).toBe("CLAUDE.md");
  const lines = [...container.querySelectorAll(".cv-memory__line")].map(
    (line) => line.querySelector(".cv-memory__text")?.textContent,
  );
  expect(lines).toEqual(["## Learned in chats", ...FACTS.map((fact) => `- ${fact}`)]);
  expect(container.ownerDocument.activeElement).toBe(container.ownerDocument.body);
  // Two pending facts offer Accept all.
  const foot = container.querySelector(".cv-memory__foot")!.closest(".cv-memory__fold")!;
  expect(foot.getAttribute("data-open")).toBe("true");
});

test("a, Return, d and Delete act on the focused fact; the arrows move between facts", async () => {
  const calls: [string[], string[]][] = [];
  const container = await render(
    <MemoryOfferCard offer={OFFER} onResolve={(accept, dismiss) => calls.push([accept, dismiss])} />,
  );
  const [first, second] = [...container.querySelectorAll<HTMLElement>("[data-fact-line]")];
  expect(first.tabIndex).toBe(0);
  expect(second.tabIndex).toBe(-1);
  first.focus();
  await press(first, "ArrowDown");
  expect(container.ownerDocument.activeElement).toBe(second);
  await press(second, "d");
  await press(first, "a");
  await press(first, "Enter");
  await press(second, "Delete");
  expect(calls).toEqual([
    [[], [FACTS[1]]],
    [[FACTS[0]], []],
    [[FACTS[0]], []],
    [[], [FACTS[1]]],
  ]);
});

test("a failed write shows the daemon's message and keeps the facts actionable", async () => {
  const failed = memoryRequestFailed(OFFER, FACTS, "EACCES: permission denied, open 'CLAUDE.md'");
  const container = await render(<MemoryOfferCard offer={failed} onResolve={() => {}} />);
  expect(container.querySelector(".cv-memory__error")?.textContent).toBe("EACCES: permission denied, open 'CLAUDE.md'");
  const buttons = [...container.querySelectorAll<HTMLButtonElement>("[data-fact-line] button")];
  expect(buttons).toHaveLength(4);
  expect(buttons.every((button) => !button.disabled)).toBe(true);
});

test("a settled offer folds to its one-line note", async () => {
  const settled = settleMemoryOffer(OFFER, { accepted: FACTS, dismissed: [] });
  const container = await render(<MemoryOfferCard offer={settled} onResolve={() => {}} />);
  const card = container.querySelector(".cv-memory")!;
  expect(card.getAttribute("data-settled")).toBe("true");
  expect(container.querySelector(".cv-memory__body")?.getAttribute("data-open")).toBe("false");
  expect(container.querySelector(".cv-memory__body")?.hasAttribute("inert")).toBe(true);
  expect(container.querySelector(".cv-memory__note")?.textContent).toBe("Added 2 notes to CLAUDE.md");
  const dismissed = settleMemoryOffer(OFFER, { accepted: [], dismissed: FACTS });
  await act(async () => root!.render(<MemoryOfferCard offer={dismissed} onResolve={() => {}} />));
  expect(container.querySelector(".cv-memory__note")?.textContent).toBe("Dismissed");
});
