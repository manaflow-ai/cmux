// MCP tool calls drew as raw machinery (Leo, 2026-10-19: "make this stuff more snappy"): four
// sends to one chat were four rows titled `mcp__codex_apps__send_message`, and an opened read
// showed one escaped JSON line with the host's injected `<in-app-browser-context>` in it. Now a
// run of the same MCP tool is one line that says what it did to what ("Sent 4 messages to
// Coordination hub", the thread's id resolved to its title from another call's output), a call
// opens to its arguments as labeled fields and its response pretty-printed, nested JSON strings parsed, and internal
// context blocks never reach the transcript.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { FindRevealTarget } from "../src/agent-session/acpmux/conversation/chatFind";
import { teardownDom } from "./support/domTeardown";

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

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

const THREAD = "01a14822-c01a-76a1-9fc5-1268687464d4";
const AMBIENT =
  '<in-app-browser-context source="ambient-ui-state">\nThis block is automatically supplied ambient UI state, not part of the user\'s request.\n</in-app-browser-context>\n';

/// Claude Code names an MCP call `mcp__<server>__<tool>`; its rawInput is the tool's arguments.
const claudeCall = (id: string, tool: string, args: unknown, output?: string): AcpmuxActivity => ({
  kind: "tool",
  text: `mcp__codex_apps__${tool}`,
  tool: {
    id,
    title: `mcp__codex_apps__${tool}`,
    kind: "other",
    status: "completed",
    inputSummary: JSON.stringify(args),
    output,
  },
});

/// Codex names one `<server>.<tool> call` and nests the arguments under rawInput.arguments.
const codexCall = (id: string, tool: string, args: unknown, output?: string): AcpmuxActivity => ({
  kind: "tool",
  text: `codex_apps.${tool} call`,
  tool: {
    // Its own ids: an opened group stays open by id across renders (transcriptDisclosure.tsx).
    id: `codex-${id}`,
    title: `codex_apps.${tool} call`,
    kind: "execute",
    status: "completed",
    inputSummary: JSON.stringify({ server: "codex_apps", tool, arguments: args }),
    output,
  },
});

/// The read's output as an MCP result: a text block holding the thread as escaped JSON, its
/// preview starting with the host's ambient context.
const readOutput = JSON.stringify({
  content: [
    {
      type: "text",
      text: JSON.stringify({
        schemaVersion: 1,
        thread: { id: THREAD, kind: "codex", hostId: "local", title: "Coordination hub", preview: `${AMBIENT}ship it` },
      }),
    },
  ],
});

const row = (items: AcpmuxActivity[]): AcpmuxRow => ({
  id: "activity",
  version: 1,
  at: 1,
  kind: "activity",
  items,
});

async function render(items: AcpmuxActivity[], reveal?: FindRevealTarget) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  const { FindReveal } = await import("../src/agent-session/acpmux/conversation/chatFind");
  // Each mount starts from no reader choices: a call's open state is kept by its id past an unmount
  // (transcriptDisclosureModel.ts useRowDisclosure), and these fixtures reuse their call ids.
  const { resetTranscriptDisclosure } =
    await import("../src/agent-session/acpmux/conversation/transcriptDisclosureModel");
  resetTranscriptDisclosure();
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <FindReveal.Provider value={reveal}>
        <ToolRows row={row(items)} />
      </FindReveal.Provider>,
    ),
  );
}

const labels = () => [...host.querySelectorAll(".cv-tool__text")].map((node) => node.textContent?.trim());
const toggles = () => [...host.querySelectorAll<HTMLButtonElement>("button.cv-tool")];
const click = async (button: HTMLButtonElement) =>
  act(async () => {
    button.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  });

