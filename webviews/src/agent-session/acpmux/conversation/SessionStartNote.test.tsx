// l10n-allow-file: test fixture versions, models and paths, not shipped UI.
// A Claude Code chat's session start note says what the chat runs on in one short line ("Claude
// Code · Opus 5.5 · sr2", the whole of it on hover and a click), and nothing else: no line under it
// explaining how the chat compacts (Leo 2026-10-21: the transcript holds events, not explainers;
// each compaction shows as its own note when it happens).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { translate } from "../i18n";
import type { AcpmuxSessionStart } from "../model";
import { SessionStartNote } from "./SessionStartNote";
import { routeOf } from "./sessionStart";
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

test("the route follows the chat's harness", () => {
  expect([routeOf("claude-sr2"), routeOf("claude-cr"), routeOf("claude"), routeOf(undefined)]).toEqual([
    "sr2",
    "coderouter",
    "own",
    "own",
  ]);
});

const facts = (container: HTMLElement) => container.querySelector(".cv-session-start .cv-tool__text")!.textContent;

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

test("an sr2 chat's start is the one facts line: no compaction explainer, no Learn more, no dismiss", async () => {
  const container = installDom();
  resetTranscriptDisclosure();
  await render(container, start("claude-sr2"));
  const wrapper = container.firstElementChild!;
  expect(wrapper.children).toHaveLength(1);
  expect(wrapper.firstElementChild!.classList.contains("cv-session-start")).toBe(true);
  expect(container.querySelectorAll("button")).toHaveLength(1);
  expect(container.textContent?.toLowerCase()).not.toContain("compact");
});

test("a chat on its own Claude Code setup shows the facts without its route, and no compaction line", async () => {
  const container = installDom();
  resetTranscriptDisclosure();
  await render(container, start("claude"));
  // No route on the short line: it is the person's own setup; the hover says so.
  expect(facts(container)).toBe([translate("sessionStart.agent"), "Opus 5.5"].join(" · "));
  expect(container.querySelector(".cv-session-start")!.getAttribute("title")).toContain(
    translate("sessionStart.route.own"),
  );
  expect(container.firstElementChild!.children).toHaveLength(1);
  expect(container.textContent?.toLowerCase()).not.toContain("compact");
});
