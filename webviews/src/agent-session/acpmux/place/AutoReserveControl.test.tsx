// Auto on reserve (RFD 0072, stage 1: shadow). Leo, 2026-11-23: "we should be able to auto-detect if your
// computer is under load, true load, OR if they're affecting interactive speed". The verdict is Rust's
// (cmux-host-budget reserve.rs); the page draws the setting and the last would-be move, and moves nothing.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { UiProvider } from "../../../ui/UiProvider";
import { settleReact } from "../../../../test/support/domTeardown";
import { translate } from "../i18n";
import { AutoReserveControl, type AutoReserveLook } from "./AutoReserveControl";
import { PlaceControl } from "./PlaceControl";
import { PLACES, RESERVES } from "./fixtures";
import { placeOf, reserveOf, type AutoReserveState } from "./placeModel";

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

test("place.reserve is read from the wire, a keep snaps down to a stop, and a bad one is none", () => {
  expect(reserveOf(undefined)).toBeUndefined();
  expect(reserveOf({ keep: 0.5 })).toBeUndefined();
  expect(reserveOf({ on: true, keep: 0.49 })).toEqual({ on: true, keep: 0.25 });
  expect(reserveOf({ on: false })).toEqual({ on: false, keep: 0.5 });
  expect(reserveOf({ on: true, keep: 0.75, shadow: { title: "T", reason: "memory", atMs: 5 } })).toEqual({
    on: true,
    keep: 0.75,
    shadow: { title: "T", reason: "memory", atMs: 5 },
  });
  expect(reserveOf({ on: true, keep: 0.5, shadow: { title: "T", reason: "load" } })).toEqual({ on: true, keep: 0.5 });
  expect(placeOf({ mode: "auto", at: "local", reserve: { on: true, keep: 0.5 } })?.reserve).toEqual({
    on: true,
    keep: 0.5,
  });
});

test("a stop and the switch each report the whole setting; off dims the stops", async () => {
  const changes: { on: boolean; keep: number }[] = [];
  const view = await draw(<AutoReserveControl reserve={RESERVES.on} onChange={(next) => changes.push(next)} />);
  await act(async () => view.querySelector<HTMLButtonElement>('[data-testid="reserve-keep-0.25"]')!.click());
  expect(changes).toEqual([{ on: true, keep: 0.25 }]);
  expect(view.textContent).toContain(translate("placeReserve.trial"));
  await act(async () => root!.render(<AutoReserveControl reserve={RESERVES.off} onChange={() => undefined} />));
  expect(view.querySelector<HTMLButtonElement>('[data-testid="reserve-keep-0.25"]')!.disabled).toBe(true);
  expect(view.textContent).not.toContain(translate("placeReserve.trial"));
});

test("the card says what would have moved, never that it moved", async () => {
  for (const [reserve, key] of [
    [RESERVES.wouldMove, "placeReserve.wouldMoveCpu"],
    [RESERVES.on, "placeReserve.noneYet"],
  ] as [AutoReserveState, string][]) {
    const view = await draw(
      <AutoReserveControl look={"card" as AutoReserveLook} reserve={reserve} onChange={() => undefined} />,
    );
    const line = view.querySelector('[data-testid="reserve-shadow"]')!.textContent ?? "";
    if (key === "placeReserve.noneYet") expect(line).toBe(translate("placeReserve.noneYet"));
    else expect(line).toContain("Port the settings page");
    await act(async () => root!.unmount());
    root = undefined;
  }
});

test("the place control draws the reserve under Auto only, when the app sends it", async () => {
  const view = await draw(
    <PlaceControl place={PLACES.autoReserve} onMode={() => undefined} onReserve={() => undefined} />,
  );
  expect(view.querySelector('[data-testid="reserve-on"]')).not.toBeNull();
  await act(async () =>
    root!.render(
      <PlaceControl
        place={{ ...PLACES.autoReserve, mode: "local" }}
        onMode={() => undefined}
        onReserve={() => undefined}
      />,
    ),
  );
  expect(view.querySelector('[data-testid="reserve-on"]')).toBeNull();
  await act(async () => root!.render(<PlaceControl place={PLACES.autoReserve} onMode={() => undefined} />));
  expect(view.querySelector('[data-testid="reserve-on"]')).toBeNull();
});