const largeSend = (count: number, tag = false): AcpmuxActivity => ({
  kind: "tool",
  text: "mcp__cmux__acpmux_send",
  tool: {
    id: `large-send-${count}-${tag}`,
    title: "mcp__cmux__acpmux_send",
    kind: "other",
    status: "completed",
    inputSummary: JSON.stringify(
      tag
        ? { tag: "area=docs", text: "hello" }
        : {
            messages: Array.from({ length: count }, (_, index) => ({
              to: `recipient-${index}`,
              text: `body-${index}`,
            })),
          },
    ),
    output: JSON.stringify({
      results: Array.from({ length: count }, (_, index) => ({
        index: tag ? 0 : index,
        to: `recipient-${index}`,
        ok: true,
      })),
    }),
  },
});

for (const [count, tag] of [
  [1024, false],
  [1025, true],
] as const) {
  test(`${count} MCP send recipients are all reachable with at most 32 mounted rows`, async () => {
    await render([largeSend(count, tag)]);
    // The group of sends starts closed, one line counting every recipient.
    expect(host.querySelectorAll(".cv-sent-msg")).toHaveLength(0);
    expect(host.querySelector(".cv-message-group__count")?.textContent).toContain(String(count));
    await click(host.querySelector<HTMLButtonElement>(".cv-sent-group__head")!);
    const seen: string[] = [];
    let pages = 0;
    for (;;) {
      const recipients = [...host.querySelectorAll(".cv-sent-msg .cv-recipient")].map((node) => node.textContent);
      expect(recipients.length).toBeGreaterThan(0);
      expect(recipients.length).toBeLessThanOrEqual(32);
      seen.push(...(recipients as string[]));
      pages += 1;
      const next = host.querySelector<HTMLButtonElement>('[data-send-page="next"]');
      expect(next).not.toBeNull();
      if (next!.disabled) break;
      await click(next!);
      expect(pages).toBeLessThanOrEqual(Math.ceil(count / 32));
    }
    expect(seen).toEqual(Array.from({ length: count }, (_, index) => `recipient-${index}`));
    expect(pages).toBe(Math.ceil(count / 32));
    await click(host.querySelector<HTMLButtonElement>('[data-send-page="previous"]')!);
    expect(host.querySelector(".cv-sent-msg .cv-recipient")?.textContent).toBe(`recipient-${(pages - 2) * 32}`);
  });
}

test("Find reaches an off-page recipient and opens only its full Raw call", async () => {
  const item = largeSend(1024, true);
  item.tool!.output = item.tool!.output!.replaceAll("recipient-1023", "Recİpient-1023");
  await render([item], {
    rowId: "activity",
    card: false,
    needle: "recipient-1023",
    repaint: () => {},
  });
  // Find mounts the row that holds its match, wherever its page is.
  expect([...host.querySelectorAll(".cv-sent-msg .cv-recipient")].map((node) => node.textContent)).toEqual([
    "Recİpient-1023",
  ]);
  // Only the match's row opens its Raw: the whole call, where the off-page recipient is.
  expect(host.querySelectorAll(".cv-sent__raw-body")).toHaveLength(1);
  expect(host.querySelector(".cv-sent__raw-body")?.textContent).toContain("Recİpient-1023");
});

test("Find reaches every matching call of a paged group, not only the first", async () => {
  const calls = Array.from({ length: 40 }, (_, index): AcpmuxActivity => ({
    kind: "tool",
    text: "mcp__cmux__acpmux_send",
    tool: {
      id: `send-${index}`,
      title: "mcp__cmux__acpmux_send",
      kind: "other",
      status: "completed",
      inputSummary: JSON.stringify({ messages: [{ to: `lane-${index}`, text: `needle ${index}` }] }),
      output: JSON.stringify({ results: [{ index: 0, to: `lane-${index}`, ok: true }] }),
    },
  }));
  await render(calls);
  await click(host.querySelector<HTMLButtonElement>(".cv-sent-group__head")!);
  expect(host.querySelectorAll(".cv-sent-msg")).toHaveLength(32);
  await render(calls, { rowId: "activity", card: false, needle: "needle", repaint: () => {} });
  // All 40 calls hold the match: each draws, past the first page, so Next reaches each one.
  expect([...host.querySelectorAll(".cv-sent-msg .cv-recipient")].map((node) => node.textContent)).toEqual(
    calls.map((_, index) => `lane-${index}`),
  );
  expect(host.querySelector('[data-send-page="next"]')).toBeNull();
});

