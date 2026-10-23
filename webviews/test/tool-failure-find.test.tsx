// l10n-allow-file: test fixtures (tool results in the harnesses' words), not shipped UI.
// Find in Chat counts what a failed command draws (Codex review of #24339): its output without
// Claude Code's leading "Exit code N" line, never the row's red word or the Shell block's own exit
// line, so the count it shows and the matches it paints agree.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { activityText } from "../src/agent-session/acpmux/conversation/chatFind";

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

const command = (id: string, output: string, extra: object = {}): AcpmuxActivity => ({
  kind: "tool",
  text: "Run",
  tool: { id, title: "Run", kind: "execute", status: "failed", command: "false", output, ...extra },
});

/// The opened row's text that Find paints: every text node outside `data-find-skip`. A lone call
/// draws as a ToolRow; one beside another command draws as a CommandRow in their group.
async function paintedText(item: AcpmuxActivity, grouped: boolean): Promise<string> {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  act(() => root?.unmount());
  root = createRoot(host);
  const items = grouped ? [command(`${item.tool!.id}-ok`, "", { status: "completed", command: "true" }), item] : [item];
  await act(async () =>
    root!.render(<ToolRows row={{ id: `row-${item.tool!.id}`, kind: "activity", at: 1, items } as never} />),
  );
  const rows = host.querySelectorAll<HTMLButtonElement>(grouped ? ".cv-command" : ".cv-tool.is-toggle");
  await act(async () => rows[rows.length - 1]!.click());
  expect(host.querySelector(".cv-shell")).not.toBeNull();
  const walker = document.createTreeWalker(host, 4 /* NodeFilter.SHOW_TEXT */);
  let text = "";
  for (let node = walker.nextNode(); node; node = walker.nextNode())
    if (!node.parentElement?.closest("[data-find-skip], [aria-hidden='true']")) text += `${node.textContent}\n`;
  return text;
}

/// Find's text for the row: the first call's too, when grouped.
const indexed = (item: AcpmuxActivity, grouped: boolean) =>
  (grouped ? activityText(command(`${item.tool!.id}-ok`, "", { status: "completed", command: "true" })) : "") +
  activityText(item);

const count = (text: string, query: string) => text.split(query).length - 1;

for (const grouped of [false, true])
  test(`an exit code read from Claude Code's first line is counted once, as drawn (${grouped ? "command row" : "lone call"})`, async () => {
    const item = command(`a${grouped}`, "Exit code 1\nbuild failed");
    const painted = await paintedText(item, grouped);
    expect(host.querySelector(grouped ? ".cv-command__failed" : ".cv-tool__failed")?.textContent?.trim()).toBe(
      "Exit 1",
    );
    expect(host.querySelector(".cv-shell__exit")?.textContent).toBe("Exit code 1");
    for (const query of ["Exit", "1", "build failed"])
      expect([query, count(painted, query)]).toEqual([query, count(indexed(item, grouped), query)]);
    expect(count(indexed(item, grouped), "Exit code")).toBe(0);
  });

for (const grouped of [false, true])
  test(`a failed call that exited 0 draws and counts its output without the exit line (${grouped ? "command row" : "lone call"})`, async () => {
    const item = command(`b${grouped}`, "Exit code 0\nresult transport failed", { exitCode: 0 });
    const painted = await paintedText(item, grouped);
    expect(host.querySelector(".cv-shell__exit")).toBeNull();
    for (const query of ["Exit code 0", "transport failed"])
      expect([query, count(painted, query)]).toEqual([query, count(indexed(item, grouped), query)]);
  });

for (const grouped of [false, true])
  test(`a completed call with a nonzero exit is drawn and counted alike (${grouped ? "command row" : "lone call"})`, async () => {
    const item = command(`c${grouped}`, "Exit code 1\nbuild failed", { status: "completed", exitCode: 1 });
    const painted = await paintedText(item, grouped);
    for (const query of ["Exit code 1", "build failed"])
      expect([query, count(painted, query)]).toEqual([query, count(indexed(item, grouped), query)]);
  });

for (const grouped of [false, true])
  test(`a coloured shell output is counted without its colour codes (${grouped ? "command row" : "lone call"})`, async () => {
    const item = command(`d${grouped}`, "\u001b[31merror\u001b[0m: could not compile", { exitCode: 101 });
    const painted = await paintedText(item, grouped);
    for (const query of ["error: could not compile", "31m"])
      expect([query, count(painted, query)]).toEqual([query, count(indexed(item, grouped), query)]);
  });

for (const grouped of [false, true])
  test(`a shell that ended in the background is drawn and counted alike (${grouped ? "command row" : "lone call"})`, async () => {
    const item = command(`e${grouped}`, "Exit code 1\nport in use", {
      status: "completed",
      exitCode: 1,
      background: { state: "failed", endedAt: 0 },
    });
    const painted = await paintedText(item, grouped);
    for (const query of ["Exit code 1", "port in use"])
      expect([query, count(painted, query)]).toEqual([query, count(indexed(item, grouped), query)]);
  });
