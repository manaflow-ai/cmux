// Another agent's message waiting in the queue draws as its received line (ComposerQueue.tsx,
// conversation/IncomingMessageCard.tsx), not as the person's prompt (Leo, 2026-10-21): the sender's
// name as a chip that opens its chat, the message as a card under it (cut to six lines when longer),
// and the row's actions (Steer, Delete, ⋯) at the line's end. The person's prompt is unchanged.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translatorFor } from "../src/agent-session/acpmux/i18n";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Range: dom.window.Range,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const { createRoot } = await import("react-dom/client");
const { ComposerQueue } = await import("../src/agent-session/acpmux/ComposerQueue");
const { SubsessionStore } = await import("../src/agent-session/acpmux/subagents/subsessions");

test("another agent's queued message draws as its received line, its actions at the line's end", async () => {
  const t = translatorFor("en");
  const text = "Rebase onto #23738 first.\n\nIt moves the queue rows.";
  const queued = [
    { id: "q1", prompt: text, message: { name: "coord-deputy", sessionId: "s-deputy", text, raw: text } },
    { id: "q2", prompt: "Also update the comment above the retry loop" },
  ];
  const opened: string[] = [];
  const subsessions = { store: new SubsessionStore(), open: (id: string) => void opened.push(id) };
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ComposerQueue
        queue={queued as never}
        t={t}
        subsessions={subsessions}
        onRemove={async () => true}
        onChange={async () => true}
      />,
    ),
  );
  const [agent, own] = [...host.querySelectorAll<HTMLElement>(".acpmux-queued")];
  const labels = (row: HTMLElement) =>
    [...row.querySelectorAll(".acpmux-queued-action")].map((button) => button.getAttribute("aria-label"));
  const all = [t("composer.queueSteer"), t("composer.queueDelete"), t("composer.queueActions")];

  // The sender's chip, and the short message whole under the line, not cut; the actions inside the line.
  expect(agent!.querySelector(".acpmux-queued-text")).toBeNull();
  expect(agent!.querySelector(".cv-received__name")?.textContent).toBe("coord-deputy");
  const body = agent!.querySelector(".cv-received__body");
  expect(body?.textContent).toContain("Rebase onto #23738 first.");
  expect(body?.textContent).toContain("It moves the queue rows.");
  expect(body?.hasAttribute("data-cut")).toBe(false);
  expect(agent!.querySelector(".cv-received__line .acpmux-queued-actions")).not.toBeNull();
  expect(labels(agent!)).toEqual(all);

  // The chip opens the sender's chat; the rest of the line opens the message.
  await act(async () => agent!.querySelector<HTMLButtonElement>("button.cv-received__name")!.click());
  expect(opened).toEqual(["s-deputy"]);
  await act(async () => agent!.querySelector<HTMLButtonElement>(".cv-received__toggle")!.click());
  expect(agent!.querySelector(".cv-received__toggle")?.getAttribute("aria-expanded")).toBe("true");
  expect(agent!.querySelector(".cv-received__body")?.textContent).toContain("It moves the queue rows.");

  // The person's prompt is unchanged.
  expect(own!.querySelector(".cv-received")).toBeNull();
  expect(own!.querySelector(".acpmux-queued-text")?.textContent).toContain("Also update the comment");
  expect(labels(own!)).toEqual(all);
});
