// l10n-allow-file: test fixture plans and option names, not shipped UI.
// A plan approval in the bottom stack disappeared in one frame once answered, and appeared in one
// frame when the agent asked, so the transcript above it jumped by the card's height each time, and
// had no Needs your input mark (Leo 2026-11-08, on a recording whose attention dot grows in and
// shrinks out). PlanAsk now draws the pill and its dot, and keeps an answered plan drawn, inert and
// marked leaving (which styles.css shrinks out), until its exit has played; with motion off it goes at
// once.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";

let transitionDuration = "0.265s";
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const globalKeys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Node",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  // The exit's length, as styles.css gives it; a test swaps it for "0s" (motion off).
  getComputedStyle: () => ({ transitionDuration, transitionDelay: "0s", opacity: "1" }),
  IS_REACT_ACT_ENVIRONMENT: true,
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Document|Event|KeyboardEvent)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  for (const key of domClasses) delete globals[key];
  dom.window.close();
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { PlanAsk } = await import("../src/agent-session/acpmux/rows/PermissionAsk");
const { translate } = await import("../src/agent-session/acpmux/i18n");

const plan: AcpmuxPermission = {
  permissionId: "plan-1",
  kind: "other",
  title: "Approve plan",
  plan: "1. Retry the chunk.",
  pending: true,
  options: [
    { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
    { id: "reject_once", name: "Reject", kind: "reject_once", allow: false },
  ],
};

function mount() {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const seen: boolean[] = [];
  const drawnCalls: boolean[] = [];
  // Stable, as App's state setter is.
  const onDrawn = (drawn: boolean) => {
    drawnCalls.push(drawn);
  };
  // `chat` is the key App gives it: the selected chat's session id.
  const draw = (permission: AcpmuxPermission | undefined, chat = "chat-1") =>
    act(() =>
      root.render(
        <PlanAsk key={chat} permission={permission} onDrawn={onDrawn}>
          {(shown, leaving) => {
            seen.push(leaving);
            return <p className="card">{shown.permissionId}</p>;
          }}
        </PlanAsk>,
      ),
    );
  return { host, root, seen, drawnCalls, draw, wrap: () => host.querySelector<HTMLElement>(".acpmux-plan-ask") };
}

test("a plan ask enters under the Needs your input pill and its dot", async () => {
  transitionDuration = "0.265s";
  const { host, root, draw, wrap } = mount();
  await draw(plan);
  expect(wrap()?.dataset.presence).toBe("shown");
  expect(wrap()?.dataset.enter).toBe("bottom");
  const pill = host.querySelector(".acpmux-plan-ask-status");
  expect(pill?.textContent).toBe(translate("question.needsInput"));
  expect(pill?.querySelector(".acpmux-needs-you-dot")).not.toBeNull();
  expect(host.querySelector(".card")?.textContent).toBe("plan-1");
  act(() => root.unmount());
});

test("an answered plan stays drawn, inert, until its exit ends", async () => {
  transitionDuration = "0.265s";
  const { host, root, seen, drawnCalls, draw, wrap } = mount();
  await draw(plan);
  await draw(undefined);
  expect(wrap()?.dataset.presence).toBe("leaving");
  // The stack around it stays while the exit plays (App.tsx `bottomAsks`).
  expect(drawnCalls).toEqual([true]);
  expect(wrap()?.hasAttribute("inert")).toBe(true);
  expect(host.querySelector(".card")?.textContent).toBe("plan-1");
  expect(seen.at(-1)).toBe(true);
  await act(async () => {
    wrap()!.dispatchEvent(new dom.window.Event("transitionend"));
  });
  expect(wrap()).toBeNull();
  expect(drawnCalls).toEqual([true, false]);
  act(() => root.unmount());
});

test("a new plan during the exit comes back at once, drawn as the new ask", async () => {
  transitionDuration = "0.265s";
  const { host, root, seen, draw, wrap } = mount();
  await draw(plan);
  await draw(undefined);
  await draw({ ...plan, permissionId: "plan-2" });
  expect(wrap()?.dataset.presence).toBe("shown");
  expect(wrap()?.hasAttribute("inert")).toBe(false);
  expect(host.querySelector(".card")?.textContent).toBe("plan-2");
  expect(seen.at(-1)).toBe(false);
  act(() => root.unmount());
});

test("switching to a chat without a plan drops the last chat's plan at once", async () => {
  transitionDuration = "0.265s";
  const { host, root, drawnCalls, draw, wrap } = mount();
  await draw(plan, "chat-1");
  await draw(undefined, "chat-2");
  expect(wrap()).toBeNull();
  expect(host.querySelector(".card")).toBeNull();
  expect(drawnCalls.at(-1)).toBe(false);
  act(() => root.unmount());
});

test("with motion off an answered plan goes at once", async () => {
  transitionDuration = "0s";
  const { root, draw, wrap } = mount();
  await draw(plan);
  await draw(undefined);
  expect(wrap()).toBeNull();
  act(() => root.unmount());
});
