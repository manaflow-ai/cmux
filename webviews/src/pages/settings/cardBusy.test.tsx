// A change in flight in a Settings card disables its rows' controls and draws no row again (visible-
// only rule 2): a harness's accounts (a routing switch), the Customization Library (a switch) and
// Shared Links (a Revoke). The controls sit in a disabled fieldset (cardWindow.ts cardBusy,
// ProviderAccounts' BusyControls), so the browser disables them with no React render of a row. Each
// test holds the change until it lets it answer, so only `busy` changes, on and off, and counts the
// rows React's commits touched (test/support/commitRenders.ts). It also checks every row control:
// the ones a change waits for match `:disabled` and fire nothing, and the ones that never waited
// (an account's rename field and its Cancel) stay usable. Each waiting button also says
// aria-disabled="true" until the change answers (cardWindow.ts useWaitingControls), so Chromium's
// accessibility tree drops `focusable` from it (test/settings-busy-ax-browser.test.ts), with no row
// render either.
import { act } from "react";
import { afterAll, afterEach, expect, setSystemTime, test } from "bun:test";
import { installDom } from "./testDom";
import type { ProviderAccount } from "./ops";
import type { Rendered } from "./testing";
import { installVirtualSizes } from "../../../test/support/virtualSizes";
import { installCardRects, settingsCardSizes } from "../../../test/support/settingsCardSizes";
import { manyShares } from "../../../test/support/settingsCardFixtures";
import { rowRenders } from "../../../test/support/commitRenders";

const restore = installDom();
afterAll(() => {
  setSystemTime();
  restore();
});
installVirtualSizes({ HTMLElement: globalThis.window.HTMLElement }, settingsCardSizes);
installCardRects({ HTMLElement: globalThis.window.HTMLElement });
const { changeValue, click, renderPage, settle } = await import("./testing");
const { mockLongLibrary } = await import("./mockLibrary");

const NOW = new Date(2026, 10, 18, 10, 0).getTime();
setSystemTime(new Date(NOW));

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const disabled = (element: Element) => element.matches(":disabled");
const controls = (within: ParentNode) => [...within.querySelectorAll<HTMLElement>("button, input, select, textarea")];
const marked = (element: Element) => element.getAttribute("aria-disabled") === "true";
/** A change the test lets answer: `answer()` resolves it with `value`. */
function held<T>(value: T) {
  let answer: () => void = () => {};
  let calls = 0;
  return {
    run: () => {
      calls += 1;
      return new Promise<T>((resolve) => (answer = () => resolve(value)));
    },
    answer: () => answer(),
    calls: () => calls,
  };
}

const account = (id: string, name: string, extra: Partial<ProviderAccount> = {}): ProviderAccount => ({
  id,
  family: "codex",
  name,
  home: `~/.cmux/accounts/${id}`,
  defaultHome: "~/.codex",
  shadowOf: null,
  signedIn: true,
  plan: "pro",
  email: `${id}@example.com`,
  enabled: true,
  builtin: false,
  ...extra,
});

