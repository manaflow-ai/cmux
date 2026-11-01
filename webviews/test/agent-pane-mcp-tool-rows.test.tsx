// MCP tool calls drew as raw machinery (Leo, 2026-10-19: "make this stuff more snappy"): four
// sends to one chat were four rows titled `mcp__codex_apps__send_message`, and an opened read
// showed one escaped JSON line with the host's injected `<in-app-browser-context>` in it. Now a
// run of the same MCP tool is one line that says what it did to what ("Sent 4 messages to
// Coordination hub", the thread's id resolved to its title from another call's output), a call
// opens to its request and response pretty-printed, nested JSON strings parsed, and internal
// context blocks never reach the transcript.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";

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

async function render(items: AcpmuxActivity[]) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(<ToolRows row={row(items)} />));
}

const labels = () => [...host.querySelectorAll(".cv-tool__text")].map((node) => node.textContent?.trim());
const toggles = () => [...host.querySelectorAll<HTMLButtonElement>("button.cv-tool")];
const click = async (button: HTMLButtonElement) =>
  act(async () => {
    button.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
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

  test(`${harness}: an opened MCP call shows its request and response pretty-printed, without internal context`, async () => {
    await render([call("r1", "read_thread", { threadId: THREAD }, readOutput)]);
    await click(toggles()[0]!);
    const blocks = [...host.querySelectorAll(".cv-mcp-call__body, .cv-tool-output")].map(
      (node) => node.textContent ?? "",
    );
    expect(blocks).toHaveLength(2);
    expect(blocks[0]).toBe(`{\n  "threadId": "${THREAD}"\n}`);
    // The text block's JSON string is parsed, not shown escaped.
    expect(blocks[1]).toContain('"schemaVersion": 1');
    expect(blocks[1]).toContain('"title": "Coordination hub"');
    expect(blocks[1]).toContain('"preview": "ship it"');
    expect(blocks[1]).not.toContain('\\"');
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
    expect(host.querySelector(".cv-mcp-call")!.textContent).toContain(output);
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
    const blocks = [...host.querySelectorAll(".cv-mcp-call__body, .cv-tool-output")].map(
      (node) => node.textContent ?? "",
    );
    expect(blocks[0]).toContain('"message": "two"');
    expect(host.textContent).not.toContain('"message": "one"');
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

test("Find reads an MCP call as it draws: its pretty request and response, without internal context", async () => {
  const { activityText } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const read = codexCall("r1", "read_thread", { threadId: THREAD }, readOutput);
  const text = activityText(read);
  expect(text).toContain(`"threadId": "${THREAD}"`);
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
test("three running MCP calls keep activity only in their group header", async () => {
  const items = [1, 2, 3].map((n) => {
    const item = claudeCall(`spinner-mcp-${n}`, "read_thread", { threadId: THREAD });
    return { ...item, tool: { ...item.tool!, status: "in_progress" } };
  });
  await render(items);
  expect(toggles()).toHaveLength(1);
  await click(toggles()[0]!);
  expect(host.querySelectorAll(".cv-tool-group button.cv-tool")).toHaveLength(3);
  expect(host.querySelectorAll(".cv-tool-group .cv-spinner")).toHaveLength(0);
  expect(host.querySelectorAll(".cv-spinner")).toHaveLength(1);
  await render([items[0]!]);
  expect(host.querySelectorAll(".cv-spinner")).toHaveLength(1);
});
