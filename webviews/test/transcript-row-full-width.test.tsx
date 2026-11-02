// Tool rows and agent message lines use the row's whole width and end in an ellipsis at its right
// edge (Leo, 2026-10-22, of a "Ran cp …" row and message previews cut at about two thirds of the
// width: "shouldnt these also ellipsis later"). A row draws the command's whole first step; only
// CSS cuts it, so no character cap in JS stops it short of the edge.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
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

async function render(items: object[]) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(<ToolRows row={{ id: "activity-1", kind: "activity", at: 1, settled: false, items } as never} />),
  );
}

// Far past the old 60-character cap.
const CP =
  "cp /private/tmp/claude-501/-Users-leoli-Projects/scratch/transcript-parity/ellipsis/before.png /Users/leoli/Projects/cmux-tp-ellipsis.noindex/docs/media/after.png";
const shell = (id: string, command: string, extra: object = {}) => ({
  kind: "tool",
  text: "Run",
  tool: { id, title: "Run", kind: "execute", status: "completed", command, output: "", ...extra },
});

test("a lone shell row draws the whole command; CSS, not a character cap, cuts it", async () => {
  await render([shell("t1", CP)]);
  const text = host.querySelector(".cv-tool__text")?.textContent ?? "";
  expect(text).toBe(`Ran ${CP}`);
  expect(text.includes("…")).toBe(false);
});

test("a group's command rows draw the whole command, without the setup before it", async () => {
  await render([shell("t1", `cd ~/wt/x && ${CP}`), shell("t2", CP)]);
  const lines = [...host.querySelectorAll(".cv-command__line")].map((line) => line.textContent);
  expect(lines).toEqual([CP, CP]);
});

test("a row still marks the steps it leaves out", async () => {
  await render([shell("t1", `${CP} && ls`), shell("t2", "ls")]);
  expect(host.querySelector(".cv-command__line")?.textContent).toBe(`${CP} …`);
});

test("toolLabel never cuts a command by length", async () => {
  const { toolLabel } = await import("../src/agent-session/acpmux/toolPaths");
  const label = toolLabel(
    { id: "t", title: "Run", kind: "execute", status: "completed", command: CP } as never,
    "",
    (c) => c,
  );
  expect(label).toBe(CP);
});

test("a one-line note with no room keeps the cap", async () => {
  const { shortCommand } = await import("../src/agent-session/acpmux/conversation/shortCommand");
  expect(shortCommand(CP).length).toBeLessThanOrEqual(60);
});

// Labels can use the row's available space and truncate without an artificial width cap.
// Short labels stay content-sized so the caret follows them; the message button still fills
// the remaining line so clicking blank space continues to expand the message.
const css = (file: string) => readFileSync(new URL(file, import.meta.url), "utf8");
const CONVERSATION = css("../src/agent-session/acpmux/conversation/conversation.css");
const MESSAGE = css("../src/agent-session/acpmux/conversation/AgentMessageRow.css");

function rule(sheet: string, selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = new RegExp(`(?:^|\\n)${escaped}\\s*\\{([^}]*)\\}`).exec(sheet);
  if (!match) throw new Error(`no rule for ${selector}`);
  return match[1]!;
}

for (const [sheet, selector, fills] of [
  [CONVERSATION, ".cv-command__text", false],
  [CONVERSATION, ".cv-tool__text", false],
  [MESSAGE, ".cv-agentmsg__toggle", true],
  [MESSAGE, ".cv-agentmsg__preview", false],
] as const) {
  test(`${selector} ends at the row's right edge in an ellipsis`, () => {
    const body = rule(sheet, selector);
    expect(body).toMatch(/min-width:\s*0/);
    expect(body).not.toMatch(/max-width|\dch\b/);
    if (fills) expect(body).toMatch(/flex:\s*1\b/);
    if (selector !== ".cv-agentmsg__toggle") expect(body).toMatch(/text-overflow:\s*ellipsis/);
  });
}
