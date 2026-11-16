// l10n-allow-file: test fixture tool titles and output, not shipped UI.
// Every collapsible in the transcript opens and closes in one motion (Leo 2026-10-20): its body's
// height and opacity over the shared fold token (`--cv-fold-duration`, the settle, `--cmux-motion-settle`),
// easing out, the chevron turning on the same token, and at once under Reduce Motion or with the
// pane's animation off. A body that closes stays drawn until it has slid away.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import {
  cssTimeMs,
  FOLD_DROP_MS,
  FOLD_DURATION_VAR,
  FOLD_RESTART_MAX_MS,
  foldMotion,
} from "../src/agent-session/acpmux/conversation/fold";
import { FOLD_SETTLE_MS } from "../src/agent-session/acpmux/conversation/foldAnchor";
import { CommandRow } from "../src/agent-session/acpmux/conversation/CommandRow";
import { McpCallRows } from "../src/agent-session/acpmux/conversation/McpCallRows";
import { ToolGroupRow } from "../src/agent-session/acpmux/conversation/ToolGroupRow";
import { ToolRow } from "../src/agent-session/acpmux/conversation/ToolRow";
import { ToolRun } from "../src/agent-session/acpmux/conversation/ToolRun";
import { resetTranscriptDisclosure } from "../src/agent-session/acpmux/conversation/transcriptDisclosureModel";
import { useAnchoredCollapse } from "../src/agent-session/acpmux/conversation/useAnchoredCollapse";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const motion = { ...foldMotion };
/// The fold token as the page resolves it, and Reduce Motion.
let token = 190;
let reduce = false;
/// `ends` runs the animation's onfinish as the browser does, outside React: React commits what it
/// sets only after the caller's `act` (the frame the animation let go of the box paints first).
type Animated = {
  keyframes: Keyframe[];
  options: KeyframeAnimationOptions;
  finish: () => void;
  ends: () => void;
  cancel: () => void;
  /// The animation's clock, as the fold sets it (`currentTime`): null until a test gives it a time.
  clock: { currentTime: number | null };
};
let animations: Animated[] = [];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
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
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // JSDOM has no Web Animations: record each one, finished by the test.
  (dom.window.HTMLElement.prototype as unknown as { animate: unknown }).animate = function (
    keyframes: Keyframe[],
    options: KeyframeAnimationOptions,
  ) {
    const animation = {
      currentTime: null as number | null,
      onfinish: null as null | (() => void),
      oncancel: null as null | (() => void),
      cancel() {
        animation.oncancel?.();
      },
    };
    animations.push({
      keyframes,
      options,
      finish: () => act(() => animation.onfinish?.()),
      ends: () => animation.onfinish?.(),
      cancel: () => act(() => animation.cancel()),
      clock: animation,
    });
    return animation;
  };
  token = 190;
  reduce = false;
  animations = [];
  foldMotion.duration = () => token;
  foldMotion.easing = () => "cubic-bezier(0, 0, 0.58, 1)";
  foldMotion.reducedMotion = () => reduce;
  resetTranscriptDisclosure();
  container = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  Object.assign(foldMotion, motion);
  resetTranscriptDisclosure();
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const tool = (id: string, extra: Record<string, unknown> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id, title: `Read src/${id}.ts`, kind: "read", status: "completed", output: `contents of ${id}`, ...extra },
});

