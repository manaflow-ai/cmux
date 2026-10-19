// Session reference hover cards (started/SessionHoverCard.tsx): a started chat's card, its name
// chip and a session id in a reply show the session's state pill, project, age and title after a
// short rest of the pointer, at once for keyboard focus, and a click on the card opens it.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { sessionEntry } from "../src/agent-session/acpmux/sessionList";
import {
  MIN_ID_MENTION,
  SessionHoverStore,
  hoverInfo,
  hoverState,
  withSessionIds,
} from "../src/agent-session/acpmux/started/sessionHover";
import { SessionHoverContent, SessionStatePill } from "../src/agent-session/acpmux/started/SessionHoverCard";

const ID = "01a0ebd5-0efe-721d-9edc-cf1a6ba78d98";
const entry = (extra: Record<string, unknown> = {}) =>
  sessionEntry({
    sessionId: ID,
    title: "Switch gh-merge-green to merge-freeze issues",
    cwd: "/home/leo/cmux",
    ...extra,
  });

describe("hover state", () => {
  test("running, needs input, failed, unread and done", () => {
    expect(hoverState(entry({ indicator: "working" }))).toBe("running");
    expect(hoverState(entry({ indicator: "input" }))).toBe("waiting");
    expect(hoverState(entry({ indicator: "failed" }))).toBe("failed");
    expect(hoverState(entry({ indicator: "lost" }))).toBe("failed");
    expect(hoverState(entry({ indicator: "done", unread: true }))).toBe("unread");
    expect(hoverState(entry({ indicator: "done" }))).toBe("done");
  });

  test("the card names the project folder and the last change", () => {
    expect(hoverInfo(entry({ updatedAt: 5 }))).toEqual({
      sessionId: ID,
      title: "Switch gh-merge-green to merge-freeze issues",
      state: "done",
      project: "cmux",
      updatedAt: 5,
    });
  });
});

describe("session ids in replies", () => {
  test("every listed session but the open chat, by its full id, after the started chats' own mentions", () => {
    const other = "01a0ebd5-0efe-721d-9edc-000000000002";
    const child = {
      text: "Fix the sidebar test",
      sessionId: "child-1",
      title: "Fix the sidebar test",
      state: "idle" as const,
    };
    const mentions = withSessionIds(
      [child],
      [
        entry(),
        sessionEntry({ sessionId: other, title: "Other" }),
        sessionEntry({ sessionId: "short-1", title: "Short" }),
        sessionEntry({ sessionId: "01a0ebd5-0efe-721d-9edc-000000000003", tags: { archived: "1" } }),
      ],
      ID,
    );
    expect(mentions.map((mention) => mention.text)).toEqual([other, "Fix the sidebar test"]);
    expect("short-1".length).toBeLessThan(MIN_ID_MENTION);
  });

  test("a started chat already named by its id is not named twice", () => {
    const mine = { text: ID, sessionId: ID, title: "Mine", state: "running" as const };
    expect(withSessionIds([mine], [entry()], "parent").filter((mention) => mention.text === ID)).toHaveLength(1);
  });
});

describe("SessionHoverStore", () => {
  test("keeps an unchanged card's object and tells listeners only of a change", () => {
    const store = new SessionHoverStore();
    let told = 0;
    store.subscribe(() => (told += 1));
    store.set([entry()]);
    const first = store.get(ID);
    store.set([entry()]);
    expect(store.get(ID)).toBe(first!);
    expect(told).toBe(1);
    store.set([entry({ indicator: "working" })]);
    expect(store.get(ID)?.state).toBe("running");
    expect(told).toBe(2);
  });
});

describe("the card", () => {
  const info = {
    sessionId: ID,
    title: "Switch gh-merge-green to merge-freeze issues",
    project: "cmux",
    updatedAt: 1_000,
  };

  test("a running session's pill draws the bare spinner, with no fill behind it", () => {
    const html = renderToStaticMarkup(
      <SessionHoverContent info={{ ...info, state: "running" }} now={1_000} onOpen={() => undefined} />,
    );
    expect(html).toContain('data-state="running"');
    expect(html).toContain("acpmux-session-pill-spinner");
    expect(html).toContain(">Running<");
    expect(html).toContain(">cmux<");
    expect(html).toContain(">now<");
    expect(html).toContain("Switch gh-merge-green to merge-freeze issues");
  });

  test("unread, needs input, done and failed each name their state with their glyph", () => {
    const labels = { unread: "New activity", waiting: "Needs input", done: "Done", failed: "Failed" } as const;
    for (const [state, label] of Object.entries(labels)) {
      const html = renderToStaticMarkup(<SessionStatePill state={state as keyof typeof labels} />);
      expect(html).toContain(`data-state="${state}"`);
      expect(html).toContain(label);
      expect(html).not.toContain("acpmux-session-pill-spinner");
    }
  });
});

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle,
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

