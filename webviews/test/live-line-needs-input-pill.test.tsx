// Leo, 2026-11-05, on Claude desktop's "Needs your input" pill: "there's a little animation that plays.
// It, like, shrinks the thing, the circle into the Thinking... portion afterwards which is cute". While
// the chat waits on the person the live line is a pill with the attention dot; once answered, the
// Thinking line that replaces it starts with that dot shrinking away, and the dot goes after.
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { readFileSync } from "node:fs";
import type { WaitingOn } from "../src/agent-session/acpmux/conversation/waitingOn";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const globalKeys = ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  dom.window.close();
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Thinking } = await import("../src/agent-session/acpmux/conversation/Thinking");
const { WaitingOnContext } = await import("../src/agent-session/acpmux/conversation/waitingOn");

test("the waiting line is a pill with the dot; once answered the dot shrinks before Thinking, then goes", async () => {
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  const draw = (waiting: WaitingOn | undefined) =>
    act(async () =>
      root.render(
        <WaitingOnContext value={waiting}>
          <Thinking since={1_000} now={() => 5_000} />
        </WaitingOnContext>,
      ),
    );
  // Thinking before any ask: no dot.
  await draw(undefined);
  expect(host.querySelector(".cv-needs-input-glyph")).toBeNull();

  await draw("permission");
  const pill = host.querySelector(".cv-waiting")!;
  expect(pill.textContent).toBe("Waiting for you: allow this?");
  expect(pill.querySelector(".cv-needs-input-glyph:not(.is-answered)")).not.toBeNull();
  // The ringed dot sits before the pill, outside it, as Claude desktop's "Needs your input".
  expect(pill.querySelector(".cv-waiting__pill")?.textContent).toBe("Waiting for you: allow this?");
  expect(pill.querySelector(".cv-waiting__pill .cv-needs-input-glyph")).toBeNull();

  // Answered: Thinking, led by the shrinking dot.
  await draw(undefined);
  expect(host.querySelector(".cv-waiting")).toBeNull();
  const dot = host.querySelector(".cv-shimmer__row > .cv-needs-input-glyph.is-answered")!;
  expect(dot).not.toBeNull();
  expect(dot.getAttribute("aria-hidden")).toBe("true");
  expect(host.textContent).toContain("Thinking");
  // The shrink's end takes it away.
  await act(async () => void dot.dispatchEvent(new dom.window.Event("animationend", { bubbles: true })));
  expect(host.querySelector(".cv-needs-input-glyph")).toBeNull();

  // With no animation (motion off) it still goes, within its fallback time (SETTLE_MS, 400 ms).
  jest.useFakeTimers();
  try {
    await draw("question");
    await draw(undefined);
    expect(host.querySelector(".cv-needs-input-glyph.is-answered")).not.toBeNull();
    await act(async () => void jest.advanceTimersByTime(399));
    expect(host.querySelector(".cv-needs-input-glyph.is-answered")).not.toBeNull();
    await act(async () => void jest.advanceTimersByTime(1));
    expect(host.querySelector(".cv-needs-input-glyph")).toBeNull();
  } finally {
    jest.useRealTimers();
  }
  await act(async () => root.unmount());
});

// Review (gpt-6-astra) at 888717437c8: the pill's look is the Thinking line's alone. The activity and
// Worked-for lines (ActivityLine.tsx, WorkingFor.tsx) also mark a waiting turn with `cv-waiting`, as
// bare text, so the shared class keeps its old full-text-colour look and the pill rule names Thinking.
test("only the Thinking line draws the pill; the other waiting lines keep plain text", () => {
  const css = readFileSync(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
    "utf8",
  );
  const rule = (selector: string) => {
    const at = css.indexOf(`\n${selector} {`);
    expect(at).toBeGreaterThanOrEqual(0);
    return css.slice(at, css.indexOf("}", at));
  };
  expect(rule(".cv-waiting")).toContain("color: var(--cv-text)");
  expect(rule(".cv-waiting")).not.toContain("inline-flex");
  expect(rule(".cv-thinking.cv-waiting")).toContain("var(--acpmux-needs-you-mark)");
});
