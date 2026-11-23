// The `/` menu's rows are names only; the highlighted row says what its command does.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "KeyboardEvent",
  "InputEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

let chats = 0;

/// A Codex chat that lists four commands: two agent commands, one with an argument, and a skill
/// and an agent command of the same name.
function chat(): AcpmuxSnapshot {
  const sessionId = `quiet-rows-${++chats}`;
  return noChat([], {
    sessionId,
    summary: { sessionId, harness: "codex", cwd: "/Users/you/src/app", turnCount: 1 },
    rows: [user("Add retries", 1)],
    commands: [
      { name: "compact", description: "Clear the history but keep a summary", source: "agent" },
      { name: "mention", description: "Mention a file", hint: "<file>", source: "agent" },
      { name: "review", description: "Review a pull request", source: "agent" },
      { name: "review", description: "Review with the team checklist", source: "skill" },
    ],
  });
}

async function composer(snapshot: AcpmuxSnapshot, typed: string) {
  let handle: ComposerHandle | null = null;
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        handle={(value) => void (handle = value)}
        snapshot={snapshot}
        sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
        chips={Chips}
        onSend={() => true}
        onStop={() => {}}
        localName="studio"
      />,
    ),
  );
  await act(async () => handle!.restore(typed, []));
  return host.querySelector<HTMLElement>("[role=combobox]")!;
}

const rows = () => [...host.querySelectorAll<HTMLElement>("#acpmux-slash-menu [role='option']")];
const shown = (row: HTMLElement, selector: string) => row.querySelector(selector)?.textContent?.trim() ?? "";
const active = () => rows().findIndex((row) => row.getAttribute("aria-selected") === "true");
/// What a row shows besides its name: its argument, what it does, where it comes from.
const details = (row: HTMLElement) =>
  [
    shown(row, ".acpmux-slash-hint"),
    shown(row, ".acpmux-slash-description"),
    shown(row, ".acpmux-slash-source"),
  ].filter(Boolean);

async function press(field: HTMLElement, key: string) {
  await act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key, keyCode: 40, bubbles: true, cancelable: true }));
  });
}

// The `/` list reads as a list of names (a1315, Lawrence 2026-11-21: "drastically simplify all
// parts of the UI"): one line per command, its name and the one-word tag of where it comes from.
// The highlighted row also says what it does (its argument and its description); a row the pointer
// or the arrows have not reached says it to a screen reader only. Two rows of one name keep the
// tag, the one thing that tells them apart.
test("only the highlighted row shows what a command does; the others show their name only", async () => {
  await composer(chat(), "/");
  const all = rows();
  expect(all.length).toBe(4);
  const at = active();
  expect(at).toBe(0);
  expect(details(all[0]!)).toEqual(["Clear the history but keep a summary"]);
  const mention = all.find((row) => shown(row, ".acpmux-slash-name") === "/mention")!;
  expect(details(mention)).toEqual([]);
  expect(mention.getAttribute("aria-description")).toBe("Mention a file");
});

test("the description follows the highlight", async () => {
  const field = await composer(chat(), "/");
  await press(field, "ArrowDown");
  const all = rows();
  expect(active()).toBe(1);
  expect(details(all[0]!)).toEqual([]);
  expect(details(all[1]!)).toEqual(["<file>", "Mention a file"]);
});

test("two rows of one name keep where each comes from", async () => {
  await composer(chat(), "/rev");
  const reviews = rows().filter((row) => shown(row, ".acpmux-slash-name") === "/review");
  expect(reviews.length).toBe(2);
  const quiet = reviews.find((row) => row.getAttribute("aria-selected") !== "true")!;
  const skill = reviews.find(
    (row) =>
      shown(row, ".acpmux-slash-description") === "Review with the team checklist" ||
      row.getAttribute("aria-description") === "Review with the team checklist",
  )!;
  // The skill's row says it is a skill, highlighted or not; the quiet row shows nothing else.
  expect(shown(skill, ".acpmux-slash-source")).not.toBe("");
  expect(details(quiet)).toEqual([shown(quiet, ".acpmux-slash-source")].filter(Boolean));
});

// A tag that every row shares tells no row apart (the agent chat's own list: "cmux" on each row).
// The tags show only when the list holds more than one source.
test("a list of one source shows no source tag", async () => {
  const sessionId = `quiet-rows-${++chats}`;
  await composer(
    noChat([], {
      sessionId,
      summary: { sessionId, harness: "codex", cwd: "/Users/you/src/app", turnCount: 1 },
      rows: [user("Add retries", 1)],
      commands: [
        { name: "checklist", description: "Review with the team checklist", source: "skill" },
        { name: "release", description: "Cut a release", source: "skill" },
      ],
    }),
    "/",
  );
  const all = rows();
  expect(all.length).toBe(2);
  expect(all.map((row) => shown(row, ".acpmux-slash-source"))).toEqual(["", ""]);
});
