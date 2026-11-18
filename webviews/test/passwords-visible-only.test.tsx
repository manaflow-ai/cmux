// The Passwords page draws what is visible (the visible-only rule): at 1,000 and 10,000 saved logins
// the page mounts the same rows and DOM nodes, and a focus, a one-row scroll and a reply that changes
// one login draw again only the rows whose data changed. Before, every login, passkey and exception
// was a mounted row, and each render drew every row: the rows were inline, with new handlers each
// render. A row whose username is being edited, or that holds focus, stays mounted however far the
// list scrolls.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { SavedPassword } from "../src/pages/passwords/types";
import { settleReact } from "./support/domTeardown";
import { mountedRowRenders } from "./support/mountedRowRenders";
import { installVirtualSizes } from "./support/virtualSizes";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLInputElement",
  "HTMLFormElement",
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

/** The Passwords page: a 600 px scroller; a site's header 32 px, a login 30 (its site's last 34). */
const passwordSizes = (element: HTMLElement) =>
  element.classList.contains("pw-scroll")
    ? 600
    : element.classList.contains("pw-site-head")
      ? 32
      : element.classList.contains("pw-site-end")
        ? 34
        : 30;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/passwords/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  installVirtualSizes(dom.window, passwordSizes);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
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
const { PasswordsPage } = await import("../src/pages/passwords/PasswordsPage");
const { createStrings } = await import("../src/pages/shared/i18n");
const table = (await import("../src/pages/passwords/generated/strings.json")).default as Record<
  string,
  Record<string, string>
>;
const { MockPasswordsProvider, sampleData } = await import("../src/pages/passwords/mockProvider");
const { PasswordsStore } = await import("../src/pages/passwords/store");
const { PasswordOps } = await import("../src/pages/passwords/types");

const NOW = Date.UTC(2026, 10, 18, 12);

/** `n` logins, two a site; every reply sends a fresh copy of each, as the app's bridge does. */
class ManyLogins extends MockPasswordsProvider {
  constructor(n: number) {
    const data = sampleData();
    data.passwords.default = Array.from({ length: n }, (_, index): SavedPassword => ({
      id: `p${index}`,
      site: `site${String(Math.floor(index / 2)).padStart(5, "0")}.example`,
      url: `https://site${index}.example/`,
      username: `person${index}@example.com`,
      created: NOW - 90 * 86_400_000,
      last_used: NOW - index * 60_000,
      times_used: index,
      weak: index % 7 === 0,
      reused: false,
    }));
    super(data);
  }
  override async call<R>(op: string, params: unknown): Promise<R> {
    const reply = await super.call<R>(op, params);
    return op === PasswordOps.list ? structuredClone(reply) : reply;
  }
}

async function mount(n: number) {
  const provider = new ManyLogins(n);
  const store = new PasswordsStore(provider);
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => {
    root!.render(<PasswordsPage store={store} strings={createStrings(table, ["en"])} />);
  });
  await act(async () => store.start());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return { provider, store, scroller: host.querySelector<HTMLElement>(".pw-scroll")! };
}

const logins = () => host.querySelectorAll(".pw-site .pw-row");
const renders = mountedRowRenders(() => host.querySelectorAll(".pw-site .pw-row"), "LoginRow");
const nodes = (scroller: HTMLElement) => scroller.querySelectorAll("*").length;

