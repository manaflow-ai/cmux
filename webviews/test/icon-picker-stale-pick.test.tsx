// An image or URL pick in the icon picker can resolve seconds after it was started. If the popover
// was closed and opened again for another target in between, the late icon belongs to the old
// session: the page drops it instead of sending it with the new session's id, which the host would
// apply to that other target.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("a pick that resolves after a newer session opened is not sent", async () => {
  const { mountIconPicker } = await import("../src/pages/icon-picker/mount");
  const { IconPickerOps } = await import("../src/pages/icon-picker/host");
  type Call = { op: string; params: Record<string, unknown> };
  const calls: Call[] = [];
  let release!: (reply: unknown) => void;
  let openSession!: (session: unknown) => void;
  const client = {
    call: (op: string, params: Record<string, unknown>) => {
      calls.push({ op, params });
      if (op === IconPickerOps.assetFromURL) return new Promise((resolve) => (release = resolve));
      return Promise.resolve(null);
    },
    subscribe: async (_stream: string, onEvent: (data: unknown) => void) => {
      openSession = onEvent;
      return () => {};
    },
    handle: () => () => {},
  };
  const picker = mountIconPicker(host, client as never);
  await act(async () => {});
  await act(async () => openSession({ id: "a", tab: "svg", assets: true }));

  const view = host.ownerDocument.defaultView!;
  const url = host.querySelector<HTMLInputElement>('input[type="url"]')!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(view.HTMLInputElement.prototype, "value")!.set!.call(
      url,
      "https://example.com/a.svg",
    );
    url.dispatchEvent(new view.Event("input", { bubbles: true }));
  });
  await act(async () => {
    host.querySelector("form.icon-asset-url")!.dispatchEvent(new view.Event("submit", { bubbles: true, cancelable: true }));
  });
  expect(calls.map((call) => call.op)).toContain(IconPickerOps.assetFromURL);

  // The popover closes and opens for another target before the download answers.
  await act(async () => picker.open({ id: "b", tab: "emoji" }));
  await act(async () => release({ icon: "svg:late" }));

  expect(calls.filter((call) => call.op === IconPickerOps.finish)).toEqual([]);
});

test("a pick in the current session is sent with its id", async () => {
  const { mountIconPicker } = await import("../src/pages/icon-picker/mount");
  const { IconPickerOps } = await import("../src/pages/icon-picker/host");
  const finishes: Array<Record<string, unknown>> = [];
  const client = {
    call: (op: string, params: Record<string, unknown>) => {
      if (op === IconPickerOps.finish) finishes.push(params);
      return Promise.resolve(null);
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  host.replaceChildren();
  const picker = mountIconPicker(host, client as never);
  await act(async () => picker.open({ id: "c", tab: "emoji" }));
  await act(async () => {
    host.ownerDocument.dispatchEvent(
      new (host.ownerDocument.defaultView!.KeyboardEvent)("keydown", { key: "Escape", bubbles: true }),
    );
  });
  const search = host.querySelector<HTMLInputElement>(".icon-picker-search")!;
  await act(async () =>
    void search.dispatchEvent(
      new (host.ownerDocument.defaultView!.KeyboardEvent)("keydown", { key: "Escape", bubbles: true, cancelable: true }),
    ),
  );
  expect(finishes).toEqual([{ session: "c", cancel: true }]);
});
