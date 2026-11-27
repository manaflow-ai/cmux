// l10n-allow-file: test fixture chat names, asks and errors, not shipped UI.
// The agent status island in a page (statusIsland/StatusIsland.tsx): a press on the pill or the
// card's collapse button swaps the island's content, and focus goes to the control in its place
// (the collapse button, the pill), never to the page's body and never to Allow. A failure the person
// folded that clears and comes back opens its card again, even under the same key. A command shows
// whole above Allow.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

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
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
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
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { StatusIsland } = await import("../src/agent-session/acpmux/statusIsland/StatusIsland");
const { islandState } = await import("../src/agent-session/acpmux/statusIsland/model");
const { needsYouItems } = await import("../src/agent-session/acpmux/needsYou/model");
type Session = import("../src/agent-session/acpmux/sessionList").AcpmuxSessionEntry;
type Ask = import("../src/agent-session/acpmux/needsYou/model").WatchedAsk;

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
afterAll(async () => {
  act(() => root.unmount());
  await teardownDom(saved, { window: dom.window, scope });
});

const actions = { answer: async () => undefined, goTo: () => undefined, openSession: () => undefined };
const chat = (sessionId: string, fields: Partial<Session> = {}): Session => ({
  sessionId,
  title: sessionId,
  harness: "claude",
  ...fields,
});
const longCommand = `bun run lint && ${"echo step && ".repeat(30)}rm -rf ./dist`;
const ask: Ask = {
  sessionId: "Tab strip review",
  at: 2_000,
  permission: {
    permissionId: "p1",
    title: "Run the linter",
    command: longCommand,
    pending: true,
    options: [
      { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
      { id: "reject_once", name: "Deny", kind: "reject_once", allow: false },
    ],
  },
};
type Actions = import("../src/agent-session/acpmux/statusIsland/StatusIsland").StatusIslandActions;
const render = async (sessions: Session[], asks: Ask[] = [], use: Actions = actions) =>
  act(async () =>
    root.render(
      <StatusIsland state={islandState({ sessions, items: needsYouItems({ sessions, asks }), asks })} actions={use} />,
    ),
  );
const q = (selector: string) => host.querySelector<HTMLElement>(selector);
const click = async (element: HTMLElement | null) =>
  act(async () => {
    element!.click();
  });

test("a press hands focus to the control in the pressed one's place, never to the body or Allow", async () => {
  await render([chat("Tab strip review")], [ask]);
  // The ask opened the card by itself: focus stays where it was.
  expect(q(".acpmux-status-island[data-expanded]")).not.toBeNull();
  expect(dom.window.document.activeElement).toBe(dom.window.document.body);

  q(".acpmux-status-island__collapse")!.focus();
  await click(q(".acpmux-status-island__collapse"));
  expect(q(".acpmux-status-island[data-expanded]")).toBeNull();
  expect(dom.window.document.activeElement).toBe(q(".acpmux-status-island__pill"));

  await click(q(".acpmux-status-island__pill"));
  expect(q(".acpmux-status-island[data-expanded]")).not.toBeNull();
  expect(dom.window.document.activeElement).toBe(q(".acpmux-status-island__collapse"));
  expect(dom.window.document.activeElement?.textContent).not.toBe("Allow");
});

test("the whole command shows above Allow", async () => {
  await render([chat("Tab strip review")], [ask]);
  const detail = q(".acpmux-status-island__detail[data-command]");
  expect(detail?.textContent).toBe(longCommand);
});

test("a folded failure that clears and comes back opens again, even under the same key", async () => {
  const failing = chat("Port the sheet", { indicator: "failed", laneError: "out of context", activityAt: 5 });
  await render([failing]);
  expect(q(".acpmux-status-island[data-expanded]")).not.toBeNull();
  await click(q(".acpmux-status-island__collapse"));
  expect(q(".acpmux-status-island[data-expanded]")).toBeNull();

  // Still failed: it stays folded.
  await render([failing]);
  expect(q(".acpmux-status-island[data-expanded]")).toBeNull();

  // It recovers and runs, then fails again (here with the same activityAt, the worst case).
  await render([chat("Port the sheet", { indicator: "working", activityAt: 5 })]);
  await render([failing]);
  expect(q(".acpmux-status-island[data-expanded]")).not.toBeNull();
});

test("a question's four long choices stack one per row, each a wrapping button", async () => {
  const labels = [
    "OAuth through the existing identity provider, with the current scopes",
    "Passkeys only, with a recovery code printed once at setup",
    "Both: passkeys first, OAuth behind a Use another way link",
    "Neither yet: keep the email link until the security review lands",
  ];
  const question = {
    id: "ask-auth",
    source: { harness: "codex", session: "auth", permission: "ask-auth", answerOption: "allow_once" },
    items: [
      {
        id: "q0",
        header: "Auth",
        prompt: "Which sign-in first?",
        options: labels.map((label, i) => ({ id: `o${i}`, label })),
        multiSelect: false,
        allowsOther: false,
      },
    ],
    state: { kind: "pending" },
  } as const;
  await render(
    [chat("auth")],
    [
      {
        sessionId: "auth",
        at: 2_000,
        permission: { permissionId: "ask-auth", pending: true, options: ask.permission.options, question },
      } as unknown as Ask,
    ],
  );
  const row = q(".acpmux-status-island__actions");
  expect(row?.hasAttribute("data-choices")).toBe(true);
  expect([...row!.querySelectorAll("button")].map((button) => button.textContent)).toEqual(labels);
});

test("the island's morph obeys Reduce Motion and the motion gate (Calm Mode and Off)", async () => {
  const css = await Bun.file(
    new URL("../src/agent-session/acpmux/statusIsland/statusIsland.css", import.meta.url),
  ).text();
  const gate = ':root:is([data-cmux-motion="off"], [data-cmux-motion="reduced"])';
  expect(css).toContain("@media (prefers-reduced-motion: reduce)");
  expect(css).toMatch(
    new RegExp(`${gate.replace(/[[\]()"=:.]/g, "\\$&")} \\.acpmux-status-island \\{\\s*transition: none;`),
  );
  expect(css).toMatch(
    new RegExp(`${gate.replace(/[[\]()"=:.]/g, "\\$&")} \\.acpmux-status-island__content \\{\\s*animation: none;`),
  );
  // Choices wrap: the row may wrap, and a choice's label is not held on one line.
  expect(css).toMatch(/\.acpmux-status-island__actions \{[^}]*flex-wrap: wrap;/);
  expect(css).toMatch(
    /\.acpmux-status-island__actions\[data-choices\] \.acpmux-status-island__action \{[^}]*white-space: normal;/,
  );
});

const options = ask.permission.options;
const askOf = (permissionId: string, permission: Partial<Ask["permission"]>, at = 2_000): Ask => ({
  sessionId: "Tab strip review",
  at,
  permission: { permissionId, pending: true, options, ...permission },
});
const allow = () =>
  [...host.querySelectorAll<HTMLElement>(".acpmux-status-island__action")].find((b) => b.textContent === "Allow")!;

test("F1: a newer request that lands mid-press gets fresh buttons; the old press sends nothing", async () => {
  const sent: string[] = [];
  const recording: Actions = {
    ...actions,
    answer: async (item) => {
      sent.push(item.permissionId ?? "");
    },
  };
  const first = askOf("p-old", { title: "Run the linter", command: "bun run lint" });
  await render([chat("Tab strip review")], [first], recording);
  const pressed = allow();
  pressed.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true }));
  // Between press and release, the old ask is answered elsewhere and a newer one takes its place.
  const second = askOf("p-new", { title: "Run the deploy", command: "bun run deploy:prod" }, 3_000);
  await render([chat("Tab strip review")], [second], recording);
  expect(pressed.isConnected).toBe(false);
  expect(allow()).not.toBe(pressed);
  await click(pressed);
  expect(sent).toEqual([]);
  // The new request's own button answers the new request.
  await click(allow());
  expect(sent).toEqual(["p-new"]);
});