/// Each collapsible, closed, and the body its toggle opens.
const collapsibles: Array<{ name: string; node: () => ReactNode; body: string }> = [
  { name: "a tool row", node: () => <ToolRow item={tool("read")} />, body: ".cv-tool-output-card" },
  {
    name: "a command row",
    node: () => <CommandRow item={tool("cmd", { kind: "execute", command: "bun test", title: "bun test" })} />,
    body: ".cv-shell",
  },
  {
    name: "an edits group",
    node: () => (
      <ToolGroupRow
        kind="edits"
        disclosureKey="group:edits:a"
        items={[tool("a", { kind: "edit", title: "Edit a.ts" }), tool("b", { kind: "edit", title: "Edit b.ts" })]}
      />
    ),
    body: ".cv-tool-group",
  },
  {
    name: "an MCP call",
    node: () => (
      <McpCallRows
        disclosureKey="group:mcp:a"
        items={[tool("mcp", { title: "mcp__hub__send_message", inputSummary: '{"to":"lane"}' })]}
      />
    ),
    // An object of arguments opens to its labeled fields (ToolDetail.tsx).
    body: ".cv-tool-detail",
  },
  {
    name: "a settled run",
    node: () => (
      <ToolRun disclosureKey="run:a" items={[tool("r1"), tool("r2")]}>
        <ToolRow item={tool("r1")} />
      </ToolRun>
    ),
    body: ".cv-tool-run",
  },
];

function render(node: ReactNode) {
  act(() => {
    root ??= createRoot(container);
    root.render(node);
  });
}
const toggle = () => container.querySelector<HTMLButtonElement>("button[aria-expanded]")!;
const click = () => act(() => toggle().click());

/// A pointer's press on the toggle, then its click released `moved` px to the right.
function dragClick(moved: number) {
  const line = toggle();
  const view = line.ownerDocument.defaultView!;
  const at = { clientX: 10, clientY: 10, button: 0, bubbles: true, cancelable: true };
  const Pointer = (view as unknown as { PointerEvent?: typeof MouseEvent }).PointerEvent ?? view.MouseEvent;
  act(() => {
    line.dispatchEvent(new Pointer("pointerdown", at));
    line.dispatchEvent(new view.MouseEvent("click", { ...at, clientX: 10 + moved, detail: 1 }));
  });
}

// Leo, 2026-11-06: "way too jittery/sensitive". Every line's own click handler, the wrappers that note
// the click (a group's, a received message's) included, hands the click to the toggle.
for (const { name, node, body } of collapsibles) {
  test(`${name}: a 12 px drag across its line opens nothing; a click in place does`, () => {
    render(node());
    dragClick(12);
    expect(toggle().getAttribute("aria-expanded")).toBe("false");
    expect(container.querySelector(body)).toBeNull();
    expect(animations.length).toBe(0);
    dragClick(2);
    expect(toggle().getAttribute("aria-expanded")).toBe("true");
  });
}

// Review of #39658: a running command row's ref is an inline callback that reattaches at every render,
// so a streamed output update between the press and the release must keep the press, and a drag
// across the line still opens nothing.
test("a command row keeps the press across an output update: a 12 px drag across it opens nothing", () => {
  const running = (output: string) => (
    <CommandRow
      item={tool("cmd", { kind: "execute", command: "bun test", title: "bun test", status: "in_progress", output })}
    />
  );
  render(running("line 1"));
  const line = toggle();
  const view = line.ownerDocument.defaultView!;
  const at = { clientX: 10, clientY: 10, button: 0, bubbles: true, cancelable: true };
  const Pointer = (view as unknown as { PointerEvent?: typeof MouseEvent }).PointerEvent ?? view.MouseEvent;
  act(() => {
    line.dispatchEvent(new Pointer("pointerdown", at));
  });
  render(running("line 1\nline 2"));
  expect(toggle()).toBe(line);
  act(() => {
    toggle().dispatchEvent(new view.MouseEvent("click", { ...at, clientX: 22, detail: 1 }));
  });
  expect(toggle().getAttribute("aria-expanded")).toBe("false");
  expect(container.querySelector(".cv-shell")).toBeNull();
  dragClick(2);
  expect(toggle().getAttribute("aria-expanded")).toBe("true");
});

/// A disclosure whose header is drawn only while `header` holds, with a second toggle below it that
/// stays: a press on the header that went must not decide a later click on the one below.
function TwoTargets({ header }: { header: boolean }) {
  const fold = useAnchoredCollapse();
  return (
    <div>
      {header && (
        <button type="button" data-testid="head" ref={fold.headerRef} onClick={fold.toggle}>
          head
        </button>
      )}
      <button type="button" data-testid="below" aria-pressed={fold.open} onClick={fold.toggle}>
        below
      </button>
    </div>
  );
}

