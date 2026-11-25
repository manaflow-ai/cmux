// The three-state cloud control's first-run and slots-full states, clicked (cmux#54829 F1, F2): a
// blocked control hands every click to `onBlockedClick` and never changes the mode, says the blocked
// action to a screen reader, wears the warning dot only for failures, turns on Keep Running for a
// chat that paused while this Mac slept, and lets a holder's row give this chat its slot.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { UiProvider } from "../../../ui/UiProvider";
import { settleReact } from "../../../../test/support/domTeardown";
import { translate } from "../i18n";
import { CloudTriToggle } from "./CloudTriToggle";
import type { HybridBlockedWhy, HybridPin } from "./hybridModel";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "CSS",
    "MouseEvent",
    "KeyboardEvent",
    "getComputedStyle",
    "MutationObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    CSS: { escape: (value: string) => value.replace(/[^\w-]/g, (char) => `\\${char}`) },
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle,
    MutationObserver: dom.window.MutationObserver,
    // The holders' menu (Base UI) schedules its open transition on a frame.
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function draw(node: React.ReactNode): Promise<HTMLElement> {
  const container = installDom();
  root = createRoot(container);
  await act(async () => root!.render(<UiProvider container={container}>{node}</UiProvider>));
  return container;
}

const segments = (container: HTMLElement) => [...container.querySelectorAll<HTMLElement>('[role="radio"]')];
const click = async (element: HTMLElement) => act(async () => element.click());

/// Every click it got, by the handler that got it.
function recorder() {
  const calls = {
    change: [] as HybridPin[],
    blocked: [] as HybridBlockedWhy[],
    lit: [] as boolean[],
    trade: [] as string[],
  };
  return {
    calls,
    props: {
      onChange: (pin: HybridPin) => calls.change.push(pin),
      onBlockedClick: (why: HybridBlockedWhy) => calls.blocked.push(why),
      onLitChange: (lit: boolean) => calls.lit.push(lit),
      onTrade: (session: string) => calls.trade.push(session),
    },
  };
}

const NOT_SLEPT: HybridBlockedWhy[] = [
  "signed-out",
  "no-plan",
  "no-cloud",
  "hours-spent",
  "trial-ended",
  "offline",
  "move-failed",
  "trial-full",
];

test("blocked, every segment and the name run the blocked action, never a mode change", async () => {
  for (const why of NOT_SLEPT) {
    const { calls, props } = recorder();
    const container = await draw(<CloudTriToggle pin="auto" blocked={{ why }} {...props} />);
    for (const segment of segments(container)) await click(segment);
    const name = container.querySelector<HTMLElement>(".acpmux-hybrid-tri__name")!;
    expect(name.textContent).toBe(translate(`hybrid.blocked.${why}`));
    await click(name);
    expect(calls.blocked).toEqual([why, why, why, why]);
    expect(calls.change).toEqual([]);
    expect(calls.lit).toEqual([]);
    if (root) await act(async () => root!.unmount());
    root = undefined;
  }
});

test("blocked, the arrow keys run the blocked action too", async () => {
  const { calls, props } = recorder();
  const container = await draw(<CloudTriToggle pin="local" blocked={{ why: "no-plan" }} {...props} />);
  const chosen = segments(container).find((segment) => segment.getAttribute("aria-checked") === "true")!;
  await act(async () => {
    chosen.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true }));
  });
  expect(calls.blocked).toEqual(["no-plan"]);
  expect(calls.change).toEqual([]);
});

test("blocked, each segment's accessible name is the blocked action, not its mode", async () => {
  const { props } = recorder();
  const container = await draw(<CloudTriToggle pin="cloud" blocked={{ why: "signed-out" }} {...props} />);
  const label = translate("hybrid.blocked.signed-out");
  expect(segments(container).map((segment) => segment.getAttribute("aria-label"))).toEqual([label, label, label]);
  // The chosen mode is still the one marked.
  expect(segments(container).map((segment) => segment.getAttribute("aria-checked"))).toEqual([
    "false",
    "true",
    "false",
  ]);
});

test("not blocked, segments keep their mode names and a pick changes the mode", async () => {
  const { calls, props } = recorder();
  const container = await draw(<CloudTriToggle pin="auto" {...props} />);
  expect(segments(container).map((segment) => segment.getAttribute("aria-label"))).toEqual([
    translate("hybrid.mode.hybrid"),
    translate("hybrid.pin.cloud"),
    translate("hybrid.pin.local"),
  ]);
  await click(segments(container)[1]!);
  expect(calls.change).toEqual(["cloud"]);
  expect(calls.blocked).toEqual([]);
});

