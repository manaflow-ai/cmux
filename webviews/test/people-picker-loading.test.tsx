import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { PeoplePicker } from "../src/pages/home-channels/PeoplePicker";
import type { Strings } from "../src/pages/shared/i18n";
import type { HomeParticipant } from "../src/pages/home-channels/types";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM;
let root: Root;
let host: HTMLElement;
const strings: Strings = { language: "en", t: (key) => key, format: (key, ...args) => `${key} ${args.join(" ")}` };
const people: HomeParticipant[] = [{ id: "person-1", name: "Taylor", kind: "human", chief: false }];

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
  const values = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(values)) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  host = dom.window.document.getElementById("root")!;
});
afterEach(() => act(() => root?.unmount()));
afterAll(() => {
  dom.window.close();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});

async function render(loading: boolean, rows: HomeParticipant[] = []) {
  await act(async () =>
    root.render(<PeoplePicker people={rows} picked={[]} onPicked={() => {}} strings={strings} loading={loading} />),
  );
}

test("an initial directory read has visible rows without selectable placeholder people", async () => {
  root = createRoot(host);
  await render(true);
  expect(host.querySelector("fieldset")?.getAttribute("aria-busy")).toBe("true");
  expect(host.querySelectorAll(".lg-picker-row").length).toBeGreaterThan(0);
  expect(host.querySelector('input[type="checkbox"]')).toBeNull();
  expect(host.querySelector(".lg-picker-none")).toBeNull();
  await render(false, people);
  expect(host.querySelector("fieldset")?.getAttribute("aria-busy")).not.toBe("true");
  expect(host.querySelector('input[aria-label="Taylor"]')).not.toBeNull();
  expect(host.querySelector(".lg-picker-loading-row")).toBeNull();
});

test("a completed empty directory replaces placeholders with the existing empty message", async () => {
  root = createRoot(host);
  await render(true);
  expect(host.querySelector(".lg-picker-loading-row")).not.toBeNull();
  await render(false);
  expect(host.querySelector(".lg-picker-loading-row")).toBeNull();
  expect(host.querySelector(".lg-picker-none")?.textContent).toBe("sheet.noMatch");
});

test("a background directory read keeps populated results selectable", async () => {
  root = createRoot(host);
  const picks: string[][] = [];
  await act(async () =>
    root.render(
      <PeoplePicker people={people} picked={[]} onPicked={(next) => picks.push(next)} strings={strings} loading />,
    ),
  );
  expect(host.querySelector(".lg-picker-loading-row")).toBeNull();
  // Review at 5301a5e0 (P2): the rows may still change while the directory reads, so it says busy.
  expect(host.querySelector("fieldset")?.getAttribute("aria-busy")).toBe("true");
  await act(async () => host.querySelector<HTMLInputElement>('input[type="checkbox"]')!.click());
  expect(picks).toEqual([["person-1"]]);
});