for (const [harness, call] of [
  ["Claude", claudeCall],
  ["Codex", codexCall],
] as const) {
  test(`${harness}: a run of MCP sends is one line naming the chat, closed by default`, async () => {
    await render([
      call("s1", "send_message", { threadId: THREAD, message: "one" }, "{}"),
      call("s2", "send_message", { threadId: THREAD, message: "two" }, "{}"),
      call("s3", "send_message", { threadId: THREAD, message: "three" }, "{}"),
      call("s4", "send_message", { threadId: THREAD, message: "four" }, "{}"),
      call("r1", "read_thread", { threadId: THREAD }, readOutput),
    ]);
    expect(labels()).toEqual(["Sent 4 messages to Coordination hub", "Read Coordination hub"]);
    // Nothing of the calls' JSON shows until a row is opened.
    expect(host.textContent).not.toContain("threadId");
    expect(host.textContent).not.toContain("schemaVersion");
  });

  test(`${harness}: an opened MCP call shows its arguments as fields and its response pretty-printed, without internal context`, async () => {
    await render([call("r1", "read_thread", { threadId: THREAD }, readOutput)]);
    await click(toggles()[0]!);
    // One labeled field per argument (ToolDetail.tsx; Leo, 2026-11-05), never one JSON block.
    const fields = [...host.querySelectorAll(".cv-tool-detail__field")].map((node) => [
      node.querySelector(".cv-tool-detail__key")?.textContent,
      node.querySelector(".cv-tool-detail__value")?.textContent,
    ]);
    expect(fields).toEqual([["threadId", THREAD]]);
    const blocks = [...host.querySelectorAll(".cv-mcp-call__body, .cv-tool-output")].map(
      (node) => node.textContent ?? "",
    );
    expect(blocks).toHaveLength(1);
    // The text block's JSON string is parsed, not shown escaped.
    expect(blocks[0]).toContain('"schemaVersion": 1');
    expect(blocks[0]).toContain('"title": "Coordination hub"');
    expect(blocks[0]).toContain('"preview": "ship it"');
    expect(blocks[0]).not.toContain('\\"');
    expect(host.textContent).not.toContain("in-app-browser-context");
    expect(host.textContent).not.toContain("ambient UI state");
  });

  for (const reason of ["Read the file before changing it.", ""]) {
    test(`${harness}: an opened hook-blocked MCP call shows its reason without the envelope (${reason || "no reason"})`, async () => {
      const item = call(
        "blocked",
        "read_thread",
        { threadId: THREAD },
        `PreToolUse:read_thread hook error: [guard.sh]: Blocked: ${reason}`,
      );
      item.tool!.status = "failed";
      await render([item]);
      expect(host.textContent).toContain("blocked by hook");
      expect(host.textContent).not.toContain("PreToolUse");
      if (reason) expect(host.textContent).not.toContain(reason);
      await click(toggles()[0]!);
      const details = host.querySelector(".cv-mcp-call")!;
      expect(details.textContent).toContain("blocked by hook");
      expect(details.textContent).toContain(THREAD);
      expect(details.textContent).not.toContain("PreToolUse");
      expect(details.textContent).not.toContain("guard.sh");
      expect(details.textContent).not.toContain("Blocked:");
      if (reason) expect(details.textContent).toContain(reason);
      else expect(details.querySelector(".cv-tool-output")).toBeNull();
      const { activityText } = await import("../src/agent-session/acpmux/conversation/chatFind");
      expect(activityText(item)).not.toContain("PreToolUse");
      expect(activityText(item)).not.toContain("guard.sh");
      if (reason) expect(activityText(item)).toContain(reason);
    });
  }

  test(`${harness}: a successful MCP response quoting a hook block stays intact`, async () => {
    const output = "PreToolUse:read_thread hook error: Blocked: example from documentation";
    await render([call("quoted", "read_thread", { threadId: THREAD }, output)]);
    await click(toggles()[0]!);
    expect(host.querySelector(".cv-tool-detail")!.textContent).toContain(output);
    expect(host.textContent).not.toContain("blocked by hook");
  });

  test(`${harness}: a Markdown MCP result shares full-read expansion, Raw, and Find formatting`, async () => {
    const { activityText } = await import("../src/agent-session/acpmux/conversation/chatFind");
    const text = `${"## Sample section\n\nRead every line.\n\n".repeat(15)}The **service** is healthy.`;
    const item = call(
      "markdown",
      "web_read",
      { url: "https://example.test/guide" },
      JSON.stringify({ content: [{ type: "text", text: `\x1b[32m${text}\x1b[0m` }] }),
    );
    await render([item]);
    await click(toggles()[0]!);
    expect(host.querySelector(".cv-tool-output__markdown h2")?.textContent).toBe("Sample section");
    expect([...host.querySelectorAll("button")].some((node) => node.textContent === "Show all 61 lines")).toBe(true);
    expect([...host.querySelectorAll("button")].some((node) => node.textContent?.trim() === "Raw")).toBe(true);
    expect(activityText(item)).toContain("The service is healthy.");
    const { menuPartAt } = await import("../src/agent-session/acpmux/conversation/menuParts");
    expect(menuPartAt(host.querySelector(".cv-tool-output-card"))?.output).toBe(text);
  });

  test(`${harness}: a send group opens to one row per call, each opening to its own request`, async () => {
    await render([
      call("s1", "send_message", { threadId: THREAD, message: "one" }, "{}"),
      call("s2", "send_message", { threadId: THREAD, message: "two" }, "{}"),
    ]);
    // No title for the thread anywhere in the run: the row says what it did without the id.
    expect(labels()).toEqual(["Sent 2 messages"]);
    await click(toggles()[0]!);
    expect(labels()).toEqual(["Sent 2 messages", "Sent a message", "Sent a message"]);
    await click(toggles()[2]!);
    const values = [...host.querySelectorAll(".cv-tool-detail__value")].map((node) => node.textContent ?? "");
    expect(values).toEqual([THREAD, "two"]);
    expect(host.textContent).not.toContain("one");
  });
}

