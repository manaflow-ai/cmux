// A channel composer whose link is down (offline, or reconnecting after a daemon restart) stays as it
// was: undimmed, typing, formatting and emoji live; only Send waits for the link and the draft stays.
// Leo, 2026-11-24 11:57Z, on input grayed out while a session reattaches.
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Strings } from "../shared/i18n";

const scope = globalThis as Record<string, unknown>;
const names = ["window", "document", "navigator", "HTMLElement", "Element", "Node", "getComputedStyle"] as const;
const saved = names.map((name) => [name, scope[name]] as const);
const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
for (const name of names) scope[name] = (dom.window as unknown as Record<string, unknown>)[name];
scope.IS_REACT_ACT_ENVIRONMENT = true;
afterAll(() => {
  dom.window.close();
  for (const [name, value] of saved) scope[name] = value;
  delete scope.IS_REACT_ACT_ENVIRONMENT;
});
const { createRoot } = await import("react-dom/client");
const { Composer } = await import("./Composer");

const strings = { t: (key: string) => key, format: (key: string) => key } as unknown as Strings;

function composer(props: { held?: boolean; disabled?: boolean }): HTMLElement {
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  act(() =>
    root.render(
      <Composer
        placeholder="Message #general"
        label="Message #general"
        strings={strings}
        initialValue="typed while the link was down"
        onSend={async () => true}
        {...props}
      />,
    ),
  );
  afterUnmount.push(() => act(() => root.unmount()));
  return host.querySelector(".hc-composer") as HTMLElement;
}
const afterUnmount: (() => void)[] = [];
// A toolbar button stays focusable when disabled (ui/Toolbar.tsx), so it says so with aria-disabled.
const off = (button: Element | null | undefined) =>
  button instanceof dom.window.HTMLButtonElement &&
  (button.disabled || button.getAttribute("aria-disabled") === "true" || button.hasAttribute("data-disabled"));

test("a held composer is not dimmed, its tools work, and only Send waits", () => {
  const box = composer({ held: true });
  expect(box.classList.contains("disabled")).toBe(false);
  const emoji = box.querySelector('[data-bar="emoji"]')?.closest("button");
  expect(emoji).toBeTruthy();
  expect(off(emoji)).toBe(false);
  const send = box.querySelector("button.hc-send");
  expect(off(send)).toBe(true);
  expect(send?.classList.contains("ready")).toBe(false);
  afterUnmount.splice(0).forEach((done) => done());
});

test("the same draft on a live link can be sent", () => {
  const box = composer({});
  const send = box.querySelector("button.hc-send");
  expect(send?.classList.contains("ready")).toBe(true);
  expect(off(send)).toBe(false);
  afterUnmount.splice(0).forEach((done) => done());
});

test("a composer that cannot post at all still dims", () => {
  const box = composer({ disabled: true });
  expect(box.classList.contains("disabled")).toBe(true);
  afterUnmount.splice(0).forEach((done) => done());
});
