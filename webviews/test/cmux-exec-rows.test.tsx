// l10n-allow-file: test fixtures (scripts, tool names and workspace titles), not shipped UI.
// cmux_exec rows (Leo, 2026-10-30: "these should be rendered better than just cmux called cmux exec
// we know what these are supposed to be"): three scripts in a row read "Called cmux · cmux exec"
// each, and opened, one showed the raw `mcp__cmux__cmux_exec` line, the script as one escaped JSON
// string and the response as escaped JSON. Now a script's row says what it did, from its result's
// `call_log` once it finished and from the calls in its script while it runs, and opens to the
// script as JavaScript, the calls it made and its result as a key/value tree, the raw call behind
// "Raw".
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import { cmuxTitle, execParts, execView, scriptCalls } from "../src/agent-session/acpmux/conversation/cmuxExec";
import { mcpCall } from "../src/agent-session/acpmux/conversation/mcpCalls";
import { jsTokens } from "../src/agent-session/acpmux/conversation/jsHighlight";
import { treeText, valueTree } from "../src/agent-session/acpmux/conversation/valueTree";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const t = translatorFor("en");

let ids = 0;
/// A Claude Code `cmux_exec` call: its script as the argument, the MCP result as its output.
function exec(
  script: string,
  answer?: unknown,
  status = answer === undefined ? "in_progress" : "completed",
): AcpmuxActivity {
  const output =
    answer === undefined
      ? undefined
      : typeof answer === "string"
        ? answer
        : JSON.stringify({
            content: [{ type: "text", text: JSON.stringify(answer) }],
            structuredContent: answer,
            isError: false,
          });
  const tool: Tool = {
    id: `exec-${(ids += 1)}`,
    title: "mcp__cmux__cmux_exec",
    kind: "other",
    status,
    inputSummary: JSON.stringify({ script }),
    ...(output !== undefined && { output }),
  };
  return { kind: "tool", text: tool.title, tool };
}

/// A Codex call to one of the cmux server's tools.
function codexCmux(tool: string, args: unknown, output = "{}"): AcpmuxActivity {
  const call: Tool = {
    id: `codex-${(ids += 1)}`,
    title: `cmux.${tool} call`,
    kind: "execute",
    status: "completed",
    inputSummary: JSON.stringify({ server: "cmux", tool, arguments: args }),
    output,
  };
  return { kind: "tool", text: call.title, tool: call };
}

const titleOf = (item: AcpmuxActivity) => {
  const call = mcpCall(item.tool!)!;
  return cmuxTitle(t, [call], [item.tool!]);
};

const LIST_SCRIPT = 'const d = await cmux.call("workspace_list", {});\nreturn d.items.map((w) => w.title);';
const OPEN_SCRIPT = [
  "const { items } = await cmux.workspace_list({});",
  'const leads = items.find((w) => w.title === "Leads");',
  "for (const session of sessions) {",
  '  await cmux.call("app_agent_open_tab", { session, workspace: leads.id });',
  "}",
  "return { opened: sessions.length };",
].join("\n");
const DOCS_SCRIPT = 'return await cmux.docs("browser tab");';
const log = (name: string, n: number, ok = true) => Array.from({ length: n }, () => ({ name, ok }));

test("a finished script's title says what its call_log did", () => {
  expect(
    titleOf(exec(LIST_SCRIPT, { calls: 1, call_log: log("workspace_list", 1), logs: [], result: ["Leads"] })),
  ).toBe("Listed workspaces");
  // A change outranks the lookup that found its workspace; twelve calls are counted, and the
  // workspace is named by the title the script looked it up by.
  const opened = exec(OPEN_SCRIPT, {
    calls: 13,
    call_log: [...log("workspace_list", 1), ...log("app_agent_open_tab", 12)],
    logs: [],
    result: { opened: 12 },
  });
  expect(titleOf(opened)).toBe("Opened 12 agent sessions in Leads");
  // docs searches are not calls (code_mode.rs records none): the script's own search names it.
  expect(titleOf(exec(DOCS_SCRIPT, { calls: 0, call_log: [], logs: [], result: { tools: [] } }))).toBe(
    "Searched cmux tools for browser tab",
  );
});

test("a running script's title comes from the calls in its source", () => {
  expect(scriptCalls(OPEN_SCRIPT)).toEqual(["workspace_list", "app_agent_open_tab"]);
  expect(titleOf(exec(LIST_SCRIPT))).toBe("Listing workspaces");
  expect(titleOf(exec(OPEN_SCRIPT))).toBe("Opening an agent session in Leads");
  expect(titleOf(exec(DOCS_SCRIPT))).toBe("Searching cmux tools for browser tab");
  expect(titleOf(exec("return 1 + 1;"))).toBe("Running cmux script");
  expect(titleOf(exec('await cmux.call("layout_apply_magic", {});'))).toBe("Running cmux script: layout apply magic");
});

