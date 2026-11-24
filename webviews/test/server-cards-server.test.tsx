// l10n-allow-file: test fixtures.
// The server surfaces on the server page over the stand-in owner: the menu bar panel draws the app's
// status, and its switch and Health row ask the app (Health opens in the same popover). Add Server is a
// native card (AddServerDialogTests), and the page has no route for it.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { PageClient } from "../src/pages/shared/pageClient";
import { createStrings } from "../src/pages/shared/i18n";
import table from "../src/pages/server-cards/generated/strings.json";
import { MockServerOwner } from "../src/pages/server-cards/server/mockOwner";
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
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/#/server-panel" });
  const { window } = dom;
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

function fakeHost() {
  const owner = new MockServerOwner("healthyMac");
  const calls: Call[] = [];
  const client: PageClient = {
    call: async <R,>(op: string, params: unknown) => {
      calls.push({ op, params });
      if (owner.handles(op)) return (await owner.call(op, params)) as R;
      return null as R;
    },
    subscribe: async <E,>(stream: string, onEvent: (data: E, seq: number) => void) => {
      if (stream === "cmux.server.changes") return owner.onChange(() => onEvent({} as E, 1));
      return () => {};
    },
    handle: () => () => {},
  };
  return { owner, client, calls };
}

async function flush() {
  for (let i = 0; i < 8; i++) await act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
}

async function mount(route: string, fake: ReturnType<typeof fakeHost>) {
  const { ServerCardsPage } = await import("../src/pages/server-cards/ServerCardsPage");
  act(() => root?.unmount());
  dom.reconfigure({ url: `https://cmux.test/#/${route}` });
  root = createRoot(host);
  act(() => root!.render(<ServerCardsPage client={fake.client} strings={createStrings(table, ["en"])} />));
  await flush();
}

const ops = (calls: Call[], op: string) => calls.filter((call) => call.op === op).map((call) => call.params);
const press = async (selector: string) => {
  act(() => (host.querySelector(selector) as HTMLButtonElement).click());
  await flush();
};
test("the panel draws the status, sends the switch, and opens Health in the same popover", async () => {
  const fake = fakeHost();
  await mount("server-panel", fake);
  expect(host.querySelector("[data-surface='panel']")?.getAttribute("data-layout")).toBe("compact");
  expect(host.textContent).toContain("Mac mini");
  expect(host.querySelector(".sv-header-state")?.textContent).toBe("Serving · Manaflow");
  await press("[data-server-switch]");
  expect(ops(fake.calls, "cmux.server.send")).toEqual([{ kind: "setEnabled", on: false }]);
  expect(host.querySelector("[data-server-switch]")?.getAttribute("aria-checked")).toBe("false");
  // Escape is the popover's own (it closes natively): the page leaves it alone.
  const escape = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
  act(() => void document.dispatchEvent(escape));
  expect(escape.defaultPrevented).toBe(false);
  await press("[data-row='health']");
  expect(location.hash).toBe("#/server-health");
  expect(host.querySelector("[data-surface='health']")).not.toBeNull();
  expect(host.querySelector("[data-check='sleep.enabled'] [data-fix]")).not.toBeNull();
  await press("[data-fix='sleep.enabled']");
  expect(ops(fake.calls, "cmux.server.send").at(-1)).toEqual({ kind: "fixCheck", check: "sleep.enabled" });
});

test("the page has no Add Server route: the hash draws nothing", async () => {
  const fake = fakeHost();
  for (const route of ["add-server", "approver"]) {
    await mount(route, fake);
    expect(host.querySelector("[data-surface]")).toBeNull();
  }
  expect(fake.calls.filter((call) => call.op.includes("approver"))).toEqual([]);
});
