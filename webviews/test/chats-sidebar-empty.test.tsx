// POLISH sweep: the chats sidebar's empty states say "chats", like every other chats list, and a
// search that matches nothing says so once, not again under Settled.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
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

const chat = (sessionId: string, title: string): AcpmuxSessionEntry => ({
  sessionId,
  displayTitle: title,
  title,
  harness: "claude",
  cwd: "/tmp/cmux",
  updatedAt: 1,
});

async function sidebar(sessions: ReturnType<typeof chat>[], settledSessions: ReturnType<typeof chat>[]) {
  const { createRoot } = await import("react-dom/client");
  const { SessionSidebar } = await import("../src/agent-session/acpmux/SessionSidebar");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(<SessionSidebar sessions={sessions} settledSessions={settledSessions} onSelect={() => {}} />),
  );
}

async function search(text: string) {
  const field = host.querySelector<HTMLInputElement>('input[type="search"]')!;
  const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setter.call(field, text);
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
}

test("a search that matches nothing says so once", async () => {
  await sidebar([chat("a", "Fix the build")], [chat("b", "Polish the home screen")]);
  await search("zzz");
  const said = host.textContent!.split("No matching chats").length - 1;
  expect(said).toBe(1);
  expect(host.textContent).not.toContain("sessions");
  expect(host.querySelector('input[type="search"]')!.getAttribute("aria-label")).toBe("Search chats");
});

test("an empty sidebar says there are no chats yet", async () => {
  await sidebar([], []);
  expect(host.textContent).toContain("No chats yet");
});

test("the default sidebar hides archived, side, and folded child chats", async () => {
  await sidebar(
    [
      chat("parent", "Parent chat"),
      { ...chat("child", "Folded child"), spawnedBy: "parent" },
      { ...chat("archived", "Archived chat"), archived: true },
      { ...chat("side", "Side question"), side: true },
    ],
    [],
  );
  expect(host.textContent).toContain("Parent chat");
  expect(host.textContent).not.toContain("Folded child");
  expect(host.textContent).not.toContain("Archived chat");
  expect(host.textContent).not.toContain("Side question");
});