test("a non-MCP call's output also drops injected internal context", async () => {
  await render([
    {
      kind: "tool",
      text: "Fetch",
      tool: { id: "f1", title: "Fetch docs", kind: "fetch", status: "completed", output: `${AMBIENT}page text` },
    },
  ]);
  await click(toggles()[0]!);
  expect(host.querySelector(".cv-tool-output__markdown")?.textContent).toBe("page text");
});

test("output that only names an internal tag keeps the text after it", async () => {
  const source = 'const tag = "<system-reminder>";\nconst next = 1;';
  await render([
    {
      kind: "tool",
      text: "Read",
      tool: { id: "f2", title: "Read tags.ts", kind: "read", status: "completed", output: source },
    },
  ]);
  await click(toggles()[0]!);
  expect(host.querySelector(".cv-tool-output")?.textContent).toBe(source);
});

test("a settled run of Codex MCP calls folds as tools used, not commands run", async () => {
  const { toolRunSummary } = await import("../src/agent-session/acpmux/conversation/toolRunSummary");
  const en = (key: string) => ({ "toolRun.used.other": "used tools", "toolRun.ran.other": "ran commands" })[key] ?? key;
  const items = [
    codexCall("s1", "send_message", { threadId: THREAD, message: "one" }, "{}"),
    codexCall("r1", "read_thread", { threadId: THREAD }, readOutput),
  ];
  expect(toolRunSummary(en as never, items)).toBe("Used tools");
});

