// Auto's setting and last move (RFD 0072, piece 6). Leo, 2026-11-24: "we should be able to auto-detect if
// your computer is under load, true load, OR if they're affecting interactive speed (idk we can figure out
// limits/heuristics/have a setting toggling/slider?)". The verdict is Rust's; the page draws the setting,
// the last move with its reason, Bring Back and Cancel, and the pool at 80%.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { UiProvider } from "../../../ui/UiProvider";
import { settleReact } from "../../../../test/support/domTeardown";
import { translate } from "../i18n";
import { AutoReserveControl, MovedChip, lastMoveText, movedChipText } from "./AutoReserveControl";
import { AutoReserveGallery } from "./AutoReserveControl.gallery";
import { poolLevel, snapReserve, type AutoReserveState } from "./autoReserveModel";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

async function draw(node: React.ReactNode): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  await act(async () => root!.render(<UiProvider container={container}>{node}</UiProvider>));
  return container;
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

const AT = Date.UTC(2026, 10, 24, 11, 2, 0);
const MOVED = { title: "Port the settings page", reason: "cpu", atMs: AT, state: "moved" } as const;
const on = (extra: Partial<AutoReserveState> = {}): AutoReserveState => ({ on: true, keep: 0.5, ...extra });

test("a keep snaps down to one of four stops, and the pool shows from 80%", () => {
  expect(snapReserve(0.49)).toBe(0.25);
  expect(snapReserve(0.75)).toBe(0.75);
  expect(snapReserve(9)).toBe(0.75);
  expect(snapReserve(undefined)).toBe(0.5);
  expect(snapReserve(-1)).toBe(0);
  expect(poolLevel(undefined)).toBe("ok");
  expect(poolLevel(0.79)).toBe("ok");
  expect(poolLevel(0.8)).toBe("near");
  expect(poolLevel(1)).toBe("ceiling");
});

async function setStop(view: HTMLElement, stop: number) {
  const slider = view.querySelector<HTMLInputElement>('[data-testid="reserve-slider"]')!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(slider, String(stop));
    slider.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
}

test("the slider and switch emit and redraw the whole normalized setting", async () => {
  const changes: { on: boolean; keep: number }[] = [];
  function Host() {
    const [reserve, setReserve] = useState(on({ keep: 0.49 }));
    return (
      <AutoReserveControl
        reserve={reserve}
        onChange={(next) => {
          changes.push(next);
          setReserve(next);
        }}
      />
    );
  }
  const view = await draw(<Host />);
  const slider = view.querySelector<HTMLInputElement>('[data-testid="reserve-slider"]')!;
  const toggle = view.querySelector<HTMLButtonElement>('[data-testid="reserve-on"]')!;
  expect(slider.max).toBe("3");
  expect(slider.value).toBe("1");
  expect(slider.getAttribute("aria-valuetext")).toBe("25%");
  expect(view.querySelector('.acpmux-reserve-ticks [data-on="true"]')!.textContent).toBe("25%");
  await act(async () => toggle.click());
  expect(changes).toEqual([{ on: false, keep: 0.25 }]);
  expect(toggle.getAttribute("aria-checked")).toBe("false");
  expect(slider.disabled).toBe(true);
  expect(view.querySelector('[data-testid="reserve-last-move"]')).toBeNull();
  await act(async () => toggle.click());
  expect(slider.disabled).toBe(false);
  for (const [index, keep] of [0, 0.25, 0.5, 0.75].entries()) {
    await setStop(view, index);
    expect(changes.at(-1)).toEqual({ on: true, keep });
    expect(slider.value).toBe(String(index));
    expect(slider.getAttribute("aria-valuetext")).toBe(`${keep * 100}%`);
  }
});

test("gallery controls update their displayed state and clear the simulated move", async () => {
  const view = await draw(<AutoReserveGallery reserve={on({ lastMove: MOVED })} />);
  await setStop(view, 3);
  expect(view.querySelector('[data-testid="reserve-slider"]')!.getAttribute("aria-valuetext")).toBe("75%");
  await act(async () => view.querySelector<HTMLButtonElement>('[data-testid="reserve-bring-back"]')!.click());
  expect(view.querySelector('[data-testid="reserve-last-move"]')!.textContent).toBe(translate("autoReserve.noMove"));
  await act(async () => view.querySelector<HTMLButtonElement>('[data-testid="reserve-on"]')!.click());
  expect(view.querySelector<HTMLInputElement>('[data-testid="reserve-slider"]')!.disabled).toBe(true);
});

test("the line names the last move and its reason; Bring Back and Cancel are one click", async () => {
  let back = 0;
  let cancel = 0;
  const view = await draw(
    <AutoReserveControl
      reserve={on({ lastMove: MOVED })}
      onChange={() => undefined}
      onBringBack={() => (back += 1)}
      onCancel={() => (cancel += 1)}
    />,
  );
  const line = view.querySelector('[data-testid="reserve-last-move"]')!.textContent ?? "";
  expect(line).toContain("Port the settings page");
  expect(line).toContain(translate("autoReserve.reasonCpu"));
  expect(view.querySelector('[data-testid="reserve-cancel"]')).toBeNull();
  await act(async () => view.querySelector<HTMLButtonElement>('[data-testid="reserve-bring-back"]')!.click());
  expect(back).toBe(1);
  await act(async () =>
    root!.render(
      <AutoReserveControl
        reserve={on({ lastMove: { ...MOVED, state: "moving" } })}
        onChange={() => undefined}
        onBringBack={() => (back += 1)}
        onCancel={() => (cancel += 1)}
      />,
    ),
  );
  expect(view.querySelector('[data-testid="reserve-bring-back"]')).toBeNull();
  await act(async () => view.querySelector<HTMLButtonElement>('[data-testid="reserve-cancel"]')!.click());
  expect([back, cancel]).toEqual([1, 1]);
  expect(lastMoveText({ ...MOVED, reason: "memory" }, (key, values) => translate(key, values))).toContain(
    translate("autoReserve.reasonMemory"),
  );
});

test("the chat's chip says where, why and when, in the words of the line", async () => {
  const text = movedChipText(MOVED, (key, values) => translate(key, values));
  expect(text.startsWith("Moved to Cloud: Mac was busy, ")).toBe(true);
  const view = await draw(<MovedChip move={MOVED} />);
  expect(view.querySelector('[data-testid="reserve-chip"]')!.textContent).toBe(text);
});

test("the pool shows at 80% and at the ceiling, and not below", async () => {
  const view = await draw(<AutoReserveControl reserve={on({ pool: 0.5 })} onChange={() => undefined} />);
  expect(view.querySelector('[data-testid="reserve-pool"]')).toBeNull();
  await act(async () => root!.render(<AutoReserveControl reserve={on({ pool: 0.8 })} onChange={() => undefined} />));
  expect(view.querySelector('[data-testid="reserve-pool"]')!.textContent).toContain("80%");
  await act(async () => root!.render(<AutoReserveControl reserve={on({ pool: 1 })} onChange={() => undefined} />));
  expect(view.querySelector('[data-testid="reserve-pool"]')!.textContent).toBe(translate("autoReserve.ceiling"));
});