test("a press on a header that went does not turn a later click elsewhere into a drag", () => {
  render(<TwoTargets header />);
  const head = container.querySelector<HTMLButtonElement>("[data-testid=head]")!;
  const view = head.ownerDocument.defaultView!;
  const Pointer = (view as unknown as { PointerEvent?: typeof MouseEvent }).PointerEvent ?? view.MouseEvent;
  act(() => {
    head.dispatchEvent(new Pointer("pointerdown", { clientX: 10, clientY: 10, button: 0, bubbles: true }));
  });
  render(<TwoTargets header={false} />);
  const below = container.querySelector<HTMLButtonElement>("[data-testid=below]")!;
  act(() => {
    below.dispatchEvent(new view.MouseEvent("click", { clientX: 200, clientY: 40, detail: 1, bubbles: true }));
  });
  expect(below.getAttribute("aria-pressed")).toBe("true");
});

for (const { name, node, body } of collapsibles) {
  test(`${name} opens and closes with the fold's height and opacity, over the shared token`, () => {
    render(node());
    expect(container.querySelector(body)).toBeNull();
    click();
    expect(toggle().getAttribute("aria-expanded")).toBe("true");
    expect(container.querySelector(`.cv-fold ${body}`)).not.toBeNull();
    expect(animations.length).toBe(1);
    const [opening] = animations;
    expect(opening!.options.duration).toBe(token);
    expect(opening!.options.easing).toBe("cubic-bezier(0, 0, 0.58, 1)");
    expect(opening!.keyframes[0]).toEqual({ height: "0px", opacity: 0 });
    expect(opening!.keyframes.at(-1)!.opacity).toBe(1);
    // The chevron turns as it opens.
    expect(toggle().querySelector(".cv-rotor")!.classList.contains("is-open")).toBe(true);

    click();
    expect(toggle().getAttribute("aria-expanded")).toBe("false");
    expect(animations.length).toBe(2);
    expect(animations[1]!.options.duration).toBe(token);
    expect(animations[1]!.keyframes.at(-1)).toEqual({ height: "0px", opacity: 0 });
    // Drawn while it slides away, then gone.
    expect(container.querySelector(body)).not.toBeNull();
    animations[1]!.finish();
    expect(container.querySelector(body)).toBeNull();
  });

  test(`${name} opens and closes at once under Reduce Motion`, () => {
    reduce = true;
    render(node());
    click();
    expect(container.querySelector(body)).not.toBeNull();
    click();
    expect(container.querySelector(body)).toBeNull();
    expect(animations).toEqual([]);
  });
}

test("with the pane's animation off, or a 0 ms token, a fold applies at once", () => {
  document.documentElement.dataset.agentMotion = "off";
  render(<ToolRow item={tool("off")} />);
  click();
  expect(container.querySelector(".cv-tool-output-card")).not.toBeNull();
  click();
  expect(container.querySelector(".cv-tool-output-card")).toBeNull();
  delete document.documentElement.dataset.agentMotion;
  // The host sends 0 for the move duration under Reduce Motion and with animation off.
  token = 0;
  click();
  click();
  expect(container.querySelector(".cv-tool-output-card")).toBeNull();
  expect(animations).toEqual([]);
});

test("a fold turned back midway starts from where it is drawn", () => {
  render(<ToolRow item={tool("turn")} />);
  click();
  // Midway through opening, the reader closes it again.
  const card = container.querySelector<HTMLElement>(".cv-fold")!;
  card.getBoundingClientRect = () => ({ height: 42 }) as DOMRect;
  click();
  expect(animations.length).toBe(2);
  expect(animations[1]!.keyframes[0]!.height).toBe("42px");
  expect(animations[1]!.keyframes.at(-1)).toEqual({ height: "0px", opacity: 0 });
});

