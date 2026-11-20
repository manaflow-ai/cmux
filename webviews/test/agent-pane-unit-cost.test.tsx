// l10n-allow-file: test fixtures, not shipped UI.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { settleReact } from "./support/domTeardown";
import { experimentArm } from "../src/experiments/experiment";
import { unitCost } from "../src/agent-session/acpmux/unitCost/unitCost.experiment";
import { experimentById } from "../src/experiments/registry";
const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
  "cmuxExperiments",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/history/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) if (name !== "cmuxExperiments") scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
  host = dom.window.document.getElementById("root")!;
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

test("unit-cost stays off without explicit activation, including stale overrides", () => {
  expect(experimentById("unit-cost")).toBe(unitCost);
  expect(experimentArm(unitCost, { overrides: {}, stored: {} })).toBe("off");
  expect(experimentArm(unitCost, { overrides: { "unit-cost": "unknown" }, stored: {} })).toBe("off");
  expect(experimentArm(unitCost, { overrides: { "unit-cost": "on" }, stored: {} })).toBe("on");
});

test("History hides the calculator by default and makes no estimate request", async () => {
  const { HistoryScreen } = await import("../src/agent-session/acpmux/newtab/HistoryScreen");
  let calls = 0;
  const root = createRoot(host);
  const props = {
    load: async () => ({ ready: true, chats: [] }),
    onOpen: () => {},
    unitCost: {
      load: async () => {
        calls++;
        return { costUsd: 1 };
      },
    },
  };
  scope.cmuxExperiments = {};
  await act(async () => root.render(<HistoryScreen {...props} initialTab="unitCost" />));
  expect(host.querySelector(".ucs")).toBeNull();
  expect(host.textContent).not.toContain("Unit cost");
  scope.cmuxExperiments = { "unit-cost": "on" };
  await act(async () => root.render(<HistoryScreen {...props} initialTab="unitCost" />));
  expect(host.querySelector(".ucs")).not.toBeNull();
  expect(calls).toBe(0);
  await act(async () => root.unmount());
});

test("missing and nonfinite replies never appear as a zero estimate; older daemons explain the update", async () => {
  const { UnitCostScreen } = await import("../src/agent-session/acpmux/unitCost/UnitCostScreen");
  for (const load of [
    async () => null,
    async () => ({ costUsd: NaN }),
    async () => ({ costUsd: -1 }),
    async () => {
      throw { code: -32601 };
    },
  ]) {
    const root = createRoot(host);
    await act(async () => root.render(<UnitCostScreen load={load} />));
    await act(async () =>
      host.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })),
    );
    expect(host.querySelector("output")!.textContent).not.toContain("$0");
    expect(host.querySelector("output")!.textContent!.length).toBeGreaterThan(0);
    await act(async () => root.unmount());
  }
});

test("a reply after unmount cannot update a later estimate", async () => {
  const { UnitCostScreen } = await import("../src/agent-session/acpmux/unitCost/UnitCostScreen");
  let release: (value: unknown) => void = () => undefined;
  const first = createRoot(host);
  await act(async () =>
    first.render(
      <UnitCostScreen
        load={() =>
          new Promise((resolve) => {
            release = resolve;
          })
        }
      />,
    ),
  );
  await act(async () =>
    host.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })),
  );
  await act(async () => first.unmount());
  const second = createRoot(host);
  await act(async () => second.render(<UnitCostScreen load={async () => ({ costUsd: 0.25 })} />));
  await act(async () =>
    host.querySelector("form")!.dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })),
  );
  await act(async () => release({ costUsd: 999 }));
  expect(host.querySelector("output")!.textContent).toBe("$0.25");
  await act(async () => second.unmount());
});
