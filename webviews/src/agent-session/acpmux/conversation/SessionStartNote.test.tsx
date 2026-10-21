// l10n-allow-file: test fixture versions, models and paths, not shipped UI.
// A Claude Code chat's session start note says what the chat runs on, then how it compacts, and
// the compaction words follow the chat's harness: sr2's (`claude-sr2`) is managed (compacts by
// about 400k tokens, moves accounts between turns); any other harness compacts the way Claude
// Code does, and the note says cmux's managed compaction is off. Dismissing it keeps it away.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import type { AcpmuxSessionStart } from "../model";
import { SessionStartNote } from "./SessionStartNote";
import { compactionModeOf, routeOf } from "./sessionStart";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(container: HTMLElement, start: AcpmuxSessionStart) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<SessionStartNote start={start} />);
  });
}

const start = (harness: string): AcpmuxSessionStart => ({
  agent: "claude",
  version: "2.1.303",
  model: "claude-opus-5-5",
  harness,
  cwd: "/Users/dev/fun/cmux",
});

test("the compaction mode and route follow the chat's harness", () => {
  expect(compactionModeOf("claude-sr2")).toBe("managed");
  for (const harness of ["claude", "claude-cr", "codex", undefined]) expect(compactionModeOf(harness)).toBe("stock");
  expect([routeOf("claude-sr2"), routeOf("claude-cr"), routeOf("claude"), routeOf(undefined)]).toEqual([
    "sr2",
    "coderouter",
    "own",
    "own",
  ]);
});

test("an sr2 chat says what it runs on and that cmux manages its compaction", async () => {
  const container = installDom();
  await render(container, start("claude-sr2"));
  const facts = container.querySelector(".cv-session-start .cv-tool__text")!.textContent;
  expect(facts).toBe(
    [
      translate("sessionStart.claudeCode", { version: "2.1.303" }),
      "claude-opus-5-5",
      translate("sessionStart.route.sr2"),
      "~/fun/cmux",
    ].join(" · "),
  );
  const note = container.querySelector(".cv-session-start__compaction")!;
  expect(note.getAttribute("data-compaction")).toBe("managed");
  expect(note.textContent).toBe(translate("sessionStart.compaction.managed"));
});

test("a chat on its own Claude Code setup says managed compaction is off", async () => {
  const container = installDom();
  await render(container, start("claude"));
  expect(container.querySelector(".cv-session-start .cv-tool__text")!.textContent).toContain(
    translate("sessionStart.route.own"),
  );
  const note = container.querySelector(".cv-session-start__compaction")!;
  expect(note.getAttribute("data-compaction")).toBe("stock");
  expect(note.textContent).toBe(translate("sessionStart.compaction.stock"));
  expect(note.textContent).not.toBe(translate("sessionStart.compaction.managed"));
});

test("a dismissed compaction note stays away, the facts line stays", async () => {
  const container = installDom();
  await render(container, start("claude-sr2"));
  const dismiss = container.querySelector<HTMLButtonElement>(".cv-session-start__dismiss")!;
  expect(dismiss.getAttribute("aria-label")).toBe(translate("sessionStart.compaction.dismiss"));
  await act(async () => dismiss.click());
  expect(container.querySelector(".cv-session-start__compaction")).toBeNull();
  expect(container.querySelector(".cv-session-start")).not.toBeNull();

  // Another sr2 chat (a new mount, same profile): still dismissed. A stock chat's note is its own.
  await act(async () => root!.unmount());
  root = undefined;
  await render(container, start("claude-sr2"));
  expect(container.querySelector(".cv-session-start__compaction")).toBeNull();
  await act(async () => root!.unmount());
  root = undefined;
  await render(container, start("claude"));
  expect(container.querySelector(".cv-session-start__compaction")).not.toBeNull();
});