test("a close holds its box shut until React removes the body, so it never flashes open", () => {
  render(<ToolRow item={tool("pop")} />);
  click();
  const box = container.querySelector<HTMLElement>(".cv-fold")!;
  animations[0]!.finish();
  // An open lets go of the height it measured: the body takes its own, content that loaded since too.
  expect(box.style.height).toBe("");
  expect(box.style.opacity).toBe("");
  expect(box.style.overflow).toBe("");
  click();
  act(() => {
    animations[1]!.ends();
    // The animation has let go and React has not committed yet: the box is still drawn, pinned shut.
    expect(box.isConnected).toBe(true);
    expect(box.style.height).toBe("0px");
    expect(box.style.opacity).toBe("0");
    expect(box.style.overflow).toBe("hidden");
  });
  expect(container.querySelector(".cv-fold")).toBeNull();
});

/// Leo, 2026-11-06, on a recording under heavy load: "way too discontinuous". A fold whose frames
/// come steadily plays; the second frame in a row that comes FOLD_DROP_MS after the one before it
/// lands the fold at its end, and its frame loop stops there. One late frame alone is not load (Leo,
/// 2026-11-07: "sometimes it doesn't play ythe animation"): the fold plays on.
test("under load a fold lands at its end on the second dropped frame in a row, not on one late frame", () => {
  const frames: FrameRequestCallback[] = [];
  (dom!.window as unknown as { requestAnimationFrame: unknown }).requestAnimationFrame = (
    callback: FrameRequestCallback,
  ) => frames.push(callback);
  const frame = (at: number) => act(() => frames.splice(0).forEach((callback) => callback(at)));
  render(<ToolRow item={tool("load")} />);
  click();
  animations[0]!.finish();
  // The open ended on its own: its loop stopped with it.
  frame(0);
  expect(frames).toEqual([]);
  click();
  expect(container.querySelector(".cv-tool-output-card")).not.toBeNull();
  // Steady frames: the close plays on.
  frame(1000);
  frame(1000 + 16.7);
  frame(1000 + 33.4);
  expect(container.querySelector(".cv-tool-output-card")).not.toBeNull();
  expect(frames.length).toBe(1);
  // One frame FOLD_DROP_MS late, then a steady one: still playing.
  frame(1000 + 33.4 + FOLD_DROP_MS);
  frame(1000 + 50 + FOLD_DROP_MS);
  expect(container.querySelector(".cv-tool-output-card")).not.toBeNull();
  expect(frames.length).toBe(1);
  // Two late frames in a row: the body is shut and gone at once, and nothing asks for another frame.
  frame(1000 + 50 + 2 * FOLD_DROP_MS);
  frame(1000 + 50 + 3 * FOLD_DROP_MS);
  expect(container.querySelector(".cv-tool-output-card")).toBeNull();
  expect(frames).toEqual([]);
});

/// The gap after a fold's first frame holds the page drawing what opened (a long log at the bottom,
/// Leo 2026-11-07: "sometimes it lags when i open it"). When it is slow the fold's clock goes back by
/// what that frame cost, at most FOLD_RESTART_MAX_MS, so the motion is not half over when it shows.
test("a slow first frame restarts the fold's clock instead of skipping the motion", () => {
  const frames: FrameRequestCallback[] = [];
  (dom!.window as unknown as { requestAnimationFrame: unknown }).requestAnimationFrame = (
    callback: FrameRequestCallback,
  ) => frames.push(callback);
  const frame = (at: number) => act(() => frames.splice(0).forEach((callback) => callback(at)));
  render(<ToolRow item={tool("slow-first")} />);
  click();
  const opening = animations[0]!;
  frame(1000);
  // The page took 90 ms to draw the opened body; the clock ran on meanwhile.
  opening.clock.currentTime = 90;
  frame(1090);
  expect(opening.clock.currentTime).toBeCloseTo(1000 / 60, 0);
  // A first frame slower still goes back by no more than FOLD_RESTART_MAX_MS.
  expect(FOLD_RESTART_MAX_MS).toBeLessThan(FOLD_SETTLE_MS);
  // Steady frames after it: the open plays on, nothing landed.
  frame(1090 + 16.7);
  expect(frames.length).toBe(1);
  expect(container.querySelector(".cv-tool-output-card")).not.toBeNull();
});

