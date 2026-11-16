// The server card page (cmux-page://cmux.server-cards/#/pair-invite) over a fake host: the Pair
// Another Machine card reads its status, asks again on every change event, copies through the host, never confirms on Return (only a click does), presses New Code on
// Return, and closes the panel on Cancel and on Escape.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { PageClient } from "../src/pages/shared/pageClient";
import { createStrings } from "../src/pages/shared/i18n";
import table from "../src/pages/server-cards/generated/strings.json";
import { arrivedStatus, endedStatus, showingStatus } from "../src/pages/server-cards/pairInvite/fixtures";
import type { PairInviteStatus } from "../src/pages/server-cards/pairInvite/types";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "location",
  "HTMLElement",
  "KeyboardEvent",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/#/pair-invite" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    location: window.location,
    HTMLElement: window.HTMLElement,
    KeyboardEvent: window.KeyboardEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

type Call = { op: string; params: unknown };

function fakeHost(initial: PairInviteStatus) {
  let status = initial;
  const calls: Call[] = [];
  const emitters: Record<string, (data: unknown) => void> = {};
  const client: PageClient = {
    call: async <R,>(op: string, params: unknown) => {
      calls.push({ op, params });
      // A fresh object per read, as the bridge decodes each reply.
      if (op === "cmux.pairInvite.status") return structuredClone(status) as R;
      return null as R;
    },
    subscribe: async <E,>(stream: string, onEvent: (data: E, seq: number) => void) => {
      emitters[stream] = (data) => onEvent(data as E, 1);
      return () => {};
    },
    handle: () => () => {},
  };
  return {
    client,
    calls,
    set: (next: PairInviteStatus) => void (status = next),
    emit: (stream: string, data: unknown = {}) => emitters[stream]?.(data),
  };
}

async function flush() {
  for (let i = 0; i < 5; i++) await act(async () => {});
}

async function mount(fake: ReturnType<typeof fakeHost>) {
  const { ServerCardsPage } = await import("../src/pages/server-cards/ServerCardsPage");
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<ServerCardsPage client={fake.client} strings={createStrings(table, ["en"])} />));
  await flush();
}

const ops = (calls: Call[], op: string) => calls.filter((call) => call.op === op);
const press = (selector: string) => act(() => (host.querySelector(selector) as HTMLButtonElement).click());
const key = (name: string) =>
  act(
    () =>
      void host
        .querySelector(".server-card")!
        .dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true })),
  );

test("the invite shows its code, its lines and the countdown, and copies through the host", async () => {
  const fake = fakeHost(showingStatus(Date.now()));
  await mount(fake);
  expect(host.querySelector("[data-card='pair-invite']")?.getAttribute("data-step")).toBe("showing");
  expect(host.querySelector(".pair-invite-code")?.textContent).toBe("7KQ4M-X2D9P");
  expect(host.textContent).toContain("cmux pair 7KQ4M-X2D9P");
  expect(host.querySelector(".pair-invite-countdown")?.textContent).toMatch(/^Expires in (10:00|9:5\d)$/);
  await press("[data-action='copyLine']");
  await flush();
  expect(ops(fake.calls, "cmux.pairInvite.copy").map((call) => call.params)).toEqual([{ target: "line" }]);
  expect(host.querySelector("[data-action='copyLine']")?.textContent).toBe("Copied");
});

test("a change event reads the status again: the arrived machine shows its words; Return never confirms", async () => {
  const fake = fakeHost(showingStatus(Date.now()));
  await mount(fake);
  fake.set(arrivedStatus(Date.now()));
  await act(async () => fake.emit("cmux.pairInvite.changes"));
  await flush();
  expect(host.querySelector("[data-card='pair-invite']")?.getAttribute("data-step")).toBe("review");
  expect([...host.querySelectorAll(".pair-invite-word")].map((word) => word.textContent)).toEqual([
    "1amber",
    "2harbor",
    "3violet",
    "4ladder",
  ]);
  await key("Enter");
  await flush();
  // SECURITY: Confirm is the panel's native footer, not the page's: the page has no Confirm, and
  // neither Return nor anything in it approves.
  expect(host.querySelector("[data-action='confirm']")).toBeNull();
  expect(host.querySelector("[data-action='cancel']")).not.toBeNull();
  expect(fake.calls.filter((call) => /confirm|approve/i.test(call.op))).toEqual([]);
  // The Name field reaches the host for the native Confirm.
  expect(ops(fake.calls, "cmux.pairInvite.setName").map((call) => call.params)).toEqual([{ name: "build-box" }]);
  // Sending the name reads no status again: no loop between the page and the host.
  const reads = ops(fake.calls, "cmux.pairInvite.status").length;
  await flush();
  await flush();
  expect(ops(fake.calls, "cmux.pairInvite.status")).toHaveLength(reads);
  expect(ops(fake.calls, "cmux.pairInvite.setName")).toHaveLength(1);
});

test("an ended invite offers New Code on Return; Cancel and Escape close the card", async () => {
  const fake = fakeHost(endedStatus(Date.now(), "voided"));
  await mount(fake);
  await key("Enter");
  await flush();
  expect(ops(fake.calls, "cmux.pairInvite.newCode")).toHaveLength(1);
  await press("[data-action='cancel']");
  await act(async () => void document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
  await act(async () => fake.emit("cmux.card.commands", { command: "cancel" }));
  expect(ops(fake.calls, "cmux.card.close").map((call) => call.params)).toEqual([
    { card: "pair-invite" },
    { card: "pair-invite" },
    { card: "pair-invite" },
  ]);
});
