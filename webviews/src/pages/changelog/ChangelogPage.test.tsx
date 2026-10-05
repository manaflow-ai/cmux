import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ChangelogPage } from "./ChangelogPage";
import { MockChangelogProvider, sampleNotes } from "./mockProvider";
import { ChangelogStore } from "./store";

const saved: Record<string, unknown> = {};
let dom: JSDOM;
let root: Root;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", { url: "http://localhost/changelog/" });
  for (const name of ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"])
    saved[name] = (globalThis as any)[name];
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  Object.assign(dom.window.HTMLElement.prototype, { attachEvent: () => undefined, detachEvent: () => undefined });
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterEach(() => {
  act(() => root.unmount());
  for (const [name, value] of Object.entries(saved)) (globalThis as any)[name] = value;
});

async function render(provider: MockChangelogProvider) {
  const store = new ChangelogStore(provider);
  await act(async () => {
    root.render(<ChangelogPage store={store} strings={createStrings(table, ["en"])} />);
  });
  await act(async () => {
    await store.start();
  });
  return store;
}

const $ = (selector: string) => dom.window.document.querySelector(selector) as HTMLElement | null;
const $$ = (selector: string) => [...dom.window.document.querySelectorAll(selector)] as HTMLElement[];

describe("ChangelogPage", () => {
  test("lists every version and opens the installed one with its highlights and changes", async () => {
    await render(new MockChangelogProvider());
    expect($$(".cl-version-name").map((e) => e.textContent)).toEqual(sampleNotes.map((n) => n.shortVersion));
    expect($("h1")?.textContent).toBe(`What's New in ${sampleNotes[0].shortVersion}`);
    expect($$(".cl-highlight h2").map((e) => e.textContent)).toEqual(["Updates you barely notice"]);
    expect($$(".cl-highlight p").length).toBe(2);
    expect($$(".cl-changes li").length).toBe(2);
    expect($(".cl-version.is-selected .cl-current")?.textContent).toBe("Installed");
  });

  test("Try it runs the highlight's action through the host", async () => {
    const provider = new MockChangelogProvider();
    await render(provider);
    await act(async () => {
      $(".cl-try")!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
    });
    expect(provider.ran).toEqual(["palette.checkForUpdates"]);
  });

  test("an older version without highlights shows only its changes", async () => {
    await render(new MockChangelogProvider());
    await act(async () => {
      $$(".cl-version")[1].dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
    });
    expect($$(".cl-highlight").length).toBe(0);
    expect($$(".cl-changes li").map((e) => e.textContent)).toEqual(["browser: faster tab restore"]);
  });

  test("a version without verified notes says so", async () => {
    await render(new MockChangelogProvider(sampleNotes, "999"));
    expect($(".cl-muted")?.textContent).toBe("The notes for this version are not available offline yet.");
  });
});