test("F2: a command carried only in an execute request's title shows whole above Allow", async () => {
  const titleOnly = askOf("p-title", { kind: "execute", title: `Run ${longCommand}` });
  await render([chat("Tab strip review")], [titleOnly]);
  expect(q(".acpmux-status-island__detail[data-command]")?.textContent).toBe(longCommand);
  expect(q(".acpmux-status-island__ask")?.textContent).toBe("Run command");
});

test("F2: a command identical to the title (Needs you drops its detail) still shows whole", async () => {
  const same = askOf("p-same", { title: longCommand, command: longCommand });
  await render([chat("Tab strip review")], [same]);
  expect(q(".acpmux-status-island__detail[data-command]")?.textContent).toBe(longCommand);
  expect(q(".acpmux-status-island__ask")?.textContent).toBe("Run command");
});

test("F4: Escape in an empty composer folds an auto-opened card and never reaches a Deny", async () => {
  const doc = dom.window.document;
  const composer = doc.createElement("div");
  composer.className = "acpmux-composer-prompt";
  const field = doc.createElement("div");
  field.className = "acpmux-md-root";
  field.tabIndex = 0;
  composer.append(field);
  doc.body.append(composer);
  // The permission card's own key handler: document capture, ignores a prevented key.
  const denied: string[] = [];
  const card = (event: KeyboardEvent) => {
    if (!event.defaultPrevented && event.key === "Escape") denied.push("deny");
  };
  doc.addEventListener("keydown", card, true);
  try {
    field.focus();
    await render([chat("Tab strip review")], [askOf("p-esc", { title: "Run the linter", command: "bun run lint" })]);
    expect(q(".acpmux-status-island[data-expanded]")).not.toBeNull();
    expect(doc.activeElement).toBe(field);
    await act(async () => {
      field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    });
    expect(denied).toEqual([]);
    expect(q(".acpmux-status-island[data-expanded]")).toBeNull();
    // The composer keeps the keyboard.
    expect(doc.activeElement).toBe(field);
    // With a draft, the composer owns its Escape: the island leaves it alone.
    await render([chat("Tab strip review")], [askOf("p-esc2", { title: "Run the tests", command: "bun test" })]);
    field.textContent = "half a prompt";
    await act(async () => {
      field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    });
    expect(q(".acpmux-status-island[data-expanded]")).not.toBeNull();
  } finally {
    doc.removeEventListener("keydown", card, true);
    composer.remove();
  }
});

