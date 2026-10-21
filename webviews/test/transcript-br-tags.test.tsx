// Leo 2026-10-21: a prompt pasted with Milkdown's `<br />` blank-line placeholder went out holding
// a literal `<br />` line, and its bubble in the transcript showed it. A sent prompt's bubble, its
// Copy and the transcript row's copy read a line that is only a `<br>` tag as the blank line it
// stood for; a `<br>` inside a line stays as written.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
const copied: string[] = [];

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.defineProperty(window.navigator, "clipboard", {
    configurable: true,
    value: { writeText: async (text: string) => void copied.push(text) },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

// As sent from a composer that pasted Milkdown's markdown: the placeholder between blank lines,
// and a bare `<br>` line.
const SENT = "First paragraph\n\n<br />\n\nSecond, line one\n<br>\nSecond, line two";
const SHOWN = "First paragraph\n\nSecond, line one\n\nSecond, line two";
const row: AcpmuxRow = { id: "user-1", version: 1, at: Date.now(), kind: "user", seq: 1, text: SENT };

test("a sent prompt's bubble never shows a literal <br />: each one is the blank line it stood for", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
  root = createRoot(host);
  await act(async () => root!.render(<UserBubble row={row} text={SENT} />));
  const bubble = host.querySelector(".cv-user__bubble")!;
  expect(bubble.textContent).not.toContain("<br");
  expect(bubble.textContent).toContain("First paragraph");
  expect(bubble.textContent).toContain("Second, line two");

  // The bubble's Copy puts the lines on the clipboard with `\n`.
  const copy = host.querySelector<HTMLButtonElement>('.cv-user__actions button[aria-label="Copy"]')!;
  await act(async () => copy.click());
  expect(copied.at(-1)).toBe(SHOWN);
});

test("the transcript row's copy of a sent prompt is its lines with \\n, no <br", async () => {
  const { transcriptCopyText, transcriptRangeText } = await import(
    "../src/agent-session/acpmux/conversation/transcriptCopy"
  );
  expect(transcriptCopyText(row)).toBe(SHOWN);
  expect(transcriptRangeText([row], [row.id])).not.toContain("<br");
  // A `<br>` inside a line (code in a prompt) is the prompt's own text.
  const code: AcpmuxRow = { ...row, id: "user-2", text: "return <div>a<br />b</div>;" };
  expect(transcriptCopyText(code)).toBe("return <div>a<br />b</div>;");
});