test("a name chip's card waits for the pointer, shows at once for focus, takes ArrowDown and Escape, and opens on click", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { StartedSessionChip } = await import("../src/agent-session/acpmux/started/StartedSessionCard");
  const { SessionHoverContext, SESSION_HOVER_DELAY } =
    await import("../src/agent-session/acpmux/started/SessionHoverCard");
  const rootElement = dom.window.document.getElementById("root")!;
  const root = createRoot(rootElement);
  const store = new SessionHoverStore();
  store.set([entry({ indicator: "working", updatedAt: Date.now() })]);
  const opened: string[] = [];
  const mention = { text: ID, sessionId: ID, title: "Switch", state: "running" as const };
  await act(async () => {
    root.render(
      <UiProvider container={rootElement}>
        <SessionHoverContext.Provider value={{ store, open: (id) => opened.push(id) }}>
          <p>
            See <StartedSessionChip mention={mention} text={ID} onOpen={() => undefined} />.
          </p>
        </SessionHoverContext.Provider>
      </UiProvider>,
    );
  });
  const chip = rootElement.querySelector<HTMLButtonElement>(".acpmux-started-chip")!;
  const card = () => rootElement.querySelector<HTMLElement>(".acpmux-session-hover-card");
  const pointer = (type: string) => chip.dispatchEvent(new dom.window.PointerEvent(type, { bubbles: true }));

  // The pointer passing over: nothing yet; resting past the delay: the card.
  await act(async () => {
    pointer("pointerover");
    pointer("pointerenter");
    await wait(SESSION_HOVER_DELAY / 3);
  });
  expect(card()).toBeNull();
  await act(async () => wait(SESSION_HOVER_DELAY));
  expect(card()?.getAttribute("role")).toBe("dialog");
  expect(card()?.getAttribute("aria-label")).toBe("Switch gh-merge-green to merge-freeze issues");
  expect(card()?.textContent).toContain("Running");
  expect(card()?.textContent).toContain("cmux");
  expect(chip.getAttribute("aria-describedby")).toBe(card()?.id ?? "missing");

  // Pointer away: the card goes after its grace.
  await act(async () => {
    pointer("pointerout");
    pointer("pointerleave");
    await wait(400);
  });
  expect(card()).toBeNull();

  // Keyboard: focus shows it at once, ArrowDown moves into it, Escape hands focus back.
  await act(async () => chip.focus());
  expect(card()).not.toBeNull();
  await act(async () => {
    chip.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
  });
  const inside = card()!.querySelector<HTMLButtonElement>(".acpmux-session-hover")!;
  expect(dom.window.document.activeElement).toBe(inside);
  // The pointer drifting off while focus is in the card keeps it.
  await act(async () => {
    pointer("pointerover");
    pointer("pointerenter");
    pointer("pointerout");
    pointer("pointerleave");
    await wait(400);
  });
  expect(card()).not.toBeNull();
  expect(dom.window.document.activeElement).toBe(inside);
  // One Escape closes the card and hands focus back; the refocus does not show it again.
  await act(async () => {
    inside.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    await wait(400);
  });
  expect(dom.window.document.activeElement).toBe(chip);
  expect(card()).toBeNull();
  expect(chip.hasAttribute("aria-describedby")).toBe(false);

  // A click on the card opens the session.
  await act(async () => {
    chip.blur();
    await wait(400);
    chip.focus();
  });
  await act(async () => card()!.querySelector<HTMLButtonElement>(".acpmux-session-hover")!.click());
  expect(opened).toEqual([ID]);
  await act(async () => root.unmount());
});

test("without a hover store a chip draws no card", async () => {
  const { StartedSessionChip } = await import("../src/agent-session/acpmux/started/StartedSessionCard");
  const html = renderToStaticMarkup(
    <StartedSessionChip
      mention={{ text: ID, sessionId: ID, title: "Switch", state: "idle" }}
      text={ID}
      onOpen={() => undefined}
    />,
  );
  expect(html).not.toContain("acpmux-session-hover");
});
