// A message to another agent is one collapsed line, as Claude draws its message rows (Leo
// 2026-10-21): "Sent to <recipient>", the message's first line, a chevron. Opened, it shows the
// whole message and how far it got (Leo 2026-10-13): a status glyph that goes sending -> sent ->
// delivered, and the delivery receipt as one status line, its id never shown.
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

const send = (status: string, output?: string, command = 'tell-coordinator "cg-next-reds BLOCKED on #20276"') => ({
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
        command,
        output,
      },
    },
  ],
});

async function render(row: object) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
  act(() => root?.unmount());
  resetTranscriptDisclosure();
  root = createRoot(host);
  await act(async () => root!.render(<ToolRows row={row as never} />));
}

const toggle = () => host.querySelector<HTMLButtonElement>(".cv-agentmsg__toggle")!;

test("a sent message starts as one collapsed line: Sent to, the recipient, a one-line preview", async () => {
  // Leo 2026-10-21: the card "should be more collapsed from the start", as Claude draws messages.
  await render(
    send("completed", "delivered to leoli-24 (id 9defc4d0ed87)\n", 'tell-coordinator "first line\\nsecond line"'),
  );
  const row = host.querySelector(".cv-agentmsg")!;
  expect(row.getAttribute("data-direction")).toBe("sent");
  expect(row.querySelector(".cv-agentmsg__line")?.textContent).toContain("Sent to");
  expect(row.querySelector(".cv-agentmsg__name")?.textContent).toBe("coordinator");
  expect(row.querySelector(".cv-agentmsg__preview")?.textContent).toBe("first line");
  expect(toggle().getAttribute("aria-expanded")).toBe("false");
  // Closed, nothing else draws: no body, no status line, no Show more.
  expect(row.querySelector(".cv-agentmsg__card")).toBeNull();
  expect(row.querySelector(".cv-message__status")).toBeNull();
  expect(row.textContent).not.toContain("second line");
  expect(row.textContent).not.toContain("Show more");
});

test("opening it shows the whole message, selectable, and the receipt as a status line", async () => {
  await render(
    send("completed", "delivered to leoli-24 (id 9defc4d0ed87)\n", 'tell-coordinator "first line\\nsecond line"'),
  );
  await act(async () => toggle().click());
  expect(toggle().getAttribute("aria-expanded")).toBe("true");
  const card = host.querySelector(".cv-agentmsg__card")!;
  expect(card.textContent).toBe("first line\nsecond line");
  expect(card.classList.contains("selectable")).toBe(true);
  expect(toggle().getAttribute("aria-controls")).toBe(card.id);
  // The preview steps aside for the card.
  expect(host.querySelector(".cv-agentmsg__preview")?.textContent).toBe("");
  const row = host.querySelector(".cv-message")!;
  expect(row.getAttribute("data-delivery")).toBe("delivered");
  expect(row.querySelector(".cv-message__status")?.textContent).toBe("Delivered to leoli-24");
  // The receipt's id is plumbing, not something to read.
  expect(row.textContent).not.toContain("9defc4d0ed87");
  await act(async () => toggle().click());
  expect(host.querySelector(".cv-agentmsg__card")).toBeNull();
});

test("a message moves through sending and sent", async () => {
  await render(send("in_progress"));
  expect(host.querySelector(".cv-message")?.getAttribute("data-delivery")).toBe("sending");
  expect(host.querySelector(".cv-agentmsg__line")?.textContent).toContain("Sending to");
  await act(async () => toggle().click());
  expect(host.querySelector(".cv-message__status")?.textContent).toBe("Sending…");
  await render(send("completed"));
  expect(host.querySelector(".cv-message")?.getAttribute("data-delivery")).toBe("sent");
  await act(async () => toggle().click());
  expect(host.querySelector(".cv-message__status")?.textContent).toBe("Sent");
});

test("an opened delivered message shows what else the send printed, without the receipt", async () => {
  // Review of the redesign: a receipt hid every other line the send printed.
  await render(send("completed", "delivered to leoli-24 (id 9defc4d0ed87)\nqueued behind 2 messages\n"));
  await act(async () => toggle().click());
  expect(host.querySelector(".cv-tool-output")?.textContent).toBe("queued behind 2 messages");
  expect(host.textContent).not.toContain("9defc4d0ed87");
});

test("the shared row draws a received message too: the caller's icon, a chip that opens the chat, end actions", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AgentMessageRow, messagePreview } = await import("../src/agent-session/acpmux/conversation/AgentMessageRow");
  act(() => root?.unmount());
  root = createRoot(host);
  const opened: string[] = [];
  let open = false;
  const draw = () =>
    root!.render(
      <AgentMessageRow
        direction="received"
        icon={<svg data-testid="harness-mark" />}
        sentence={"Received message from \u0000"}
        name="grid-fix"
        onOpenName={() => opened.push("grid-fix")}
        openNameLabel="Open grid-fix"
        preview={messagePreview("**Done**: the grid fix is on `cmux/grid-fix`.\nTests pass.")}
        label="Message from grid-fix to This agent"
        open={open}
        onToggle={() => {
          open = !open;
          draw();
        }}
        actions={
          <button type="button" className="reply">
            Reply
          </button>
        }
        body="the whole message"
      />,
    );
  await act(async () => draw());
  const row = host.querySelector(".cv-agentmsg")!;
  expect(row.getAttribute("data-direction")).toBe("received");
  expect(row.querySelector(".cv-agentmsg__icon [data-testid=harness-mark]")).not.toBeNull();
  expect(row.querySelector(".cv-agentmsg__line > .reply")?.textContent).toBe("Reply");
  // First line only, its Markdown marks dropped.
  expect(row.querySelector(".cv-agentmsg__preview")?.textContent).toBe("Done: the grid fix is on cmux/grid-fix.");
  await act(async () => host.querySelector<HTMLButtonElement>("button.cv-agentmsg__name")!.click());
  expect(opened).toEqual(["grid-fix"]);
  expect(host.querySelector(".cv-agentmsg__card")).toBeNull();
  await act(async () => toggle().click());
  expect(host.querySelector(".cv-agentmsg__card")?.textContent).toBe("the whole message");
});