test("a harness's accounts: a routing change in flight disables every gesture control, keeps the rename field and its Cancel usable, and draws no row", async () => {
  page = await renderPage({ path: "/settings/agents" });
  await settle();
  const accounts = [
    account("codex-login", "ChatGPT", { home: null, builtin: true }),
    account("codex-2", "ChatGPT 2", { shadowOf: "codex-login" }),
    account("codex-3", "ChatGPT 3", { signedIn: false }),
  ];
  await act(async () => page!.provider.setHarnesses({ ...page!.provider.harnesses, accounts }));
  await settle();
  const selector = '[data-card="harnesses"] [data-harness="codex"] [data-account]';
  const rows = () => [...page!.container.querySelectorAll<HTMLElement>(selector)];
  expect(rows().length).toBe(3);
  // The first account's rename is open before the change starts.
  await click(rows()[0]!.querySelector('[data-account-action="rename"]')!);
  const renameForm = () => rows()[0]!.querySelector<HTMLFormElement>("[data-account-rename]");
  expect(renameForm()).not.toBeNull();

  const change = held(undefined);
  page.store.runHarnesses = change.run;
  const renders = rowRenders();
  renders.begin(page.container, selector);
  await click(rows()[1]!.querySelector('[role="switch"]')!);
  expect(renders.end()).toMatchObject({ rerendered: 0, added: 0 });
  expect(change.calls()).toBe(1);

  // Waits for the change: every gesture button, every routing switch and the rename's Save.
  const waits = rows().flatMap((row) => [
    ...row.querySelectorAll("[data-account-action]"),
    ...row.querySelectorAll('[role="switch"]'),
  ]);
  const save = renameForm()!.querySelector<HTMLButtonElement>('button[type="submit"]')!;
  expect(waits.length).toBeGreaterThan(6);
  expect([...waits, save].every(disabled)).toBe(true);
  expect([...waits, save].every(marked)).toBe(true);
  // Never waited: the rename field and its Cancel; nothing else in a row is a control.
  const field = renameForm()!.querySelector<HTMLInputElement>("input")!;
  const cancel = [...renameForm()!.querySelectorAll("button")].find((button) => button.type === "button")!;
  const usable: HTMLElement[] = [field, cancel];
  expect(usable.some(disabled)).toBe(false);
  expect(usable.some(marked)).toBe(false);
  const all = rows().flatMap(controls);
  // The Switch's hidden form input waits with its switch.
  const hidden = all.filter((one) => one instanceof window.HTMLInputElement && one !== field);
  expect(all.filter((one) => !usable.includes(one) && !hidden.includes(one)).every(disabled)).toBe(true);
  expect(hidden.every(disabled)).toBe(true);

  // A waiting control fires nothing; the usable ones work.
  await click(rows()[2]!.querySelector('[role="switch"]')!);
  await click(rows()[2]!.querySelector('[data-account-action="signIn"]')!);
  expect(change.calls()).toBe(1);
  await changeValue(field, "Work");
  expect(renameForm()!.querySelector("input")!.value).toBe("Work");
  await click(cancel);
  expect(renameForm()).toBeNull();

  // The change answers with the same accounts: the controls come back, and no row draws.
  renders.begin(page.container, selector);
  await act(async () => change.answer());
  await settle();
  expect(renders.end()).toMatchObject({ rerendered: 0, added: 0 });
  expect(rows().flatMap(controls).some(disabled)).toBe(false);
  expect(rows().flatMap(controls).some(marked)).toBe(false);
});

test("a harness's accounts: a rename cancelled while a change is in flight brings back a Rename that waits and says so, then gives it back on answer, with no row drawn by the change", async () => {
  page = await renderPage({ path: "/settings/agents" });
  await settle();
  const accounts = [
    account("codex-login", "ChatGPT", { home: null, builtin: true }),
    account("codex-2", "ChatGPT 2", { shadowOf: "codex-login" }),
    account("codex-3", "ChatGPT 3", { signedIn: false }),
  ];
  await act(async () => page!.provider.setHarnesses({ ...page!.provider.harnesses, accounts }));
  await settle();
  const selector = '[data-card="harnesses"] [data-harness="codex"] [data-account]';
  const rows = () => [...page!.container.querySelectorAll<HTMLElement>(selector)];
  const renameOf = (row: number) => rows()[row]!.querySelector<HTMLButtonElement>('[data-account-action="rename"]');
  const renameForm = () => rows()[1]!.querySelector<HTMLFormElement>("[data-account-rename]");
  // The second account's rename is open (its Rename unmounted) before the change starts.
  await click(renameOf(1)!);
  expect(renameOf(1)).toBeNull();

  const change = held(undefined);
  page.store.runHarnesses = change.run;
  const renders = rowRenders();
  renders.begin(page.container, selector);
  // Another account's routing switch starts the change.
  await click(rows()[2]!.querySelector('[role="switch"]')!);
  expect(renders.end()).toMatchObject({ rerendered: 0, added: 0 });
  expect(change.calls()).toBe(1);

  // Cancel while it waits: the row's Rename mounts again, into a change it never saw.
  const cancel = [...renameForm()!.querySelectorAll("button")].find((button) => button.type === "button")!;
  await click(cancel);
  expect(renameForm()).toBeNull();
  const rename = renameOf(1)!;
  expect(rename).not.toBeNull();
  expect(disabled(rename)).toBe(true);
  expect(marked(rename)).toBe(true);
  // Every gesture control of every row waits and says so, the remounted one included.
  const waits = () =>
    rows().flatMap((row) => [
      ...row.querySelectorAll<HTMLElement>("[data-account-action]"),
      ...row.querySelectorAll<HTMLElement>('[role="switch"]'),
    ]);
  expect(waits().every(disabled)).toBe(true);
  expect(waits().filter((one) => !marked(one))).toEqual([]);
  await click(rename);
  expect(renameForm()).toBeNull();
  expect(change.calls()).toBe(1);

  // The change answers with the same accounts: no row draws, and the mark comes off the remounted
  // Rename as off every other control.
  renders.begin(page.container, selector);
  await act(async () => change.answer());
  await settle();
  expect(renders.end()).toMatchObject({ rerendered: 0, added: 0 });
  expect(renameOf(1)).toBe(rename);
  expect(disabled(rename)).toBe(false);
  expect(marked(rename)).toBe(false);
  expect(rows().flatMap(controls).some(disabled)).toBe(false);
  expect(rows().flatMap(controls).some(marked)).toBe(false);
});