test("Find reads an MCP call as it draws: its argument fields and pretty response, without internal context", async () => {
  const { activityText } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const read = codexCall("r1", "read_thread", { threadId: THREAD }, readOutput);
  const text = activityText(read);
  // The fields draw their values; their keys are labels Find skips (ToolDetail.tsx).
  expect(text.split("\n")[0]).toBe(THREAD);
  expect(text).not.toContain("threadId");
  expect(text).toContain('"preview": "ship it"');
  expect(text).not.toContain("ambient UI state");
  expect(text).not.toContain("codex_apps.read_thread call");
  const fetch: AcpmuxActivity = {
    kind: "tool",
    text: "Fetch",
    tool: { id: "f1", title: "Fetch docs", kind: "fetch", status: "completed", output: `${AMBIENT}page text` },
  };
  expect(activityText(fetch)).not.toContain("ambient UI state");
});

test("a context block in the middle of output is the output's own text and stays", async () => {
  const { cleanText } = await import("../src/agent-session/acpmux/conversation/mcpCalls");
  const middle = `# Template\n${AMBIENT}more`;
  expect(cleanText(middle)).toBe(middle);
  expect(cleanText(`${AMBIENT}body\n${AMBIENT}`)).toBe("body\n");
  expect(cleanText(`${middle}\n${AMBIENT}`)).toBe(`${middle}\n`);
});

test("only id-named arguments resolve to titles, and a message names its recipient, not its subject", async () => {
  const { mcpTarget } = await import("../src/agent-session/acpmux/conversation/mcpCalls");
  const names = new Map([["x1", "Coordination hub"]]);
  expect(mcpTarget({ server: "s", tool: "list_items", args: { valid: "x1" } }, names)).toBeUndefined();
  expect(mcpTarget({ server: "s", tool: "read_thread", args: { thread_id: "x1" } }, names)).toBe("Coordination hub");
  expect(mcpTarget({ server: "s", tool: "send_email", args: { subject: "Re: lunch", to: "Sam" } }, names)).toBe("Sam");
  expect(mcpTarget({ server: "s", tool: "send_email", args: { subject: "Re: lunch" } }, names)).toBeUndefined();
});

test("a hook-blocked cmux_exec call uses the same clean MCP details", async () => {
  const item = claudeCall(
    "blocked-exec",
    "cmux_exec",
    { code: "return 1;" },
    "PreToolUse:cmux_exec hook error: Blocked: Run the checks first.",
  );
  item.tool!.title = "mcp__cmux__cmux_exec";
  item.tool!.status = "failed";
  await render([item]);
  await click(toggles()[0]!);
  expect(host.querySelector(".cv-mcp-call")!.textContent).toContain("blocked by hook");
  expect(host.textContent).toContain("Run the checks first.");
  expect(host.textContent).not.toContain("PreToolUse");
  const { activityText } = await import("../src/agent-session/acpmux/conversation/chatFind");
  expect(activityText(item)).toContain("Run the checks first.");
  expect(activityText(item)).not.toContain("PreToolUse");
});
// Leo, 2026-10-31: "I FUCKING HATE THESE SPINNERS FOR TOOL CALLS AND SHIT" (#32196): the group and its
// rows keep their glyphs while they run.
test("three running MCP calls show no spinner, header or rows", async () => {
  const items = [1, 2, 3].map((n) => {
    const item = claudeCall(`spinner-mcp-${n}`, "read_thread", { threadId: THREAD });
    return { ...item, tool: { ...item.tool!, status: "in_progress" } };
  });
  await render(items);
  expect(toggles()).toHaveLength(1);
  await click(toggles()[0]!);
  expect(host.querySelectorAll(".cv-tool-group button.cv-tool")).toHaveLength(3);
  expect(host.querySelectorAll(".cv-spinner")).toHaveLength(0);
  await render([items[0]!]);
  expect(host.querySelectorAll(".cv-spinner")).toHaveLength(0);
});