/** Mounted rows, DOM nodes and the row renders of one focus, one-row scroll and one-login change. */
async function measure(n: number) {
  const { provider, store, scroller } = await mount(n);
  const mounted = { rows: logins().length, nodes: nodes(scroller) };

  renders.mark();
  const copy = host.querySelectorAll<HTMLElement>(".pw-site .pw-row .pw-row-button")[5]!;
  await act(async () => copy.focus());
  const focus = renders.since();

  const rects = { calls: 0 };
  const original = dom.window.Element.prototype.getBoundingClientRect;
  dom.window.Element.prototype.getBoundingClientRect = function (this: Element) {
    rects.calls++;
    return original.call(this);
  };
  renders.mark();
  await act(async () => {
    scroller.scrollTop += 30;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const scroll = { renders: renders.since(), rects: rects.calls };
  dom.window.Element.prototype.getBoundingClientRect = original;

  renders.mark();
  const rows = provider.data.passwords.default!;
  // A change that keeps the row in its place (the logins of a site sort by username).
  rows[3] = { ...rows[3]!, username: "person3.changed@example.com" };
  await act(async () => store.reload());
  const change = renders.since();
  return { mounted, focus, scroll, change, n };
}

test("1,000 and 10,000 logins mount the same rows, and one event draws only the rows it changed", async () => {
  const small = await measure(1_000);
  act(() => root?.unmount());
  const large = await measure(10_000);
  console.log(JSON.stringify({ small, large }));

  // Rule 1: the viewport's rows (600 / 30) and about one viewport each side, not the list.
  for (const run of [small, large]) {
    expect(run.mounted.rows).toBeGreaterThan(10);
    expect(run.mounted.rows).toBeLessThanOrEqual(60);
  }
  expect(Math.abs(large.mounted.rows - small.mounted.rows)).toBeLessThanOrEqual(small.mounted.rows * 0.1);
  expect(Math.abs(large.mounted.nodes - small.mounted.nodes)).toBeLessThanOrEqual(small.mounted.nodes * 0.1);

  for (const run of [small, large]) {
    // Rule 2: focusing a row's button draws no row.
    expect(run.focus).toBe(0);
    // One row's scroll draws only the rows it brings in; the mounted ones keep their place.
    expect(run.scroll.renders).toBeLessThanOrEqual(2);
    // A reply that changes one login draws that row alone.
    expect(run.change).toBeLessThanOrEqual(1);
  }
  // Rule 3: a scroll reads no row's layout, at any length.
  expect(large.scroll.rects).toBe(small.scroll.rects);
});

test("the row being edited and the focused row stay mounted far past the window; rows carry their place", async () => {
  const { store, scroller } = await mount(1_000);
  const first = () => host.querySelector<HTMLElement>('.pw-row[data-id="p0"]');
  const copy = first()!.querySelectorAll<HTMLElement>(".pw-row-button")[1]!;
  await act(async () => copy.focus());
  await act(async () => {
    scroller.scrollTop = 20_000;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(copy.isConnected).toBe(true);
  expect(dom.window.document.activeElement).toBe(copy);
  expect(first()!.closest("[aria-posinset]")?.getAttribute("aria-posinset")).toBe("1");
  expect(first()!.closest("[aria-posinset]")?.getAttribute("aria-setsize")).toBe("1000");
  expect(logins().length).toBeLessThanOrEqual(61);

  // The editor keeps its field (and what was typed) while the list scrolls away and back.
  const row = store.getSnapshot().passwords.find((login) => login.id === "p1")!;
  await act(async () => {
    scroller.scrollTop = 0;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  await act(async () => store.editUsername(row));
  const field = host.querySelector<HTMLInputElement>(".pw-username-input")!;
  field.value = "typed";
  await act(async () => {
    scroller.scrollTop = 20_000;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(field.isConnected).toBe(true);
  expect(field.value).toBe("typed");
});

/** Native Tab, as a test can have it: the next (or previous) element in the document's tab order.
 *  Every tab stop on this page has the default tab index, so that order is the DOM's. */
function tabStop(back = false): HTMLElement | undefined {
  const stops = [
    ...host.ownerDocument.querySelectorAll<HTMLElement>(
      "button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])",
    ),
  ];
  const at = stops.indexOf(host.ownerDocument.activeElement as HTMLElement);
  return stops[back ? at - 1 : at + 1];
}
const stopOf = (element: HTMLElement | undefined) =>
  element && `${element.closest<HTMLElement>("[data-key]")?.dataset.key}|${element.getAttribute("aria-label")}`;

async function scrollPage(scroller: HTMLElement, top: number) {
  await act(async () => {
    scroller.scrollTop = top;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

// A site is 96 px (its 32 px header and two logins, 30 and 34): login p980 is in the 490th site.
const NEAR_END = 490 * 96;

/** The logins scrolled near their end, login p980's `button` (0 Show Password .. 3 Delete) focused,
 *  and a wheel scroll back to the top (a wheel moves the list, not the focus). */
async function focusThenScrollAway(button: number) {
  const { scroller } = await mount(1_000);
  await scrollPage(scroller, NEAR_END);
  await act(async () => host.querySelectorAll<HTMLElement>('[data-key="login:p980"] .pw-row-button')[button]!.focus());
  await scrollPage(scroller, 0);
}

test("Tab from a focused login the list scrolled away from reaches the next login, as with every row mounted", async () => {
  await focusThenScrollAway(3);
  expect(stopOf(tabStop())).toBe("login:p981|Show Password");
});

test("Shift-Tab from a focused login the list scrolled away from reaches the login before it", async () => {
  await focusThenScrollAway(0);
  expect(stopOf(tabStop(true))).toBe("login:p979|Delete");
});

test("Tab from the sort menu into logins scrolled far down reaches the first login", async () => {
  const { scroller } = await mount(1_000);
  await scrollPage(scroller, 40_000);
  await act(async () => host.querySelector<HTMLElement>(".pw-search-row select")!.focus());
  expect(stopOf(tabStop())).toBe("login:p0|Show Password");
});

test("Shift-Tab from the first passkey into logins scrolled to the top reaches the last login", async () => {
  const { scroller } = await mount(1_000);
  await act(async () => host.querySelector<HTMLElement>("[data-key^='passkey:'] .pw-row-button")!.focus());
  await scrollPage(scroller, 0);
  expect(stopOf(tabStop(true))).toBe("login:p999|Delete");
});