test("calls the table has no words for fall back to the script line, naming the first call", () => {
  const answer = { calls: 3, call_log: [...log("layout_apply_magic", 2), ...log("sidebar_shuffle", 1)], logs: [] };
  expect(titleOf(exec("await cmux.layout_apply_magic({});", answer))).toBe(
    "Ran cmux script (3 calls): layout apply magic",
  );
  // A generic `<noun>_<verb>` name reads in the MCP rows' words.
  expect(titleOf(exec("x", { calls: 1, call_log: log("workspace_get", 1), logs: [] }))).toBe("Read workspace");
  // Other steps of the main step's kind are counted after it.
  const both = { calls: 3, call_log: [...log("tab_close", 2), ...log("workspace_create", 1)], logs: [] };
  expect(titleOf(exec("x", both))).toBe("Closed 2 tabs and 1 more step");
});

test("a cut call log never gives a count: the title says the script's total calls", () => {
  // The server keeps the first 200 calls of a script that made more (`call_log_truncated`).
  const cut = { calls: 250, call_log: log("tab_close", 200), call_log_truncated: true, logs: [] };
  expect(titleOf(exec("x", cut))).toBe("Ran cmux script (250 calls): tab close");
  // A log shorter than the count it reports is cut too, even without the flag.
  const short = { calls: 250, call_log: log("tab_close", 200), logs: [] };
  expect(titleOf(exec("x", short))).toBe("Ran cmux script (250 calls): tab close");
  expect(titleOf(exec("x", { calls: 200, call_log: log("tab_close", 200), logs: [] }))).toBe("Closed 200 tabs");
});

test("a failed call counts only when none of its kind went through", () => {
  const mixed = { calls: 3, call_log: [...log("tab_close", 2), { name: "tab_close", ok: false, state: "not_run" }] };
  expect(titleOf(exec("x", mixed))).toBe("Closed 2 tabs");
  const failed = {
    calls: 1,
    call_log: [{ name: "tab_close", ok: false, state: "not_run" }],
    error: { message: "no tab" },
  };
  expect(titleOf(exec("x", failed, "failed"))).toBe("Closed 1 tab");
});

test("a malformed or missing response still names the script by its calls", () => {
  expect(titleOf(exec(LIST_SCRIPT, "cmux_exec: the server went away"))).toBe("Ran cmux script: workspace list");
  expect(titleOf(exec(LIST_SCRIPT, "{not json"))).toBe("Ran cmux script: workspace list");
  expect(titleOf(exec("return 1;", '{"content":[]}'))).toBe("Ran cmux script");
  expect(execView(exec(LIST_SCRIPT, "{not json").tool!, { script: LIST_SCRIPT }).answer).toBeUndefined();
});

test("the cmux server's own tools called directly say what they did; other servers' keep their row", () => {
  const titles = (items: AcpmuxActivity[]) =>
    cmuxTitle(
      t,
      items.map((item) => mcpCall(item.tool!)!),
      items.map((item) => item.tool!),
    );
  expect(titles([codexCmux("workspace_list", {})])).toBe("Listed workspaces");
  expect(titles([codexCmux("tab_close", { tab: "tab_1" }), codexCmux("tab_close", { tab: "tab_2" })])).toBe(
    "Closed 2 tabs",
  );
  expect(titles([codexCmux("cmux_docs", { query: "split" })])).toBe("Searched cmux tools for split");
  // A folded server's tool (computer use, sub-sessions) is not the cmux server's own.
  expect(titles([codexCmux("cua_click", { x: 1 })])).toBeUndefined();
  expect(titles([codexCmux("subsessions_start_session", {})])).toBeUndefined();
});

test("a direct call's title names its workspace once the run's names resolve it", () => {
  const item = codexCmux("app_agent_open_tab", { session: "s1", workspace: "ws_leads" });
  const call = mcpCall(item.tool!)!;
  // Drawn first before the run's names are known, then again with them: the title is not stuck.
  expect(cmuxTitle(t, [call], [item.tool!], new Map())).toBe("Opened 1 agent session");
  expect(cmuxTitle(t, [call], [item.tool!], new Map([["ws_leads", "Leads"]]))).toBe("Opened 1 agent session in Leads");
  expect(cmuxTitle(t, [call], [item.tool!], new Map())).toBe("Opened 1 agent session");
});

test("an integer a double would round, in any JSON layer, shows the response as it came", () => {
  const answer = (id: string) =>
    `{"calls":1,"call_log":[{"name":"workspace_list","ok":true}],"logs":[],"result":{"id":${id}}}`;
  // Only in the text block: the outer JSON holds it inside a string, so only the inner layer loses it.
  const nested = (id: string) => exec(LIST_SCRIPT, JSON.stringify({ content: [{ type: "text", text: answer(id) }] }));
  const parts = (item: AcpmuxActivity) => {
    const call = mcpCall(item.tool!)!;
    return execParts(execView(item.tool!, call.args), (text) => text);
  };
  const lossy = parts(nested("9007199254740993"));
  expect(lossy.rawResponse).toBe(true);
  expect(lossy.result).toBeUndefined();
  // The title still reads the call_log.
  expect(titleOf(nested("9007199254740993"))).toBe("Listed workspaces");
  // A safe integer still reads as a tree.
  const safe = parts(nested("42"));
  expect(safe.rawResponse).toBe(false);
  expect(treeText(safe.result!)).toBe("id: 42");
});