test("Customization Library: a switch's change in flight disables every row control and draws no row, on and off", async () => {
  page = await renderPage({
    path: "/settings/personalization",
    setup: (provider) => (provider.library = mockLongLibrary(1_000)),
  });
  await settle();
  const selector = '[data-card="customizeLibrary"] [data-library-entry]';
  const rows = () => [...page!.container.querySelectorAll<HTMLElement>(selector)];
  expect(rows().length).toBeGreaterThan(20);
  // A button disabled for its own reason (the first entry's Move Up, the last's Move Down).
  const own = (one: HTMLElement) => (one as HTMLButtonElement).disabled;
  const change = held({ library: null, refusal: null });
  page.store.customizeLibrary = change.run;

  const renders = rowRenders();
  renders.begin(page.container, selector);
  await click(page.container.querySelector(`${selector}[data-index="5"] [role="switch"]`)!);
  expect(renders.end()).toMatchObject({ rerendered: 0, added: 0 });
  expect(change.calls()).toBe(1);
  // Every control in a row waits (Move Up, Move Down, Remove, the switch): none stays usable.
  const all = rows().flatMap(controls);
  expect(all.length).toBeGreaterThan(rows().length * 4 - 1);
  expect(all.every(disabled)).toBe(true);
  expect(all.filter((one) => one instanceof window.HTMLButtonElement).every(marked)).toBe(true);
  await click(page.container.querySelector(`${selector}[data-index="7"] [role="switch"]`)!);
  await click(page.container.querySelector(`${selector}[data-index="7"] [data-library-action="down"]`)!);
  expect(change.calls()).toBe(1);

  renders.begin(page.container, selector);
  await act(async () => change.answer());
  await settle();
  expect(renders.end()).toMatchObject({ rerendered: 0, added: 0 });
  expect(
    rows()
      .flatMap(controls)
      .every((one) => disabled(one) === own(one)),
  ).toBe(true);
  expect(rows().flatMap(controls).some(marked)).toBe(false);
});

test("Shared Links: a revoke in flight disables every Revoke and draws no row, on and off", async () => {
  page = await renderPage({
    path: "/settings/privacy",
    setup: (provider) => (provider.shares = manyShares(1_000, NOW)),
  });
  await settle();
  const selector = '[data-card="sharedLinks"] [data-shared-link]';
  const rows = () => [...page!.container.querySelectorAll<HTMLElement>(selector)];
  const revokes = () => rows().map((row) => row.querySelector('[data-shared-link-action="revoke"]')!);
  expect(rows().length).toBeGreaterThan(20);
  const change = held(null);
  page.store.revokeShares = change.run;

  const renders = rowRenders();
  renders.begin(page.container, selector);
  await click(revokes()[5]!);
  expect(renders.end()).toMatchObject({ rerendered: 0, added: 0 });
  expect(change.calls()).toBe(1);
  // Revoke is a row's only control, and it waits.
  expect(rows().flatMap(controls)).toEqual(revokes() as HTMLElement[]);
  expect(revokes().every(disabled)).toBe(true);
  expect(revokes().every(marked)).toBe(true);
  await click(revokes()[6]!);
  expect(change.calls()).toBe(1);

  renders.begin(page.container, selector);
  await act(async () => change.answer());
  await settle();
  expect(renders.end()).toMatchObject({ rerendered: 0, added: 0 });
  expect(revokes().some(disabled)).toBe(false);
  expect(revokes().some(marked)).toBe(false);
});
