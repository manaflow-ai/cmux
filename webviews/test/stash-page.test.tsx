// The Stashed Tabs page (cmux NEXT; the React page that replaced the Swift StashPageView): OneTab
// parsing, search, restore and delete through the owners, the Undo answer of the app's toast, and
// a stash another client made showing without a reload.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLInputElement",
  "HTMLTextAreaElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/stash/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const menu of dom.window.document.querySelectorAll('[role="menu"]')) menu.remove();
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { StashPage } = await import("../src/pages/stash/StashPage");
const { UiProvider } = await import("../src/ui/UiProvider");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/stash/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;
const { MockStashProvider } = await import("../src/pages/stash/mockProvider");
const { StashStore } = await import("../src/pages/stash/store");
const { StashOps } = await import("../src/pages/stash/types");
const { matchGroups, parseOneTab, normalized } = await import("../src/pages/stash/model");

async function mount(provider = new MockStashProvider(), options = {}) {
  const store = new StashStore(provider, options);
  const strings = createStrings(table, ["en"]);
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <UiProvider container={host}>
        <StashPage store={store} strings={strings} />
      </UiProvider>,
    );
  });
  await act(async () => store.start());
  return { provider, store };
}

const rows = () => [...host.querySelectorAll<HTMLElement>(".stash-row")];
const titles = () => rows().map((row) => row.querySelector(".stash-row-title")?.textContent);
const button = (text: string, within: ParentNode = host) =>
  [...within.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === text)!;
const menuItems = () => [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')];
const menuLabels = () => menuItems().map((item) => item.textContent);
const menuItem = (text: string) => menuItems().find((item) => item.textContent === text);
async function menuKey(target: HTMLElement) {
  target.focus();
  await act(async () => {
    target.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "F10", shiftKey: true, bubbles: true, cancelable: true }),
    );
  });
}
const last = (provider: InstanceType<typeof MockStashProvider>, op: string) =>
  provider.calls.filter((call) => call.op === op).at(-1)?.params;

test("OneTab text parses into groups at blank lines, with titles and bare addresses", () => {
  const groups = parseOneTab("https://a.example/ | A\r\nhttps://b.example/\n\n  \nhttps://c.example/ |\n");
  expect(groups).toEqual([
    { tabs: [{ url: "https://a.example/", title: "A" }, { url: "https://b.example/" }] },
    { tabs: [{ url: "https://c.example/" }] },
  ]);
  const long = parseOneTab(Array.from({ length: 1001 }, (_, index) => `https://x.example/${index}`).join("\n"));
  expect(long.map((group) => group.tabs.length)).toEqual([1000, 1]);
  expect(parseOneTab(`https://t.example/ | ${"é".repeat(600)}`)[0]!.tabs[0]!.title!.length).toBe(512);
});

test("search ignores case and diacritics, keeps a whole group by its name and a workspace by its tabs", () => {
  const groups = new MockStashProvider().stashes.map(normalized);
  expect(matchGroups(groups, "RESUME")[0]!.members.map((member) => member.id)).toEqual(["m1"]);
  expect(matchGroups(groups, "atlas-web")[0]!.members.length).toBe(3);
  expect(matchGroups(groups, "psql")[0]!.id).toBe("s2");
  expect(matchGroups(groups, "  ").length).toBe(3);
});

test("the page lists stashes; a row restores its page and Restore in New Workspace the whole group", async () => {
  const { provider } = await mount();
  expect(titles()).toEqual([
    "Atlas release notes",
    "Design review — editor states",
    "TypeScript handbook",
    "backend",
    "Résumé of the week",
    "https://example.org/long/path",
  ]);
  expect(host.querySelector(".stash-row-aside")?.textContent).toBe("docs.example.test");
  await act(async () => rows()[0]!.querySelector<HTMLButtonElement>(".stash-row-main")!.click());
  expect(last(provider, StashOps.restore)).toEqual({ stash: "s1", members: ["m1"], new_workspace: false });
  expect(titles()[0]).toBe("Design review — editor states");
  // The header shows Restore All only; the rest is in its menu (Shift-F10 on Restore All).
  const group = host.querySelector<HTMLElement>(".stash-group")!;
  expect([...group.querySelectorAll(".stash-group-header button")].map((item) => item.textContent)).toEqual([
    "Restore All",
  ]);
  await menuKey(button("Restore All", group));
  expect(menuLabels()).toEqual(["Restore All", "Restore in New Workspace", "Delete Group"]);
  await act(async () => menuItem("Restore in New Workspace")!.click());
  expect(last(provider, StashOps.restore)).toEqual({ stash: "s1", members: ["m2", "m3"], new_workspace: true });
  expect(titles()[0]).toBe("backend");
});

