// A message to another agent shows how far it got (Leo 2026-10-13, transcript row design): a status
// glyph that goes sending -> sent -> delivered, and the delivery receipt as one visible status line.
// Before, the card offered "Show more" on a short message and that only revealed the receipt
// ("delivered to leoli-24 (id 9defc4d0ed87)") in a code box.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const send = (status: string, output?: string) => ({
  id: "activity-1",
  kind: "activity",
  at: 1_000,
  settled: status !== "in_progress",
  items: [
    {
      kind: "tool",
      text: "Run",
      tool: {
        id: "t1",
        title: "Run",
        kind: "execute",
        status,
        command: 'tell-coordinator "cg-next-reds BLOCKED on #20276"',
        output,
      },
    },
  ],
});

async function render(row: object) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(<ToolRows row={row as never} />));
}

test("a delivered message shows its receipt as a status line, with no Show more", async () => {
  await render(send("completed", "delivered to leoli-24 (id 9defc4d0ed87)\n"));
  const card = host.querySelector(".cv-message")!;
  expect(card.getAttribute("data-delivery")).toBe("delivered");
  expect(card.querySelector(".cv-message__status")?.textContent).toBe("Delivered to leoli-24");
  expect(card.querySelector(".cv-message__more")).toBeNull();
  // The receipt's id is plumbing, not something to read.
  expect(card.textContent).not.toContain("9defc4d0ed87");
});

test("a message moves through sending and sent", async () => {
  await render(send("in_progress"));
  expect(host.querySelector(".cv-message")?.getAttribute("data-delivery")).toBe("sending");
  expect(host.querySelector(".cv-message__status")?.textContent).toBe("Sending…");
  await render(send("completed"));
  expect(host.querySelector(".cv-message")?.getAttribute("data-delivery")).toBe("sent");
  expect(host.querySelector(".cv-message__status")?.textContent).toBe("Sent");
});

test("an opened delivered message shows what else the send printed, without the receipt", async () => {
  // Review of the redesign: a receipt hid every other line the send printed.
  await render(send("completed", "delivered to leoli-24 (id 9defc4d0ed87)\nqueued behind 2 messages\n"));
  await act(async () => host.querySelector<HTMLButtonElement>(".cv-message__head")!.click());
  expect(host.querySelector(".cv-tool-output")?.textContent).toBe("queued behind 2 messages");
  expect(host.textContent).not.toContain("9defc4d0ed87");
});
