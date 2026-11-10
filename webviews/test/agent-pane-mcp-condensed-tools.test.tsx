// l10n-allow-file: test fixtures (tool names, descriptions and summaries), not shipped UI.
// acpmux's condensed MCP tools (`pr_state`, `bg_start`, `run_wait`) take an optional `description`
// argument, what the call is for in a few words, and return a one-line outcome first (also
// `structuredContent.summary`, with `status` ok, failed or running). The transcript reads them as
// Claude Code desktop reads described calls (Leo, 2026-11-03: "claude code desktop's summarization
// of tool calls/parsing of them seem kinda good? we should bea bel to do that AND have condensed
// tools that are callable in acpmux/cmux-next"): each described call is its own row titled with its
// description, its outcome muted after it, and a failed status in the failure red. A call without a
// description reads as before.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { mcpCall, mcpDescription, mcpOutcome } from "../src/agent-session/acpmux/conversation/mcpCalls";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { toolLabel } from "../src/agent-session/acpmux/toolPaths";
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

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const t = translatorFor("en");
const ran = (command: string) => t("tools.ranCommand", { command });

const envelope = (summary: string, status: string, facts: Record<string, unknown> = {}) =>
  JSON.stringify({
    content: [{ type: "text", text: `${summary}\n${JSON.stringify(facts)}` }],
    structuredContent: { summary, status, ...facts },
    isError: false,
  });

const claude = (id: string, tool: string, args: unknown, output?: string): AcpmuxActivity => ({
  kind: "tool",
  text: `mcp__acpmux__${tool}`,
  tool: {
    id,
    title: `mcp__acpmux__${tool}`,
    kind: "other",
    status: "completed",
    inputSummary: JSON.stringify(args),
    output,
  },
});

const codex = (id: string, tool: string, args: unknown, output?: string): AcpmuxActivity => ({
  kind: "tool",
  text: `acpmux.${tool} call`,
  tool: {
    id: `codex-${id}`,
    title: `acpmux.${tool} call`,
    kind: "execute",
    status: "completed",
    inputSummary: JSON.stringify({ server: "acpmux", tool, arguments: args }),
    output,
  },
});

const row = (items: AcpmuxActivity[]): AcpmuxRow => ({ id: "activity", version: 1, at: 1, kind: "activity", items });

async function render(items: AcpmuxActivity[]) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(<ToolRows row={row(items)} />));
}

const texts = () => [...host.querySelectorAll(".cv-tool__text")];

for (const [harness, call] of [
  ["Claude", claude],
  ["Codex", codex],
] as const) {
  test(`${harness}: a described call is titled with its description, its summary muted after it`, async () => {
    await render([
      call(
        "p1",
        "pr_state",
        { repo: "manaflow-ai/cmux", pr: 33316, description: "Check the pr_state PR" },
        envelope("#33316 merged at 4c1e9a0", "ok"),
      ),
    ]);
    const [text] = texts();
    expect(text?.textContent).toStartWith("Check the pr_state PR");
    expect(text?.querySelector(".cv-tool__detail")?.textContent?.trim()).toBe("#33316 merged at 4c1e9a0");
    expect(text?.querySelector(".cv-tool__failed")).toBeNull();
  });

  test(`${harness}: a condensed tool's failed status shows the Failed mark`, async () => {
    await render([
      call(
        "w1",
        "run_wait",
        { run: 19123456789, description: "Wait for the webview tests" },
        envelope("web / react-apps-base-check failed: 2 tests", "failed"),
      ),
    ]);
    const [text] = texts();
    expect(text?.textContent).toStartWith("Wait for the webview tests");
    expect(text?.querySelector(".cv-tool__failed")?.textContent?.trim()).toBe(t("tools.failed"));
    expect(text?.querySelector(".cv-tool__detail")?.textContent?.trim()).toBe(
      "web / react-apps-base-check failed: 2 tests",
    );
  });

  test(`${harness}: described calls of one tool are each their own row`, async () => {
    await render([
      call(
        "b1",
        "bg_start",
        { command: "rg a", description: "Find a" },
        envelope("Background command completed", "ok"),
      ),
      call(
        "b2",
        "bg_start",
        { command: "rg b", description: "Find b" },
        envelope("Background command started", "running"),
      ),
    ]);
    const shown = texts().map((node) => node.textContent ?? "");
    expect(shown).toHaveLength(2);
    expect(shown[0]).toStartWith("Find a");
    expect(shown[1]).toStartWith("Find b");
  });

  test(`${harness}: a call without a description reads as before`, async () => {
    await render([
      call("n1", "pr_state", { repo: "manaflow-ai/cmux", pr: 1 }, envelope("#1 open", "ok")),
      call("n2", "pr_state", { repo: "manaflow-ai/cmux", pr: 2 }, envelope("#2 open", "ok")),
    ]);
    // Grouped as one line, as any run of one tool is.
    expect(texts()).toHaveLength(1);
    expect(texts()[0]?.textContent).not.toContain("#1 open");
  });
}

test("the summary falls back to the text result's first line for a described call", () => {
  const described = mcpCall({
    id: "x",
    title: "mcp__acpmux__bg_start",
    kind: "other",
    status: "completed",
    inputSummary: JSON.stringify({ command: "ls", description: "List files" }),
  })!;
  expect(mcpDescription(described)).toBe("List files");
  expect(mcpOutcome("Background command completed\nid: bg-1\n", described)).toEqual({
    summary: "Background command completed",
    failed: false,
  });
  expect(
    mcpOutcome(JSON.stringify({ content: [{ type: "text", text: "Started bg-2\n{}" }] }), described)?.summary,
  ).toBe("Started bg-2");
  // Without a description a text result is not a summary.
  const bare = { ...described, args: { command: "ls" } };
  expect(mcpOutcome("Background command completed", bare)).toBeUndefined();
  // A blank description is none.
  expect(mcpDescription({ ...described, args: { description: "   " } })).toBeUndefined();
});

test("the live line and turn copy name a described MCP call by its description", () => {
  const tool: Tool = {
    id: "l1",
    title: "mcp__acpmux__run_wait",
    kind: "other",
    status: "in_progress",
    inputSummary: JSON.stringify({ run: 1, description: "Wait for the webview tests" }),
  };
  expect(toolLabel(tool, "", ran)).toBe("Wait for the webview tests");
  expect(toolLabel({ ...tool, inputSummary: JSON.stringify({ run: 1 }) }, "", ran)).toBe("Using acpmux: run wait");
});
