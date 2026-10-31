// Session reference hover cards (started/SessionHoverCard.tsx): a started chat's name chip and a
// session id in a reply show the session as a row of Claude Code's PR list does, the title over
// `Status · repo #N`, then its folder and branch, beside the chip (above it when more of the reply runs under
// it), after a short rest of the pointer, at once for keyboard focus, and a click on it opens it.
import { afterAll, beforeAll, describe, expect, jest, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { sessionEntry } from "../src/agent-session/acpmux/sessionList";
import {
  MIN_ID_MENTION,
  SessionHoverStore,
  hoverInfo,
  withSessionIds,
} from "../src/agent-session/acpmux/started/sessionHover";
import { SessionHoverContent, hoverCardSide } from "../src/agent-session/acpmux/started/SessionHoverCard";

const ID = "01a0ebd5-0efe-721d-9edc-cf1a6ba78d98";
const entry = (extra: Record<string, unknown> = {}) =>
  sessionEntry({
    sessionId: ID,
    title: "Switch gh-merge-green to merge-freeze issues",
    cwd: "/home/leo/cmux",
    ...extra,
  });

describe("hover info", () => {
  test("its status: needs input, failed, running, new activity or done", () => {
    const status = (extra: Record<string, unknown>) => hoverInfo(entry(extra)).status;
    expect(status({ indicator: "working" })).toBe("running");
    expect(status({ indicator: "input" })).toBe("waiting");
    expect(status({ indicator: "failed" })).toBe("failed");
    expect(status({ indicator: "lost" })).toBe("failed");
    expect(status({ indicator: "done", unread: true })).toBe("unread");
    expect(status({ indicator: "done" })).toBe("done");
  });

  test("the title, the status, then where it runs: its folder and branch", () => {
    expect(hoverInfo(entry({ updatedAt: 5 }))).toEqual({
      sessionId: ID,
      title: "Switch gh-merge-green to merge-freeze issues",
      status: "done",
      meta: ["cmux"],
    });
    expect(hoverInfo(entry({ branch: "merge-freeze" })).meta).toEqual(["cmux", "merge-freeze"]);
    expect(hoverInfo(entry({ host: "mini-7", hostKind: "cloud", branch: "main" })).meta).toEqual(["cmux", "mini-7"]);
    expect(hoverInfo(sessionEntry({ sessionId: ID, title: "No folder" })).meta).toBeUndefined();
  });

  test("a pull request's status leads, as on the chat's row", () => {
    const info = hoverInfo(
      entry({
        indicator: "working",
        pullRequests: ["https://github.com/manaflow-ai/cmux/pull/22092"],
        pullRequest: { number: 22092, title: "x", state: "open", checks: "failing" },
      }),
    );
    expect(info.status).toBe("failing");
    expect(info.pullRequests).toEqual({ count: 1, tone: "failing", number: 22092, repo: "cmux" });
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
    expect(store.get(ID)?.status).toBe("running");
    expect(told).toBe(2);
  });
});

describe("the card", () => {
  const info = { sessionId: ID, title: "Switch gh-merge-green to merge-freeze issues" };

  // Claude Code's PR list rows, then Claude desktop's card meta (Leo, 2026-10-20: "title, then the
  // status row, then meta"): the title, the status line (glyph and word in its colour, then
  // `· repo #N`), then the folder and branch in the muted caption. No age, no outline around the status.
  test("the title over the status line over the meta line", () => {
    const html = renderToStaticMarkup(
      <SessionHoverContent
        info={{
          ...info,
          status: "failing",
          pullRequests: { count: 1, tone: "failing", number: 22092, repo: "cmux" },
          meta: ["cmux", "merge-freeze"],
        }}
        onOpen={() => undefined}
      />,
    );
    expect(html).toMatch(
      /class="acpmux-session-hover-title">Switch gh-merge-green to merge-freeze issues<[^]*class="acpmux-session-status" data-status="failing"[^]*>Checks failed<[^]*>cmux #22092<[^]*class="acpmux-session-hover-meta">cmux · merge-freeze</,
    );
    expect(html).not.toContain("pill");
    expect(html).not.toContain("age");
  });

  test("without a folder there is no meta line", () => {
    const html = renderToStaticMarkup(
      <SessionHoverContent info={{ ...info, status: "done" }} onOpen={() => undefined} />,
    );
    expect(html).not.toContain("acpmux-session-hover-meta");
  });

  test("a running session's status draws the bare spinner", () => {
    const html = renderToStaticMarkup(
      <SessionHoverContent info={{ ...info, status: "running" }} onOpen={() => undefined} />,
    );
    expect(html).toContain("acpmux-session-status-spinner");
    expect(html).toContain(">Running<");
    expect(html).not.toContain("acpmux-session-status-pr");
  });

  test("done, new activity, needs input and failed each name their status", () => {
    const labels = { done: "Done", unread: "New activity", waiting: "Needs input", failed: "Failed" } as const;
    for (const [status, label] of Object.entries(labels)) {
      const html = renderToStaticMarkup(
        <SessionHoverContent info={{ ...info, status: status as keyof typeof labels }} onOpen={() => undefined} />,
      );
      expect(html).toContain(`data-status="${status}"`);
      expect(html).toContain(`>${label}<`);
    }
  });
});

describe("where the card goes", () => {
  const rect = (top: number, bottom: number) => ({ top, bottom, left: 0, right: 0, width: 0, height: bottom - top });
  const place = (chip: [number, number], block: [number, number] | undefined) => {
    const parent = block ? { getBoundingClientRect: () => rect(...block) } : null;
    const anchor = { closest: () => parent, getBoundingClientRect: () => rect(...chip) } as unknown as Element;
    return hoverCardSide(anchor);
  };

  test("below a chip on the last line of its paragraph; above one with more of the reply under it", () => {
    expect(place([40, 60], [0, 60])).toBe("bottom");
    expect(place([20, 40], [0, 60])).toBe("top");
    expect(place([20, 40], undefined)).toBe("bottom");
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
  // A fake clock: the delays are the behavior, so they run exactly, never on a busy runner's wall clock.
  jest.useFakeTimers();
  const wait = (ms: number) => void jest.advanceTimersByTime(ms);
  try {
    // The pointer passing over: nothing until the delay has passed; then the card.
    await act(async () => {
      pointer("pointerover");
      pointer("pointerenter");
      wait(SESSION_HOVER_DELAY - 1);
    });
    expect(card()).toBeNull();
    await act(async () => wait(1));
    expect(card()?.getAttribute("role")).toBe("dialog");
    expect(card()?.getAttribute("aria-label")).toBe("Switch gh-merge-green to merge-freeze issues");
    expect(card()?.textContent).toBe("Switch gh-merge-green to merge-freeze issuesRunningcmux");
    expect(chip.getAttribute("aria-describedby")).toBe(card()?.id ?? "missing");

    // Pointer away: the card goes after its grace.
    await act(async () => {
      pointer("pointerout");
      pointer("pointerleave");
      wait(400);
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
      wait(400);
    });
    expect(card()).not.toBeNull();
    expect(dom.window.document.activeElement).toBe(inside);
    // One Escape closes the card and hands focus back; the refocus does not show it again.
    await act(async () => {
      inside.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
      wait(400);
    });
    expect(dom.window.document.activeElement).toBe(chip);
    expect(card()).toBeNull();
    expect(chip.hasAttribute("aria-describedby")).toBe(false);

    // A click on the card opens the session.
    await act(async () => {
      chip.blur();
      wait(400);
      chip.focus();
    });
    await act(async () => card()!.querySelector<HTMLButtonElement>(".acpmux-session-hover")!.click());
    expect(opened).toEqual([ID]);
  } finally {
    jest.useRealTimers();
  }
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
