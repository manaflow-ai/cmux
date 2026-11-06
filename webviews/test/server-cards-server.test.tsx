// l10n-allow-file: test fixtures.
// The server surfaces on the server card page over the stand-in owner: the menu bar panel draws the
// app's status, its switch and Health row ask the app (Health opens in the same popover), and the
// Add Server card looks a code up, approves only on a click (never Return) once the server is found,
// closes on Done (Return), and cancels the draft and closes on Escape. `#/approver` is the card's other name.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { PageClient } from "../src/pages/shared/pageClient";
import { createStrings } from "../src/pages/shared/i18n";
import table from "../src/pages/server-cards/generated/strings.json";
import { MockServerOwner } from "../src/pages/server-cards/server/mockOwner";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "location",
  "HTMLElement",
  "HTMLInputElement",
  "KeyboardEvent",
  "Event",
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
    HTMLInputElement: window.HTMLInputElement,
    KeyboardEvent: window.KeyboardEvent,
    Event: window.Event,
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

type Call = { op: string; params: unknown };

function fakeHost() {
  const owner = new MockServerOwner("healthyMac", 0);
  const calls: Call[] = [];
  const emitters: Record<string, (data: unknown) => void> = {};
  const client: PageClient = {
    call: async <R,>(op: string, params: unknown) => {
      calls.push({ op, params });
      if (owner.handles(op)) return (await owner.call(op, params)) as R;
      return null as R;
    },
    subscribe: async <E,>(stream: string, onEvent: (data: E, seq: number) => void) => {
      if (stream === "cmux.server.changes") return owner.onChange(() => onEvent({} as E, 1));
      emitters[stream] = (data) => onEvent(data as E, 1);
      return () => {};
    },
    handle: () => () => {},
  };
  return { owner, client, calls, emit: (stream: string, data: unknown = {}) => emitters[stream]?.(data) };
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
const key = async (name: string) => {
  act(
    () =>
      void host
        .querySelector("[data-surface='add-server']")!
        .dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true })),
  );
  await flush();
};
const type = async (text: string) => {
  const input = host.querySelector(".sv-code-input") as HTMLInputElement;
  act(() => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, text);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
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
  await press("[data-row='health']");
  expect(location.hash).toBe("#/server-health");
  expect(host.querySelector("[data-surface='health']")).not.toBeNull();
  expect(host.querySelector("[data-check='sleep.enabled'] [data-fix]")).not.toBeNull();
  await press("[data-fix='sleep.enabled']");
  expect(ops(fake.calls, "cmux.server.send").at(-1)).toEqual({ kind: "fixCheck", check: "sleep.enabled" });
});

test("Add Server looks the code up, approves only on a click once found, and Done closes", async () => {
  const fake = fakeHost();
  await mount("add-server", fake);
  expect(host.querySelector("[data-surface='add-server']")?.getAttribute("data-step")).toBe("enterCode");
  await key("Enter");
  expect(ops(fake.calls, "cmux.server.approver.approve")).toEqual([]);
  await type("7kq4m2xd");
  expect(ops(fake.calls, "cmux.server.approver.setCode").at(-1)).toEqual({ code: "7KQ4-M2XD" });
  expect(host.querySelector("[data-surface='add-server']")?.getAttribute("data-step")).toBe("review");
  expect([...host.querySelectorAll(".sv-word")].map((word) => word.textContent)).toEqual([
    "1copper",
    "2lantern",
    "3meadow",
    "4violet",
  ]);
  expect(host.querySelector("[data-action='cancel']")?.textContent).toContain("Deny");
  expect(host.querySelector("[data-action='approve']")?.hasAttribute("data-person-click")).toBe(true);
  await key("Enter");
  expect(ops(fake.calls, "cmux.server.approver.approve")).toEqual([]);
  await press("[data-action='approve']");
  expect(ops(fake.calls, "cmux.server.approver.approve")).toEqual([{ name: "build-01" }]);
  expect(host.querySelector("[data-surface='add-server']")?.getAttribute("data-step")).toBe("added");
  await key("Enter");
  expect(ops(fake.calls, "cmux.card.close")).toEqual([{ card: "add-server" }]);
});

test("Escape cancels the draft and closes the card; #/approver is the same card", async () => {
  const fake = fakeHost();
  await mount("approver", fake);
  await type("7KQ4M2XD");
  await key("Escape");
  expect(ops(fake.calls, "cmux.server.approver.cancel")).toHaveLength(1);
  expect(ops(fake.calls, "cmux.card.close")).toEqual([{ card: "add-server" }]);
  expect(fake.owner.current.approver.draft.code).toBe("");
  await act(async () => fake.emit("cmux.card.commands", { command: "cancel" }));
  expect(ops(fake.calls, "cmux.server.approver.cancel")).toHaveLength(2);
});
