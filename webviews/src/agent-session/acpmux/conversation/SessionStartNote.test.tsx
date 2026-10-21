// l10n-allow-file: test fixture versions, models and paths, not shipped UI.
// A Claude Code chat's session start note says what the chat runs on in one short line ("Claude
// Code · Opus 5.5 · sr2", the whole of it on hover and a click), then how it compacts in one line
// that opens to its explanation (Leo 2026-10-20: the long facts line and the compaction paragraph
// were a mishmash at the turn's end). The compaction words follow the chat's harness: sr2's
// (`claude-sr2`) is managed; any other harness compacts the way Claude Code does. Dismissing the
// note keeps it away.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import type { AcpmuxSessionStart } from "../model";
import { SessionStartNote } from "./SessionStartNote";
import { compactionModeOf, routeOf } from "./sessionStart";
import { resetTranscriptDisclosure } from "./transcriptDisclosure";

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
    "CSS",
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
    CSS: { escape: (value: string) => value.replace(/[^\w-]/g, (char) => `\\${char}`) },
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

const facts = (container: HTMLElement) => container.querySelector(".cv-session-start .cv-tool__text")!.textContent;
const compactionLine = (container: HTMLElement) =>
  container.querySelector(".cv-session-start__compaction .cv-session-start__compaction-text")!.textContent;

test("an sr2 chat says what it runs on in one short line, the whole of it on hover and on a click", async () => {
  const container = installDom();
  resetTranscriptDisclosure();
  await render(container, start("claude-sr2"));
  expect(facts(container)).toBe(
    [translate("sessionStart.agent"), "Opus 5.5", translate("sessionStart.routeShort.sr2")].join(" · "),
  );
  const whole = [
    translate("sessionStart.claudeCode", { version: "2.1.303" }),
    "claude-opus-5-5",
    translate("sessionStart.route.sr2"),
    "~/fun/cmux",
  ].join(" · ");
  const line = container.querySelector<HTMLButtonElement>(".cv-session-start")!;
  expect(line.getAttribute("title")).toBe(whole);
  // The version and the folder are not on the line itself.
  expect(facts(container)).not.toContain("2.1.303");
  expect(facts(container)).not.toContain("~/fun/cmux");
  expect(container.querySelector(".cv-session-start__detail")).toBeNull();
  await act(async () => line.click());
  expect(line.getAttribute("aria-expanded")).toBe("true");
  expect(container.querySelector(".cv-session-start__detail")!.textContent).toBe(whole);
});

test("the compaction note is one line that opens to its explanation", async () => {
  const container = installDom();
  resetTranscriptDisclosure();
  await render(container, start("claude-sr2"));
  const note = container.querySelector(".cv-session-start__compaction")!;
  expect(note.getAttribute("data-compaction")).toBe("managed");
  expect(note.classList.contains("cv-tool")).toBe(true);
  expect(compactionLine(container)).toBe(translate("sessionStart.compaction.managedShort"));
  // The paragraph waits behind Learn more.
  expect(container.textContent).not.toContain(translate("sessionStart.compaction.managed"));
  const more = container.querySelector<HTMLButtonElement>(".cv-session-start__more")!;
  expect(more.textContent).toBe(translate("sessionStart.compaction.learnMore"));
  expect(more.getAttribute("aria-expanded")).toBe("false");
  await act(async () => more.click());
  expect(more.getAttribute("aria-expanded")).toBe("true");
  const explain = container.querySelector(`#${CSS.escape(more.getAttribute("aria-controls")!)}`)!;
  expect(explain.textContent).toBe(translate("sessionStart.compaction.managed"));
});

test("a chat on its own Claude Code setup says Claude Code compacts on its own", async () => {
  const container = installDom();
  resetTranscriptDisclosure();
  await render(container, start("claude"));
  // No route on the short line: it is the person's own setup; the hover says so.
  expect(facts(container)).toBe([translate("sessionStart.agent"), "Opus 5.5"].join(" · "));
  expect(container.querySelector(".cv-session-start")!.getAttribute("title")).toContain(
    translate("sessionStart.route.own"),
  );
  const note = container.querySelector(".cv-session-start__compaction")!;
  expect(note.getAttribute("data-compaction")).toBe("stock");
  expect(compactionLine(container)).toBe(translate("sessionStart.compaction.stockShort"));
  await act(async () => container.querySelector<HTMLButtonElement>(".cv-session-start__more")!.click());
  expect(container.textContent).toContain(translate("sessionStart.compaction.stock"));
  expect(container.textContent).not.toContain(translate("sessionStart.compaction.managed"));
});

test("a dismissed compaction note stays away, the facts line stays", async () => {
  const container = installDom();
  resetTranscriptDisclosure();
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