test("F3: Open Chat shows only where the host can go", async () => {
  const failing = chat("Port the sheet", { indicator: "failed", laneError: "out of context", activityAt: 9 });
  await render([failing], [], { ...actions, canOpen: () => false });
  expect(q(".acpmux-status-island[data-expanded]")).not.toBeNull();
  expect(host.textContent).not.toContain("Open Chat");
  await render([failing], [], { ...actions, canOpen: () => true });
  expect(host.textContent).toContain("Open Chat");
});

test("review r2 F1: an ask with no one-click answer offers Open Chat only where it can go", async () => {
  // Another computer's chat waiting on the person: an `input` item with no answers, which goTo
  // cannot open (useNeedsYou's openElsewhere skips a peer).
  const peer = chat("Release notes", { peer: "studio", indicator: "input" });
  const local = chat("Tab strip review", { indicator: "input" });
  const went: string[] = [];
  const asApp = (sessions: Session[]): Actions => ({
    ...actions,
    goTo: (item) => {
      went.push(item.sessionId);
    },
    canOpen: (sessionId) => !sessions.some((entry) => entry.sessionId === sessionId && entry.peer),
  });
  await render([peer], [], asApp([peer]));
  expect(q(".acpmux-status-island[data-expanded]")).not.toBeNull();
  expect(q(".acpmux-status-island__ask")).not.toBeNull();
  expect(host.textContent).not.toContain("Open Chat");
  expect(q(".acpmux-status-island__actions")).toBeNull();

  // A chat on this computer still opens at its source.
  await render([local], [], asApp([local]));
  expect(host.textContent).toContain("Open Chat");
  await click(
    [...host.querySelectorAll<HTMLElement>(".acpmux-status-island__action")].find(
      (b) => b.textContent === "Open Chat",
    )!,
  );
  expect(went).toEqual(["Tab strip review"]);
});

test("review r2 F2: the card stops at the pane's foot and scrolls, so every answer stays reachable", async () => {
  const css = await Bun.file(
    new URL("../src/agent-session/acpmux/statusIsland/statusIsland.css", import.meta.url),
  ).text();
  const card = css.match(/\.acpmux-status-island__card \{([^}]*)\}/)?.[1] ?? "";
  expect(card).toContain("max-height: calc(var(--acpmux-status-island-room, 100vh) - var(--ds-space-3));");
  expect(card).toContain("overflow-y: auto;");
  // Its rows keep their height under the cap, so the ask line scrolls rather than shrinks away.
  expect(css).toMatch(/\.acpmux-status-island__card > \* \{\s*flex-shrink: 0;\s*\}/);

  // The island measures the room under its top in the pane it floats over (its offset parent).
  const proto = dom.window.HTMLElement.prototype;
  const shell = dom.window.document.createElement("div");
  const keep = ["offsetParent", "offsetTop", "clientHeight"].map(
    (key) => [key, Object.getOwnPropertyDescriptor(proto, key)] as const,
  );
  Object.defineProperty(proto, "offsetParent", { configurable: true, get: () => shell });
  Object.defineProperty(proto, "offsetTop", { configurable: true, get: () => 40 });
  Object.defineProperty(proto, "clientHeight", { configurable: true, get: () => 220 });
  try {
    await act(async () => root.render(<></>));
    await render([chat("Tab strip review")], [ask]);
    const island = q(".acpmux-status-island")!;
    expect(island.style.getPropertyValue("--acpmux-status-island-room")).toBe("180px");
  } finally {
    for (const [key, descriptor] of keep)
      if (descriptor) Object.defineProperty(proto, key, descriptor);
      else delete (proto as unknown as Record<string, unknown>)[key];
  }
});