test("a motion policy cancellation finishes a closing tool call instead of leaving its body mounted", () => {
  render(<ToolRow item={tool("cancelled")} />);
  click();
  animations[0]!.finish();
  click();
  expect(container.querySelector(".cv-tool-output-card")).not.toBeNull();
  animations[1]!.cancel();
  expect(container.querySelector(".cv-tool-output-card")).toBeNull();
});

test("a move token that becomes zero settles the active fold even when fade motion remains", async () => {
  render(<ToolRow item={tool("policy-change")} />);
  click();
  animations[0]!.finish();
  click();
  expect(container.querySelector(".cv-tool-output-card")).not.toBeNull();
  const box = container.querySelector<HTMLElement>(".cv-fold")!;
  document.documentElement.style.setProperty("--agent-motion-in", "80ms");
  token = 0;
  document.documentElement.style.setProperty("--agent-motion-move", "0ms");
  await act(async () => {
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
  });
  expect(box.style.height).toBe("0px");
  expect(box.style.opacity).toBe("0");
  expect(container.querySelector(".cv-tool-output-card")).toBeNull();
});

test("a fold reopened as its close ends opens from its own size, not the pinned one", () => {
  render(<ToolRow item={tool("reopen")} />);
  click();
  animations[0]!.finish();
  click();
  const box = container.querySelector<HTMLElement>(".cv-fold")!;
  // The reader opens it again in the same frame the close ends: React keeps the same box.
  act(() => {
    animations[1]!.ends();
    toggle().click();
  });
  expect(container.querySelector(".cv-fold")).toBe(box);
  expect(animations.length).toBe(3);
  expect(animations[2]!.keyframes[0]).toEqual({ height: "0px", opacity: 0 });
  // Under the motion the box holds the open's start height, never the close's pin: a frame drawn
  // before the motion applies shows it shut, not open at full height (composer-hat-fold-balance).
  expect(box.style.height).toBe("0px");
  expect(box.style.opacity).toBe("");
  animations[2]!.finish();
  expect(box.style.height).toBe("");
  expect(box.style.opacity).toBe("");
  expect(box.style.overflow).toBe("");
});

// Leo, 2026-11-07: "they dont overshoot but they decelerate at the end. i think that might be the key".
test("the fold token is the settle (one curve for every web fold), and the chevron turns on it", () => {
  const css = readFileSync(
    path.resolve(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
    "utf8",
  );
  expect(FOLD_DURATION_VAR).toBe("--cv-fold-duration");
  expect(css).toMatch(/--cv-fold-duration:\s*var\(--cmux-motion-settle,\s*180ms\)/);
  expect(css).toMatch(/--cv-fold-ease:\s*var\(--cmux-ease-settle,\s*cubic-bezier\(0\.16, 1, 0\.3, 1\)\)/);
  expect(css).toMatch(/\.cv-rotor\s*\{\s*transition:\s*transform var\(--cv-fold-duration\) var\(--cv-fold-ease/);
  // The chevron snaps under Reduce Motion: its transition is only under no-preference.
  expect(css).toMatch(
    /@media \(prefers-reduced-motion: no-preference\)\s*\{\s*\.cv-rotor\s*\{\s*transition: transform var\(--cv-fold-duration\)/,
  );
  // The fold reads the token as the page resolves it.
  expect(cssTimeMs("190ms")).toBe(190);
  expect(cssTimeMs(" 0.18s")).toBe(180);
  expect(cssTimeMs("0ms")).toBe(0);
  expect(cssTimeMs("")).toBeUndefined();
});
