// A message to another agent is one collapsed line, as Claude draws its message rows (Leo
// 2026-10-21): "Sent to <recipient>", the message's first line, a chevron, and how far it got as
// one muted word (Sent, Queued, Delivered, Failed). The recipient is a name, never a hex id.
// Opened, the message grows in place and nothing else draws: never the send's raw result (Leo
// 2026-10-21: "THIS SHOW MORE IS IMMEDIATELY TMI"). Copy sits in the line's hover row.
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
  // Closed, how far it got is one word on the line; nothing else draws: no body, no Show more.
  expect(row.querySelector(".cv-agentmsg__line > .cv-message__status")?.textContent).toBe("Delivered");
  expect(row.querySelector(".cv-agentmsg__card")).toBeNull();
  expect(row.querySelectorAll(".cv-message__status")).toHaveLength(1);
  expect(row.textContent).not.toContain("second line");
  expect(row.textContent).not.toContain("Show more");
});

test("opening it grows the message in place: the card holds the text and nothing else", async () => {
  // Leo 2026-10-21: "THIS SHOW MORE IS IMMEDIATELY TMI". Opened, no status block, no output block.
  await render(
    send("completed", "delivered to leoli-24 (id 9defc4d0ed87)\n", 'tell-coordinator "first line\\nsecond line"'),
  );
  await act(async () => toggle().click());
  expect(toggle().getAttribute("aria-expanded")).toBe("true");
  const card = host.querySelector(".cv-agentmsg__card")!;
  expect(card.textContent).toBe("first line\nsecond line");
  expect(card.classList.contains("selectable")).toBe(true);
  expect(toggle().getAttribute("aria-controls")).toBe(card.id);
  // One scroller in the card, the message's text, capped by the stylesheet (conversation.css).
  expect([...card.children].map((child) => child.className)).toEqual(["cv-message__text"]);
  // The preview steps aside for the card.
  expect(host.querySelector(".cv-agentmsg__preview")?.textContent).toBe("");
  const row = host.querySelector(".cv-message")!;
  // Nothing but the line and the card: no receipt line, no output block, no Show more.
  expect([...row.children].map((child) => child.className)).toEqual([
    "cv-tool cv-agentmsg__line is-strong",
    "cv-agentmsg__card selectable",
  ]);
  expect(row.querySelector(".cv-tool-output")).toBeNull();
  expect(row.textContent).not.toContain("Show more");
  expect(row.getAttribute("data-delivery")).toBe("delivered");
  // The receipt's id is plumbing, not something to read.
  expect(row.textContent).not.toContain("9defc4d0ed87");
  await act(async () => toggle().click());
  expect(host.querySelector(".cv-agentmsg__card")).toBeNull();
});

test("how far a send got is one muted word on its line: Sending shows none, then Sent", async () => {
  await render(send("in_progress"));
  expect(host.querySelector(".cv-message")?.getAttribute("data-delivery")).toBe("sending");
  expect(host.querySelector(".cv-agentmsg__line")?.textContent).toContain("Sending to");
  expect(host.querySelector(".cv-message__status")).toBeNull();
  await render(send("completed"));
  expect(host.querySelector(".cv-message")?.getAttribute("data-delivery")).toBe("sent");
  expect(host.querySelector(".cv-agentmsg__line > .cv-message__status")?.textContent).toBe("Sent");
});

const sendMessage = (to: string, output: string, status = "completed") => ({
  id: "activity-2",
  kind: "activity",
  at: 1_000,
  settled: status !== "in_progress",
  items: [
    {
      kind: "tool",
      text: "SendMessage",
      tool: {
        id: "t2",
        title: "SendMessage",
        kind: "other",
        status,
        inputSummary: JSON.stringify({ to, message: "Rebase on main, then rerun the grid tests." }),
        output,
      },
    },
  ],
});

const RESULTS = {
  queued: JSON.stringify({
    success: true,
    message: "Message queued for delivery to a39e817af38ddf5e7 at its next tool round.",
    pin: { id: "p1", at: 1 },
  }),
  delivered: JSON.stringify({ success: true, message: "Message delivered to a39e817af38ddf5e7." }),
  sent: JSON.stringify({ success: true, message: "Message sent to a39e817af38ddf5e7." }),
};

for (const [delivery, output] of Object.entries(RESULTS))
  test(`a SendMessage whose result says ${delivery} shows the word, never the result's JSON`, async () => {
    await render(sendMessage("a39e817af38ddf5e7", output));
    const row = host.querySelector(".cv-message")!;
    expect(row.getAttribute("data-delivery")).toBe(delivery);
    const word = { queued: "Queued", delivered: "Delivered", sent: "Sent" }[delivery];
    expect(row.querySelector(".cv-agentmsg__line > .cv-message__status")?.textContent).toBe(word!);
    for (const opened of [false, true]) {
      if (opened) await act(async () => toggle().click());
      for (const raw of ['{"success"', '"pin"', "queued for delivery", "a39e817af38ddf5e7"])
        expect(row.textContent).not.toContain(raw);
    }
  });

