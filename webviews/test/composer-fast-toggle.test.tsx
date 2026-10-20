// l10n-allow-file: test fixtures.
// Leo 2026-10-15 composer feedback, item 5: "Add Fast/Ultrafast: a lightning-bolt toggle at the
// bottom right, just left of the mic button." At the composer's boundary: the real composer with
// the real chips, a stand-in mic, and a host that records what the pane sends.
//   - the bolt sits in the trailing cluster, immediately left of the mic; with Claude Code's split
//     (the plain footer, on by default; Leo 2026-10-19) it moves with the chips to the quiet row
//     under the box, right after the model and effort, before the context ring;
//   - a click cycles off -> each offered tier -> off, through the session's speed option, with the
//     command the reasoning menu sends (chat.effort's configId=value);
//   - a model with no speed tier shows no bolt;
//   - the chips no longer say "Fast": the bolt carries the state.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "HTMLInputElement",
  "Element",
  "Node",
  "Text",
  "Range",
  "Selection",
  "ShadowRoot",
  "MouseEvent",
  "KeyboardEvent",
  "InputEvent",
  "customElements",
  "MutationObserver",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "PointerEvent",
  "FocusEvent",
  "ResizeObserver",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const w = dom.window as unknown as Record<string, unknown>;
  Object.assign(scope, Object.fromEntries(keys.map((key) => [key, w[key]])), {
    IS_REACT_ACT_ENVIRONMENT: true,
    PointerEvent: w.PointerEvent ?? w.MouseEvent,
    ResizeObserver:
      w.ResizeObserver ??
      class {
        observe() {}
        unobserve() {}
        disconnect() {}
      },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Option = { value: string; name?: string };
type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;

function snapshot(speed: { options: Option[]; current: string } | undefined): Snapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: [],
    summary: {
      sessionId: "s1",
      harness: "codex",
      model: "gpt-6-astra",
      turnCount: 1,
      configOptions: [
        {
          id: "reasoning_effort",
          name: "Reasoning",
          category: "thought_level",
          currentValue: "medium",
          options: ["low", "medium", "high"].map((value) => ({ value })),
        },
        ...(speed
          ? [
              {
                id: "fast-mode",
                name: "Fast mode",
                category: "model_config",
                currentValue: speed.current,
                options: speed.options,
              },
            ]
          : []),
      ],
    },
  } as unknown as Snapshot;
}

const sent: string[] = [];
let client: import("@tanstack/react-query").QueryClient;

async function render(shot: Snapshot) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  client ??= new QueryClient();
  const Chips = ({ snapshot: chipSnapshot }: { snapshot: Snapshot }) => (
    <ComposerPickers
      snapshot={chipSnapshot}
      onModel={() => undefined}
      onMode={() => undefined}
      onEffort={(configId, value) => sent.push(`${configId}=${value}`)}
      onHarness={() => undefined}
      showPlan={false}
    />
  );
  root ??= createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={client}>
        <Composer
          snapshot={shot}
          chips={Chips}
          onSend={() => undefined}
          onStop={() => undefined}
          accessory={<button type="button" className="acpmux-mic" aria-label="Dictation" />}
        />
      </QueryClientProvider>,
    );
  });
}

const bolt = () => host.querySelector<HTMLButtonElement>(".acpmux-fast");
function press(element: Element) {
  for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"])
    element.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0 }));
}

const twoState: Option[] = [
  { value: "off", name: "Off" },
  { value: "on", name: "On" },
];
const threeTier: Option[] = [{ value: "standard" }, { value: "fast" }, { value: "ultrafast" }];

test("the bolt follows the chips into the quiet row, and toggles one offered tier with the speed command", async () => {
  sent.length = 0;
  await render(snapshot({ options: twoState, current: "off" }));
  const button = bolt();
  expect(button, "a speed toggle in the quiet row").not.toBeNull();
  // The split: the box keeps the mic and Send; the bolt is the quiet row's, after the chips and
  // before the context ring.
  const foot = host.querySelector<HTMLElement>(".acpmux-composer-foot")!;
  expect(foot.contains(button)).toBe(true);
  expect(host.querySelector(".acpmux-composer-inner .acpmux-fast")).toBeNull();
  expect(host.querySelector(".acpmux-composer-inner .acpmux-composer-actions .acpmux-mic")).not.toBeNull();
  const items = [...foot.children];
  const at = items.findIndex((item) => item.contains(button));
  expect(items.findIndex((item) => item.classList.contains("acpmux-chips"))).toBeLessThan(at);
  const ring = items.findIndex((item) => item.classList.contains("acpmux-context"));
  if (ring >= 0) expect(ring).toBeGreaterThan(at);
  expect(button!.getAttribute("aria-pressed")).toBe("false");
  expect(button!.getAttribute("aria-label")).toBe("Speed: Standard");
  expect(button!.title).toContain("Speed: Standard");
  await act(async () => press(button!));
  expect(sent).toEqual(["fast-mode=on"]);

  await render(snapshot({ options: twoState, current: "on" }));
  expect(bolt()!.getAttribute("aria-pressed")).toBe("true");
  expect(bolt()!.getAttribute("aria-label")).toBe("Speed: Fast");
  // The chips no longer say Fast: the bolt carries it.
  expect(host.querySelector(".acpmux-chips")!.textContent).not.toMatch(/fast/i);
  await act(async () => press(bolt()!));
  expect(sent).toEqual(["fast-mode=on", "fast-mode=off"]);
});

test("with two tiers a click cycles off, Fast, Ultrafast and back to off", async () => {
  sent.length = 0;
  for (const [current, label] of [
    ["standard", "Speed: Standard"],
    ["fast", "Speed: Fast"],
    ["ultrafast", "Speed: Ultrafast"],
  ] as const) {
    await render(snapshot({ options: threeTier, current }));
    expect(bolt()!.getAttribute("aria-label")).toBe(label);
    expect(bolt()!.getAttribute("aria-pressed")).toBe(String(current !== "standard"));
    expect(bolt()!.dataset.tier).toBe(current === "standard" ? "off" : current);
    await act(async () => press(bolt()!));
  }
  expect(sent).toEqual(["fast-mode=fast", "fast-mode=ultrafast", "fast-mode=standard"]);
  expect(host.querySelector(".acpmux-chips")!.textContent).not.toMatch(/fast/i);
});

test("a model with no speed tier shows no bolt", async () => {
  await render(snapshot(undefined));
  expect(host.querySelector(".acpmux-composer-actions .acpmux-mic")).not.toBeNull();
  expect(bolt()).toBeNull();
});
