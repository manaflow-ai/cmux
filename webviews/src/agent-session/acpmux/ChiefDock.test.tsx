// l10n-allow-file: test fixture titles, not shipped UI.
// The Chief Dock from the keyboard and to assistive technology: folded, its cards take no Tab
// stop; every control says what it does; Escape folds it; the badge counts every chat that
// waits, not only the four it draws.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ChiefDock } from "./ChiefDock";
import type { AcpmuxSessionEntry } from "./sessionList";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "KeyboardEvent",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  globalThis.__cmuxPaneStrings = {
    en: {
      "header.agentChat": "Agent Chat",
      "floating.moveToTab": "Move to tab",
      "floating.keepOnTop": "Keep on top",
      "sidebar.newChat": "New chat",
      "sidebar.noSessions": "No chats yet",
      "sidebar.sessions": "Chats",
      "render.collapse": "Collapse",
      "render.expand": "Expand",
      "chiefDock.detach": "Detach",
    },
  };
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
    });
  root = undefined;
  dom?.window.close();
  dom = undefined;
  delete globalThis.__cmuxPaneStrings;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const chat = (sessionId: string, fields: Partial<AcpmuxSessionEntry> = {}): AcpmuxSessionEntry => ({
  sessionId,
  title: sessionId,
  status: "idle",
  updatedAt: 1,
  ...fields,
});

async function render(sessions: AcpmuxSessionEntry[], defaultExpanded = false): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ChiefDock
        sessions={sessions}
        defaultExpanded={defaultExpanded}
        onSelect={() => {}}
        onNewChat={() => {}}
        onMoveToTab={() => {}}
      />,
    );
  });
  return container.querySelector<HTMLElement>(".acpmux-chief-dock")!;
}

/** Buttons a Tab press can reach: not disabled and not inside an inert subtree. */
const tabStops = (dock: HTMLElement) =>
  [...dock.querySelectorAll<HTMLButtonElement>("button")].filter(
    (button) => !button.disabled && !button.closest("[inert]"),
  );

test("a remote session card puts the session name before its secondary machine", async () => {
  const dock = await render(
    [chat("remote", { name: "gcp-codex-lane-10/pr-row", peer: "gcp-codex-lane-10", harness: "codex" })],
    true,
  );
  const identity = dock.querySelector(".acpmux-sender");
  expect(identity?.querySelector(".acpmux-sender__name")?.textContent).toBe("pr-row");
  expect(identity?.querySelector(".acpmux-sender__host")?.textContent).toBe("gcp-codex-lane-10");
  expect(identity?.textContent).toBe("pr-rowgcp-codex-lane-10");
});

const label = (button: Element) => button.getAttribute("aria-label");

test("folded, the cards behind the mascot take no Tab stop", async () => {
  const dock = await render([chat("a", { indicator: "working" }), chat("b"), chat("c")]);
  const stops = tabStops(dock);
  expect(stops.every((button) => !button.closest(".acpmux-chief-dock-cards"))).toBe(true);
  expect(dock.querySelector(".acpmux-chief-dock-cards")!.hasAttribute("inert")).toBe(true);
});

test("unfolded, the cards and their actions take Tab stops again", async () => {
  const dock = await render([chat("a"), chat("b")], true);
  expect(dock.querySelector(".acpmux-chief-dock-cards")!.hasAttribute("inert")).toBe(false);
  expect(tabStops(dock).some((button) => button.closest(".acpmux-chief-dock-cards"))).toBe(true);
});

test("each rail control names what it does, and no two share a name", async () => {
  const dock = await render([chat("a")]);
  const rail = [...dock.querySelectorAll(".acpmux-chief-dock-rail button")];
  expect(rail.map(label)).toEqual(["New chat", "Detach", "Expand"]);
  expect(rail[1]!.getAttribute("aria-pressed")).toBe("false");
  await act(async () => (rail[1] as HTMLButtonElement).click());
  expect(label(rail[1]!)).toBe("Detach");
  expect(rail[1]!.getAttribute("aria-pressed")).toBe("true");
  await act(async () => (rail[2] as HTMLButtonElement).click());
  expect(label(rail[2]!)).toBe("Collapse");
  expect(rail[2]!.getAttribute("aria-expanded")).toBe("true");
});

test("a card's close button says it folds the dock", async () => {
  const dock = await render([chat("a")], true);
  const close = dock.querySelector(".acpmux-chief-card-dismiss")!;
  expect(label(close)).toBe("Collapse");
});

test("Escape folds the open dock and leaves focus on the mascot", async () => {
  const dock = await render([chat("a"), chat("b")], true);
  const card = dock.querySelector<HTMLButtonElement>(".acpmux-chief-card-main")!;
  card.focus();
  await act(async () => {
    card.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  });
  expect(dock.dataset.expanded).toBe("false");
  expect(dock.ownerDocument.activeElement).toBe(dock.querySelector(".acpmux-chief-dock-mascot"));
});

test("a card's close pressed from the keyboard leaves focus on the mascot, not the page", async () => {
  const dock = await render([chat("a")], true);
  const close = dock.querySelector<HTMLButtonElement>(".acpmux-chief-card-dismiss")!;
  close.focus();
  await act(async () => close.click());
  expect(dock.dataset.expanded).toBe("false");
  expect(dock.ownerDocument.activeElement).toBe(dock.querySelector(".acpmux-chief-dock-mascot"));
});

test("a modified Escape does not fold the dock", async () => {
  const dock = await render([chat("a")], true);
  const card = dock.querySelector<HTMLButtonElement>(".acpmux-chief-card-main")!;
  const event = new KeyboardEvent("keydown", { key: "Escape", metaKey: true, bubbles: true, cancelable: true });
  await act(async () => {
    card.dispatchEvent(event);
  });
  expect(dock.dataset.expanded).toBe("true");
  expect(event.defaultPrevented).toBe(false);
});

test("Escape on a folded dock is left for the window", async () => {
  const dock = await render([chat("a")]);
  const mascot = dock.querySelector<HTMLButtonElement>(".acpmux-chief-dock-mascot")!;
  const event = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
  await act(async () => {
    mascot.dispatchEvent(event);
  });
  expect(event.defaultPrevented).toBe(false);
});

test("the badge counts every chat that waits, not only the four cards drawn", async () => {
  const waiting = [1, 2, 3, 4, 5].map((n) => chat(`wait-${n}`, { indicator: "input", updatedAt: n }));
  const dock = await render([...waiting, chat("quiet")]);
  expect(dock.querySelectorAll(".acpmux-chief-card")).toHaveLength(4);
  expect(dock.querySelector(".acpmux-chief-dock-badge")!.textContent).toBe("5");
});