test("a delete hides its row while the app's Undo toast is up; Undo brings it back", async () => {
  const provider = new MockStashProvider();
  let release!: () => void;
  provider.toast = new Promise((resolve) => (release = resolve));
  provider.undo = true;
  await mount(provider);
  // A row carries no destructive control: Delete is in its menu (Shift-F10 on the focused row).
  expect(host.querySelector(".stash-row button:not(.stash-row-main)")).toBeNull();
  await menuKey(rows()[0]!.querySelector<HTMLButtonElement>(".stash-row-main")!);
  expect(menuLabels()).toEqual(["Restore", "Delete"]);
  await act(async () => menuItem("Delete")!.click());
  expect(titles()).not.toContain("Atlas release notes");
  expect(last(provider, StashOps.delete)).toEqual({ stash: "s1", members: ["m1"] });
  await act(async () => release());
  expect(titles()).toContain("Atlas release notes");
  // No Undo this time: the group goes for good.
  provider.toast = undefined;
  provider.undo = false;
  await menuKey(button("Restore All", host.querySelector<HTMLElement>(".stash-group")!));
  await act(async () => menuItem("Delete Group")!.click());
  expect(titles()).not.toContain("Atlas release notes");
  expect(provider.stashes.map((stash) => stash.id)).toEqual(["s2", "s3"]);
});

test("Restore All during a member's Undo window sends the shown members only, never the hidden one", async () => {
  const provider = new MockStashProvider();
  let release!: () => void;
  provider.toast = new Promise((resolve) => (release = resolve));
  provider.undo = false;
  const { store } = await mount(provider);
  const group = () => store.getSnapshot().groups.find((candidate) => candidate.id === "s1")!;
  const pending = store.delete(group(), group().members[0]!);
  await act(async () => {});
  expect(titles()).not.toContain("Atlas release notes");
  // Restore All from the header (the whole group as shown) and from the store's default.
  await act(async () => button("Restore All", host.querySelector<HTMLElement>(".stash-group")!).click());
  expect(last(provider, StashOps.restore)).toEqual({ stash: "s1", members: ["m2", "m3"], new_workspace: false });
  await act(async () => release());
  await act(async () => pending);
  expect(provider.stashes.some((stash) => stash.id === "s1")).toBe(false);
});

test("the store's group restores default to the group's shown members", async () => {
  const provider = new MockStashProvider();
  provider.toast = new Promise(() => undefined);
  const { store } = await mount(provider);
  const group = store.getSnapshot().groups.find((candidate) => candidate.id === "s1")!;
  void store.delete(group, group.members[1]!);
  await act(async () => {});
  // A stale group object (read before the delete) still never sends the hidden member.
  await act(async () => store.restore(group, undefined, true));
  expect(last(provider, StashOps.restore)).toEqual({ stash: "s1", members: ["m1", "m3"], new_workspace: true });
});

test("Import from OneTab… imports pasted text, says how many, and a stash made elsewhere shows at once", async () => {
  const { provider } = await mount();
  await act(async () => button("Import from OneTab…").click());
  const text = host.querySelector<HTMLTextAreaElement>(".stash-import-text")!;
  const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(text, "https://new.example/ | New\nfile:///etc/passwd");
    text.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () => button("Import").click());
  expect(last(provider, StashOps.import)).toEqual({
    source: "onetab",
    groups: [{ tabs: [{ url: "https://new.example/", title: "New" }, { url: "file:///etc/passwd" }] }],
    idempotency_key: expect.any(String),
  });
  expect(host.querySelector(".stash-notice")?.textContent).toBe("Imported 1, skipped 1.");
  expect(host.querySelector(".stash-import")).toBeNull();
  expect(titles()[0]).toBe("New");
  await act(async () =>
    provider.push({
      id: "cli",
      created_at_ms: Date.now(),
      members: [{ id: "a", url: "https://cli.example/", title: "From the CLI" }],
    }),
  );
  expect(titles()[0]).toBe("From the CLI");
});

test("the route #/import opens the paste box, and an empty paste says nothing was found", async () => {
  await mount(new MockStashProvider([]), { importOpen: true });
  expect(host.querySelector(".stash-empty")?.textContent).toContain("No stashed tabs.");
  const text = host.querySelector<HTMLTextAreaElement>(".stash-import-text")!;
  const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, "value")!.set!;
  await act(async () => {
    setter.call(text, "   \n\n");
    text.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  expect(button("Import").disabled).toBe(true);
});