test("paused while this Mac slept: a click turns on Keep Running, never the blocked action", async () => {
  const { calls, props } = recorder();
  const container = await draw(<CloudTriToggle pin="auto" blocked={{ why: "slept" }} {...props} />);
  await click(segments(container)[2]!);
  await click(container.querySelector<HTMLElement>(".acpmux-hybrid-tri__name")!);
  expect(calls.lit).toEqual([true, true]);
  expect(calls.blocked).toEqual([]);
  expect(calls.change).toEqual([]);
});

test("paused while this Mac slept, with no Keep Running wire: a click does nothing", async () => {
  const { calls, props } = recorder();
  const { onLitChange: _unused, ...rest } = props;
  const container = await draw(<CloudTriToggle pin="auto" blocked={{ why: "slept" }} {...rest} />);
  await click(segments(container)[0]!);
  expect(calls.blocked).toEqual([]);
  expect(calls.change).toEqual([]);
});

test("the one-button form, blocked: its click is the blocked action and its name says it", async () => {
  const { calls, props } = recorder();
  const container = await draw(<CloudTriToggle pin="auto" form="cycle" blocked={{ why: "hours-spent" }} {...props} />);
  const button = container.querySelector<HTMLElement>('[data-form="cycle"]')!;
  expect(button.getAttribute("aria-label")).toContain(translate("hybrid.blocked.hours-spent"));
  await click(button);
  expect(calls.blocked).toEqual(["hours-spent"]);
  expect(calls.change).toEqual([]);
});

test("only offline and a failed move wear the warning dot, on the glyph that shows the cloud", async () => {
  const { props } = recorder();
  const dotted = async (why: HybridBlockedWhy | undefined, pin: HybridPin) => {
    const container = await draw(<CloudTriToggle pin={pin} blocked={why ? { why } : undefined} {...props} />);
    const marked = [...container.querySelectorAll(".acpmux-hybrid-tri__dot")].map((dot) =>
      dot.closest("[data-mode]")?.getAttribute("data-mode"),
    );
    await act(async () => root!.unmount());
    root = undefined;
    return marked;
  };
  expect(await dotted("offline", "auto")).toEqual(["auto"]);
  expect(await dotted("move-failed", "cloud")).toEqual(["cloud"]);
  // Only on This Mac shows no cloud: the dot goes on Only in Cloud's glyph.
  expect(await dotted("offline", "local")).toEqual(["cloud"]);
  for (const why of ["signed-out", "no-plan", "no-cloud", "hours-spent", "trial-ended", "trial-full", "slept"] as const)
    expect(await dotted(why, "auto")).toEqual([]);
  expect(await dotted(undefined, "auto")).toEqual([]);
});

test("every slot taken: the holders' menu lists each chat and its row gives this chat the slot", async () => {
  const { calls, props } = recorder();
  const holders = [
    { session: "s-1", title: "Fix the flaky sync test" },
    { session: "s-2", title: "Port the settings page" },
  ];
  const container = await draw(<CloudTriToggle pin="auto" lit holders={holders} holdersOpen {...props} />);
  const doc = container.ownerDocument;
  const rows = [...doc.querySelectorAll<HTMLElement>(".acpmux-hybrid-holder")];
  expect(rows.map((row) => row.querySelector(".acpmux-hybrid-holder__title")?.textContent)).toEqual([
    "Fix the flaky sync test",
    "Port the settings page",
  ]);
  for (const row of rows) expect(row.textContent).toContain(translate("hybrid.holders.trade"));
  await click(rows[1]!);
  expect(calls.trade).toEqual(["s-2"]);
  expect(calls.change).toEqual([]);
});

test("blocked wins over the holders' menu: the name is the blocked action", async () => {
  const { calls, props } = recorder();
  const container = await draw(
    <CloudTriToggle pin="auto" blocked={{ why: "offline" }} holders={[{ session: "s-1", title: "One" }]} {...props} />,
  );
  expect(container.ownerDocument.querySelector('[data-menu="Slots"]')).toBeNull();
  await click(container.querySelector<HTMLElement>(".acpmux-hybrid-tri__name")!);
  expect(calls.blocked).toEqual(["offline"]);
  expect(calls.trade).toEqual([]);
});