test("a send that did not arrive says why, never Sent: a stopped agent, no such agent, or just Not delivered", async () => {
  // Leo 2026-10-21: a card read "✓ Sent" over a success:false result.
  const cases: [string, string][] = [
    [
      JSON.stringify({
        success: false,
        message: "Agent a5b7309ddf7afa44d was stopped by the user and won't be resumed.",
      }),
      "Not delivered: agent stopped",
    ],
    [JSON.stringify({ success: false, error: "No agent named grid-fix" }), "Not delivered: no such agent"],
    [JSON.stringify({ success: false }), "Not delivered"],
  ];
  for (const [output, word] of cases) {
    await render(sendMessage("grid-fix", output));
    const row = host.querySelector(".cv-message")!;
    expect(row.getAttribute("data-delivery")).toBe("failed");
    expect(row.querySelector(".cv-agentmsg__line > .cv-message__status")?.textContent).toBe(word);
    await act(async () => toggle().click());
    for (const raw of ['{"success"', "won't be resumed", "No agent named"]) expect(row.textContent).not.toContain(raw);
  }
});

async function renderNamed(to: string, names: Map<string, string>) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  const { AgentNamesContext } = await import("../src/agent-session/acpmux/conversation/agentNames");
  const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
  act(() => root?.unmount());
  resetTranscriptDisclosure();
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <AgentNamesContext.Provider value={names}>
        <ToolRows row={sendMessage(to, RESULTS.queued) as never} />
      </AgentNamesContext.Provider>,
    ),
  );
}

test("the recipient is the Agent call's description for its agentId, or a short id, never the hex id", async () => {
  await renderNamed("a39e817af38ddf5e7", new Map([["a39e817af38ddf5e7", "Fix grid jump"]]));
  const line = host.querySelector(".cv-agentmsg__line")!;
  expect(line.querySelector(".cv-agentmsg__name")?.textContent).toBe("Fix grid jump");
  expect(line.textContent).not.toContain("This agent");
  expect(host.textContent).not.toContain("a39e817af38ddf5e7");
  // The full id is the chip's tooltip.
  expect(line.querySelector(".cv-agentmsg__name")?.getAttribute("title")).toBe("Agent ID: a39e817af38ddf5e7");
  // An id nothing names reads as a short id, the full one in the tooltip.
  await renderNamed("a5f0c2b9e1d4a7c3b", new Map());
  expect(host.querySelector(".cv-agentmsg__name")?.textContent).toBe("a5f0c2b9");
  expect(host.querySelector(".cv-agentmsg__name")?.getAttribute("title")).toBe("Agent ID: a5f0c2b9e1d4a7c3b");
  expect(host.textContent).not.toContain("a5f0c2b9e1d4a7c3b");
  // A name the call gives (a teammate, an acpmux session) shows as it is, with no tooltip.
  await renderNamed("grid-fix", new Map());
  expect(host.querySelector(".cv-agentmsg__name")?.textContent).toBe("grid-fix");
  expect(host.querySelector(".cv-agentmsg__name")?.hasAttribute("title")).toBe(false);
});

test("Copy is in the line's hover row, after the status word, not over the line's words", async () => {
  await render(send("completed", "", 'tell-coordinator "first line\\nsecond line"'));
  const line = host.querySelector(".cv-agentmsg__line")!;
  const actions = line.querySelector(":scope > .cv-sent-actions")!;
  expect(actions).not.toBeNull();
  expect(actions.querySelector("button")?.getAttribute("aria-label")).toBe("Copy");
  // The line's last child: the words, chip, preview and status word all come before it.
  expect(line.lastElementChild).toBe(actions);
  expect(actions.previousElementSibling?.classList.contains("cv-message__status")).toBe(true);
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

test("an acpmux_send call draws as the same collapsed message line, never an MCP row", async () => {
  // Agents message lanes with the acpmux MCP server (acpmux_mcp.rs) instead of piping text into
  // `acpmux send` in a shell.
  const row = {
    id: "activity-2",
    kind: "activity",
    at: 1_000,
    settled: true,
    items: [
      {
        kind: "tool",
        text: "mcp__cmux__acpmux_send",
        tool: {
          id: "t2",
          title: "mcp__cmux__acpmux_send",
          kind: "other",
          status: "completed",
          inputSummary: JSON.stringify({ to: "build-box/lane-a", text: "Rebase on main.\nThen push." }),
          output: "Sent to lane-a: steered into its running turn (promptId 0199).",
        },
      },
    ],
  };
  await render(row);
  const message = host.querySelector(".cv-agentmsg")!;
  expect(message.getAttribute("data-direction")).toBe("sent");
  expect(message.querySelector(".cv-agentmsg__name")?.textContent).toBe("build-box/lane-a");
  expect(message.querySelector(".cv-agentmsg__preview")?.textContent).toBe("Rebase on main.");
  expect(toggle().getAttribute("aria-expanded")).toBe("false");
});