test("the script's tokens keep every character and color its keywords, strings and calls", () => {
  const tokens = jsTokens(LIST_SCRIPT);
  expect(tokens.map((token) => token.text).join("")).toBe(LIST_SCRIPT);
  expect(tokens.find((token) => token.text === "const")?.role).toBe("keyword");
  expect(tokens.find((token) => token.text === '"workspace_list"')?.role).toBe("string");
  expect(tokens.find((token) => token.text === "call")?.role).toBe("function");
});

test("a result reads as a key/value tree with its text unescaped", () => {
  const value = { workspaces: [{ id: "ws_1", title: "Leads" }], docs: "line one\nline two", count: 2, json: '{"a":1}' };
  expect(treeText(valueTree(value))).toBe(
    [
      "workspaces:",
      "  - id: ws_1",
      "    title: Leads",
      "docs:",
      "  line one",
      "  line two",
      "count: 2",
      "json:",
      "  a: 1",
    ].join("\n"),
  );
});

// The rows as the transcript draws them.
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

const row = (items: AcpmuxActivity[]): AcpmuxRow => ({ id: "activity", version: 1, at: 1, kind: "activity", items });

async function render(items: AcpmuxActivity[]) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(<ToolRows row={row(items)} />));
}

const labels = () => [...host.querySelectorAll(".cv-tool__text")].map((node) => node.textContent?.trim());
const click = async (button: Element) =>
  act(async () => {
    button.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  });

const DOCS_ANSWER = {
  calls: 0,
  call_log: [],
  logs: ["found 2"],
  result: { tools: [{ name: "tab_create_browser", description: "Opens a browser tab.\nTakes url." }] },
};

test("three scripts in a row are three rows, each saying what it did", async () => {
  await render([
    exec(LIST_SCRIPT, { calls: 1, call_log: log("workspace_list", 1), logs: [], result: ["Leads"] }),
    exec(OPEN_SCRIPT, {
      calls: 13,
      call_log: [...log("workspace_list", 1), ...log("app_agent_open_tab", 12)],
      logs: [],
      result: { opened: 12 },
    }),
    exec(DOCS_SCRIPT, DOCS_ANSWER),
  ]);
  expect(labels()).toEqual([
    "Listed workspaces",
    "Opened 12 agent sessions in Leads",
    "Searched cmux tools for browser tab",
  ]);
  expect(host.textContent).not.toContain("cmux exec");
  expect(host.textContent).not.toContain("mcp__cmux__cmux_exec");
});

test("an opened script shows highlighted JavaScript, its calls and a structured result; Raw keeps the call", async () => {
  await render([exec(DOCS_SCRIPT.replace("return", "console.log('x');\nreturn"), DOCS_ANSWER)]);
  await click(host.querySelector("button.cv-tool")!);
  const details = host.querySelector(".cv-cmux-exec")!;
  const code = details.querySelector('pre[data-lang="javascript"]')!;
  // Real line breaks, not a JSON string's `\n`, and colored tokens.
  expect(code.textContent).toContain("console.log('x');\nreturn await cmux.docs(\"browser tab\");");
  expect(code.querySelector('[data-role="keyword"]')?.textContent).toBe("return");
  expect(code.querySelector('[data-role="string"]')).not.toBeNull();
  const tree = details.querySelector("pre[data-tree]")!;
  expect(tree.textContent).toBe(
    [
      "tools:",
      "  - name: tab_create_browser",
      "    description:",
      "      Opens a browser tab.",
      "      Takes url.",
    ].join("\n"),
  );
  expect(tree.querySelector('[data-role="attribute"]')?.textContent).toBe("tools");
  // Find highlights a match across the coloured tokens ("await cmux"): each block is one Find run
  // (chatFind.ts findRuns).
  expect(code.hasAttribute("data-find-join")).toBe(true);
  expect(tree.hasAttribute("data-find-join")).toBe(true);
  expect(tree.textContent).not.toContain("\\n");
  expect(details.textContent).toContain("found 2");
  // The machine name and the call as it came are behind Raw, not in the default view.
  expect(details.textContent).not.toContain("mcp__cmux__cmux_exec");
  const raw = details.querySelector(".cv-cmux-exec__raw button")!;
  expect(raw.textContent).toContain("Raw");
  await click(raw);
  expect(details.querySelector(".cv-mcp-call__name")?.textContent).toBe("mcp__cmux__cmux_exec");
});

test("Find reads an opened script as it draws", async () => {
  const { activityText } = await import("../src/agent-session/acpmux/conversation/chatFind");
  const text = activityText(exec(DOCS_SCRIPT, DOCS_ANSWER));
  expect(text).toContain('return await cmux.docs("browser tab");');
  expect(text).toContain("    description:\n      Opens a browser tab.");
  expect(text).not.toContain("call_log");
});
