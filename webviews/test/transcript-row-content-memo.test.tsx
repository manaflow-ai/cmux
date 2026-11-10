// l10n-allow-file: test fixture recipients, not shipped UI.
// A row's content (VirtualTranscript `RowContent`) is drawn again only when what it draws from
// changes, so a frame moved by a scroll draws none of it again (Leo, 2026-11-06: "Still seeing the
// flicker re-render"). It must still draw a change its row's version does not cover: the activity
// line under a running turn keeps one version while the send in flight changes recipient
// (turns.ts `sendingTo`), and a stale "Sending to ..." is worse than a redraw.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ACTIVITY_LINE } from "../src/agent-session/acpmux/conversation/turns";
import type { RowProps } from "../src/agent-session/acpmux/rows/rowProps";
import { RowContent } from "../src/agent-session/acpmux/VirtualTranscript";
import { sameRowFrame } from "../src/agent-session/acpmux/virtualTranscriptModel";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
beforeAll(() => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const line = (to: string): AcpmuxRow => ({
  id: `${ACTIVITY_LINE}-u1`,
  version: 42,
  at: 1_000,
  kind: ACTIVITY_LINE,
  text: "Sending message",
  doingSendTo: to,
});

const drawn: string[] = [];
function Recipient({ row }: RowProps) {
  drawn.push(String(row.doingSendTo));
  return <span>{row.doingSendTo}</span>;
}

test("an activity line whose recipient changes under the same version draws the new recipient", async () => {
  const root = createRoot(document.getElementById("root")!);
  const props = { Component: Recipient, onToggleActivity: () => {}, expanded: false };
  await act(async () => root.render(<RowContent {...props} row={line("tests")} />));
  await act(async () => root.render(<RowContent {...props} row={line("reviewer")} />));
  expect(document.body.textContent).toBe("reviewer");
  // The same row object again (a frame moved by a scroll) draws nothing.
  const same = line("reviewer");
  await act(async () => root.render(<RowContent {...props} row={same} />));
  const before = drawn.length;
  await act(async () => root.render(<RowContent {...props} row={same} />));
  expect(drawn.length).toBe(before);
  await act(async () => root.unmount());
});

test("the activity line's frame redraws when its recipient changes under the same version", () => {
  expect(sameRowFrame({ row: line("tests") }, { row: line("reviewer") })).toBe(false);
  expect(sameRowFrame({ row: line("tests") }, { row: line("tests") })).toBe(true);
});
