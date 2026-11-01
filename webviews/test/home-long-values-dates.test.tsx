// l10n-allow-file: test fixture chat names and paths, not shipped UI.
// Home and New Tab keep long values readable and older dates absolute (#28079):
// - A row's ages stay relative for under a week, then read as a localized date, so "3mo ago" or
//   "45d" never stands in for a date the person has to work out.
// - A cut title, project, ask or where-line carries its whole value as a tooltip, on Home's lists
//   and New Tab's All chats, live chats at the top included.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  localStorage: dom.window.localStorage,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent|Event)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
// TanStack Virtual sizes the list from layout, which JSDOM lacks: give every element a viewport.
dom.window.HTMLElement.prototype.getBoundingClientRect = () =>
  ({ top: 0, left: 0, right: 600, bottom: 800, width: 600, height: 800, x: 0, y: 0, toJSON() {} }) as DOMRect;
Object.defineProperty(dom.window.HTMLElement.prototype, "offsetHeight", { configurable: true, get: () => 800 });
Object.defineProperty(dom.window.HTMLElement.prototype, "offsetWidth", { configurable: true, get: () => 600 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
const { HomeLists, age } = await import("../src/agent-session/acpmux/HomeLists");
const { ageLabel } = await import("../src/agent-session/acpmux/NewTabPage");
const { session } = await import("../src/gallery/fixtures/acpmux");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const document = dom.window.document;
const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const DAY = 24 * 60 * 60_000;
const NOW = Date.UTC(2026, 9, 31, 12);
const dateOf = (at: number) => new Intl.DateTimeFormat("en", { dateStyle: "medium" }).format(new Date(at));

test("ages stay relative under a week and read as a localized date from seven days on", () => {
  expect(age(NOW - 3 * 60_000, NOW)).toBe("3m ago");
  expect(age(NOW - 6 * DAY, NOW)).toBe("6d ago");
  expect(ageLabel(NOW - 6 * DAY, NOW)).toBe("6d");
  for (const days of [7, 45, 400]) {
    const at = NOW - days * DAY;
    expect(age(at, NOW)).toBe(dateOf(at));
    expect(ageLabel(at, NOW)).toBe(dateOf(at));
  }
  expect(age(undefined, NOW)).toBeUndefined();
  expect(ageLabel(undefined, NOW)).toBe("");
});

const LONG_TITLE = "Refactor the payment reconciliation worker so retries never double-charge a customer";
const LONG_CWD = "/Users/sample/projects/atlas-web-payments-reconciliation-service";

test("All chats gives every cut title its whole text, the live chats at the top included", async () => {
  const root = createRoot(document.getElementById("root")!);
  const load = async () => ({
    chats: [{ key: "old", harness: "claude", title: "Indexed " + LONG_TITLE, cwd: LONG_CWD, updatedAt: 1 }],
    ready: true,
  });
  const active = [
    { id: "s-run", title: "Live " + LONG_TITLE, harness: "claude", state: "running" as const, label: "Working" },
  ];
  await act(async () => root.render(<AllChatsList load={load} onOpen={() => {}} active={active} now={10} />));
  await settle();
  const live = document.querySelector(".nt-all-active .nt-all-title");
  expect(live?.textContent).toBe("Live " + LONG_TITLE);
  expect(live?.getAttribute("title")).toBe("Live " + LONG_TITLE);
  const indexed = [...document.querySelectorAll(".nt-all-title")].find((title) =>
    title.textContent?.startsWith("Indexed"),
  );
  expect(indexed?.getAttribute("title")).toBe("Indexed " + LONG_TITLE);
  expect(document.querySelector(".nt-all-project")?.getAttribute("title")).toBe(LONG_CWD);
  await act(async () => root.unmount());
});

test("Home's rows give a cut title and project their whole value", async () => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const sessions = [
    session({ sessionId: "home", updatedAt: NOW }),
    session({
      sessionId: "long",
      title: "Payments",
      cwd: LONG_CWD,
      updatedAt: NOW - 8 * DAY,
      pullRequest: { number: 19031, title: LONG_TITLE, state: "open", reviewReady: true },
    }),
  ];
  await act(async () =>
    root.render(
      <HomeLists sessions={sessions} currentId="home" onSelect={() => {}} onAnswer={async () => "answered"} />,
    ),
  );
  const title = [...host.querySelectorAll(".acpmux-home-title")].find((node) => node.textContent === LONG_TITLE);
  expect(title).toBeDefined();
  expect(title!.getAttribute("title")).toBe(LONG_TITLE);
  const metas = [...title!.parentElement!.querySelectorAll(".acpmux-home-meta")];
  expect(metas.some((meta) => meta.getAttribute("title") === LONG_CWD)).toBe(true);
  await act(async () => root.unmount());
  host.remove();
});

test("Home's folder name cuts with an ellipsis instead of pushing the age and chevron off the row", async () => {
  // JSDOM has no layout: check that the folder span is the shrinkable, ellipsized one. The gallery's
  // agent-pane.home-lists#long-values state shows the row itself.
  const css = await Bun.file(new URL("../src/agent-session/acpmux/styles.css", import.meta.url)).text();
  const rule = css.match(/\.acpmux-home-project\{([^}]*)\}/)?.[1] ?? "";
  for (const declaration of ["min-width:0", "overflow:hidden", "text-overflow:ellipsis", "white-space:nowrap"])
    expect(rule).toContain(declaration);
  expect(rule).not.toContain("flex:none");

  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const sessions = [
    session({ sessionId: "home", updatedAt: NOW }),
    session({
      sessionId: "long",
      title: "Payments",
      cwd: LONG_CWD,
      updatedAt: NOW,
      pullRequest: { number: 19031, title: "Retry", state: "open", reviewReady: true },
    }),
  ];
  await act(async () =>
    root.render(
      <HomeLists sessions={sessions} currentId="home" onSelect={() => {}} onAnswer={async () => "answered"} />,
    ),
  );
  expect(host.querySelector(".acpmux-home-project")?.getAttribute("title")).toBe(LONG_CWD);
  await act(async () => root.unmount());
  host.remove();
});

test("New Tab's relative ages keep rounding to the nearest minute, as before the date switch", () => {
  // Base's ageLabel rounded: a chat 59.9 s old read "1m", 90 s read "2m". The date switch must not
  // turn those into "now" and "1m".
  expect(ageLabel(NOW - 59_900, NOW)).toBe("1m");
  expect(ageLabel(NOW - 90_000, NOW)).toBe("2m");
  expect(ageLabel(NOW - 20_000, NOW)).toBe("now");
  // Home's age floors, as it always did.
  expect(age(NOW - 59_900, NOW)).toBe("now");
});
